use std::{
    collections::{HashMap, HashSet},
    path::Path,
    str::FromStr,
    sync::Arc,
    time::{Duration, Instant},
};

use eframe::egui::{self, Color32, RichText, Stroke, Vec2};
use global_hotkey::{hotkey::HotKey, HotKeyState};
use tracing::{debug, error, info, warn};

use crate::{
    activation::ActivationListener,
    config::{AppConfig, AppPaths, RememberedWindow, RuntimeState, WindowRule},
    diagnostics,
    fader::{FaderOverlay, FaderRequest},
    input::{InputController, InputEvent},
    platform::{NativeWindowId, WindowBackend, WindowIdentity, WindowInfo},
    tray::{AppTray, TrayAction},
};

const RUNTIME_STATE_SAVE_DELAY: Duration = Duration::from_millis(350);
const RUNTIME_STATE_SAVE_RETRY_DELAY: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Page {
    Control,
    Preferences,
    Rules,
    Diagnostics,
}

#[derive(Clone, Copy)]
struct RegisteredHotkeys {
    toggle_topmost: HotKey,
    show_preferences: HotKey,
}

impl RegisteredHotkeys {
    fn parse(config: &AppConfig) -> anyhow::Result<Self> {
        let toggle_topmost = HotKey::from_str(&config.hotkeys.toggle_topmost)?;
        let show_preferences = HotKey::from_str(&config.hotkeys.show_preferences)?;
        Ok(Self {
            toggle_topmost,
            show_preferences,
        })
    }

    fn pair(self) -> [HotKey; 2] {
        [self.toggle_topmost, self.show_preferences]
    }
}

pub struct TopFadeApp {
    paths: AppPaths,
    backend: Arc<dyn WindowBackend>,
    config: AppConfig,
    persisted_config: AppConfig,
    runtime_state: RuntimeState,
    input: Option<InputController>,
    hotkeys: Option<RegisteredHotkeys>,
    activation: Option<ActivationListener>,
    tray: Option<AppTray>,
    selected: Option<WindowInfo>,
    recent_windows: Vec<WindowInfo>,
    opacity_cache: HashMap<WindowIdentity, u8>,
    restored_windows: HashSet<WindowIdentity>,
    last_foreground_candidate: Option<WindowIdentity>,
    fader_overlay: Option<FaderOverlay>,
    pending_click_through: Option<WindowInfo>,
    window_search: String,
    page: Page,
    status: String,
    restore_scan_due: Option<Instant>,
    runtime_state_save_due: Option<Instant>,
    runtime_state_dirty: bool,
    quit_confirmation_requested: bool,
    quit_requested: bool,
}

impl TopFadeApp {
    pub fn new(
        creation_context: &eframe::CreationContext<'_>,
        paths: AppPaths,
        backend: Arc<dyn WindowBackend>,
    ) -> Self {
        configure_style(&creation_context.egui_ctx);
        let wake_context = creation_context.egui_ctx.clone();
        let wake: Arc<dyn Fn() + Send + Sync> = Arc::new(move || wake_context.request_repaint());
        let config = AppConfig::load(&paths);
        if let Err(error) = diagnostics::cleanup_logs(
            &paths.logs_dir,
            config.diagnostics.retention_days,
            config.diagnostics.max_total_mb,
        ) {
            warn!(error = %format!("{error:#}"), "configured log cleanup failed");
        }
        let runtime_state = RuntimeState::load(&paths);
        let watch_window_events = restoration_needed_for(&config, &runtime_state);
        let mut startup_issues = Vec::new();
        let activation = match ActivationListener::install(wake.clone()) {
            Ok(activation) => {
                info!("single-instance activation listener initialized");
                Some(activation)
            }
            Err(error) => {
                error!(error = %format!("{error:#}"), "single-instance activation listener failed");
                startup_issues.push(format!(
                    "duplicate-launch activation unavailable: {error:#}"
                ));
                None
            }
        };
        let mut hotkeys = match RegisteredHotkeys::parse(&config) {
            Ok(hotkeys) => Some(hotkeys),
            Err(error) => {
                error!(error = %format!("{error:#}"), "global hotkey configuration is invalid");
                startup_issues.push(format!("global hotkeys unavailable: {error:#}"));
                None
            }
        };
        let input = match InputController::install(
            config.opacity.consume_alt_shift_wheel,
            watch_window_events,
            hotkeys.map(RegisteredHotkeys::pair),
            wake.clone(),
        ) {
            Ok((input, hotkey_error)) => {
                if let Some(error) = hotkey_error {
                    error!(%error, "global hotkey registration failed");
                    startup_issues.push(format!("global hotkeys unavailable: {error}"));
                    hotkeys = None;
                } else if hotkeys.is_some() {
                    info!(
                        toggle = %config.hotkeys.toggle_topmost,
                        preferences = %config.hotkeys.show_preferences,
                        "global hotkeys registered on the native event thread"
                    );
                }
                info!("global opacity wheel and window event hooks installed");
                Some(input)
            }
            Err(error) => {
                error!(error = %format!("{error:#}"), "native input event thread failed");
                startup_issues.push(format!("native input unavailable: {error:#}"));
                hotkeys = None;
                None
            }
        };
        let tray = match AppTray::new(wake) {
            Ok(tray) => {
                info!("system tray initialized");
                Some(tray)
            }
            Err(error) => {
                warn!(error = %format!("{error:#}"), "tray initialization failed");
                startup_issues.push(format!("tray unavailable: {error:#}"));
                None
            }
        };
        let fader_overlay = match FaderOverlay::install() {
            Ok(overlay) => Some(overlay),
            Err(error) => {
                warn!(error = %format!("{error:#}"), "native opacity fader unavailable");
                startup_issues.push(format!("opacity fader unavailable: {error:#}"));
                None
            }
        };

        let mut app = Self {
            paths,
            backend,
            persisted_config: config.clone(),
            config,
            runtime_state,
            input,
            hotkeys,
            activation,
            tray,
            selected: None,
            recent_windows: Vec::new(),
            opacity_cache: HashMap::new(),
            restored_windows: HashSet::new(),
            last_foreground_candidate: None,
            fader_overlay,
            pending_click_through: None,
            window_search: String::new(),
            page: Page::Control,
            status: if startup_issues.is_empty() {
                "Ready".into()
            } else {
                startup_issues.join(" | ")
            },
            restore_scan_due: None,
            runtime_state_save_due: None,
            runtime_state_dirty: false,
            quit_confirmation_requested: false,
            quit_requested: false,
        };
        app.refresh_windows();
        if app.restoration_needed() {
            app.restore_remembered_and_rules();
        }
        if app.config.behavior.start_minimized {
            if can_hide_to_tray(true, app.tray.is_some()) {
                creation_context
                    .egui_ctx
                    .send_viewport_cmd(egui::ViewportCommand::Visible(false));
            } else {
                app.status = append_status(
                    &app.status,
                    "Start-hidden was skipped because the system tray is unavailable",
                );
            }
        }
        app
    }

    fn refresh_windows(&mut self) {
        match self.backend.focused_window() {
            Ok(window) => {
                if let Some(window) = &window {
                    self.last_foreground_candidate = Some(window.identity());
                }
                self.selected = window;
            }
            Err(error) => self.status = format!("Focused-window inspection failed: {error:#}"),
        }
        match self.backend.enumerate_windows() {
            Ok(mut windows) => {
                windows.sort_by_key(|window| window.title.to_lowercase());
                let live_identities = windows
                    .iter()
                    .map(WindowInfo::identity)
                    .collect::<HashSet<_>>();
                retain_live_window_tracking(
                    &mut self.opacity_cache,
                    &mut self.restored_windows,
                    &live_identities,
                );
                self.recent_windows = windows;
            }
            Err(error) => self.status = format!("Window list failed: {error:#}"),
        }
    }

    fn select_focused(&mut self) {
        match self.backend.focused_window() {
            Ok(Some(window)) => {
                self.status = format!("Selected {}", window.title);
                self.last_foreground_candidate = Some(window.identity());
                self.selected = Some(window);
            }
            Ok(None) => self.status = "No controllable focused window".into(),
            Err(error) => self.status = format!("Window selection failed: {error:#}"),
        }
    }

    fn toggle_focused_topmost(&mut self) {
        let window = match self.backend.focused_window() {
            Ok(Some(window)) => window,
            Ok(None) => {
                self.status = "No controllable focused window".into();
                return;
            }
            Err(error) => {
                self.status = format!("Focused-window inspection failed: {error:#}");
                return;
            }
        };
        self.set_topmost(&window, None);
    }

    fn toggle_hotkey_topmost(&mut self, raw_foreground: NativeWindowId) {
        let direct = self.backend.inspect(raw_foreground).ok();
        let remembered = self.last_foreground_candidate.and_then(|target| {
            self.backend
                .inspect(target.id)
                .ok()
                .filter(|window| window.process_id == target.process_id)
        });
        let fallback = || self.backend.focused_window().ok().flatten();
        let Some(window) = direct.or(remembered).or_else(fallback) else {
            self.status = "No controllable focused window".into();
            return;
        };
        self.set_topmost(&window, None);
    }

    fn toggle_selected_topmost(&mut self) {
        if let Some(window) = self.selected.clone() {
            self.set_topmost(&window, None);
        } else {
            self.select_focused();
        }
    }

    fn set_topmost(&mut self, window: &WindowInfo, enabled: Option<bool>) {
        if self.is_excluded(window) {
            self.status = format!("{} is excluded by a rule", window.title);
            return;
        }
        let enabled = enabled.unwrap_or(!window.topmost);
        match self.backend.set_topmost(window.identity(), enabled) {
            Ok(()) => {
                self.last_foreground_candidate = Some(window.identity());
                diagnostics::record_event(format!(
                    "topmost target=0x{:X} enabled={} title={:?}",
                    window.id.0, enabled, window.title
                ));
                info!(
                    window = %window.title,
                    executable = %window.executable,
                    id = window.id.0,
                    enabled,
                    "topmost changed"
                );
                self.status = if enabled {
                    format!("Pinned {}", window.title)
                } else {
                    format!("Unpinned {}", window.title)
                };
                self.remember_window(window, enabled);
                self.selected = self.backend.inspect(window.id).ok();
            }
            Err(error) => {
                error!(window = %window.title, error = %format!("{error:#}"), "topmost change failed");
                self.status = format!("Could not pin {}: {error:#}", window.title);
            }
        }
    }

    fn set_selected_opacity(&mut self, percent: u8) {
        if let Some(window) = self.selected.clone() {
            self.apply_opacity(&window, percent, None);
        }
    }

    fn apply_opacity(&mut self, window: &WindowInfo, percent: u8, cursor: Option<[f32; 2]>) {
        let percent = percent.clamp(self.config.opacity.minimum_percent, 100);
        if self.is_excluded(window) {
            self.status = format!("{} is excluded by a rule", window.title);
            return;
        }
        match self.backend.set_opacity(window.identity(), percent) {
            Ok(()) => {
                self.last_foreground_candidate = Some(window.identity());
                self.opacity_cache.insert(window.identity(), percent);
                diagnostics::record_event(format!(
                    "opacity target=0x{:X} percent={} title={:?}",
                    window.id.0, percent, window.title
                ));
                self.status = format!("{} opacity: {}%", window.title, percent);
                if self.config.opacity.show_overlay {
                    let position = cursor.unwrap_or([
                        (window.rect.x + window.rect.width / 2) as f32,
                        (window.rect.y + 48) as f32,
                    ]);
                    if let Some(overlay) = &self.fader_overlay {
                        let request = FaderRequest {
                            title: self
                                .config
                                .appearance
                                .show_window_title_in_overlay
                                .then(|| window.title.clone()),
                            opacity_percent: percent,
                            x: position[0] as i32,
                            y: position[1] as i32,
                            duration_ms: self.config.opacity.overlay_duration_ms,
                            accent_rgb: self.config.appearance.accent_rgb,
                        };
                        if let Err(error) = overlay.show(request) {
                            warn!(error = %format!("{error:#}"), "native opacity fader update failed");
                        }
                    }
                }
                if let Some(selected) = self.selected.as_mut() {
                    if selected.identity() == window.identity() {
                        selected.opacity_percent = percent;
                    }
                }
                self.update_remembered_opacity(window, percent);
            }
            Err(error) => {
                error!(window = %window.title, error = %format!("{error:#}"), "opacity change failed");
                self.status = format!("Could not fade {}: {error:#}", window.title);
            }
        }
    }

    fn set_click_through(&mut self, window: &WindowInfo, enabled: bool) {
        if self.is_excluded(window) {
            self.status = format!("{} is excluded by a rule", window.title);
            return;
        }
        match self.backend.set_click_through(window.identity(), enabled) {
            Ok(()) => {
                diagnostics::record_event(format!(
                    "click-through target=0x{:X} enabled={} title={:?}",
                    window.id.0, enabled, window.title
                ));
                info!(
                    window = %window.title,
                    executable = %window.executable,
                    id = window.id.0,
                    enabled,
                    "click-through changed"
                );
                self.selected = self.backend.inspect(window.id).ok();
                self.status = format!("Click-through: {enabled}");
            }
            Err(error) => {
                error!(window = %window.title, error = %format!("{error:#}"), "click-through change failed");
                self.status = format!("Click-through failed: {error:#}");
            }
        }
    }

    fn render_click_through_confirmation(&mut self, ctx: &egui::Context) {
        let Some(window) = self.pending_click_through.clone() else {
            return;
        };
        let mut confirm = false;
        let mut cancel = false;
        egui::Window::new("Enable click-through?")
            .id(egui::Id::new("topfade-click-through-confirmation"))
            .anchor(egui::Align2::CENTER_CENTER, Vec2::ZERO)
            .collapsible(false)
            .resizable(false)
            .show(ctx, |ui| {
                ui.label(format!(
                    "{} will ignore mouse input until click-through is disabled from TopFade.",
                    window.title
                ));
                ui.add_space(8.0);
                ui.horizontal(|ui| {
                    confirm = ui.button("Enable").clicked();
                    cancel = ui.button("Cancel").clicked();
                });
            });
        if confirm {
            self.pending_click_through = None;
            self.set_click_through(&window, true);
        } else if cancel {
            self.pending_click_through = None;
            self.status = "Click-through unchanged".into();
        }
    }

    fn request_quit(&mut self, ctx: &egui::Context) {
        if has_staged_config_changes(&self.config, &self.persisted_config) {
            self.quit_confirmation_requested = true;
            self.status = "Save or discard the staged changes before quitting".into();
            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
            ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
        } else {
            self.quit_requested = true;
        }
    }

    fn render_quit_confirmation(&mut self, ctx: &egui::Context) {
        if !self.quit_confirmation_requested {
            return;
        }

        let mut save_and_quit = false;
        let mut discard_and_quit = false;
        let mut cancel = false;
        egui::Window::new("Quit TopFade?")
            .id(egui::Id::new("topfade-quit-confirmation"))
            .anchor(egui::Align2::CENTER_CENTER, Vec2::ZERO)
            .collapsible(false)
            .resizable(false)
            .show(ctx, |ui| {
                ui.label("There are staged preference or rule changes that have not been saved.");
                ui.add_space(8.0);
                ui.horizontal_wrapped(|ui| {
                    save_and_quit = ui.button("Save and quit").clicked();
                    discard_and_quit = ui.button("Quit without saving").clicked();
                    cancel = ui.button("Cancel").clicked();
                });
            });

        if save_and_quit {
            self.save_preferences();
            if !has_staged_config_changes(&self.config, &self.persisted_config) {
                self.quit_confirmation_requested = false;
                self.quit_requested = true;
            }
        } else if discard_and_quit {
            diagnostics::record_event("staged preference edits discarded by confirmed quit");
            self.config = self.persisted_config.clone();
            self.quit_confirmation_requested = false;
            self.quit_requested = true;
        } else if cancel {
            self.quit_confirmation_requested = false;
            self.status = "Quit canceled".into();
        }
    }

    fn handle_input(&mut self, ctx: &egui::Context) {
        loop {
            let event = self.input.as_ref().and_then(InputController::try_recv);
            let Some(event) = event else {
                break;
            };
            match event {
                InputEvent::OpacityWheel {
                    target,
                    wheel_steps,
                    cursor_x,
                    cursor_y,
                } => {
                    debug!(
                        target = format_args!("0x{:X}", target.0),
                        wheel_steps, cursor_x, cursor_y, "opacity wheel event received"
                    );
                    let window = if self.config.opacity.target_under_cursor {
                        self.backend
                            .window_at_point(cursor_x, cursor_y)
                            .ok()
                            .flatten()
                            .or_else(|| self.backend.inspect(target).ok())
                    } else {
                        self.backend.focused_window().ok().flatten()
                    };
                    if let Some(window) = window {
                        let current = self
                            .opacity_cache
                            .get(&window.identity())
                            .copied()
                            .unwrap_or(window.opacity_percent.max(1));
                        let delta = i16::from(self.config.opacity.step_percent) * wheel_steps;
                        let next = u8::try_from(
                            (i16::from(current) + delta)
                                .clamp(i16::from(self.config.opacity.minimum_percent), 100),
                        )
                        .expect("clamped opacity always fits in u8");
                        self.selected = Some(window.clone());
                        self.apply_opacity(
                            &window,
                            next,
                            Some([cursor_x as f32 + 18.0, cursor_y as f32 + 18.0]),
                        );
                    }
                }
                InputEvent::WindowAvailable { target } => {
                    if self.restore_scan_due.is_some() || !self.restoration_needed() {
                        continue;
                    }
                    let window = self.backend.inspect(target).ok();
                    let is_candidate = window.as_ref().is_some_and(|window| {
                        !self.restored_windows.contains(&window.identity())
                            && self.window_has_restore_candidate(window)
                    });
                    if is_candidate {
                        // Some applications set their title shortly after showing the window.
                        self.restore_scan_due = Some(Instant::now() + Duration::from_millis(400));
                    }
                }
                InputEvent::ForegroundChanged { target } => {
                    if let Ok(window) = self.backend.inspect(target) {
                        self.last_foreground_candidate = Some(window.identity());
                    }
                }
                InputEvent::Hotkey {
                    id,
                    state,
                    foreground,
                } => {
                    info!(
                        id,
                        ?state,
                        foreground = foreground.0,
                        "global hotkey event received"
                    );
                    if state == HotKeyState::Pressed {
                        let toggle = self
                            .hotkeys
                            .is_some_and(|hotkeys| id == hotkeys.toggle_topmost.id());
                        let show = self
                            .hotkeys
                            .is_some_and(|hotkeys| id == hotkeys.show_preferences.id());
                        if toggle {
                            self.toggle_hotkey_topmost(foreground);
                        }
                        if show {
                            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                            ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
                            self.page = Page::Preferences;
                        }
                    }
                }
            }
        }
    }

    fn handle_tray(&mut self, ctx: &egui::Context) {
        let actions = self.tray.as_ref().map_or_else(Vec::new, AppTray::poll);
        for action in actions {
            match action {
                TrayAction::Show => {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                    ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
                }
                TrayAction::ToggleFocused => self.toggle_focused_topmost(),
                TrayAction::ResetFocusedOpacity => {
                    if let Ok(Some(window)) = self.backend.focused_window() {
                        self.apply_opacity(&window, 100, None);
                    }
                }
                TrayAction::ExportDiagnostics => self.export_diagnostics(),
                TrayAction::Quit => self.request_quit(ctx),
            }
        }
    }

    fn handle_activation(&mut self, ctx: &egui::Context) {
        let requested = self
            .activation
            .as_ref()
            .is_some_and(ActivationListener::take_pending);
        if requested {
            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
            ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
            self.status = "Opened by a second TopFade launch".into();
            diagnostics::record_event("existing instance activated by duplicate launch");
        }
    }

    fn restore_remembered_and_rules(&mut self) {
        let Ok(windows) = self.backend.enumerate_windows() else {
            return;
        };
        let executable_counts = windows.iter().fold(HashMap::new(), |mut counts, window| {
            *counts
                .entry(window.executable.to_lowercase())
                .or_insert(0_usize) += 1;
            counts
        });
        let live_identities = windows
            .iter()
            .map(WindowInfo::identity)
            .collect::<HashSet<_>>();
        retain_live_window_tracking(
            &mut self.opacity_cache,
            &mut self.restored_windows,
            &live_identities,
        );

        for window in windows {
            let identity = window.identity();
            if self.restored_windows.contains(&identity) || self.is_excluded(&window) {
                continue;
            }
            let remembered = self
                .config
                .behavior
                .restore_when_apps_reopen
                .then(|| {
                    self.runtime_state
                        .remembered_windows
                        .iter()
                        .find(|remembered| {
                            remembered_window_matches(
                                remembered,
                                &window,
                                executable_counts
                                    .get(&window.executable.to_lowercase())
                                    .copied()
                                    .unwrap_or(0),
                            )
                        })
                })
                .flatten()
                .cloned();
            let matching_rule = self
                .config
                .rules
                .iter()
                .find(|rule| {
                    rule.has_automatic_action() && rule.matches(&window.executable, &window.title)
                })
                .cloned();

            if let Some(remembered) = remembered {
                let restore = apply_window_state_transactionally(
                    self.backend.as_ref(),
                    &window,
                    Some(remembered.topmost),
                    Some(remembered.opacity_percent),
                );
                match restore {
                    Ok(()) => {
                        self.opacity_cache
                            .insert(identity, remembered.opacity_percent);
                        self.restored_windows.insert(identity);
                        diagnostics::record_event(format!("restored target=0x{:X}", window.id.0));
                    }
                    Err(error) => {
                        self.log_restore_failure(&window, "remembered state", &error);
                    }
                }
            } else if let Some(rule) = matching_rule {
                let restore = apply_window_state_transactionally(
                    self.backend.as_ref(),
                    &window,
                    rule.auto_pin.then_some(true),
                    (rule.opacity_percent < 100).then_some(rule.opacity_percent),
                );
                match restore {
                    Ok(()) => {
                        if rule.opacity_percent < 100 {
                            self.opacity_cache.insert(identity, rule.opacity_percent);
                        }
                        self.restored_windows.insert(identity);
                    }
                    Err(error) => {
                        self.log_restore_failure(&window, &format!("rule {:?}", rule.name), &error);
                    }
                }
            }
        }
    }

    fn log_restore_failure(&mut self, window: &WindowInfo, source: &str, error: &anyhow::Error) {
        let details = format!("{error:#}");
        warn!(
            window = %window.title,
            executable = %window.executable,
            id = window.id.0,
            source,
            error = %details,
            "window restoration failed and remains retryable"
        );
        diagnostics::record_event(format!(
            "restore failed target=0x{:X} source={source:?} error={details:?}",
            window.id.0
        ));
        self.status = format!("Could not restore {}. See diagnostics.", window.title);
    }

    fn window_has_restore_candidate(&self, window: &WindowInfo) -> bool {
        if self.is_excluded(window) {
            return false;
        }
        let remembered = self.config.behavior.restore_when_apps_reopen
            && self
                .runtime_state
                .remembered_windows
                .iter()
                .any(|entry| entry.executable.eq_ignore_ascii_case(&window.executable));
        let rule = self.config.rules.iter().any(|rule| {
            rule.has_automatic_action() && rule.matches(&window.executable, &window.title)
        });
        remembered || rule
    }

    fn restoration_needed(&self) -> bool {
        restoration_needed_for(&self.config, &self.runtime_state)
    }

    fn remember_window(&mut self, window: &WindowInfo, topmost: bool) {
        if !self.config.behavior.remember_pinned_windows {
            return;
        }
        if window.executable.trim().is_empty() {
            warn!(
                window = %window.title,
                id = window.id.0,
                "window state was not remembered because its executable identity is unavailable"
            );
            return;
        }
        let opacity = self
            .opacity_cache
            .get(&window.identity())
            .copied()
            .unwrap_or(100);
        let changed = self.runtime_state.remember_window(RememberedWindow {
            executable: window.executable.clone(),
            title_hint: window.title.clone(),
            topmost,
            opacity_percent: opacity,
        });
        if changed {
            self.runtime_state_dirty = true;
            InputController::set_watch_window_events(self.restoration_needed());
            self.flush_runtime_state();
        }
    }

    fn update_remembered_opacity(&mut self, window: &WindowInfo, opacity: u8) {
        if self
            .runtime_state
            .update_opacity(&window.executable, &window.title, opacity)
        {
            self.runtime_state_dirty = true;
            InputController::set_watch_window_events(self.restoration_needed());
            self.runtime_state_save_due = Some(Instant::now() + RUNTIME_STATE_SAVE_DELAY);
        }
    }

    fn flush_runtime_state(&mut self) {
        if !self.runtime_state_dirty {
            self.runtime_state_save_due = None;
            return;
        }
        match self.runtime_state.save(&self.paths) {
            Ok(()) => {
                self.runtime_state_dirty = false;
                self.runtime_state_save_due = None;
            }
            Err(error) => {
                warn!(
                    path = %self.paths.state_file.display(),
                    error = %format!("{error:#}"),
                    "runtime state save failed"
                );
                self.status = format!("Remembered state could not be saved: {error:#}");
                self.runtime_state_save_due = Some(Instant::now() + RUNTIME_STATE_SAVE_RETRY_DELAY);
            }
        }
    }

    fn forget_remembered_executable(&mut self, executable: &str) {
        if self.runtime_state.forget_executable(executable) {
            self.runtime_state_dirty = true;
            InputController::set_watch_window_events(self.restoration_needed());
            self.flush_runtime_state();
            if !self.runtime_state_dirty {
                let name = Path::new(executable)
                    .file_name()
                    .and_then(|value| value.to_str())
                    .unwrap_or(executable);
                self.status = format!("Forgot {name}; open windows were not changed");
            }
        }
    }

    fn clear_remembered_state(&mut self) {
        if self.runtime_state.clear_remembered() {
            self.runtime_state_dirty = true;
            InputController::set_watch_window_events(self.restoration_needed());
            self.flush_runtime_state();
            self.restored_windows.clear();
            if !self.runtime_state_dirty {
                self.status = "Cleared remembered state; open windows were not changed".into();
            }
        }
    }

    fn is_excluded(&self, window: &WindowInfo) -> bool {
        self.config
            .rules
            .iter()
            .any(|rule| rule.exclude && rule.matches(&window.executable, &window.title))
    }

    fn save_preferences(&mut self) {
        self.config.sanitize();
        let previous = self.persisted_config.clone();
        let old_hotkeys = self.hotkeys;
        let hotkeys_changed = self.config.hotkeys != previous.hotkeys;
        let launch_changed =
            self.config.behavior.launch_at_login != previous.behavior.launch_at_login;
        let wheel_mode_changed =
            self.config.opacity.consume_alt_shift_wheel != previous.opacity.consume_alt_shift_wheel;
        let diagnostics_changed = self.config.diagnostics != previous.diagnostics;
        let restoration_changed = self.config.rules != previous.rules
            || self.config.behavior.restore_when_apps_reopen
                != previous.behavior.restore_when_apps_reopen;
        let mut applied_hotkeys = false;

        if hotkeys_changed {
            let hotkeys = match RegisteredHotkeys::parse(&self.config) {
                Ok(hotkeys) => hotkeys,
                Err(error) => {
                    self.status = format!("Hotkey registration failed: {error:#}");
                    self.config.hotkeys = previous.hotkeys.clone();
                    return;
                }
            };
            let registration = self.input.as_ref().map_or_else(
                || Err(anyhow::anyhow!("native input event thread is unavailable")),
                |input| input.set_hotkeys(Some(hotkeys.pair())),
            );
            if let Err(error) = registration {
                self.status = format!("Hotkey registration failed: {error:#}");
                self.config.hotkeys = previous.hotkeys.clone();
                return;
            }
            self.hotkeys = Some(hotkeys);
            applied_hotkeys = true;
        }

        let previous_launch = previous.behavior.launch_at_login;
        let requested_launch = self.config.behavior.launch_at_login;
        if launch_changed {
            if let Err(error) = apply_launch_at_login(requested_launch) {
                let mut rollback_errors = Vec::new();
                if applied_hotkeys {
                    let hotkey_rollback = self.input.as_ref().map_or_else(
                        || Err(anyhow::anyhow!("native input event thread is unavailable")),
                        |input| input.set_hotkeys(old_hotkeys.map(RegisteredHotkeys::pair)),
                    );
                    self.hotkeys = match hotkey_rollback {
                        Ok(()) => old_hotkeys,
                        Err(rollback) => {
                            rollback_errors.push(format!("hotkeys: {rollback:#}"));
                            None
                        }
                    };
                }
                if let Err(rollback) = apply_launch_at_login(previous_launch) {
                    rollback_errors.push(format!("launch at login: {rollback:#}"));
                }
                self.config.hotkeys = previous.hotkeys.clone();
                self.config.behavior.launch_at_login = previous_launch;
                self.status = if rollback_errors.is_empty() {
                    format!(
                        "Launch-at-login update failed; runtime changes were rolled back: {error:#}"
                    )
                } else {
                    format!(
                        "Launch-at-login update failed: {error:#}; rollback failures: {}",
                        rollback_errors.join("; ")
                    )
                };
                return;
            }
        }

        match self.config.save(&self.paths) {
            Ok(()) => {
                if wheel_mode_changed {
                    InputController::set_consume_wheel(self.config.opacity.consume_alt_shift_wheel);
                }
                if diagnostics_changed {
                    if let Err(error) = diagnostics::cleanup_logs(
                        &self.paths.logs_dir,
                        self.config.diagnostics.retention_days,
                        self.config.diagnostics.max_total_mb,
                    ) {
                        warn!(error = %format!("{error:#}"), "configured log cleanup failed");
                    }
                    if let Err(error) =
                        diagnostics::set_log_level(&self.config.diagnostics.log_level)
                    {
                        warn!(error = %format!("{error:#}"), "log level update failed");
                    }
                }
                self.persisted_config = self.config.clone();
                if restoration_changed {
                    self.restored_windows.clear();
                    InputController::set_watch_window_events(self.restoration_needed());
                    if self.restoration_needed() {
                        self.restore_scan_due = Some(Instant::now());
                    }
                }
                self.status = "Preferences saved".into();
            }
            Err(error) => {
                let mut rollback_errors = Vec::new();
                if applied_hotkeys {
                    let hotkey_rollback = self.input.as_ref().map_or_else(
                        || Err(anyhow::anyhow!("native input event thread is unavailable")),
                        |input| input.set_hotkeys(old_hotkeys.map(RegisteredHotkeys::pair)),
                    );
                    if let Err(rollback) = hotkey_rollback {
                        self.hotkeys = None;
                        rollback_errors.push(format!("hotkeys: {rollback:#}"));
                    } else {
                        self.hotkeys = old_hotkeys;
                    }
                }
                if launch_changed {
                    if let Err(rollback) = apply_launch_at_login(previous_launch) {
                        rollback_errors.push(format!("launch at login: {rollback:#}"));
                    }
                }
                self.config.hotkeys = previous.hotkeys;
                self.config.behavior.launch_at_login = previous_launch;
                self.status = if rollback_errors.is_empty() {
                    format!("Save failed; runtime changes were rolled back: {error:#}")
                } else {
                    format!(
                        "Save failed: {error:#}; rollback failures: {}",
                        rollback_errors.join("; ")
                    )
                };
            }
        }
    }

    fn export_diagnostics(&mut self) {
        match diagnostics::export_report(&self.paths, self.backend.as_ref(), Some(&self.config)) {
            Ok(path) => self.status = format!("Diagnostic report: {}", path.display()),
            Err(error) => self.status = format!("Diagnostic export failed: {error:#}"),
        }
    }

    fn render_navigation(&mut self, root_ui: &mut egui::Ui) {
        egui::Panel::left("navigation")
            .exact_size(190.0)
            .frame(
                egui::Frame::side_top_panel(&root_ui.ctx().global_style())
                    .fill(Color32::from_rgb(24, 25, 27))
                    .inner_margin(egui::Margin::same(18)),
            )
            .show_inside(root_ui, |ui| {
                ui.add_space(8.0);
                ui.label(
                    RichText::new("TOPFADE")
                        .size(24.0)
                        .strong()
                        .color(accent(&self.config)),
                );
                ui.label(RichText::new("pin less, focus more").color(Color32::GRAY));
                ui.add_space(28.0);
                nav_button(ui, &mut self.page, Page::Control, "Control");
                nav_button(ui, &mut self.page, Page::Preferences, "Preferences");
                nav_button(ui, &mut self.page, Page::Rules, "Rules");
                nav_button(ui, &mut self.page, Page::Diagnostics, "Diagnostics");
                ui.with_layout(egui::Layout::bottom_up(egui::Align::LEFT), |ui| {
                    ui.label(
                        RichText::new(format!("{} backend", self.backend.platform_name()))
                            .small()
                            .color(Color32::DARK_GRAY),
                    );
                });
            });
    }

    fn render_control(&mut self, ui: &mut egui::Ui) {
        page_heading(
            ui,
            "Window control",
            "Pin and fade the window you are working with.",
        );
        ui.add_space(12.0);

        egui::Frame::new()
            .fill(Color32::from_rgb(31, 32, 35))
            .corner_radius(16)
            .inner_margin(egui::Margin::same(20))
            .stroke(Stroke::new(1.0_f32, Color32::from_rgb(52, 54, 58)))
            .show(ui, |ui| {
                if let Some(window) = self.selected.clone() {
                    let excluded = self.is_excluded(&window);
                    ui.horizontal(|ui| {
                        ui.vertical(|ui| {
                            ui.label(RichText::new(&window.title).size(20.0).strong());
                            let exe = Path::new(&window.executable)
                                .file_name()
                                .and_then(|name| name.to_str())
                                .unwrap_or("Unknown application");
                            ui.label(RichText::new(exe).color(Color32::GRAY));
                        });
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            let label = if window.topmost { "Unpin" } else { "Pin on top" };
                            if ui
                                .add_enabled(
                                    !excluded,
                                    egui::Button::new(label).fill(accent(&self.config)),
                                )
                                .clicked()
                            {
                                self.toggle_selected_topmost();
                            }
                        });
                    });
                    if excluded {
                        ui.label(
                            RichText::new("This window is protected by an exclusion rule.")
                                .color(Color32::from_rgb(244, 177, 84)),
                        );
                    }
                    ui.add_space(18.0);
                    let mut opacity = self
                        .opacity_cache
                        .get(&window.identity())
                        .copied()
                        .unwrap_or(window.opacity_percent);
                    ui.horizontal(|ui| {
                        ui.label("Opacity");
                        let changed = ui
                            .add_enabled(
                                !excluded,
                                egui::Slider::new(
                                    &mut opacity,
                                    self.config.opacity.minimum_percent..=100,
                                )
                                .suffix("%")
                                .show_value(true),
                            )
                            .changed();
                        if changed {
                            self.set_selected_opacity(opacity);
                        }
                        if ui.add_enabled(!excluded, egui::Button::new("Reset")).clicked() {
                            self.set_selected_opacity(100);
                        }
                    });
                    ui.horizontal(|ui| {
                        ui.label(RichText::new("Quick").small().color(Color32::GRAY));
                        let presets = [self.config.opacity.minimum_percent, 50, 75, 100];
                        let mut previous = None;
                        for preset in presets {
                            if preset < self.config.opacity.minimum_percent
                                || previous == Some(preset)
                            {
                                continue;
                            }
                            previous = Some(preset);
                            if ui
                                .add_enabled(
                                    !excluded,
                                    egui::Button::new(format!("{preset}%")).small(),
                                )
                                .clicked()
                            {
                                self.set_selected_opacity(preset);
                            }
                        }
                    });
                    ui.add_space(8.0);
                    let mut click_through = window.click_through;
                    if ui
                        .add_enabled(
                            !excluded,
                            egui::Checkbox::new(&mut click_through, "Mouse click-through"),
                        )
                        .on_hover_text("The target ignores clicks until this is disabled from TopFade's window list.")
                        .changed()
                    {
                        if click_through && self.config.behavior.confirm_click_through {
                            self.pending_click_through = Some(window.clone());
                            self.status = "Click-through confirmation required".into();
                        } else {
                            self.set_click_through(&window, click_through);
                        }
                    }
                } else {
                    ui.label(RichText::new("No target selected").size(20.0).strong());
                    ui.label("Focus a normal application window, then return here and select it.");
                }
                ui.add_space(16.0);
                if ui.button("Use currently focused window").clicked() {
                    self.select_focused();
                }
            });

        self.render_click_through_confirmation(ui.ctx());

        ui.add_space(18.0);
        ui.horizontal(|ui| {
            ui.label(RichText::new("Open windows").size(17.0).strong());
            if ui.small_button("Refresh").clicked() {
                self.refresh_windows();
            }
        });
        ui.horizontal(|ui| {
            ui.add(
                egui::TextEdit::singleline(&mut self.window_search)
                    .hint_text("Search title or application")
                    .desired_width(f32::INFINITY),
            );
            ui.label(
                RichText::new(format!("{} total", self.recent_windows.len()))
                    .small()
                    .color(Color32::GRAY),
            );
        });
        let query = self.window_search.trim().to_lowercase();
        let windows = self
            .recent_windows
            .iter()
            .filter(|window| {
                query.is_empty()
                    || window.title.to_lowercase().contains(&query)
                    || window.executable.to_lowercase().contains(&query)
            })
            .cloned()
            .collect::<Vec<_>>();
        egui::ScrollArea::vertical()
            .max_height(220.0)
            .show(ui, |ui| {
                if windows.is_empty() {
                    ui.label(RichText::new("No matching windows").color(Color32::GRAY));
                }
                for window in windows {
                    let selected = self
                        .selected
                        .as_ref()
                        .is_some_and(|item| item.identity() == window.identity());
                    let executable = Path::new(&window.executable)
                        .file_name()
                        .and_then(|name| name.to_str())
                        .unwrap_or("Unknown application");
                    let state = if window.topmost && window.opacity_percent < 100 {
                        format!(" · pinned · {}%", window.opacity_percent)
                    } else if window.topmost {
                        " · pinned".into()
                    } else if window.opacity_percent < 100 {
                        format!(" · {}%", window.opacity_percent)
                    } else {
                        String::new()
                    };
                    let label = format!("{}  —  {}{}", window.title, executable, state);
                    if ui.selectable_label(selected, label).clicked() {
                        self.selected = Some(window);
                    }
                }
            });
    }

    fn render_preferences(&mut self, ui: &mut egui::Ui) {
        page_heading(
            ui,
            "Preferences",
            "Everything here has an active runtime purpose.",
        );
        ui.add_space(12.0);
        egui::ScrollArea::vertical()
            .id_salt("topfade-preferences-scroll")
            .auto_shrink([false, false])
            .show(ui, |ui| {
                section(ui, "Hotkeys", |ui| {
                    ui.label("Toggle focused window on top");
                    ui.text_edit_singleline(&mut self.config.hotkeys.toggle_topmost);
                    ui.label("Show preferences");
                    ui.text_edit_singleline(&mut self.config.hotkeys.show_preferences);
                    ui.small("Format examples: Control+Super+KeyT, Control+Alt+Comma");
                });
                section(ui, "Opacity wheel", |ui| {
                    ui.horizontal(|ui| {
                        ui.label("Minimum");
                        ui.add(
                            egui::Slider::new(&mut self.config.opacity.minimum_percent, 10..=95)
                                .suffix("%"),
                        );
                    });
                    ui.horizontal(|ui| {
                        ui.label("Wheel step");
                        ui.add(
                            egui::Slider::new(&mut self.config.opacity.step_percent, 1..=25)
                                .suffix("%"),
                        );
                    });
                    ui.checkbox(
                        &mut self.config.opacity.target_under_cursor,
                        "Fade the window under the cursor",
                    );
                    ui.checkbox(
                        &mut self.config.opacity.consume_alt_shift_wheel,
                        "Consume Alt+Shift+wheel so the target does not also scroll",
                    );
                    ui.checkbox(
                        &mut self.config.opacity.show_overlay,
                        "Show the fader overlay",
                    );
                    ui.horizontal(|ui| {
                        ui.label("Fader duration");
                        ui.add(
                            egui::Slider::new(
                                &mut self.config.opacity.overlay_duration_ms,
                                300..=5_000,
                            )
                            .suffix(" ms"),
                        );
                    });
                });
                section(ui, "Behavior", |ui| {
                    ui.checkbox(
                        &mut self.config.behavior.remember_pinned_windows,
                        "Remember pinned applications",
                    );
                    ui.checkbox(
                        &mut self.config.behavior.restore_when_apps_reopen,
                        "Restore remembered state when applications reopen",
                    );
                    ui.checkbox(
                        &mut self.config.behavior.close_to_tray,
                        "Close the preferences window to the tray",
                    );
                    ui.checkbox(
                        &mut self.config.behavior.start_minimized,
                        "Start hidden in the tray",
                    );
                    if self.tray.is_none() {
                        ui.label(
                            RichText::new(
                                "The system tray is unavailable, so TopFade will stay visible and closing the window will exit.",
                            )
                            .small()
                            .color(Color32::from_rgb(244, 177, 84)),
                        );
                    }
                    ui.checkbox(&mut self.config.behavior.launch_at_login, "Launch at login");
                    ui.checkbox(
                        &mut self.config.behavior.confirm_click_through,
                        "Confirm before enabling mouse click-through",
                    );
                });
                section(ui, "Appearance", |ui| {
                    ui.horizontal(|ui| {
                        ui.label("Accent color");
                        ui.color_edit_button_srgb(&mut self.config.appearance.accent_rgb);
                    });
                    ui.checkbox(
                        &mut self.config.appearance.show_window_title_in_overlay,
                        "Show the window title in the opacity fader",
                    );
                });
                section(ui, "Diagnostics", |ui| {
                    egui::ComboBox::from_id_salt("topfade-log-level")
                        .selected_text(&self.config.diagnostics.log_level)
                        .show_ui(ui, |ui| {
                            for level in ["trace", "debug", "info", "warn", "error"] {
                                ui.selectable_value(
                                    &mut self.config.diagnostics.log_level,
                                    level.into(),
                                    level,
                                );
                            }
                        });
                    ui.horizontal(|ui| {
                        ui.label("Keep logs");
                        ui.add(
                            egui::Slider::new(&mut self.config.diagnostics.retention_days, 1..=90)
                                .suffix(" days"),
                        );
                    });
                    ui.horizontal(|ui| {
                        ui.label("Maximum log storage");
                        ui.add(
                            egui::Slider::new(&mut self.config.diagnostics.max_total_mb, 2..=250)
                                .suffix(" MB"),
                        );
                    });
                });
                ui.add_space(12.0);
                ui.horizontal(|ui| {
                    if ui
                        .add_enabled(
                            self.config != self.persisted_config,
                            egui::Button::new("Save all changes"),
                        )
                        .clicked()
                    {
                        self.save_preferences();
                    }
                    if ui.button("Discard all changes").clicked() {
                        self.config = self.persisted_config.clone();
                        self.status = "Unsaved changes discarded".into();
                    }
                });
            });
    }

    fn render_rules(&mut self, ui: &mut egui::Ui) {
        page_heading(
            ui,
            "Rules",
            "Automatically pin, fade, or exclude matching applications.",
        );
        ui.add_space(12.0);
        let selected_template = self.selected.as_ref().and_then(|window| {
            let path = Path::new(&window.executable);
            let executable = path.file_name()?.to_str()?.to_owned();
            let name = path
                .file_stem()
                .and_then(|value| value.to_str())
                .unwrap_or(&executable)
                .to_owned();
            Some(WindowRule {
                name,
                executable_contains: executable,
                ..WindowRule::default()
            })
        });
        let mut remove = None;
        let mut move_rule = None;
        let mut save_requested = false;
        let mut discard_requested = false;
        egui::ScrollArea::vertical()
            .id_salt("topfade-rules-scroll")
            .auto_shrink([false, false])
            .show(ui, |ui| {
                ui.horizontal_wrapped(|ui| {
                    if ui.button("Add blank rule").clicked() {
                        self.config.rules.push(WindowRule::default());
                    }
                    if let Some(template) = &selected_template {
                        if ui.button("Add rule for selected app").clicked() {
                            self.config.rules.push(template.clone());
                        }
                    }
                    if ui
                        .add_enabled(
                            self.config != self.persisted_config,
                            egui::Button::new("Save all changes"),
                        )
                        .clicked()
                    {
                        save_requested = true;
                    }
                    if ui
                        .add_enabled(
                            self.config != self.persisted_config,
                            egui::Button::new("Discard all changes"),
                        )
                        .clicked()
                    {
                        discard_requested = true;
                    }
                });
                ui.small(
                    "Exclusions always take priority. Automatic rules run top to bottom; rules with no pin or fade action are ignored.",
                );
                ui.add_space(10.0);

                if self.config.rules.is_empty() {
                    ui.label(
                        RichText::new("No automatic rules. Manual pinning and fading still work.")
                            .color(Color32::GRAY),
                    );
                }

                let rule_count = self.config.rules.len();
                for (index, rule) in self.config.rules.iter_mut().enumerate() {
                    let unbounded = rule.executable_contains.trim().is_empty()
                        && rule.title_contains.trim().is_empty();
                    egui::Frame::new()
                        .fill(Color32::from_rgb(31, 32, 35))
                        .corner_radius(12)
                        .inner_margin(egui::Margin::same(14))
                        .stroke(Stroke::new(1.0_f32, Color32::from_rgb(52, 54, 58)))
                        .show(ui, |ui| {
                            ui.horizontal(|ui| {
                                ui.add(
                                    egui::TextEdit::singleline(&mut rule.name)
                                        .hint_text("Rule name")
                                        .desired_width(f32::INFINITY),
                                );
                                if ui
                                    .add_enabled(index > 0, egui::Button::new("↑").small())
                                    .on_hover_text("Move rule up")
                                    .clicked()
                                {
                                    move_rule = Some((index, index - 1));
                                }
                                if ui
                                    .add_enabled(
                                        index + 1 < rule_count,
                                        egui::Button::new("↓").small(),
                                    )
                                    .on_hover_text("Move rule down")
                                    .clicked()
                                {
                                    move_rule = Some((index, index + 1));
                                }
                                if ui.small_button("Remove").clicked() {
                                    remove = Some(index);
                                }
                            });
                            if unbounded {
                                ui.label(
                                    RichText::new("Matches every controllable window")
                                        .color(Color32::from_rgb(244, 177, 84)),
                                );
                            }
                            ui.horizontal(|ui| {
                                ui.label("Executable contains");
                                ui.add(
                                    egui::TextEdit::singleline(
                                        &mut rule.executable_contains,
                                    )
                                    .hint_text("example.exe")
                                    .desired_width(f32::INFINITY),
                                );
                            });
                            ui.horizontal(|ui| {
                                ui.label("Title contains");
                                ui.add(
                                    egui::TextEdit::singleline(&mut rule.title_contains)
                                        .hint_text("optional title fragment")
                                        .desired_width(f32::INFINITY),
                                );
                            });
                            ui.checkbox(&mut rule.exclude, "Exclude from TopFade");
                            ui.add_enabled_ui(!rule.exclude, |ui| {
                                ui.horizontal(|ui| {
                                    ui.checkbox(&mut rule.auto_pin, "Pin on launch");
                                    ui.label("Opacity");
                                    ui.add(
                                        egui::Slider::new(
                                            &mut rule.opacity_percent,
                                            10..=100,
                                        )
                                        .suffix("%"),
                                    );
                                });
                            });
                            if rule.exclude {
                                ui.small("Pin and opacity settings are ignored for exclusions.");
                            } else if !rule.has_automatic_action() {
                                ui.label(
                                    RichText::new(
                                        "No automatic action is enabled; this rule will be ignored.",
                                    )
                                    .color(Color32::from_rgb(244, 177, 84)),
                                );
                            }
                        });
                    ui.add_space(8.0);
                }
            });
        if let Some(index) = remove {
            self.config.rules.remove(index);
        } else if let Some((from, to)) = move_rule {
            self.config.rules.swap(from, to);
        }
        if discard_requested {
            self.config = self.persisted_config.clone();
            self.status = "Unsaved rule changes discarded".into();
        } else if save_requested {
            self.save_preferences();
        }
    }

    fn render_diagnostics(&mut self, ui: &mut egui::Ui) {
        page_heading(
            ui,
            "Diagnostics",
            "Crash evidence and runtime state, without telemetry.",
        );
        ui.add_space(12.0);
        let remembered = self.runtime_state.remembered_windows.clone();
        let mut forget = None;
        let mut clear_all = false;
        egui::ScrollArea::vertical()
            .id_salt("topfade-diagnostics-scroll")
            .auto_shrink([false, false])
            .show(ui, |ui| {
                section(ui, "Runtime", |ui| {
                    ui.label(format!("Backend: {}", self.backend.platform_name()));
                    ui.label(format!(
                        "Direct control: {}",
                        self.backend.supports_direct_window_control()
                    ));
                    ui.label(self.backend.permission_status());
                    ui.label(format!("Visible windows: {}", self.recent_windows.len()));
                    ui.label(format!("Remembered applications: {}", remembered.len()));
                    ui.label(format!(
                        "State pending save: {}",
                        self.runtime_state_dirty
                    ));
                });
                section(ui, "Remembered applications", |ui| {
                    ui.small(
                        "Forgetting state only stops future restoration. It does not alter windows that are currently open.",
                    );
                    if remembered.is_empty() {
                        ui.label(RichText::new("Nothing is remembered.").color(Color32::GRAY));
                    }
                    for entry in &remembered {
                        let name = Path::new(&entry.executable)
                            .file_name()
                            .and_then(|value| value.to_str())
                            .unwrap_or(&entry.executable);
                        ui.horizontal(|ui| {
                            ui.vertical(|ui| {
                                ui.label(RichText::new(name).strong());
                                ui.label(
                                    RichText::new(format!(
                                        "{} · {}% · {}",
                                        if entry.topmost { "pinned" } else { "not pinned" },
                                        entry.opacity_percent,
                                        entry.title_hint
                                    ))
                                    .small()
                                    .color(Color32::GRAY),
                                );
                            });
                            ui.with_layout(
                                egui::Layout::right_to_left(egui::Align::Center),
                                |ui| {
                                    if ui.small_button("Forget").clicked() {
                                        forget = Some(entry.executable.clone());
                                    }
                                },
                            );
                        });
                        ui.separator();
                    }
                    clear_all = ui
                        .add_enabled(
                            !remembered.is_empty(),
                            egui::Button::new("Clear all remembered state"),
                        )
                        .clicked();
                });
                section(ui, "Paths", |ui| {
                    ui.monospace(self.paths.data_dir.display().to_string());
                    ui.horizontal(|ui| {
                        if ui.button("Open data folder").clicked() {
                            if let Err(error) = open_path(&self.paths.data_dir) {
                                self.status = format!("Could not open data folder: {error:#}");
                            }
                        }
                        if ui.button("Export report").clicked() {
                            self.export_diagnostics();
                        }
                    });
                });
                section(ui, "Validation", |ui| {
                    ui.label("The release self-test changes a dedicated local fixture window briefly, verifies topmost, opacity, and click-through, then restores and closes it.");
                    ui.monospace("topfade.exe --self-test");
                });
            });
        if let Some(executable) = forget {
            self.forget_remembered_executable(&executable);
        } else if clear_all {
            self.clear_remembered_state();
        }
    }
}

fn restoration_needed_for(config: &AppConfig, runtime_state: &RuntimeState) -> bool {
    (config.behavior.restore_when_apps_reopen && !runtime_state.remembered_windows.is_empty())
        || config.rules.iter().any(WindowRule::has_automatic_action)
}

impl eframe::App for TopFadeApp {
    fn logic(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.handle_activation(ctx);
        self.handle_input(ctx);
        self.handle_tray(ctx);
        if let Some(due) = self.restore_scan_due {
            let now = Instant::now();
            if now >= due {
                self.restore_scan_due = None;
                self.restore_remembered_and_rules();
            } else {
                ctx.request_repaint_after(due - now);
            }
        }
        if let Some(due) = self.runtime_state_save_due {
            let now = Instant::now();
            if now >= due {
                self.flush_runtime_state();
            } else {
                ctx.request_repaint_after(due - now);
            }
        }
        if ctx.input(|input| input.viewport().close_requested()) && !self.quit_requested {
            if can_hide_to_tray(self.config.behavior.close_to_tray, self.tray.is_some()) {
                ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
                ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
            } else if has_staged_config_changes(&self.config, &self.persisted_config) {
                ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
                self.quit_confirmation_requested = true;
                self.status = "Save or discard the staged changes before quitting".into();
            }
        }
        if self.quit_requested {
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        self.render_navigation(ui);
        egui::Panel::bottom("status")
            .frame(
                egui::Frame::new()
                    .fill(Color32::from_rgb(22, 23, 25))
                    .inner_margin(egui::Margin::symmetric(16, 8)),
            )
            .show_inside(ui, |ui| {
                ui.label(RichText::new(&self.status).small().color(Color32::GRAY));
            });
        egui::CentralPanel::default()
            .frame(
                egui::Frame::new()
                    .fill(Color32::from_rgb(19, 20, 22))
                    .inner_margin(egui::Margin::same(24)),
            )
            .show_inside(ui, |ui| match self.page {
                Page::Control => self.render_control(ui),
                Page::Preferences => self.render_preferences(ui),
                Page::Rules => self.render_rules(ui),
                Page::Diagnostics => self.render_diagnostics(ui),
            });
        self.render_quit_confirmation(&ctx);
    }

    fn on_exit(&mut self, _gl: Option<&eframe::glow::Context>) {
        if has_staged_config_changes(&self.config, &self.persisted_config) {
            diagnostics::record_event("unsaved preference edits discarded during shutdown");
            warn!("unsaved preference edits discarded during shutdown");
        }
        if self.runtime_state_dirty {
            if let Err(error) = self.runtime_state.save(&self.paths) {
                error!(
                    path = %self.paths.state_file.display(),
                    error = %format!("{error:#}"),
                    "runtime state save failed during shutdown"
                );
            }
        }
        drop(self.activation.take());
        drop(self.input.take());
        drop(self.tray.take());
        diagnostics::record_event("shutdown complete");
        info!("TopFade shutdown complete");
    }
}

pub fn generate_app_icon(size: u32) -> Arc<egui::IconData> {
    let mut rgba = vec![0_u8; (size * size * 4) as usize];
    let center = (size as f32 - 1.0) / 2.0;
    let radius = center - 2.0;
    for y in 0..size {
        for x in 0..size {
            let dx = x as f32 - center;
            let dy = y as f32 - center;
            let distance = (dx * dx + dy * dy).sqrt();
            let index = ((y * size + x) * 4) as usize;
            if distance <= radius {
                let pin = (dx.abs() < size as f32 * 0.08 && dy > -(size as f32) * 0.05)
                    || (dy < -(size as f32) * 0.04
                        && dy > -(size as f32) * 0.28
                        && dx.abs() < size as f32 * 0.24);
                let color = if pin {
                    [255, 246, 230, 255]
                } else {
                    [232, 91, 63, 255]
                };
                rgba[index..index + 4].copy_from_slice(&color);
            }
        }
    }
    Arc::new(egui::IconData {
        rgba,
        width: size,
        height: size,
    })
}

fn configure_style(ctx: &egui::Context) {
    let mut visuals = egui::Visuals::dark();
    visuals.panel_fill = Color32::from_rgb(19, 20, 22);
    visuals.window_fill = Color32::from_rgb(27, 28, 31);
    visuals.extreme_bg_color = Color32::from_rgb(14, 15, 17);
    visuals.selection.bg_fill = Color32::from_rgb(232, 91, 63);
    visuals.widgets.active.bg_fill = Color32::from_rgb(232, 91, 63);
    visuals.widgets.hovered.bg_fill = Color32::from_rgb(60, 61, 65);
    ctx.set_visuals(visuals);
    let mut style = (*ctx.global_style()).clone();
    style.spacing.item_spacing = Vec2::new(10.0, 10.0);
    style.spacing.button_padding = Vec2::new(14.0, 8.0);
    ctx.set_global_style(style);
}

fn accent(config: &AppConfig) -> Color32 {
    Color32::from_rgb(
        config.appearance.accent_rgb[0],
        config.appearance.accent_rgb[1],
        config.appearance.accent_rgb[2],
    )
}

fn nav_button(ui: &mut egui::Ui, current: &mut Page, page: Page, label: &str) {
    let selected = *current == page;
    if ui
        .add_sized(
            [154.0, 38.0],
            egui::Button::new(RichText::new(label).size(15.0))
                .selected(selected)
                .fill(if selected {
                    Color32::from_rgb(46, 47, 51)
                } else {
                    Color32::TRANSPARENT
                }),
        )
        .clicked()
    {
        *current = page;
    }
}

fn page_heading(ui: &mut egui::Ui, title: &str, subtitle: &str) {
    ui.label(RichText::new(title).size(27.0).strong());
    ui.label(RichText::new(subtitle).size(14.0).color(Color32::GRAY));
}

fn section(ui: &mut egui::Ui, title: &str, content: impl FnOnce(&mut egui::Ui)) {
    egui::Frame::new()
        .fill(Color32::from_rgb(31, 32, 35))
        .corner_radius(14)
        .inner_margin(egui::Margin::same(16))
        .stroke(Stroke::new(1.0_f32, Color32::from_rgb(52, 54, 58)))
        .show(ui, |ui| {
            ui.label(RichText::new(title).size(17.0).strong());
            ui.add_space(4.0);
            content(ui);
        });
    ui.add_space(10.0);
}

fn apply_window_state_transactionally(
    backend: &dyn WindowBackend,
    window: &WindowInfo,
    requested_topmost: Option<bool>,
    requested_opacity: Option<u8>,
) -> anyhow::Result<()> {
    let target = window.identity();
    let topmost_changed = requested_topmost.is_some_and(|value| value != window.topmost);
    if let Some(topmost) = requested_topmost.filter(|value| *value != window.topmost) {
        backend.set_topmost(target, topmost).map_err(|error| {
            anyhow::anyhow!(
                "topmost restoration failed for 0x{:X}: {error:#}",
                window.id.0
            )
        })?;
    }

    if let Some(opacity) = requested_opacity.filter(|value| *value != window.opacity_percent) {
        if let Err(error) = backend.set_opacity(target, opacity) {
            let primary = format!(
                "opacity restoration failed for 0x{:X}: {error:#}",
                window.id.0
            );
            if topmost_changed {
                if let Err(rollback) = backend.set_topmost(target, window.topmost) {
                    anyhow::bail!(
                        "{primary}; topmost rollback also failed for 0x{:X}: {rollback:#}",
                        window.id.0
                    );
                }
            }
            anyhow::bail!(primary);
        }
    }
    Ok(())
}

fn remembered_window_matches(
    remembered: &RememberedWindow,
    window: &WindowInfo,
    same_executable_windows: usize,
) -> bool {
    if !remembered
        .executable
        .eq_ignore_ascii_case(&window.executable)
    {
        return false;
    }
    let title_hint = remembered.title_hint.trim();
    title_hint.is_empty()
        || same_executable_windows <= 1
        || window
            .title
            .to_lowercase()
            .contains(&title_hint.to_lowercase())
}

fn retain_live_window_tracking(
    opacity_cache: &mut HashMap<WindowIdentity, u8>,
    restored_windows: &mut HashSet<WindowIdentity>,
    live_identities: &HashSet<WindowIdentity>,
) {
    opacity_cache.retain(|identity, _| live_identities.contains(identity));
    restored_windows.retain(|identity| live_identities.contains(identity));
}

fn can_hide_to_tray(requested: bool, tray_available: bool) -> bool {
    requested && tray_available
}

fn has_staged_config_changes(current: &AppConfig, persisted: &AppConfig) -> bool {
    current != persisted
}

fn append_status(current: &str, message: &str) -> String {
    if current.trim().is_empty() || current == "Ready" {
        message.into()
    } else {
        format!("{current} | {message}")
    }
}

fn open_path(path: &Path) -> anyhow::Result<()> {
    #[cfg(target_os = "windows")]
    let status = std::process::Command::new("explorer.exe")
        .arg(path)
        .status()?;
    #[cfg(target_os = "macos")]
    let status = std::process::Command::new("open").arg(path).status()?;
    if !status.success() {
        anyhow::bail!("OS file manager exited with {status}");
    }
    Ok(())
}

fn apply_launch_at_login(enabled: bool) -> anyhow::Result<()> {
    #[cfg(target_os = "windows")]
    {
        use std::{os::windows::ffi::OsStrExt, slice};

        use anyhow::Context;
        use windows::{
            core::{w, PCWSTR},
            Win32::{
                Foundation::ERROR_FILE_NOT_FOUND,
                System::Registry::{
                    RegCloseKey, RegCreateKeyExW, RegDeleteValueW, RegOpenKeyExW, RegSetValueExW,
                    HKEY, HKEY_CURRENT_USER, KEY_SET_VALUE, REG_OPTION_NON_VOLATILE, REG_SZ,
                },
            },
        };

        let launch_value = if enabled {
            let executable = std::env::current_exe()?;
            let mut value = vec![u16::from(b'\"')];
            value.extend(executable.as_os_str().encode_wide());
            value.extend([u16::from(b'\"'), 0]);
            Some(value)
        } else {
            None
        };
        let mut key = HKEY::default();
        let open_status = unsafe {
            if enabled {
                RegCreateKeyExW(
                    HKEY_CURRENT_USER,
                    w!("Software\\Microsoft\\Windows\\CurrentVersion\\Run"),
                    None,
                    PCWSTR::null(),
                    REG_OPTION_NON_VOLATILE,
                    KEY_SET_VALUE,
                    None,
                    &raw mut key,
                    None,
                )
            } else {
                RegOpenKeyExW(
                    HKEY_CURRENT_USER,
                    w!("Software\\Microsoft\\Windows\\CurrentVersion\\Run"),
                    None,
                    KEY_SET_VALUE,
                    &raw mut key,
                )
            }
        };
        if !enabled && open_status == ERROR_FILE_NOT_FOUND {
            return Ok(());
        }
        open_status
            .ok()
            .context("could not open the current-user Run registry key")?;

        let operation = if enabled {
            let value = launch_value
                .as_ref()
                .expect("launch value exists when launch at login is enabled");
            // REG_SZ receives UTF-16 bytes, including the trailing NUL.
            let bytes = unsafe {
                slice::from_raw_parts(
                    value.as_ptr().cast::<u8>(),
                    value.len() * std::mem::size_of::<u16>(),
                )
            };
            unsafe { RegSetValueExW(key, w!("TopFade"), None, REG_SZ, Some(bytes)) }
                .ok()
                .context("could not enable TopFade launch at login")
        } else {
            let status = unsafe { RegDeleteValueW(key, w!("TopFade")) };
            if status == ERROR_FILE_NOT_FOUND {
                Ok(())
            } else {
                status
                    .ok()
                    .context("could not disable TopFade launch at login")
            }
        };
        let close = unsafe { RegCloseKey(key) }
            .ok()
            .context("could not close the current-user Run registry key");
        // Always attempt to close the key even if setting or deleting the value failed.
        let operation_result = operation;
        operation_result?;
        close?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;

    #[derive(Debug)]
    struct MutationState {
        topmost: bool,
        opacity: u8,
        topmost_calls: Vec<bool>,
        fail_opacity_once: bool,
    }

    struct FakeBackend {
        state: Mutex<MutationState>,
    }

    impl FakeBackend {
        fn new(fail_opacity_once: bool) -> Self {
            Self {
                state: Mutex::new(MutationState {
                    topmost: false,
                    opacity: 100,
                    topmost_calls: Vec::new(),
                    fail_opacity_once,
                }),
            }
        }
    }

    impl WindowBackend for FakeBackend {
        fn platform_name(&self) -> &'static str {
            "test"
        }

        fn focused_window(&self) -> anyhow::Result<Option<WindowInfo>> {
            Ok(None)
        }

        fn window_at_point(&self, _x: i32, _y: i32) -> anyhow::Result<Option<WindowInfo>> {
            Ok(None)
        }

        fn enumerate_windows(&self) -> anyhow::Result<Vec<WindowInfo>> {
            Ok(Vec::new())
        }

        fn inspect(&self, _id: NativeWindowId) -> anyhow::Result<WindowInfo> {
            anyhow::bail!("not used by this test")
        }

        fn set_topmost(&self, _target: WindowIdentity, enabled: bool) -> anyhow::Result<()> {
            let mut state = self.state.lock().unwrap();
            state.topmost_calls.push(enabled);
            state.topmost = enabled;
            Ok(())
        }

        fn set_opacity(&self, _target: WindowIdentity, percent: u8) -> anyhow::Result<()> {
            let mut state = self.state.lock().unwrap();
            if state.fail_opacity_once {
                state.fail_opacity_once = false;
                anyhow::bail!("injected opacity failure");
            }
            state.opacity = percent;
            Ok(())
        }

        fn set_click_through(&self, _target: WindowIdentity, _enabled: bool) -> anyhow::Result<()> {
            Ok(())
        }

        fn supports_direct_window_control(&self) -> bool {
            true
        }

        fn permission_status(&self) -> String {
            "test".into()
        }
    }

    fn window(executable: &str, title: &str) -> WindowInfo {
        WindowInfo {
            id: NativeWindowId(1),
            process_id: 10,
            title: title.into(),
            executable: executable.into(),
            rect: crate::platform::WindowRect::default(),
            topmost: false,
            opacity_percent: 100,
            click_through: false,
        }
    }

    #[test]
    fn single_application_window_restores_after_its_title_changes() {
        let remembered = RememberedWindow {
            executable: "C:\\Apps\\Editor.exe".into(),
            title_hint: "Old Project - Editor".into(),
            topmost: true,
            opacity_percent: 90,
        };
        assert!(remembered_window_matches(
            &remembered,
            &window("c:\\apps\\EDITOR.EXE", "New Project - Editor"),
            1,
        ));
    }

    #[test]
    fn multiple_application_windows_require_the_remembered_title() {
        let remembered = RememberedWindow {
            executable: "C:\\Apps\\Editor.exe".into(),
            title_hint: "PRIMARY PROJECT".into(),
            topmost: true,
            opacity_percent: 100,
        };
        assert!(remembered_window_matches(
            &remembered,
            &window("C:\\Apps\\Editor.exe", "Primary Project - Editor"),
            2,
        ));
        assert!(!remembered_window_matches(
            &remembered,
            &window("C:\\Apps\\Editor.exe", "Secondary Project - Editor"),
            2,
        ));
    }

    #[test]
    fn closed_window_tracking_is_pruned_without_removing_live_entries() {
        let live = WindowIdentity {
            id: NativeWindowId(10),
            process_id: 100,
        };
        let closed = WindowIdentity {
            id: NativeWindowId(20),
            process_id: 200,
        };
        let live_identities = HashSet::from([live]);
        let mut opacity_cache = HashMap::from([(live, 75), (closed, 60)]);
        let mut restored_windows = HashSet::from([live, closed]);

        retain_live_window_tracking(&mut opacity_cache, &mut restored_windows, &live_identities);

        assert_eq!(opacity_cache, HashMap::from([(live, 75)]));
        assert_eq!(restored_windows, HashSet::from([live]));
    }

    #[test]
    fn tray_hiding_requires_a_working_tray_owner() {
        assert!(can_hide_to_tray(true, true));
        assert!(!can_hide_to_tray(true, false));
        assert!(!can_hide_to_tray(false, true));
    }

    #[test]
    fn quit_confirmation_is_required_only_for_staged_configuration_changes() {
        let persisted = AppConfig::default();
        let mut staged = persisted.clone();
        assert!(!has_staged_config_changes(&staged, &persisted));

        staged.opacity.step_percent = 10;
        assert!(has_staged_config_changes(&staged, &persisted));
    }

    #[test]
    fn status_append_replaces_ready_and_preserves_existing_failures() {
        assert_eq!(
            append_status("Ready", "Tray unavailable"),
            "Tray unavailable"
        );
        assert_eq!(
            append_status("Hotkeys unavailable", "Tray unavailable"),
            "Hotkeys unavailable | Tray unavailable"
        );
    }

    #[test]
    fn restore_transaction_rolls_back_topmost_when_opacity_fails() {
        let backend = FakeBackend::new(true);
        let target = window("C:\\Apps\\Editor.exe", "Project");

        let error = apply_window_state_transactionally(&backend, &target, Some(true), Some(75))
            .expect_err("injected opacity failure should fail the transaction");

        assert!(format!("{error:#}").contains("injected opacity failure"));
        let state = backend.state.lock().unwrap();
        assert!(!state.topmost);
        assert_eq!(state.opacity, 100);
        assert_eq!(state.topmost_calls, [true, false]);
    }

    #[test]
    fn restore_transaction_skips_mutations_already_at_target_state() {
        let backend = FakeBackend::new(false);
        let target = window("C:\\Apps\\Editor.exe", "Project");

        apply_window_state_transactionally(&backend, &target, Some(false), Some(100)).unwrap();

        let state = backend.state.lock().unwrap();
        assert_eq!(state.topmost_calls, []);
        assert_eq!(state.opacity, 100);
    }
}
