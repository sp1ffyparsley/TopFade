use std::{thread, time::Duration};

#[cfg(target_os = "windows")]
use std::path::PathBuf;

use anyhow::{Context, Result};
use tracing::{info, warn};

use crate::{
    config::AppPaths,
    diagnostics,
    platform::{WindowBackend, WindowInfo},
};

pub fn run(backend: &dyn WindowBackend, paths: &AppPaths) -> Result<()> {
    info!(platform = backend.platform_name(), "self-test started");
    let mut target = acquire_target(backend, paths)?;
    let original_topmost = target.window.topmost;
    let original_opacity = target.window.opacity_percent;
    let original_click_through = target.window.click_through;

    let check_result = run_window_checks(backend, &target.window);
    let restore_result = restore_window(
        backend,
        &target.window,
        original_topmost,
        original_opacity,
        original_click_through,
    );
    #[cfg(target_os = "windows")]
    let layered_restore_result = if check_result.is_ok() && restore_result.is_ok() {
        run_layered_restoration_check(backend, &target.window)
    } else {
        Ok(())
    };
    target.cleanup();

    if let Err(error) = check_result {
        if let Err(restore_error) = restore_result {
            return Err(error.context(format!("target restoration also failed: {restore_error:#}")));
        }
        return Err(error);
    }
    restore_result?;
    #[cfg(target_os = "windows")]
    layered_restore_result?;

    let report = diagnostics::export_report(paths, backend, None)?;
    info!(path = %report.display(), "self-test passed");
    println!(
        "TopFade self-test passed on {:?}. Report: {}",
        target.window.title,
        report.display()
    );
    Ok(())
}

#[cfg(target_os = "windows")]
fn run_layered_restoration_check(backend: &dyn WindowBackend, target: &WindowInfo) -> Result<()> {
    use std::ffi::c_void;

    use windows::Win32::{
        Foundation::COLORREF,
        UI::WindowsAndMessaging::{
            GetWindowLongPtrW, SetLayeredWindowAttributes, GWL_EXSTYLE, LWA_ALPHA, LWA_COLORKEY,
            WS_EX_LAYERED,
        },
    };

    let handle = usize::try_from(target.id.0).context("self-test HWND does not fit usize")?;
    let hwnd = windows::Win32::Foundation::HWND(handle as *mut c_void);
    let original_style = unsafe { GetWindowLongPtrW(hwnd, GWL_EXSTYLE) };
    if original_style & WS_EX_LAYERED.0 as isize != 0 {
        warn!(
            id = target.id.0,
            "layered-attribute restoration check skipped because the dedicated target was already layered"
        );
        return Ok(());
    }

    let preset_color_key = COLORREF(0x00FF_00FF);
    let preset_alpha = 173_u8;
    let preset_flags = LWA_ALPHA | LWA_COLORKEY;

    let check_result = (|| -> Result<()> {
        set_test_extended_style(hwnd, original_style | WS_EX_LAYERED.0 as isize)?;
        unsafe { SetLayeredWindowAttributes(hwnd, preset_color_key, preset_alpha, preset_flags) }
            .context("self-test could not preset layered attributes")?;

        backend
            .set_opacity(target.identity(), 82)
            .context("self-test could not fade an existing layered window")?;
        let (faded_color_key, faded_alpha, faded_flags) = read_test_layered_attributes(hwnd)?;
        let expected_faded_alpha = ((82_u16 * 255) / 100) as u8;
        if faded_color_key != preset_color_key
            || faded_alpha != expected_faded_alpha
            || faded_flags != preset_flags
        {
            anyhow::bail!(
                "self-test verification failed: existing layered attributes were not preserved while faded"
            );
        }

        backend
            .set_opacity(target.identity(), 100)
            .context("self-test could not restore an existing layered window")?;
        let (restored_color_key, restored_alpha, restored_flags) =
            read_test_layered_attributes(hwnd)?;
        if restored_color_key != preset_color_key
            || restored_alpha != preset_alpha
            || restored_flags != preset_flags
        {
            anyhow::bail!(
                "self-test verification failed: original layered attributes were not restored exactly"
            );
        }
        let restored_style = unsafe { GetWindowLongPtrW(hwnd, GWL_EXSTYLE) };
        if restored_style & WS_EX_LAYERED.0 as isize == 0 {
            anyhow::bail!(
                "self-test verification failed: the target's original layered style was removed"
            );
        }
        Ok(())
    })();

    // Clear any managed backend entry first, then restore the fixture's exact original raw style.
    let managed_cleanup = backend.set_opacity(target.identity(), 100);
    let raw_cleanup = set_test_extended_style(hwnd, original_style);
    check_result.context("existing layered-window restoration check failed")?;
    managed_cleanup.context("self-test could not clear layered-window managed state")?;
    raw_cleanup.context("self-test could not restore the fixture's original extended style")?;

    info!(
        id = target.id.0,
        "existing layered-window attributes restored exactly"
    );
    Ok(())
}

#[cfg(target_os = "windows")]
fn read_test_layered_attributes(
    hwnd: windows::Win32::Foundation::HWND,
) -> Result<(
    windows::Win32::Foundation::COLORREF,
    u8,
    windows::Win32::UI::WindowsAndMessaging::LAYERED_WINDOW_ATTRIBUTES_FLAGS,
)> {
    use windows::Win32::{
        Foundation::COLORREF,
        UI::WindowsAndMessaging::{GetLayeredWindowAttributes, LAYERED_WINDOW_ATTRIBUTES_FLAGS},
    };

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
    .context("self-test could not read layered attributes")?;
    Ok((color_key, alpha, flags))
}

#[cfg(target_os = "windows")]
fn set_test_extended_style(hwnd: windows::Win32::Foundation::HWND, style: isize) -> Result<()> {
    use windows::Win32::{
        Foundation::{GetLastError, SetLastError, WIN32_ERROR},
        UI::WindowsAndMessaging::{SetWindowLongPtrW, GWL_EXSTYLE},
    };

    unsafe { SetLastError(WIN32_ERROR(0)) };
    let previous = unsafe { SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style) };
    if previous == 0 {
        let error = unsafe { GetLastError() };
        if error != WIN32_ERROR(0) {
            anyhow::bail!("SetWindowLongPtrW failed with Win32 error {}", error.0);
        }
    }
    Ok(())
}

fn run_window_checks(backend: &dyn WindowBackend, target: &WindowInfo) -> Result<()> {
    backend
        .set_topmost(target.identity(), true)
        .context("self-test could not enable always-on-top")?;
    thread::sleep(Duration::from_millis(150));
    let pinned = backend.inspect(target.id)?;
    if !pinned.topmost {
        anyhow::bail!("self-test verification failed: target is not topmost after the API call");
    }

    backend
        .set_opacity(target.identity(), 82)
        .context("self-test could not set opacity")?;
    thread::sleep(Duration::from_millis(150));
    let faded = backend.inspect(target.id)?;
    if faded.opacity_percent != 82 {
        anyhow::bail!(
            "self-test verification failed: expected 82% opacity, got {}%",
            faded.opacity_percent
        );
    }

    backend
        .set_click_through(target.identity(), true)
        .context("self-test could not enable click-through")?;
    if !backend.inspect(target.id)?.click_through {
        anyhow::bail!("self-test verification failed: click-through did not become active");
    }
    backend
        .set_click_through(target.identity(), false)
        .context("self-test could not disable click-through")?;
    if backend.inspect(target.id)?.click_through {
        anyhow::bail!("self-test verification failed: click-through did not turn off");
    }
    Ok(())
}

fn restore_window(
    backend: &dyn WindowBackend,
    target: &WindowInfo,
    topmost: bool,
    opacity: u8,
    click_through: bool,
) -> Result<()> {
    let opacity_result = backend.set_opacity(target.identity(), opacity.max(10));
    let click_through_result = backend.set_click_through(target.identity(), click_through);
    let topmost_result = backend.set_topmost(target.identity(), topmost);
    opacity_result.context("self-test could not restore target opacity")?;
    click_through_result.context("self-test could not restore target click-through")?;
    topmost_result.context("self-test could not restore target topmost state")?;
    Ok(())
}

struct TestTarget {
    window: WindowInfo,
    #[cfg(target_os = "windows")]
    child: Option<std::process::Child>,
    #[cfg(target_os = "windows")]
    test_file: PathBuf,
}

impl TestTarget {
    fn cleanup(&mut self) {
        #[cfg(target_os = "windows")]
        {
            close_window(self.window.id);
            if let Some(child) = self.child.as_mut() {
                thread::sleep(Duration::from_millis(100));
                if child.try_wait().ok().flatten().is_none() {
                    let _ = child.kill();
                }
                let _ = child.wait();
            }
            if let Err(error) = std::fs::remove_file(&self.test_file) {
                if error.kind() != std::io::ErrorKind::NotFound {
                    warn!(
                        path = %self.test_file.display(),
                        %error,
                        "failed to remove self-test fixture"
                    );
                }
            }
        }
    }
}

#[cfg(target_os = "windows")]
fn acquire_target(backend: &dyn WindowBackend, paths: &AppPaths) -> Result<TestTarget> {
    use std::{fs, os::windows::process::CommandExt, process::Command, time::Instant};

    let test_file = paths.reports_dir.join("self-test-target.txt");
    fs::write(
        &test_file,
        "TopFade production self-test target.\nThis local file is intentionally reused to avoid cache growth.\n",
    )
    .with_context(|| format!("failed to write {}", test_file.display()))?;

    let result = (|| -> Result<TestTarget> {
        let notepad_is_open = backend.enumerate_windows()?.iter().any(|window| {
            window
                .executable
                .to_ascii_lowercase()
                .ends_with("\\notepad.exe")
        });
        if !notepad_is_open {
            let mut child = Command::new("notepad.exe")
                .arg(&test_file)
                .spawn()
                .context("failed to launch the dedicated Notepad self-test target")?;
            let window = match wait_for_window(backend, "self-test-target", Instant::now()) {
                Ok(window) => window,
                Err(error) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(error);
                }
            };
            info!(pid = window.process_id, title = %window.title, "dedicated Notepad target ready");
            return Ok(TestTarget {
                window,
                child: Some(child),
                test_file: test_file.clone(),
            });
        }

        warn!("Notepad is already open; using an isolated PowerShell WPF target instead");
        let title = format!("TopFade Self-Test {}", std::process::id());
        let escaped_title = title.replace('\'', "''");
        let escaped_path = test_file.display().to_string().replace('\'', "''");
        let script = format!(
            "$content=Get-Content -Raw -LiteralPath '{escaped_path}';\
             Add-Type -AssemblyName PresentationFramework;\
             $w=New-Object Windows.Window; $w.Title='{escaped_title}';\
             $w.Width=640; $w.Height=360; $w.WindowStartupLocation='CenterScreen';\
             $t=New-Object Windows.Controls.TextBlock; $t.Text=$content; $t.Margin=32;\
             $t.FontSize=20; $t.TextWrapping='Wrap'; $w.Content=$t; [void]$w.ShowDialog()"
        );
        let mut child = Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-STA", "-Command", &script])
            .creation_flags(0x0800_0000)
            .spawn()
            .context("failed to launch the isolated WPF self-test target")?;
        let window = match wait_for_window(backend, &title, Instant::now()) {
            Ok(window) => window,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        };
        info!(pid = window.process_id, title = %window.title, "isolated WPF target ready");
        Ok(TestTarget {
            window,
            child: Some(child),
            test_file: test_file.clone(),
        })
    })();
    if result.is_err() {
        if let Err(error) = fs::remove_file(&test_file) {
            if error.kind() != std::io::ErrorKind::NotFound {
                warn!(
                    path = %test_file.display(),
                    %error,
                    "failed to remove self-test fixture after target acquisition failure"
                );
            }
        }
    }
    result
}

#[cfg(target_os = "windows")]
fn wait_for_window(
    backend: &dyn WindowBackend,
    title_fragment: &str,
    started: std::time::Instant,
) -> Result<WindowInfo> {
    while started.elapsed() < Duration::from_secs(8) {
        if let Some(window) = backend.enumerate_windows()?.into_iter().find(|window| {
            window
                .title
                .to_ascii_lowercase()
                .contains(&title_fragment.to_ascii_lowercase())
        }) {
            return Ok(window);
        }
        thread::sleep(Duration::from_millis(100));
    }
    anyhow::bail!("timed out waiting for the dedicated self-test window {title_fragment:?}")
}

#[cfg(target_os = "windows")]
fn close_window(id: crate::platform::NativeWindowId) {
    use std::ffi::c_void;

    use windows::Win32::{
        Foundation::{HWND, LPARAM, WPARAM},
        UI::WindowsAndMessaging::{PostMessageW, WM_CLOSE},
    };

    let Ok(handle) = usize::try_from(id.0) else {
        return;
    };
    let hwnd = HWND(handle as *mut c_void);
    let _ = unsafe { PostMessageW(Some(hwnd), WM_CLOSE, WPARAM(0), LPARAM(0)) };
}

#[cfg(target_os = "macos")]
fn acquire_target(backend: &dyn WindowBackend, _paths: &AppPaths) -> Result<TestTarget> {
    let window = backend
        .focused_window()?
        .or_else(|| backend.enumerate_windows().ok()?.into_iter().next())
        .context("macOS self-test needs one selected replica window")?;
    Ok(TestTarget { window })
}
