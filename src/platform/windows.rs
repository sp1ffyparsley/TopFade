use std::{collections::HashMap, ffi::c_void, sync::Mutex};

use anyhow::{Context, Result};
use windows::{
    core::{w, BOOL, PCWSTR, PWSTR},
    Win32::{
        Foundation::{
            CloseHandle, GetLastError, SetLastError, COLORREF, HANDLE, HWND, LPARAM, POINT, RECT,
            WIN32_ERROR,
        },
        Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED},
        System::Threading::{
            GetCurrentProcessId, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_FORMAT,
            PROCESS_QUERY_LIMITED_INFORMATION,
        },
        UI::WindowsAndMessaging::{
            EnumWindows, GetAncestor, GetForegroundWindow, GetLayeredWindowAttributes, GetPropW,
            GetWindow, GetWindowLongPtrW, GetWindowRect, GetWindowTextLengthW, GetWindowTextW,
            GetWindowThreadProcessId, IsWindow, IsWindowVisible, RemovePropW,
            SetLayeredWindowAttributes, SetPropW, SetWindowLongPtrW, SetWindowPos, WindowFromPoint,
            GA_ROOT, GWL_EXSTYLE, GW_HWNDNEXT, HWND_NOTOPMOST, HWND_TOPMOST,
            LAYERED_WINDOW_ATTRIBUTES_FLAGS, LWA_ALPHA, SET_WINDOW_POS_FLAGS, SWP_NOACTIVATE,
            SWP_NOMOVE, SWP_NOOWNERZORDER, SWP_NOSIZE, WS_EX_LAYERED, WS_EX_TOOLWINDOW,
            WS_EX_TOPMOST, WS_EX_TRANSPARENT,
        },
    },
};

use super::{NativeWindowId, WindowBackend, WindowIdentity, WindowInfo, WindowRect};

const RECOVERY_MARKER: u32 = 0x5446_5031;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct LayeredAttributes {
    color_key: COLORREF,
    alpha: u8,
    flags: LAYERED_WINDOW_ATTRIBUTES_FLAGS,
}

#[derive(Debug, Clone, Copy, Default)]
struct ManagedStyle {
    opacity_percent: u8,
    click_through: bool,
    original_ex_style: isize,
    original_layered_attributes: Option<LayeredAttributes>,
}

pub struct WindowsBackend {
    process_id: u32,
    managed_styles: Mutex<HashMap<WindowIdentity, ManagedStyle>>,
}

impl WindowsBackend {
    pub fn new() -> Self {
        Self {
            process_id: unsafe { GetCurrentProcessId() },
            managed_styles: Mutex::new(HashMap::new()),
        }
    }

    fn hwnd(id: NativeWindowId) -> HWND {
        HWND(usize::try_from(id.0).expect("window handle fits in usize") as *mut c_void)
    }

    fn id(hwnd: HWND) -> NativeWindowId {
        NativeWindowId(hwnd.0 as usize as u64)
    }

    fn ensure_valid(target: WindowIdentity) -> Result<HWND> {
        let hwnd = Self::hwnd(target.id);
        if hwnd.0.is_null() || !unsafe { IsWindow(Some(hwnd)) }.as_bool() {
            anyhow::bail!("window 0x{:X} no longer exists", target.id.0);
        }
        let mut process_id = 0_u32;
        unsafe { GetWindowThreadProcessId(hwnd, Some(&raw mut process_id)) };
        if process_id == 0 || process_id != target.process_id {
            anyhow::bail!(
                "window 0x{:X} changed owners (expected PID {}, found PID {})",
                target.id.0,
                target.process_id,
                process_id
            );
        }
        Ok(hwnd)
    }

    fn window_info(&self, hwnd: HWND) -> Result<WindowInfo> {
        if hwnd.0.is_null() {
            anyhow::bail!("received a null window handle");
        }

        let mut process_id = 0_u32;
        unsafe { GetWindowThreadProcessId(hwnd, Some(&raw mut process_id)) };
        let title = window_text(hwnd);
        let executable = process_path(process_id).unwrap_or_default();
        let mut rect = RECT::default();
        unsafe { GetWindowRect(hwnd, &raw mut rect) }
            .with_context(|| format!("GetWindowRect failed for 0x{:X}", Self::id(hwnd).0))?;

        let style = unsafe { GetWindowLongPtrW(hwnd, GWL_EXSTYLE) };
        let id = Self::id(hwnd);
        let identity = WindowIdentity { id, process_id };
        let managed = {
            let styles = self
                .managed_styles
                .lock()
                .expect("managed style mutex poisoned");
            styles.get(&identity).copied()
        };
        let opacity_percent = actual_opacity(hwnd, style)
            .or_else(|| managed.map(|value| value.opacity_percent.max(1)))
            .unwrap_or(100);

        Ok(WindowInfo {
            id,
            process_id,
            title,
            executable,
            rect: WindowRect {
                x: rect.left,
                y: rect.top,
                width: rect.right - rect.left,
                height: rect.bottom - rect.top,
            },
            topmost: style & WS_EX_TOPMOST.0 as isize != 0,
            opacity_percent,
            click_through: style & WS_EX_TRANSPARENT.0 as isize != 0,
        })
    }

    fn is_candidate(&self, hwnd: HWND) -> bool {
        if hwnd.0.is_null() || !unsafe { IsWindowVisible(hwnd) }.as_bool() {
            return false;
        }

        let mut process_id = 0_u32;
        unsafe { GetWindowThreadProcessId(hwnd, Some(&raw mut process_id)) };
        if process_id == 0 || process_id == self.process_id {
            return false;
        }

        let style = unsafe { GetWindowLongPtrW(hwnd, GWL_EXSTYLE) };
        let title = window_text(hwnd);
        if style & WS_EX_TOOLWINDOW.0 as isize != 0
            || title.trim().is_empty()
            || title.eq_ignore_ascii_case("New notification")
            || is_windows_shell_surface(process_id)
        {
            return false;
        }

        let mut cloaked = 0_u32;
        let cloaked_result = unsafe {
            DwmGetWindowAttribute(
                hwnd,
                DWMWA_CLOAKED,
                (&raw mut cloaked).cast(),
                u32::try_from(size_of::<u32>()).expect("u32 size fits in u32"),
            )
        };
        cloaked_result.is_err() || cloaked == 0
    }

    fn acquire_managed_style(
        &self,
        target: WindowIdentity,
        hwnd: HWND,
        style: isize,
    ) -> Result<(ManagedStyle, bool)> {
        let mut styles = self
            .managed_styles
            .lock()
            .expect("managed style mutex poisoned");
        styles.retain(|managed_identity, _managed| {
            let managed_hwnd = Self::hwnd(managed_identity.id);
            if managed_hwnd.0.is_null() || !unsafe { IsWindow(Some(managed_hwnd)) }.as_bool() {
                return false;
            }
            let mut current_process_id = 0_u32;
            unsafe {
                GetWindowThreadProcessId(managed_hwnd, Some(&raw mut current_process_id));
            }
            current_process_id != 0 && current_process_id == managed_identity.process_id
        });
        if let Some(managed) = styles.get(&target).copied() {
            return Ok((managed, false));
        }
        drop(styles);

        if let Some(recovered) = recovered_managed_style(hwnd, style) {
            self.managed_styles
                .lock()
                .expect("managed style mutex poisoned")
                .insert(target, recovered);
            return Ok((recovered, false));
        }

        let original = ManagedStyle {
            opacity_percent: 100,
            click_through: false,
            original_ex_style: style,
            original_layered_attributes: layered_attributes(hwnd, style),
        };
        if original.original_ex_style & WS_EX_LAYERED.0 as isize != 0
            && original.original_layered_attributes.is_none()
        {
            anyhow::bail!(
                "window 0x{:X} uses per-pixel layered rendering that cannot be changed safely",
                target.id.0
            );
        }
        persist_original_style(hwnd, original)?;
        self.managed_styles
            .lock()
            .expect("managed style mutex poisoned")
            .insert(target, original);
        Ok((original, true))
    }

    fn release_managed_style(&self, target: WindowIdentity, hwnd: HWND) {
        self.managed_styles
            .lock()
            .expect("managed style mutex poisoned")
            .remove(&target);
        clear_recovery_properties(hwnd);
    }
}

impl WindowBackend for WindowsBackend {
    fn platform_name(&self) -> &'static str {
        "Windows"
    }

    fn focused_window(&self) -> Result<Option<WindowInfo>> {
        let mut hwnd = unsafe { GetForegroundWindow() };
        if self.is_candidate(hwnd) {
            return self.window_info(hwnd).map(Some);
        }

        let mut foreground_process_id = 0_u32;
        unsafe { GetWindowThreadProcessId(hwnd, Some(&raw mut foreground_process_id)) };
        let foreground_is_shell = window_text(hwnd).eq_ignore_ascii_case("New notification")
            || is_windows_shell_surface(foreground_process_id);
        if foreground_process_id != self.process_id && !foreground_is_shell {
            return Ok(None);
        }

        // The app the user just left is directly behind TopFade or a shell toast in Z order.
        for _ in 0..64 {
            let Ok(next) = (unsafe { GetWindow(hwnd, GW_HWNDNEXT) }) else {
                break;
            };
            if next.0.is_null() {
                break;
            }
            hwnd = next;
            if self.is_candidate(hwnd) {
                return self.window_info(hwnd).map(Some);
            }
        }
        Ok(None)
    }

    fn window_at_point(&self, x: i32, y: i32) -> Result<Option<WindowInfo>> {
        let point = POINT { x, y };
        let hit = unsafe { WindowFromPoint(point) };
        let mut root = unsafe { GetAncestor(hit, GA_ROOT) };

        // A TopFade fader can be the top hit even though it is mouse-pass-through. Walk the
        // top-level Z order until the first controllable window containing the pointer.
        for _ in 0..64 {
            if self.is_candidate(root) && window_contains_point(root, point) {
                return self.window_info(root).map(Some);
            }
            let Ok(next) = (unsafe { GetWindow(root, GW_HWNDNEXT) }) else {
                break;
            };
            if next.0.is_null() {
                break;
            }
            root = next;
        }
        Ok(None)
    }

    fn enumerate_windows(&self) -> Result<Vec<WindowInfo>> {
        struct Context<'a> {
            backend: &'a WindowsBackend,
            windows: Vec<WindowInfo>,
        }

        unsafe extern "system" fn callback(hwnd: HWND, lparam: LPARAM) -> BOOL {
            let context = unsafe { &mut *(lparam.0 as *mut Context<'_>) };
            if context.backend.is_candidate(hwnd) {
                if let Ok(info) = context.backend.window_info(hwnd) {
                    context.windows.push(info);
                }
            }
            true.into()
        }

        let mut context = Context {
            backend: self,
            windows: Vec::new(),
        };
        unsafe {
            EnumWindows(
                Some(callback),
                LPARAM((&raw mut context).cast::<c_void>() as isize),
            )
        }
        .context("EnumWindows failed")?;
        Ok(context.windows)
    }

    fn inspect(&self, id: NativeWindowId) -> Result<WindowInfo> {
        let hwnd = Self::hwnd(id);
        if hwnd.0.is_null() || !unsafe { IsWindow(Some(hwnd)) }.as_bool() {
            anyhow::bail!("window 0x{:X} no longer exists", id.0);
        }
        if !self.is_candidate(hwnd) {
            anyhow::bail!("window 0x{:X} is not controllable", id.0);
        }
        self.window_info(hwnd)
    }

    fn set_topmost(&self, target: WindowIdentity, enabled: bool) -> Result<()> {
        let hwnd = Self::ensure_valid(target)?;
        let insert_after = if enabled {
            HWND_TOPMOST
        } else {
            HWND_NOTOPMOST
        };
        let flags = SET_WINDOW_POS_FLAGS(
            SWP_NOMOVE.0 | SWP_NOSIZE.0 | SWP_NOACTIVATE.0 | SWP_NOOWNERZORDER.0,
        );
        unsafe { SetWindowPos(hwnd, Some(insert_after), 0, 0, 0, 0, flags) }.with_context(
            || {
                format!(
                    "failed to set topmost={enabled} for window 0x{:X}",
                    target.id.0
                )
            },
        )?;
        Ok(())
    }

    fn set_opacity(&self, target: WindowIdentity, percent: u8) -> Result<()> {
        let hwnd = Self::ensure_valid(target)?;
        let percent = percent.clamp(10, 100);
        let current_style = unsafe { GetWindowLongPtrW(hwnd, GWL_EXSTYLE) };
        let (original, newly_acquired) = self.acquire_managed_style(target, hwnd, current_style)?;
        let originally_layered = original.original_ex_style & WS_EX_LAYERED.0 as isize != 0;

        if percent == 100 && originally_layered {
            restore_layered_attributes(hwnd, target, original)?;
            if original.click_through {
                let mut updated = original;
                updated.opacity_percent = 100;
                self.managed_styles
                    .lock()
                    .expect("managed style mutex poisoned")
                    .insert(target, updated);
            } else {
                self.release_managed_style(target, hwnd);
            }
            return Ok(());
        }

        let layered_style = current_style | WS_EX_LAYERED.0 as isize;
        let added_layered_style = layered_style != current_style;
        if layered_style != current_style {
            if let Err(error) = set_extended_style(hwnd, layered_style) {
                if newly_acquired {
                    self.release_managed_style(target, hwnd);
                }
                return Err(error);
            }
        }

        let alpha = ((u16::from(percent) * 255) / 100) as u8;
        let attributes = original.original_layered_attributes.unwrap_or_default();
        let color_key = if originally_layered {
            attributes.color_key
        } else {
            COLORREF(0)
        };
        let flags = if originally_layered {
            attributes.flags | LWA_ALPHA
        } else {
            LWA_ALPHA
        };
        if let Err(error) = unsafe { SetLayeredWindowAttributes(hwnd, color_key, alpha, flags) }
            .with_context(|| format!("failed to set opacity for window 0x{:X}", target.id.0))
        {
            let rollback = added_layered_style
                .then(|| set_extended_style(hwnd, current_style))
                .transpose();
            if newly_acquired && rollback.as_ref().is_ok() {
                self.release_managed_style(target, hwnd);
            }
            if let Err(rollback) = rollback {
                anyhow::bail!(
                    "{error:#}; extended-style rollback also failed for window 0x{:X}: {rollback:#}",
                    target.id.0
                );
            }
            return Err(error);
        }

        let mut updated = original;
        updated.opacity_percent = percent;
        if percent == 100 && !updated.click_through && !originally_layered {
            let latest_style = unsafe { GetWindowLongPtrW(hwnd, GWL_EXSTYLE) };
            set_extended_style(hwnd, latest_style & !(WS_EX_LAYERED.0 as isize))?;
            self.release_managed_style(target, hwnd);
        } else {
            self.managed_styles
                .lock()
                .expect("managed style mutex poisoned")
                .insert(target, updated);
        }
        Ok(())
    }

    fn set_click_through(&self, target: WindowIdentity, enabled: bool) -> Result<()> {
        let hwnd = Self::ensure_valid(target)?;
        let current_style = unsafe { GetWindowLongPtrW(hwnd, GWL_EXSTYLE) };
        let (original, newly_acquired) = self.acquire_managed_style(target, hwnd, current_style)?;
        let mut new_style = if enabled {
            current_style | WS_EX_LAYERED.0 as isize | WS_EX_TRANSPARENT.0 as isize
        } else {
            (current_style & !(WS_EX_TRANSPARENT.0 as isize))
                | (original.original_ex_style & WS_EX_TRANSPARENT.0 as isize)
        };
        let finished = !enabled && original.opacity_percent >= 100;
        if finished && original.original_ex_style & WS_EX_LAYERED.0 as isize == 0 {
            new_style &= !(WS_EX_LAYERED.0 as isize);
        }
        if let Err(error) = set_extended_style(hwnd, new_style) {
            if newly_acquired {
                self.release_managed_style(target, hwnd);
            }
            return Err(error);
        }

        let mut styles = self
            .managed_styles
            .lock()
            .expect("managed style mutex poisoned");
        if finished {
            drop(styles);
            self.release_managed_style(target, hwnd);
        } else {
            let mut updated = original;
            updated.click_through = enabled;
            styles.insert(target, updated);
        }
        Ok(())
    }

    fn supports_direct_window_control(&self) -> bool {
        true
    }

    fn permission_status(&self) -> String {
        "Native Win32 access active. Elevated target applications require TopFade to run elevated."
            .into()
    }
}

fn persist_original_style(hwnd: HWND, style: ManagedStyle) -> Result<()> {
    clear_recovery_properties(hwnd);
    let result = (|| -> Result<()> {
        set_property_u32(
            hwnd,
            w!("TopFade.OriginalExStyle.v1"),
            u32::from_ne_bytes((style.original_ex_style as i32).to_ne_bytes()),
        )?;
        if let Some(attributes) = style.original_layered_attributes {
            set_property_u32(
                hwnd,
                w!("TopFade.OriginalColorKey.v1"),
                attributes.color_key.0,
            )?;
            set_property_u32(
                hwnd,
                w!("TopFade.OriginalAlpha.v1"),
                u32::from(attributes.alpha),
            )?;
            set_property_u32(
                hwnd,
                w!("TopFade.OriginalLayeredFlags.v1"),
                attributes.flags.0,
            )?;
        }
        // Publish the marker last so another TopFade process never consumes partial metadata.
        set_property_u32(hwnd, w!("TopFade.Managed.v1"), RECOVERY_MARKER)
    })();
    if result.is_err() {
        clear_recovery_properties(hwnd);
    }
    result.context("failed to persist crash-recovery metadata on the target window")
}

fn recovered_managed_style(hwnd: HWND, current_style: isize) -> Option<ManagedStyle> {
    if property_u32(hwnd, w!("TopFade.Managed.v1")) != RECOVERY_MARKER {
        return None;
    }

    let original_ex_style =
        i32::from_ne_bytes(property_u32(hwnd, w!("TopFade.OriginalExStyle.v1")).to_ne_bytes())
            as isize;
    let originally_layered = original_ex_style & WS_EX_LAYERED.0 as isize != 0;
    let original_layered_attributes = originally_layered.then(|| LayeredAttributes {
        color_key: COLORREF(property_u32(hwnd, w!("TopFade.OriginalColorKey.v1"))),
        alpha: u8::try_from(property_u32(hwnd, w!("TopFade.OriginalAlpha.v1"))).unwrap_or(255),
        flags: LAYERED_WINDOW_ATTRIBUTES_FLAGS(property_u32(
            hwnd,
            w!("TopFade.OriginalLayeredFlags.v1"),
        )),
    });
    let current_attributes = layered_attributes(hwnd, current_style);
    let opacity_percent = if originally_layered && current_attributes == original_layered_attributes
    {
        100
    } else {
        actual_opacity(hwnd, current_style).unwrap_or(100).max(1)
    };
    let original_transparent = original_ex_style & WS_EX_TRANSPARENT.0 as isize != 0;
    let current_transparent = current_style & WS_EX_TRANSPARENT.0 as isize != 0;

    Some(ManagedStyle {
        opacity_percent,
        click_through: current_transparent && !original_transparent,
        original_ex_style,
        original_layered_attributes,
    })
}

fn set_property_u32(hwnd: HWND, name: PCWSTR, value: u32) -> Result<()> {
    if value == 0 {
        return Ok(());
    }
    let data = HANDLE(value as usize as *mut c_void);
    unsafe { SetPropW(hwnd, name, Some(data)) }
        .with_context(|| format!("SetPropW failed for recovery value {value:#X}"))
}

fn property_u32(hwnd: HWND, name: PCWSTR) -> u32 {
    unsafe { GetPropW(hwnd, name) }.0 as usize as u32
}

fn clear_recovery_properties(hwnd: HWND) {
    for name in [
        w!("TopFade.Managed.v1"),
        w!("TopFade.OriginalExStyle.v1"),
        w!("TopFade.OriginalColorKey.v1"),
        w!("TopFade.OriginalAlpha.v1"),
        w!("TopFade.OriginalLayeredFlags.v1"),
    ] {
        let _ = unsafe { RemovePropW(hwnd, name) };
    }
}

fn layered_attributes(hwnd: HWND, ex_style: isize) -> Option<LayeredAttributes> {
    if ex_style & WS_EX_LAYERED.0 as isize == 0 {
        return None;
    }
    let mut color_key = COLORREF::default();
    let mut alpha = 255_u8;
    let mut flags = LAYERED_WINDOW_ATTRIBUTES_FLAGS::default();
    unsafe {
        GetLayeredWindowAttributes(
            hwnd,
            Some(&raw mut color_key),
            Some(&raw mut alpha),
            Some(&raw mut flags),
        )
    }
    .ok()?;
    (flags != LAYERED_WINDOW_ATTRIBUTES_FLAGS::default()).then_some(LayeredAttributes {
        color_key,
        alpha,
        flags,
    })
}

fn restore_layered_attributes(
    hwnd: HWND,
    target: WindowIdentity,
    style: ManagedStyle,
) -> Result<()> {
    let attributes = style.original_layered_attributes.with_context(|| {
        format!(
            "window 0x{:X} original layered attributes are unavailable",
            target.id.0
        )
    })?;
    unsafe {
        SetLayeredWindowAttributes(
            hwnd,
            attributes.color_key,
            attributes.alpha,
            attributes.flags,
        )
    }
    .with_context(|| {
        format!(
            "failed to restore original layered attributes for window 0x{:X}",
            target.id.0
        )
    })?;
    Ok(())
}

fn set_extended_style(hwnd: HWND, style: isize) -> Result<()> {
    unsafe { SetLastError(WIN32_ERROR(0)) };
    let previous = unsafe { SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style) };
    if previous == 0 {
        let error = unsafe { GetLastError() };
        if error.0 != 0 {
            anyhow::bail!(
                "SetWindowLongPtrW failed for {:?}: OS error {}",
                hwnd,
                error.0
            );
        }
    }
    Ok(())
}

fn window_text(hwnd: HWND) -> String {
    let length = unsafe { GetWindowTextLengthW(hwnd) };
    if length <= 0 {
        return String::new();
    }
    let mut buffer = vec![0_u16; usize::try_from(length).expect("positive title length") + 1];
    let read = unsafe { GetWindowTextW(hwnd, &mut buffer) };
    String::from_utf16_lossy(
        &buffer[..usize::try_from(read.max(0)).expect("non-negative title length")],
    )
}

fn window_contains_point(hwnd: HWND, point: POINT) -> bool {
    let mut rect = RECT::default();
    unsafe { GetWindowRect(hwnd, &raw mut rect) }.is_ok()
        && point.x >= rect.left
        && point.x < rect.right
        && point.y >= rect.top
        && point.y < rect.bottom
}

fn actual_opacity(hwnd: HWND, ex_style: isize) -> Option<u8> {
    if ex_style & WS_EX_LAYERED.0 as isize == 0 {
        return Some(100);
    }
    let mut alpha = 255_u8;
    let mut flags = LAYERED_WINDOW_ATTRIBUTES_FLAGS::default();
    unsafe { GetLayeredWindowAttributes(hwnd, None, Some(&raw mut alpha), Some(&raw mut flags)) }
        .ok()?;
    if flags & LWA_ALPHA == LAYERED_WINDOW_ATTRIBUTES_FLAGS::default() {
        return None;
    }
    let percent = (u16::from(alpha) * 100 + 127) / 255;
    Some(u8::try_from(percent).expect("alpha percentage fits in u8"))
}

fn process_path(process_id: u32) -> Result<String> {
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, process_id) }
        .with_context(|| format!("OpenProcess failed for PID {process_id}"))?;
    let mut buffer = vec![0_u16; 32_768];
    let mut size = u32::try_from(buffer.len()).expect("process path buffer fits in u32");
    let result = unsafe {
        QueryFullProcessImageNameW(
            handle,
            PROCESS_NAME_FORMAT(0),
            PWSTR(buffer.as_mut_ptr()),
            &raw mut size,
        )
    };
    let _ = unsafe { CloseHandle(handle) };
    result.with_context(|| format!("QueryFullProcessImageNameW failed for PID {process_id}"))?;
    Ok(String::from_utf16_lossy(&buffer[..size as usize]))
}

fn is_windows_shell_surface(process_id: u32) -> bool {
    let Ok(path) = process_path(process_id) else {
        return false;
    };
    let executable = path
        .rsplit('\\')
        .next()
        .unwrap_or(&path)
        .to_ascii_lowercase();
    matches!(
        executable.as_str(),
        "lockapp.exe"
            | "searchapp.exe"
            | "searchhost.exe"
            | "shellexperiencehost.exe"
            | "startmenuexperiencehost.exe"
            | "textinputhost.exe"
    )
}
