use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use directories::BaseDirs;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use tracing::{info, warn};

const CONFIG_SCHEMA_VERSION: u32 = 2;
const RUNTIME_STATE_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone)]
pub struct AppPaths {
    pub data_dir: PathBuf,
    pub config_file: PathBuf,
    pub state_file: PathBuf,
    pub logs_dir: PathBuf,
    pub reports_dir: PathBuf,
}

impl AppPaths {
    pub fn discover() -> Result<Self> {
        let base = BaseDirs::new().context("OS did not provide a user profile directory")?;
        let data_dir = std::env::var_os("TOPFADE_DATA_DIR")
            .map_or_else(|| base.data_local_dir().join("TopFade"), PathBuf::from);
        let paths = Self {
            config_file: data_dir.join("config.json"),
            state_file: data_dir.join("state.json"),
            logs_dir: data_dir.join("logs"),
            reports_dir: data_dir.join("reports"),
            data_dir,
        };
        fs::create_dir_all(&paths.logs_dir)
            .context("failed to create the TopFade log directory")?;
        fs::create_dir_all(&paths.reports_dir)
            .context("failed to create the TopFade report directory")?;
        Ok(paths)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct AppConfig {
    pub schema_version: u32,
    pub hotkeys: HotkeyConfig,
    pub opacity: OpacityConfig,
    pub behavior: BehaviorConfig,
    pub appearance: AppearanceConfig,
    pub diagnostics: DiagnosticsConfig,
    pub rules: Vec<WindowRule>,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            schema_version: CONFIG_SCHEMA_VERSION,
            hotkeys: HotkeyConfig::default(),
            opacity: OpacityConfig::default(),
            behavior: BehaviorConfig::default(),
            appearance: AppearanceConfig::default(),
            diagnostics: DiagnosticsConfig::default(),
            rules: Vec::new(),
        }
    }
}

impl AppConfig {
    pub fn load(paths: &AppPaths) -> Self {
        load_document(&paths.config_file)
    }

    pub fn save(&self, paths: &AppPaths) -> Result<()> {
        atomic_write_json(&paths.config_file, self)
            .context("failed to save TopFade configuration")?;
        info!(path = %paths.config_file.display(), "configuration saved");
        Ok(())
    }

    pub fn sanitize(&mut self) {
        if self.schema_version < 2 {
            self.behavior.start_minimized = true;
            self.behavior.launch_at_login = true;
        }
        self.schema_version = CONFIG_SCHEMA_VERSION;
        self.opacity.minimum_percent = self.opacity.minimum_percent.clamp(10, 95);
        self.opacity.step_percent = self.opacity.step_percent.clamp(1, 25);
        self.opacity.overlay_duration_ms = self.opacity.overlay_duration_ms.clamp(300, 5_000);
        self.diagnostics.retention_days = self.diagnostics.retention_days.clamp(1, 90);
        self.diagnostics.max_total_mb = self.diagnostics.max_total_mb.clamp(2, 250);
        self.diagnostics.log_level = match self.diagnostics.log_level.to_ascii_lowercase().as_str()
        {
            "trace" => "trace",
            "debug" => "debug",
            "warn" => "warn",
            "error" => "error",
            _ => "info",
        }
        .into();
        for rule in &mut self.rules {
            rule.opacity_percent = rule.opacity_percent.clamp(10, 100);
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct HotkeyConfig {
    pub toggle_topmost: String,
    pub show_preferences: String,
}

impl Default for HotkeyConfig {
    fn default() -> Self {
        Self {
            toggle_topmost: "Control+Super+KeyT".into(),
            show_preferences: "Control+Alt+Comma".into(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct OpacityConfig {
    pub minimum_percent: u8,
    pub step_percent: u8,
    pub show_overlay: bool,
    pub overlay_duration_ms: u64,
    #[serde(alias = "consume_ctrl_shift_wheel")]
    pub consume_alt_shift_wheel: bool,
    pub target_under_cursor: bool,
}

impl Default for OpacityConfig {
    fn default() -> Self {
        Self {
            minimum_percent: 20,
            step_percent: 5,
            show_overlay: true,
            overlay_duration_ms: 1_250,
            consume_alt_shift_wheel: true,
            target_under_cursor: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct BehaviorConfig {
    pub remember_pinned_windows: bool,
    pub restore_when_apps_reopen: bool,
    pub close_to_tray: bool,
    pub start_minimized: bool,
    pub launch_at_login: bool,
    pub confirm_click_through: bool,
}

impl Default for BehaviorConfig {
    fn default() -> Self {
        Self {
            remember_pinned_windows: true,
            restore_when_apps_reopen: true,
            close_to_tray: true,
            start_minimized: true,
            launch_at_login: true,
            confirm_click_through: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct AppearanceConfig {
    pub accent_rgb: [u8; 3],
    pub show_window_title_in_overlay: bool,
}

impl Default for AppearanceConfig {
    fn default() -> Self {
        Self {
            accent_rgb: [232, 91, 63],
            show_window_title_in_overlay: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct DiagnosticsConfig {
    pub log_level: String,
    pub retention_days: u16,
    pub max_total_mb: u16,
}

impl Default for DiagnosticsConfig {
    fn default() -> Self {
        Self {
            log_level: "info".into(),
            retention_days: 14,
            max_total_mb: 20,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct WindowRule {
    pub name: String,
    pub executable_contains: String,
    pub title_contains: String,
    pub auto_pin: bool,
    pub opacity_percent: u8,
    pub exclude: bool,
}

impl Default for WindowRule {
    fn default() -> Self {
        Self {
            name: "New rule".into(),
            executable_contains: String::new(),
            title_contains: String::new(),
            auto_pin: false,
            opacity_percent: 100,
            exclude: false,
        }
    }
}

impl WindowRule {
    pub fn matches(&self, executable: &str, title: &str) -> bool {
        let executable_pattern = self.executable_contains.trim();
        let title_pattern = self.title_contains.trim();
        let exe_match = executable_pattern.is_empty()
            || executable
                .to_lowercase()
                .contains(&executable_pattern.to_lowercase());
        let title_match = title_pattern.is_empty()
            || title.to_lowercase().contains(&title_pattern.to_lowercase());
        exe_match && title_match
    }

    pub fn has_automatic_action(&self) -> bool {
        !self.exclude && (self.auto_pin || self.opacity_percent < 100)
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct RuntimeState {
    pub schema_version: u32,
    pub remembered_windows: Vec<RememberedWindow>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RememberedWindow {
    pub executable: String,
    pub title_hint: String,
    pub topmost: bool,
    pub opacity_percent: u8,
}

impl RuntimeState {
    pub fn load(paths: &AppPaths) -> Self {
        load_document(&paths.state_file)
    }

    pub fn save(&self, paths: &AppPaths) -> Result<()> {
        atomic_write_json(&paths.state_file, self).context("failed to save runtime state")
    }

    fn fresh() -> Self {
        Self {
            schema_version: RUNTIME_STATE_SCHEMA_VERSION,
            remembered_windows: Vec::new(),
        }
    }

    fn sanitize(&mut self) {
        self.schema_version = RUNTIME_STATE_SCHEMA_VERSION;
        self.remembered_windows
            .retain(|window| !window.executable.trim().is_empty());
        for window in &mut self.remembered_windows {
            window.opacity_percent = window.opacity_percent.clamp(10, 100);
        }
    }

    pub fn remember_window(&mut self, window: RememberedWindow) -> bool {
        if window.executable.trim().is_empty() {
            return false;
        }
        if !window.topmost && window.opacity_percent >= 100 {
            return self.forget_executable(&window.executable);
        }

        if let Some(existing) = self
            .remembered_windows
            .iter_mut()
            .find(|entry| entry.executable.eq_ignore_ascii_case(&window.executable))
        {
            if *existing == window {
                return false;
            }
            *existing = window;
        } else {
            self.remembered_windows.push(window);
        }
        true
    }

    pub fn update_opacity(
        &mut self,
        executable: &str,
        title_hint: &str,
        opacity_percent: u8,
    ) -> bool {
        let Some(index) = self
            .remembered_windows
            .iter()
            .position(|entry| entry.executable.eq_ignore_ascii_case(executable))
        else {
            return false;
        };

        let opacity_percent = opacity_percent.clamp(10, 100);
        if !self.remembered_windows[index].topmost && opacity_percent >= 100 {
            self.remembered_windows.remove(index);
            return true;
        }

        let entry = &mut self.remembered_windows[index];
        let changed = entry.opacity_percent != opacity_percent || entry.title_hint != title_hint;
        entry.opacity_percent = opacity_percent;
        title_hint.clone_into(&mut entry.title_hint);
        changed
    }

    pub fn forget_executable(&mut self, executable: &str) -> bool {
        let previous_len = self.remembered_windows.len();
        self.remembered_windows
            .retain(|entry| !entry.executable.eq_ignore_ascii_case(executable));
        self.remembered_windows.len() != previous_len
    }

    pub fn clear_remembered(&mut self) -> bool {
        if self.remembered_windows.is_empty() {
            return false;
        }
        self.remembered_windows.clear();
        true
    }
}

trait PersistedDocument: Clone + PartialEq + Serialize + DeserializeOwned + Sized {
    const KIND: &'static str;

    fn fresh_document() -> Self;
    fn validate_and_sanitize(&mut self) -> Result<()>;
}

impl PersistedDocument for AppConfig {
    const KIND: &'static str = "configuration";

    fn fresh_document() -> Self {
        Self::default()
    }

    fn validate_and_sanitize(&mut self) -> Result<()> {
        if self.schema_version > CONFIG_SCHEMA_VERSION {
            anyhow::bail!(
                "unsupported configuration schema {}; this build supports up to {}",
                self.schema_version,
                CONFIG_SCHEMA_VERSION
            );
        }
        self.sanitize();
        Ok(())
    }
}

impl PersistedDocument for RuntimeState {
    const KIND: &'static str = "runtime state";

    fn fresh_document() -> Self {
        Self::fresh()
    }

    fn validate_and_sanitize(&mut self) -> Result<()> {
        if self.schema_version > RUNTIME_STATE_SCHEMA_VERSION {
            anyhow::bail!(
                "unsupported runtime-state schema {}; this build supports up to {}",
                self.schema_version,
                RUNTIME_STATE_SCHEMA_VERSION
            );
        }
        self.sanitize();
        Ok(())
    }
}

fn parse_document<T: PersistedDocument>(raw: &str) -> Result<(T, bool)> {
    let mut value = serde_json::from_str::<T>(raw)?;
    let original = value.clone();
    value.validate_and_sanitize()?;
    let normalized = value != original;
    Ok((value, normalized))
}

fn load_backup<T: PersistedDocument>(path: &Path) -> Option<T> {
    let backup = path.with_extension("bak");
    match fs::read_to_string(&backup) {
        Ok(raw) => match parse_document::<T>(&raw) {
            Ok((value, _)) => {
                info!(
                    path = %path.display(),
                    backup = %backup.display(),
                    kind = T::KIND,
                    "recovered persisted document from backup"
                );
                Some(value)
            }
            Err(error) => {
                warn!(
                    path = %path.display(),
                    backup = %backup.display(),
                    kind = T::KIND,
                    error = %format!("{error:#}"),
                    "persisted-document backup is invalid"
                );
                None
            }
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => {
            warn!(
                path = %path.display(),
                backup = %backup.display(),
                kind = T::KIND,
                %error,
                "persisted-document backup could not be read"
            );
            None
        }
    }
}

fn load_document<T: PersistedDocument>(path: &Path) -> T {
    match fs::read_to_string(path) {
        Ok(raw) => match parse_document::<T>(&raw) {
            Ok((value, normalized)) => {
                if normalized {
                    if let Err(error) = atomic_write_json(path, &value) {
                        warn!(
                            path = %path.display(),
                            kind = T::KIND,
                            error = %format!("{error:#}"),
                            "normalized persisted document could not be written back"
                        );
                    } else {
                        info!(
                            path = %path.display(),
                            kind = T::KIND,
                            "persisted document was normalized and upgraded"
                        );
                    }
                }
                info!(path = %path.display(), kind = T::KIND, "persisted document loaded");
                value
            }
            Err(error) => {
                warn!(
                    path = %path.display(),
                    kind = T::KIND,
                    error = %format!("{error:#}"),
                    "persisted document is invalid"
                );
                let value = load_backup(path).unwrap_or_else(T::fresh_document);
                preserve_invalid_and_repair(path, &value);
                value
            }
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let value = load_backup(path).unwrap_or_else(T::fresh_document);
            if let Err(save_error) = write_json(path, &value, false) {
                warn!(
                    path = %path.display(),
                    kind = T::KIND,
                    error = %format!("{save_error:#}"),
                    "initial or recovered persisted document could not be saved"
                );
            }
            value
        }
        Err(error) => {
            warn!(
                path = %path.display(),
                kind = T::KIND,
                %error,
                "persisted document read failed"
            );
            load_backup(path).unwrap_or_else(T::fresh_document)
        }
    }
}

fn atomic_write_json(path: &Path, value: &impl Serialize) -> Result<()> {
    write_json(path, value, true)
}

fn preserve_invalid_and_repair(path: &Path, value: &impl Serialize) {
    let invalid = path.with_extension("json.invalid");
    if let Err(error) = fs::copy(path, &invalid) {
        warn!(path = %path.display(), backup = %invalid.display(), %error, "invalid file backup failed; original left unchanged");
        return;
    }
    if let Err(error) = write_json(path, value, false) {
        warn!(path = %path.display(), backup = %invalid.display(), error = %format!("{error:#}"), "invalid file repair failed; preserved copy is available");
    } else {
        info!(path = %path.display(), backup = %invalid.display(), "invalid file preserved and repaired with a validated recovery value");
    }
}

fn write_json(path: &Path, value: &impl Serialize, keep_backup: bool) -> Result<()> {
    let raw = serde_json::to_vec_pretty(value)?;
    let temporary = path.with_extension("tmp");
    let result = (|| -> Result<()> {
        let mut file = fs::File::create(&temporary)
            .with_context(|| format!("failed to create {}", temporary.display()))?;
        file.write_all(&raw)
            .with_context(|| format!("failed to write {}", temporary.display()))?;
        file.sync_all()
            .with_context(|| format!("failed to flush {}", temporary.display()))?;
        drop(file);
        if keep_backup && path.exists() {
            let backup = path.with_extension("bak");
            fs::copy(path, &backup)
                .with_context(|| format!("failed to create backup {}", backup.display()))?;
        }
        replace_file(&temporary, path)
    })();
    if result.is_err() && temporary.exists() {
        if let Err(error) = fs::remove_file(&temporary) {
            warn!(
                path = %temporary.display(),
                %error,
                "failed to remove temporary JSON file after write failure"
            );
        }
    }
    result
}

#[cfg(target_os = "windows")]
fn replace_file(temporary: &Path, destination: &Path) -> Result<()> {
    use std::os::windows::ffi::OsStrExt;

    use windows::{
        core::PCWSTR,
        Win32::Storage::FileSystem::{
            MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
        },
    };

    let destination_display = destination.display().to_string();
    let temporary = temporary
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect::<Vec<_>>();
    let destination = destination
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect::<Vec<_>>();
    unsafe {
        MoveFileExW(
            PCWSTR(temporary.as_ptr()),
            PCWSTR(destination.as_ptr()),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    }
    .with_context(|| format!("failed to replace {destination_display}"))?;
    Ok(())
}

#[cfg(not(target_os = "windows"))]
fn replace_file(temporary: &Path, destination: &Path) -> Result<()> {
    fs::rename(temporary, destination)
        .with_context(|| format!("failed to replace {}", destination.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rule_matching_is_case_insensitive() {
        let rule = WindowRule {
            executable_contains: "PREMIERE".into(),
            title_contains: "timeline".into(),
            ..WindowRule::default()
        };
        assert!(rule.matches("C:/Adobe/premiere.exe", "TIMELINE - Edit"));
        assert!(!rule.matches("C:/Adobe/afterfx.exe", "Timeline"));
    }

    #[test]
    fn rule_matching_trims_patterns_and_treats_whitespace_as_blank() {
        let match_all = WindowRule {
            executable_contains: "  \t".into(),
            title_contains: "   ".into(),
            ..WindowRule::default()
        };
        assert!(match_all.matches("C:/Adobe/premiere.exe", "Timeline - Edit"));

        let trimmed = WindowRule {
            executable_contains: "  premiere.exe  ".into(),
            title_contains: "  timeline  ".into(),
            ..WindowRule::default()
        };
        assert!(trimmed.matches("C:/Adobe/PREMIERE.EXE", "TIMELINE - Edit"));
    }

    #[test]
    fn only_non_exclusion_rules_with_a_real_effect_are_automatic() {
        let mut rule = WindowRule::default();
        assert!(!rule.has_automatic_action());
        rule.auto_pin = true;
        assert!(rule.has_automatic_action());
        rule.auto_pin = false;
        rule.opacity_percent = 75;
        assert!(rule.has_automatic_action());
        rule.exclude = true;
        assert!(!rule.has_automatic_action());
    }

    #[test]
    fn unsafe_ranges_are_clamped() {
        let mut config = AppConfig {
            schema_version: 999,
            ..AppConfig::default()
        };
        config.opacity.minimum_percent = 0;
        config.opacity.step_percent = 99;
        config.diagnostics.max_total_mb = 0;
        config.rules.push(WindowRule {
            opacity_percent: 0,
            ..WindowRule::default()
        });
        config.sanitize();
        assert_eq!(config.schema_version, CONFIG_SCHEMA_VERSION);
        assert_eq!(config.opacity.minimum_percent, 10);
        assert_eq!(config.opacity.step_percent, 25);
        assert_eq!(config.diagnostics.max_total_mb, 2);
        assert_eq!(config.rules[0].opacity_percent, 10);
    }

    #[test]
    fn legacy_config_migrates_to_resident_startup_and_alt_shift_wheel() {
        let raw = r#"{
            "schema_version": 1,
            "opacity": { "consume_ctrl_shift_wheel": false },
            "behavior": { "start_minimized": false, "launch_at_login": false }
        }"#;
        let (config, normalized) = parse_document::<AppConfig>(raw).unwrap();

        assert!(normalized);
        assert_eq!(config.schema_version, CONFIG_SCHEMA_VERSION);
        assert!(config.behavior.start_minimized);
        assert!(config.behavior.launch_at_login);
        assert!(!config.opacity.consume_alt_shift_wheel);
    }

    #[test]
    fn restored_unpinned_window_is_forgotten_at_full_opacity() {
        let mut state = RuntimeState::fresh();
        assert!(state.remember_window(RememberedWindow {
            executable: "C:/Apps/Editor.exe".into(),
            title_hint: "Project".into(),
            topmost: true,
            opacity_percent: 70,
        }));
        assert!(state.remember_window(RememberedWindow {
            executable: "c:/apps/EDITOR.exe".into(),
            title_hint: "Project".into(),
            topmost: false,
            opacity_percent: 70,
        }));

        assert!(state.update_opacity("C:/Apps/Editor.exe", "Project", 100));
        assert!(state.remembered_windows.is_empty());
    }

    #[test]
    fn remembered_state_skips_identical_updates() {
        let mut state = RuntimeState::fresh();
        let remembered = RememberedWindow {
            executable: "C:/Apps/Editor.exe".into(),
            title_hint: "Project".into(),
            topmost: true,
            opacity_percent: 80,
        };
        assert!(state.remember_window(remembered.clone()));
        assert!(!state.remember_window(remembered));
        assert!(!state.update_opacity("C:/Apps/Editor.exe", "Project", 80));
    }

    #[test]
    fn atomic_json_write_replaces_existing_file_and_keeps_backup() {
        let directory = std::env::temp_dir().join(format!(
            "topfade-config-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("config.json");

        let mut first = AppConfig::default();
        first.opacity.step_percent = 3;
        atomic_write_json(&path, &first).unwrap();
        let mut second = first.clone();
        second.opacity.step_percent = 7;
        atomic_write_json(&path, &second).unwrap();

        let current: AppConfig = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        let backup: AppConfig =
            serde_json::from_slice(&fs::read(path.with_extension("bak")).unwrap()).unwrap();
        assert_eq!(current.opacity.step_percent, 7);
        assert_eq!(backup.opacity.step_percent, 3);
        assert!(!path.with_extension("tmp").exists());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn invalid_config_is_preserved_and_recovers_valid_backup() {
        let directory = unique_test_directory("config-recovery");
        fs::create_dir_all(&directory).unwrap();
        let paths = test_paths(&directory);
        let mut valid = AppConfig::default();
        valid.opacity.step_percent = 7;
        valid.save(&paths).unwrap();
        fs::copy(&paths.config_file, paths.config_file.with_extension("bak")).unwrap();
        fs::write(&paths.config_file, b"{ definitely not json").unwrap();

        let recovered = AppConfig::load(&paths);

        assert_eq!(recovered.opacity.step_percent, 7);
        assert_eq!(
            fs::read_to_string(paths.config_file.with_extension("json.invalid")).unwrap(),
            "{ definitely not json"
        );
        let repaired: AppConfig =
            serde_json::from_slice(&fs::read(&paths.config_file).unwrap()).unwrap();
        let backup: AppConfig =
            serde_json::from_slice(&fs::read(paths.config_file.with_extension("bak")).unwrap())
                .unwrap();
        assert_eq!(repaired.opacity.step_percent, 7);
        assert_eq!(backup.opacity.step_percent, 7);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn future_config_schema_is_preserved_and_recovers_supported_backup() {
        let directory = unique_test_directory("future-config-recovery");
        fs::create_dir_all(&directory).unwrap();
        let paths = test_paths(&directory);
        let mut supported = AppConfig::default();
        supported.opacity.step_percent = 4;
        write_json(&paths.config_file.with_extension("bak"), &supported, false).unwrap();
        let mut future = supported.clone();
        future.schema_version = CONFIG_SCHEMA_VERSION + 1;
        write_json(&paths.config_file, &future, false).unwrap();

        let recovered = AppConfig::load(&paths);

        assert_eq!(recovered.schema_version, CONFIG_SCHEMA_VERSION);
        assert_eq!(recovered.opacity.step_percent, 4);
        let preserved: AppConfig = serde_json::from_slice(
            &fs::read(paths.config_file.with_extension("json.invalid")).unwrap(),
        )
        .unwrap();
        assert_eq!(preserved.schema_version, CONFIG_SCHEMA_VERSION + 1);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn invalid_runtime_state_is_preserved_and_repaired() {
        let directory = unique_test_directory("state-recovery");
        fs::create_dir_all(&directory).unwrap();
        let paths = test_paths(&directory);
        fs::write(&paths.state_file, b"not-json").unwrap();

        let recovered = RuntimeState::load(&paths);

        assert_eq!(recovered.schema_version, 1);
        assert!(recovered.remembered_windows.is_empty());
        assert_eq!(
            fs::read_to_string(paths.state_file.with_extension("json.invalid")).unwrap(),
            "not-json"
        );
        let repaired: RuntimeState =
            serde_json::from_slice(&fs::read(&paths.state_file).unwrap()).unwrap();
        assert_eq!(repaired.schema_version, 1);
        assert!(repaired.remembered_windows.is_empty());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn missing_runtime_primary_recovers_valid_backup() {
        let directory = unique_test_directory("missing-state-recovery");
        fs::create_dir_all(&directory).unwrap();
        let paths = test_paths(&directory);
        let mut state = RuntimeState::fresh();
        state.remembered_windows.push(RememberedWindow {
            executable: "C:/Apps/Editor.exe".into(),
            title_hint: "Project".into(),
            topmost: true,
            opacity_percent: 80,
        });
        write_json(&paths.state_file.with_extension("bak"), &state, false).unwrap();

        let recovered = RuntimeState::load(&paths);

        assert_eq!(recovered, state);
        let repaired: RuntimeState =
            serde_json::from_slice(&fs::read(&paths.state_file).unwrap()).unwrap();
        assert_eq!(repaired, state);
        fs::remove_dir_all(directory).unwrap();
    }

    fn unique_test_directory(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "topfade-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn test_paths(directory: &Path) -> AppPaths {
        AppPaths {
            data_dir: directory.to_path_buf(),
            config_file: directory.join("config.json"),
            state_file: directory.join("state.json"),
            logs_dir: directory.join("logs"),
            reports_dir: directory.join("reports"),
        }
    }
}
