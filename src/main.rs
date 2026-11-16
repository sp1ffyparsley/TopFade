#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

#[cfg(not(target_os = "windows"))]
compile_error!("Build the native macOS app from macos/TopFadeMac instead of this Windows crate.");

mod activation;
mod app;
mod config;
mod diagnostics;
mod fader;
mod input;
mod platform;
mod self_test;
mod tray;

use std::sync::Arc;

use anyhow::{Context, Result};
use config::AppPaths;
use platform::WindowBackend;
use tracing::{error, info};

fn main() {
    let paths = match AppPaths::discover() {
        Ok(paths) => paths,
        Err(error) => {
            eprintln!("TopFade could not determine its data directory: {error:#}");
            std::process::exit(1);
        }
    };

    let log_guard = match diagnostics::init(&paths) {
        Ok(guard) => guard,
        Err(error) => {
            eprintln!("TopFade logging initialization failed: {error:#}");
            std::process::exit(1);
        }
    };

    diagnostics::install_panic_hook(paths.clone());
    let failed = run(paths).is_err_and(|error| {
        error!(error = %format!("{error:#}"), "TopFade terminated with an error");
        let _ = diagnostics::write_fatal_report(&error);
        true
    });
    drop(log_guard);
    if failed {
        std::process::exit(1);
    }
}

fn run(paths: AppPaths) -> Result<()> {
    info!(
        version = env!("CARGO_PKG_VERSION"),
        os = std::env::consts::OS,
        "TopFade starting"
    );

    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--self-test") {
        let backend = platform::create_backend()?;
        let (input, _) = input::InputController::install(true, false, None, Arc::new(|| {}))
            .context("self-test could not install native input hooks")?;
        let result = self_test::run(backend.as_ref(), &paths);
        drop(input);
        return result;
    }
    if args.iter().any(|arg| arg == "--diagnostic-report") {
        let backend = platform::create_backend()?;
        let path = diagnostics::export_report(&paths, backend.as_ref(), None)?;
        println!("{}", path.display());
        return Ok(());
    }

    let instance = single_instance::SingleInstance::new("com.tavito.topfade")
        .context("failed to create the single-instance guard")?;
    if !instance.is_single() {
        activation::signal_existing()?;
        info!("existing TopFade instance activation requested");
        return Ok(());
    }

    run_ui(paths, platform::create_backend()?)
}

fn run_ui(paths: AppPaths, backend: Arc<dyn WindowBackend>) -> Result<()> {
    let icon = app::generate_app_icon(64);
    let native_options = eframe::NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default()
            .with_title("TopFade")
            .with_inner_size([860.0, 620.0])
            .with_min_inner_size([720.0, 520.0])
            .with_icon(icon),
        // TopFade owns persistence in AppConfig/RuntimeState rather than eframe's second store.
        persist_window: false,
        renderer: eframe::Renderer::Glow,
        ..Default::default()
    };

    eframe::run_native(
        "TopFade",
        native_options,
        Box::new(move |creation_context| {
            Ok(Box::new(app::TopFadeApp::new(
                creation_context,
                paths,
                backend,
            )))
        }),
    )
    .map_err(|error| anyhow::anyhow!(error.to_string()))
}
