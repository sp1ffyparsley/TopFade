use std::sync::Arc;

use anyhow::{Context, Result};
use crossbeam_channel::{bounded, Receiver};
use tray_icon::{
    menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem},
    Icon, MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent,
};

const TRAY_ACTION_CAPACITY: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayAction {
    Show,
    ToggleFocused,
    ResetFocusedOpacity,
    ExportDiagnostics,
    Quit,
}

pub struct AppTray {
    _icon: TrayIcon,
    receiver: Receiver<TrayAction>,
}

impl AppTray {
    pub fn new(wake: Arc<dyn Fn() + Send + Sync>) -> Result<Self> {
        let menu = Menu::new();
        let show = MenuItem::new("Open TopFade", true, None);
        let toggle = MenuItem::new("Toggle focused window on top", true, None);
        let reset = MenuItem::new("Reset focused window opacity", true, None);
        let diagnostics = MenuItem::new("Export diagnostic report", true, None);
        let quit = MenuItem::new("Quit", true, None);
        menu.append_items(&[
            &show,
            &PredefinedMenuItem::separator(),
            &toggle,
            &reset,
            &PredefinedMenuItem::separator(),
            &diagnostics,
            &PredefinedMenuItem::separator(),
            &quit,
        ])
        .context("failed to build tray menu")?;

        let icon = generated_tray_icon(32)?;
        let tray = TrayIconBuilder::new()
            .with_tooltip("TopFade - pin and fade windows")
            .with_menu(Box::new(menu))
            .with_icon(icon)
            .build()
            .context("failed to create the system tray icon")?;

        let (sender, receiver) = bounded(TRAY_ACTION_CAPACITY);
        let show_id = show.id().clone();
        let toggle_id = toggle.id().clone();
        let reset_id = reset.id().clone();
        let diagnostics_id = diagnostics.id().clone();
        let quit_id = quit.id().clone();
        let menu_sender = sender.clone();
        let menu_wake = wake.clone();
        MenuEvent::set_event_handler(Some(move |event: MenuEvent| {
            let action = if event.id == show_id {
                Some(TrayAction::Show)
            } else if event.id == toggle_id {
                Some(TrayAction::ToggleFocused)
            } else if event.id == reset_id {
                Some(TrayAction::ResetFocusedOpacity)
            } else if event.id == diagnostics_id {
                Some(TrayAction::ExportDiagnostics)
            } else if event.id == quit_id {
                Some(TrayAction::Quit)
            } else {
                None
            };
            if let Some(action) = action {
                let _ = menu_sender.try_send(action);
                menu_wake();
            }
        }));
        TrayIconEvent::set_event_handler(Some(move |event: TrayIconEvent| {
            if matches!(
                event,
                TrayIconEvent::Click {
                    button: MouseButton::Left,
                    button_state: MouseButtonState::Up,
                    ..
                }
            ) {
                let _ = sender.try_send(TrayAction::Show);
                wake();
            }
        }));

        Ok(Self {
            _icon: tray,
            receiver,
        })
    }

    pub fn poll(&self) -> Vec<TrayAction> {
        let mut actions = Vec::new();
        while let Ok(action) = self.receiver.try_recv() {
            actions.push(action);
        }
        actions
    }
}

impl Drop for AppTray {
    fn drop(&mut self) {
        MenuEvent::set_event_handler::<fn(MenuEvent)>(None);
        TrayIconEvent::set_event_handler::<fn(TrayIconEvent)>(None);
    }
}

fn generated_tray_icon(size: u32) -> Result<Icon> {
    let mut rgba = vec![0_u8; (size * size * 4) as usize];
    let center = (size as f32 - 1.0) / 2.0;
    let radius = center - 1.0;
    for y in 0..size {
        for x in 0..size {
            let dx = x as f32 - center;
            let dy = y as f32 - center;
            let distance = (dx * dx + dy * dy).sqrt();
            let index = ((y * size + x) * 4) as usize;
            if distance <= radius {
                let pin = (dx.abs() < size as f32 * 0.09 && dy > -(size as f32) * 0.08)
                    || (dy < -(size as f32) * 0.02
                        && dy > -(size as f32) * 0.30
                        && dx.abs() < size as f32 * 0.26);
                let color = if pin {
                    [255, 247, 232, 255]
                } else {
                    [232, 91, 63, 255]
                };
                rgba[index..index + 4].copy_from_slice(&color);
            }
        }
    }
    Icon::from_rgba(rgba, size, size).context("generated tray icon was invalid")
}
