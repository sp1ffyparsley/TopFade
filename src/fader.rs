use std::{
    sync::{mpsc, Mutex, OnceLock},
    thread::{self, JoinHandle},
};

use anyhow::{Context, Result};
use windows::{
    core::w,
    Win32::{
        Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM},
        Graphics::Gdi::{
            BeginPaint, CreateSolidBrush, DeleteObject, DrawTextW, EndPaint, FillRect,
            InvalidateRect, SetBkMode, SetTextColor, DT_END_ELLIPSIS, DT_LEFT, DT_NOPREFIX,
            DT_SINGLELINE, DT_VCENTER, PAINTSTRUCT, TRANSPARENT,
        },
        System::{LibraryLoader::GetModuleHandleW, Threading::GetCurrentThreadId},
        UI::WindowsAndMessaging::{
            CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetClientRect,
            GetMessageW, KillTimer, PostThreadMessageW, RegisterClassW, SetLayeredWindowAttributes,
            SetTimer, SetWindowPos, ShowWindow, TranslateMessage, CS_HREDRAW, CS_VREDRAW,
            HWND_TOPMOST, LWA_ALPHA, MSG, SWP_NOACTIVATE, SWP_SHOWWINDOW, SW_HIDE, WM_APP,
            WM_ERASEBKGND, WM_PAINT, WM_QUIT, WM_TIMER, WNDCLASSW, WS_EX_LAYERED, WS_EX_NOACTIVATE,
            WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_TRANSPARENT, WS_POPUP,
        },
    },
};

const SHOW_MESSAGE: u32 = WM_APP + 0x54;
const HIDE_TIMER_ID: usize = 1;

#[derive(Clone)]
pub struct FaderRequest {
    pub title: Option<String>,
    pub opacity_percent: u8,
    pub x: i32,
    pub y: i32,
    pub duration_ms: u64,
    pub accent_rgb: [u8; 3],
}

#[derive(Clone)]
struct PaintState {
    title: Option<String>,
    opacity_percent: u8,
    accent_rgb: [u8; 3],
    x: i32,
    y: i32,
    duration_ms: u32,
}

impl Default for PaintState {
    fn default() -> Self {
        Self {
            title: None,
            opacity_percent: 100,
            accent_rgb: [232, 91, 63],
            x: 0,
            y: 0,
            duration_ms: 1_250,
        }
    }
}

static PAINT_STATE: OnceLock<Mutex<PaintState>> = OnceLock::new();

pub struct FaderOverlay {
    thread_id: u32,
    thread: Option<JoinHandle<()>>,
}

impl FaderOverlay {
    pub fn install() -> Result<Self> {
        PAINT_STATE.get_or_init(|| Mutex::new(PaintState::default()));
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let thread = thread::Builder::new()
            .name("topfade-fader".into())
            .spawn(move || {
                if let Err(error) = run_overlay_thread(&ready_tx) {
                    let _ = ready_tx.try_send(Err(format!("{error:#}")));
                    tracing::warn!(error = %format!("{error:#}"), "native fader thread ended during startup");
                }
            })
            .context("failed to spawn the native fader thread")?;
        let thread_id = ready_rx
            .recv()
            .context("native fader thread ended before startup acknowledgement")?
            .map_err(anyhow::Error::msg)?;
        Ok(Self {
            thread_id,
            thread: Some(thread),
        })
    }

    pub fn show(&self, request: FaderRequest) -> Result<()> {
        let state = PAINT_STATE
            .get()
            .context("native fader state was not initialized")?;
        let mut state = state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.title = request.title;
        state.opacity_percent = request.opacity_percent.clamp(1, 100);
        state.accent_rgb = request.accent_rgb;
        state.x = request.x;
        state.y = request.y;
        state.duration_ms = u32::try_from(request.duration_ms.clamp(300, 5_000))
            .expect("bounded fader duration fits in u32");
        drop(state);
        unsafe { PostThreadMessageW(self.thread_id, SHOW_MESSAGE, WPARAM(0), LPARAM(0)) }
            .context("failed to wake the native fader thread")
    }
}

impl Drop for FaderOverlay {
    fn drop(&mut self) {
        let _ = unsafe { PostThreadMessageW(self.thread_id, WM_QUIT, WPARAM(0), LPARAM(0)) };
        if let Some(thread) = self.thread.take() {
            if thread.join().is_err() {
                tracing::warn!("native fader thread panicked during shutdown");
            }
        }
    }
}

fn run_overlay_thread(ready_tx: &mpsc::SyncSender<std::result::Result<u32, String>>) -> Result<()> {
    let module = unsafe { GetModuleHandleW(None) }.context("failed to resolve TopFade module")?;
    let instance = HINSTANCE(module.0);
    let class = WNDCLASSW {
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(fader_window_proc),
        hInstance: instance,
        lpszClassName: w!("TopFade.FaderOverlay"),
        ..Default::default()
    };
    if unsafe { RegisterClassW(&raw const class) } == 0 {
        anyhow::bail!("failed to register the native fader window class");
    }
    let hwnd = unsafe {
        CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT,
            w!("TopFade.FaderOverlay"),
            w!("TopFade opacity"),
            WS_POPUP,
            0,
            0,
            1,
            1,
            None,
            None,
            Some(instance),
            None,
        )
    }
    .context("failed to create the native fader window")?;
    unsafe { SetLayeredWindowAttributes(hwnd, COLORREF(0), 242, LWA_ALPHA) }
        .context("failed to configure native fader opacity")?;

    let thread_id = unsafe { GetCurrentThreadId() };
    ready_tx
        .send(Ok(thread_id))
        .context("native fader startup receiver disconnected")?;
    let mut message = MSG::default();
    while unsafe { GetMessageW(&raw mut message, None, 0, 0) }.as_bool() {
        if message.message == SHOW_MESSAGE {
            show_current_state(hwnd);
        } else if message.message == WM_TIMER && message.wParam.0 == HIDE_TIMER_ID {
            let _ = unsafe { KillTimer(Some(hwnd), HIDE_TIMER_ID) };
            let _ = unsafe { ShowWindow(hwnd, SW_HIDE) };
        } else {
            let _ = unsafe { TranslateMessage(&raw const message) };
            unsafe { DispatchMessageW(&raw const message) };
        }
    }
    let _ = unsafe { DestroyWindow(hwnd) };
    Ok(())
}

fn show_current_state(hwnd: HWND) {
    let Some(shared) = PAINT_STATE.get() else {
        return;
    };
    let state = shared
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone();
    let (width, height) = if state.title.is_some() {
        (310, 86)
    } else {
        (210, 72)
    };
    let _ = unsafe {
        SetWindowPos(
            hwnd,
            Some(HWND_TOPMOST),
            state.x,
            state.y,
            width,
            height,
            SWP_NOACTIVATE | SWP_SHOWWINDOW,
        )
    };
    let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
    let _ = unsafe { KillTimer(Some(hwnd), HIDE_TIMER_ID) };
    unsafe { SetTimer(Some(hwnd), HIDE_TIMER_ID, state.duration_ms, None) };
}

unsafe extern "system" fn fader_window_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match message {
        WM_ERASEBKGND => LRESULT(1),
        WM_PAINT => {
            paint_fader(hwnd);
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
    }
}

fn paint_fader(hwnd: HWND) {
    let Some(shared) = PAINT_STATE.get() else {
        return;
    };
    let state = shared
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone();
    let mut paint = PAINTSTRUCT::default();
    let hdc = unsafe { BeginPaint(hwnd, &raw mut paint) };
    let mut client = RECT::default();
    if unsafe { GetClientRect(hwnd, &raw mut client) }.is_err() {
        let _ = unsafe { EndPaint(hwnd, &raw const paint) };
        return;
    }

    let background = unsafe { CreateSolidBrush(rgb(24, 25, 27)) };
    unsafe { FillRect(hdc, &raw const client, background) };

    let mut text_rect = RECT {
        left: 18,
        top: 10,
        right: client.right - 18,
        bottom: client.bottom - 28,
    };
    let label = state.title.as_ref().map_or_else(
        || format!("{}%", state.opacity_percent),
        |title| format!("{}%   {title}", state.opacity_percent),
    );
    let mut wide: Vec<u16> = label.encode_utf16().collect();
    unsafe {
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, rgb(238, 238, 240));
        DrawTextW(
            hdc,
            &mut wide,
            &raw mut text_rect,
            DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX,
        );
    }

    let track = RECT {
        left: 18,
        top: client.bottom - 22,
        right: client.right - 18,
        bottom: client.bottom - 14,
    };
    let track_brush = unsafe { CreateSolidBrush(rgb(54, 55, 59)) };
    unsafe { FillRect(hdc, &raw const track, track_brush) };
    let track_width = (track.right - track.left).max(0);
    let fill = RECT {
        right: track.left + track_width * i32::from(state.opacity_percent) / 100,
        ..track
    };
    let accent = unsafe {
        CreateSolidBrush(rgb(
            state.accent_rgb[0],
            state.accent_rgb[1],
            state.accent_rgb[2],
        ))
    };
    unsafe { FillRect(hdc, &raw const fill, accent) };

    unsafe {
        let _ = DeleteObject(background.into());
        let _ = DeleteObject(track_brush.into());
        let _ = DeleteObject(accent.into());
        let _ = EndPaint(hwnd, &raw const paint);
    }
}

fn rgb(red: u8, green: u8, blue: u8) -> COLORREF {
    COLORREF(u32::from(red) | (u32::from(green) << 8) | (u32::from(blue) << 16))
}
