use std::{
    backtrace::Backtrace,
    collections::VecDeque,
    fs,
    path::{Path, PathBuf},
    sync::{OnceLock, RwLock},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use tracing::{info, warn};
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::{fmt, EnvFilter};

use crate::{
    config::{AppConfig, AppPaths},
    platform::WindowBackend,
};

static PATHS: OnceLock<AppPaths> = OnceLock::new();
static RECENT_EVENTS: OnceLock<RwLock<VecDeque<String>>> = OnceLock::new();
type FilterReload = dyn Fn(&str) -> std::result::Result<(), String> + Send + Sync;
static FILTER_RELOAD: OnceLock<Box<FilterReload>> = OnceLock::new();

pub struct LogGuard {
    _file_guard: WorkerGuard,
}

pub fn init(paths: &AppPaths) -> Result<LogGuard> {
    PATHS.set(paths.clone()).ok();
    RECENT_EVENTS.get_or_init(|| RwLock::new(VecDeque::with_capacity(128)));
    cleanup_logs(&paths.logs_dir, 14, 20)?;

    let file_appender = tracing_appender::rolling::daily(&paths.logs_dir, "topfade.log");
    let (file_writer, file_guard) = tracing_appender::non_blocking(file_appender);
    let level = initial_log_level(paths);
    let filter = EnvFilter::try_new(&level).unwrap_or_else(|_| EnvFilter::new("info"));
    let subscriber = fmt()
        .with_ansi(false)
        .with_target(true)
        .with_thread_ids(true)
        .with_writer(file_writer)
        .with_env_filter(filter)
        .with_filter_reloading();
    let reload_handle = subscriber.reload_handle();
    subscriber
        .try_init()
        .map_err(|error| anyhow::anyhow!("failed to install the tracing subscriber: {error}"))?;
    let _ = FILTER_RELOAD.set(Box::new(move |level| {
        let filter = EnvFilter::try_new(level).map_err(|error| error.to_string())?;
        reload_handle
            .reload(filter)
            .map_err(|error| error.to_string())
    }));

    record_event(format!("startup version={}", env!("CARGO_PKG_VERSION")));
    info!(log_level = %level, path = %paths.logs_dir.display(), "logging initialized");
    Ok(LogGuard {
        _file_guard: file_guard,
    })
}

pub fn set_log_level(level: &str) -> Result<()> {
    let reload = FILTER_RELOAD
        .get()
        .context("log filter reload handle is unavailable")?;
    reload(level).map_err(anyhow::Error::msg)?;
    info!(log_level = %level, "log level changed");
    Ok(())
}

pub fn record_event(message: impl Into<String>) {
    let message = message.into();
    if let Some(events) = RECENT_EVENTS.get() {
        if let Ok(mut events) = events.write() {
            if events.len() >= 128 {
                events.pop_front();
            }
            events.push_back(format!("{} {message}", epoch_millis()));
        }
    }
}

pub fn install_panic_hook(paths: AppPaths) {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |panic_info| {
        let crash_path = paths.logs_dir.join(format!("crash-{}.log", epoch_millis()));
        let location = panic_info.location().map_or_else(
            || "unknown".into(),
            |location| {
                format!(
                    "{}:{}:{}",
                    location.file(),
                    location.line(),
                    location.column()
                )
            },
        );
        let payload = panic_info.payload().downcast_ref::<&str>().map_or_else(
            || {
                panic_info
                    .payload()
                    .downcast_ref::<String>()
                    .cloned()
                    .unwrap_or_else(|| "non-string panic payload".into())
            },
            |message| (*message).to_string(),
        );
        let recent = recent_events().join("\n");
        let report = format!(
            "TopFade crash report\nversion={}\nos={}\nlocation={}\npanic={}\n\nrecent events:\n{}\n\nbacktrace:\n{}\n",
            env!("CARGO_PKG_VERSION"),
            std::env::consts::OS,
            location,
            payload,
            recent,
            Backtrace::force_capture(),
        );
        let _ = fs::write(&crash_path, report);
        previous(panic_info);
    }));
}

pub fn write_fatal_report(error: &anyhow::Error) -> Result<PathBuf> {
    let paths = PATHS.get().context("diagnostic paths are unavailable")?;
    let path = paths.logs_dir.join(format!("fatal-{}.log", epoch_millis()));
    let report = format!(
        "TopFade fatal error\nversion={}\nos={}\nerror={error:#}\n\nbacktrace:\n{}\n\nrecent events:\n{}\n",
        env!("CARGO_PKG_VERSION"),
        std::env::consts::OS,
        Backtrace::force_capture(),
        recent_events().join("\n"),
    );
    fs::write(&path, report).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(path)
}

pub fn export_report(
    paths: &AppPaths,
    backend: &dyn WindowBackend,
    config: Option<&AppConfig>,
) -> Result<PathBuf> {
    let path = paths
        .reports_dir
        .join(format!("diagnostic-{}.txt", epoch_millis()));
    let windows = backend.enumerate_windows();
    let window_section = match windows {
        Ok(windows) => windows
            .iter()
            .map(|window| {
                format!(
                    "id=0x{:X} pid={} topmost={} opacity={} title={:?} executable={:?}",
                    window.id.0,
                    window.process_id,
                    window.topmost,
                    window.opacity_percent,
                    window.title,
                    window.executable,
                )
            })
            .collect::<Vec<_>>()
            .join("\n"),
        Err(error) => format!("window enumeration failed: {error:#}"),
    };
    let config_section = config.map_or_else(
        || "not supplied".into(),
        |config| serde_json::to_string_pretty(config).unwrap_or_else(|error| error.to_string()),
    );
    let report = format!(
        "TopFade diagnostic report\ncreated_epoch_ms={}\nversion={}\nos={}\narch={}\nplatform_backend={}\npermission_status={}\ndata_dir={}\n\nCONFIG\n{}\n\nWINDOWS\n{}\n\nRECENT EVENTS\n{}\n",
        epoch_millis(),
        env!("CARGO_PKG_VERSION"),
        std::env::consts::OS,
        std::env::consts::ARCH,
        backend.platform_name(),
        backend.permission_status(),
        paths.data_dir.display(),
        config_section,
        window_section,
        recent_events().join("\n"),
    );
    fs::write(&path, report).with_context(|| format!("failed to write {}", path.display()))?;
    info!(path = %path.display(), "diagnostic report exported");
    Ok(path)
}

pub fn cleanup_logs(log_dir: &Path, retention_days: u16, max_total_mb: u16) -> Result<()> {
    let mut files = fs::read_dir(log_dir)
        .with_context(|| format!("failed to read {}", log_dir.display()))?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let metadata = entry.metadata().ok()?;
            metadata.is_file().then_some((entry.path(), metadata))
        })
        .collect::<Vec<_>>();
    let cutoff = SystemTime::now()
        .checked_sub(Duration::from_secs(u64::from(retention_days) * 86_400))
        .unwrap_or(UNIX_EPOCH);

    for (path, metadata) in &files {
        if metadata.modified().unwrap_or(SystemTime::now()) < cutoff {
            if let Err(error) = fs::remove_file(path) {
                warn!(path = %path.display(), %error, "old log cleanup failed");
            }
        }
    }

    files.retain(|(path, _)| path.exists());
    files.sort_by_key(|(_, metadata)| metadata.modified().unwrap_or(UNIX_EPOCH));
    let max_bytes = u64::from(max_total_mb) * 1024 * 1024;
    let mut total = files
        .iter()
        .map(|(_, metadata)| metadata.len())
        .sum::<u64>();
    for (path, metadata) in files {
        if total <= max_bytes {
            break;
        }
        if fs::remove_file(&path).is_ok() {
            total = total.saturating_sub(metadata.len());
        }
    }
    Ok(())
}

fn recent_events() -> Vec<String> {
    RECENT_EVENTS
        .get()
        .and_then(|events| {
            events
                .read()
                .ok()
                .map(|events| events.iter().cloned().collect())
        })
        .unwrap_or_default()
}

fn epoch_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

fn initial_log_level(paths: &AppPaths) -> String {
    if let Ok(level) = std::env::var("TOPFADE_LOG") {
        return level;
    }
    fs::read_to_string(&paths.config_file)
        .ok()
        .and_then(|raw| serde_json::from_str::<AppConfig>(&raw).ok())
        .map_or_else(|| "info".into(), |config| config.diagnostics.log_level)
}
