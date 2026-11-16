use std::sync::Arc;

use anyhow::Result;
use serde::{Deserialize, Serialize};

#[cfg(target_os = "windows")]
mod windows;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct NativeWindowId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct WindowIdentity {
    pub id: NativeWindowId,
    pub process_id: u32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WindowRect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WindowInfo {
    pub id: NativeWindowId,
    pub process_id: u32,
    pub title: String,
    pub executable: String,
    pub rect: WindowRect,
    pub topmost: bool,
    pub opacity_percent: u8,
    pub click_through: bool,
}

impl WindowInfo {
    pub fn identity(&self) -> WindowIdentity {
        WindowIdentity {
            id: self.id,
            process_id: self.process_id,
        }
    }
}

pub trait WindowBackend: Send + Sync {
    fn platform_name(&self) -> &'static str;
    fn focused_window(&self) -> Result<Option<WindowInfo>>;
    fn window_at_point(&self, x: i32, y: i32) -> Result<Option<WindowInfo>>;
    fn enumerate_windows(&self) -> Result<Vec<WindowInfo>>;
    fn inspect(&self, id: NativeWindowId) -> Result<WindowInfo>;
    fn set_topmost(&self, target: WindowIdentity, enabled: bool) -> Result<()>;
    fn set_opacity(&self, target: WindowIdentity, percent: u8) -> Result<()>;
    fn set_click_through(&self, target: WindowIdentity, enabled: bool) -> Result<()>;
    fn supports_direct_window_control(&self) -> bool;
    fn permission_status(&self) -> String;
}

#[allow(clippy::unnecessary_wraps)]
pub fn create_backend() -> Result<Arc<dyn WindowBackend>> {
    #[cfg(target_os = "windows")]
    {
        Ok(Arc::new(windows::WindowsBackend::new()))
    }
    #[cfg(not(target_os = "windows"))]
    {
        anyhow::bail!("build the native macOS app from macos/TopFadeMac")
    }
}
