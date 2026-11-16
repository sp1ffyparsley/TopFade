use std::sync::Arc;

use anyhow::Result;
use crossbeam_channel::{bounded, Receiver};
use global_hotkey::{hotkey::HotKey, HotKeyState};

use crate::platform::NativeWindowId;

const PRIORITY_INPUT_CAPACITY: usize = 256;
const WINDOW_INPUT_CAPACITY: usize = 256;

#[derive(Debug, Clone)]
pub enum InputEvent {
    OpacityWheel {
        target: NativeWindowId,
        wheel_steps: i16,
        cursor_x: i32,
        cursor_y: i32,
    },
    WindowAvailable {
        target: NativeWindowId,
    },
    ForegroundChanged {
        target: NativeWindowId,
    },
    Hotkey {
        id: u32,
        state: HotKeyState,
        foreground: NativeWindowId,
    },
}

pub struct InputController {
    priority_receiver: Receiver<InputEvent>,
    window_receiver: Receiver<InputEvent>,
    #[cfg(target_os = "windows")]
    hooks: windows_hook::WindowsEventHooks,
}

impl InputController {
    pub fn install(
        consume_wheel: bool,
        watch_window_events: bool,
        hotkeys: Option<[HotKey; 2]>,
        wake: Arc<dyn Fn() + Send + Sync>,
    ) -> Result<(Self, Option<String>)> {
        let (priority_sender, priority_receiver) = bounded(PRIORITY_INPUT_CAPACITY);
        let (window_sender, window_receiver) = bounded(WINDOW_INPUT_CAPACITY);
        #[cfg(target_os = "windows")]
        let (hooks, hotkey_error) = windows_hook::WindowsEventHooks::install(
            priority_sender,
            window_sender,
            consume_wheel,
            watch_window_events,
            hotkeys,
            wake,
        )?;

        #[cfg(target_os = "macos")]
        macos_tap::install(priority_sender, window_sender, consume_wheel, wake)?;

        Ok((
            Self {
                priority_receiver,
                window_receiver,
                #[cfg(target_os = "windows")]
                hooks,
            },
            #[cfg(target_os = "windows")]
            hotkey_error,
            #[cfg(not(target_os = "windows"))]
            None,
        ))
    }

    pub fn try_recv(&self) -> Option<InputEvent> {
        self.priority_receiver
            .try_recv()
            .ok()
            .or_else(|| self.window_receiver.try_recv().ok())
    }

    pub fn set_consume_wheel(consume: bool) {
        #[cfg(target_os = "windows")]
        windows_hook::set_consume(consume);
        #[cfg(target_os = "macos")]
        macos_tap::set_consume(consume);
    }

    pub fn set_watch_window_events(watch: bool) {
        #[cfg(target_os = "windows")]
        windows_hook::set_watch_window_events(watch);
        #[cfg(target_os = "macos")]
        let _ = watch;
    }

    #[cfg(target_os = "windows")]
    pub fn set_hotkeys(&self, hotkeys: Option<[HotKey; 2]>) -> Result<()> {
        self.hooks.set_hotkeys(hotkeys)
    }
}

#[cfg(target_os = "windows")]
mod windows_hook {
    use std::{
        sync::{
            atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering},
            mpsc::SyncSender,
            Arc, OnceLock,
        },
        thread,
        time::Duration,
    };

    use anyhow::{Context, Result};
    use crossbeam_channel::{unbounded, Receiver as CommandReceiver, Sender};
    use global_hotkey::{hotkey::HotKey, GlobalHotKeyEvent, GlobalHotKeyManager};
    use tracing::warn;
    use windows::Win32::{
        Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM},
        System::{LibraryLoader::GetModuleHandleW, Threading::GetCurrentThreadId},
        UI::{
            Accessibility::{SetWinEventHook, UnhookWinEvent, HWINEVENTHOOK},
            Input::KeyboardAndMouse::{GetAsyncKeyState, VK_MENU, VK_SHIFT},
            WindowsAndMessaging::{
                CallNextHookEx, DispatchMessageW, GetAncestor, GetForegroundWindow, GetMessageW,
                PostThreadMessageW, SetWindowsHookExW, TranslateMessage, UnhookWindowsHookEx,
                EVENT_OBJECT_NAMECHANGE, EVENT_OBJECT_SHOW, EVENT_SYSTEM_FOREGROUND, GA_ROOT, MSG,
                MSLLHOOKSTRUCT, OBJID_WINDOW, WH_MOUSE_LL, WINEVENT_OUTOFCONTEXT,
                WINEVENT_SKIPOWNPROCESS, WM_APP, WM_MOUSEWHEEL, WM_QUIT,
            },
        },
    };

    use crate::platform::NativeWindowId;

    use super::InputEvent;

    static PRIORITY_SENDER: OnceLock<Sender<InputEvent>> = OnceLock::new();
    static WINDOW_SENDER: OnceLock<Sender<InputEvent>> = OnceLock::new();
    static WAKE: OnceLock<Arc<dyn Fn() + Send + Sync>> = OnceLock::new();
    static CONSUME: AtomicBool = AtomicBool::new(true);
    static WATCH_WINDOW_EVENTS: AtomicBool = AtomicBool::new(true);
    static WHEEL_REMAINDER: AtomicI32 = AtomicI32::new(0);
    static WHEEL_TARGET: AtomicU64 = AtomicU64::new(0);
    const HOTKEY_COMMAND_MESSAGE: u32 = WM_APP + 0x46;

    enum HotkeyCommand {
        Configure {
            hotkeys: Option<[HotKey; 2]>,
            response: SyncSender<std::result::Result<(), String>>,
        },
    }

    pub fn set_consume(consume: bool) {
        CONSUME.store(consume, Ordering::Release);
    }

    pub struct WindowsEventHooks {
        thread: Option<thread::JoinHandle<()>>,
        event_thread_id: u32,
        hotkey_commands: Sender<HotkeyCommand>,
    }

    impl WindowsEventHooks {
        pub fn install(
            priority_sender: Sender<InputEvent>,
            window_sender: Sender<InputEvent>,
            consume: bool,
            watch_window_events: bool,
            initial_hotkeys: Option<[HotKey; 2]>,
            wake: Arc<dyn Fn() + Send + Sync>,
        ) -> Result<(Self, Option<String>)> {
            PRIORITY_SENDER
                .set(priority_sender)
                .map_err(|_| anyhow::anyhow!("mouse hook was already installed"))?;
            WINDOW_SENDER
                .set(window_sender)
                .map_err(|_| anyhow::anyhow!("window event hook was already installed"))?;
            WAKE.set(wake)
                .map_err(|_| anyhow::anyhow!("mouse-hook wake handler was already installed"))?;
            GlobalHotKeyEvent::set_event_handler(Some(forward_hotkey_event));
            CONSUME.store(consume, Ordering::Release);
            WATCH_WINDOW_EVENTS.store(watch_window_events, Ordering::Release);

            let (hotkey_commands, command_receiver) = unbounded();
            let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel(1);
            let thread = thread::Builder::new()
                .name("topfade-win-events".into())
                .spawn(move || unsafe {
                    let event_thread_id = GetCurrentThreadId();
                    let hotkey_manager = GlobalHotKeyManager::new();
                    let mut registered_hotkeys = None;
                    let hotkey_error = match (&hotkey_manager, initial_hotkeys) {
                        (Ok(manager), Some(hotkeys)) => {
                            set_registered_hotkeys(manager, &mut registered_hotkeys, Some(hotkeys))
                                .err()
                        }
                        (Err(error), _) => Some(format!(
                            "native hotkey message window could not be created: {error}"
                        )),
                        (Ok(_), None) => None,
                    };

                    let module = GetModuleHandleW(None).ok();
                    let instance = module.map(|module| HINSTANCE(module.0));
                    let mouse_hook =
                        match SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_hook_proc), instance, 0) {
                            Ok(hook) => hook,
                            Err(error) => {
                                let _ = ready_tx.send(Err(error.to_string()));
                                return;
                            }
                        };
                    let foreground_hook = SetWinEventHook(
                        EVENT_SYSTEM_FOREGROUND,
                        EVENT_SYSTEM_FOREGROUND,
                        None,
                        Some(window_event_proc),
                        0,
                        0,
                        WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
                    );
                    if foreground_hook.is_invalid() {
                        let _ = UnhookWindowsHookEx(mouse_hook);
                        let _ = ready_tx.send(Err(
                            "native foreground-window hook could not be installed".into(),
                        ));
                        return;
                    }
                    let show_hook = SetWinEventHook(
                        EVENT_OBJECT_SHOW,
                        EVENT_OBJECT_SHOW,
                        None,
                        Some(window_event_proc),
                        0,
                        0,
                        WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
                    );
                    if show_hook.is_invalid() {
                        let _ = UnhookWinEvent(foreground_hook);
                        let _ = UnhookWindowsHookEx(mouse_hook);
                        let _ = ready_tx.send(Err(
                            "native window-availability hook could not be installed".into(),
                        ));
                        return;
                    }
                    let name_hook = SetWinEventHook(
                        EVENT_OBJECT_NAMECHANGE,
                        EVENT_OBJECT_NAMECHANGE,
                        None,
                        Some(window_event_proc),
                        0,
                        0,
                        WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
                    );
                    if name_hook.is_invalid() {
                        let _ = UnhookWinEvent(show_hook);
                        let _ = UnhookWinEvent(foreground_hook);
                        let _ = UnhookWindowsHookEx(mouse_hook);
                        let _ = ready_tx
                            .send(Err("native window-title hook could not be installed".into()));
                        return;
                    }

                    let _ = ready_tx.send(Ok::<(u32, Option<String>), String>((
                        event_thread_id,
                        hotkey_error,
                    )));
                    let mut message = MSG::default();
                    while GetMessageW(&raw mut message, None, 0, 0).as_bool() {
                        if message.message == HOTKEY_COMMAND_MESSAGE {
                            process_hotkey_commands(
                                hotkey_manager.as_ref().ok(),
                                &command_receiver,
                                &mut registered_hotkeys,
                            );
                        } else {
                            let _ = TranslateMessage(&raw const message);
                            DispatchMessageW(&raw const message);
                        }
                    }
                    let _ = UnhookWinEvent(name_hook);
                    let _ = UnhookWinEvent(show_hook);
                    let _ = UnhookWinEvent(foreground_hook);
                    let _ = UnhookWindowsHookEx(mouse_hook);
                })
                .context("failed to spawn the Windows event thread")?;

            let (event_thread_id, hotkey_error) = ready_rx
                .recv()
                .context("Windows event thread ended during startup")?
                .map_err(anyhow::Error::msg)?;

            Ok((
                Self {
                    thread: Some(thread),
                    event_thread_id,
                    hotkey_commands,
                },
                hotkey_error,
            ))
        }

        pub fn set_hotkeys(&self, hotkeys: Option<[HotKey; 2]>) -> Result<()> {
            let (response, result) = std::sync::mpsc::sync_channel(1);
            self.hotkey_commands
                .send(HotkeyCommand::Configure { hotkeys, response })
                .context("Windows event thread is unavailable")?;
            unsafe {
                PostThreadMessageW(
                    self.event_thread_id,
                    HOTKEY_COMMAND_MESSAGE,
                    WPARAM(0),
                    LPARAM(0),
                )
            }
            .context("failed to wake the Windows event thread")?;
            result
                .recv_timeout(Duration::from_secs(2))
                .context("Windows hotkey update timed out")?
                .map_err(anyhow::Error::msg)
        }
    }

    fn process_hotkey_commands(
        manager: Option<&GlobalHotKeyManager>,
        commands: &CommandReceiver<HotkeyCommand>,
        registered: &mut Option<[HotKey; 2]>,
    ) {
        while let Ok(command) = commands.try_recv() {
            match command {
                HotkeyCommand::Configure { hotkeys, response } => {
                    let result = manager.map_or_else(
                        || Err("native hotkey message window is unavailable".into()),
                        |manager| set_registered_hotkeys(manager, registered, hotkeys),
                    );
                    let _ = response.send(result);
                }
            }
        }
    }

    fn set_registered_hotkeys(
        manager: &GlobalHotKeyManager,
        registered: &mut Option<[HotKey; 2]>,
        requested: Option<[HotKey; 2]>,
    ) -> std::result::Result<(), String> {
        if requested.is_some_and(|pair| pair[0].id() == pair[1].id()) {
            return Err("toggle and preferences hotkeys must be different".into());
        }

        let previous = *registered;
        if let Some(previous) = previous {
            unregister_pair(manager, previous)?;
            *registered = None;
        }

        let Some(requested) = requested else {
            return Ok(());
        };
        match register_pair(manager, requested) {
            Ok(()) => {
                *registered = Some(requested);
                Ok(())
            }
            Err(error) => {
                if let Some(previous) = previous {
                    if let Err(rollback_error) = register_pair(manager, previous) {
                        return Err(format!(
                            "{error}; previous hotkeys could not be restored: {rollback_error}"
                        ));
                    }
                    *registered = Some(previous);
                }
                Err(error)
            }
        }
    }

    fn register_pair(
        manager: &GlobalHotKeyManager,
        hotkeys: [HotKey; 2],
    ) -> std::result::Result<(), String> {
        manager
            .register(hotkeys[0])
            .map_err(|error| error.to_string())?;
        if let Err(error) = manager.register(hotkeys[1]) {
            let _ = manager.unregister(hotkeys[0]);
            return Err(error.to_string());
        }
        Ok(())
    }

    fn unregister_pair(
        manager: &GlobalHotKeyManager,
        hotkeys: [HotKey; 2],
    ) -> std::result::Result<(), String> {
        let first = manager.unregister(hotkeys[0]).err();
        let second = manager.unregister(hotkeys[1]).err();
        match (first, second) {
            (None, None) => Ok(()),
            (Some(error), None) | (None, Some(error)) => Err(error.to_string()),
            (Some(first), Some(second)) => Err(format!("{first}; {second}")),
        }
    }

    fn forward_hotkey_event(event: GlobalHotKeyEvent) {
        let foreground = unsafe { GetForegroundWindow() };
        dispatch_priority(InputEvent::Hotkey {
            id: event.id,
            state: event.state,
            foreground: NativeWindowId(foreground.0 as usize as u64),
        });
    }

    fn dispatch_priority(event: InputEvent) -> bool {
        dispatch_to(PRIORITY_SENDER.get(), event)
    }

    fn dispatch_window(event: InputEvent) -> bool {
        dispatch_to(WINDOW_SENDER.get(), event)
    }

    pub fn set_watch_window_events(watch: bool) {
        WATCH_WINDOW_EVENTS.store(watch, Ordering::Release);
    }

    fn dispatch_to(sender: Option<&Sender<InputEvent>>, event: InputEvent) -> bool {
        let sent = sender.is_some_and(|sender| sender.try_send(event).is_ok());
        if sent {
            if let Some(wake) = WAKE.get() {
                wake();
            }
        }
        sent
    }

    impl Drop for WindowsEventHooks {
        fn drop(&mut self) {
            GlobalHotKeyEvent::set_event_handler::<fn(GlobalHotKeyEvent)>(None);
            let quit_posted =
                unsafe { PostThreadMessageW(self.event_thread_id, WM_QUIT, WPARAM(0), LPARAM(0)) }
                    .is_ok();
            let Some(thread) = self.thread.take() else {
                return;
            };
            if quit_posted {
                if thread.join().is_err() {
                    warn!("Windows event thread panicked during shutdown");
                }
            } else {
                // The thread may already have exited. Detaching is safer than blocking forever if
                // Windows no longer accepts messages for its thread queue.
                warn!("could not post Windows event-thread shutdown message");
            }
        }
    }

    unsafe extern "system" fn mouse_hook_proc(
        code: i32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        if code >= 0 && u32::try_from(wparam.0).is_ok_and(|value| value == WM_MOUSEWHEEL) {
            let alt = unsafe { GetAsyncKeyState(i32::from(VK_MENU.0)) } < 0;
            let shift = unsafe { GetAsyncKeyState(i32::from(VK_SHIFT.0)) } < 0;
            if alt && shift {
                let hook = unsafe { &*(lparam.0 as *const MSLLHOOKSTRUCT) };
                let delta_bits = u16::try_from(hook.mouseData >> 16)
                    .expect("high word of mouse data always fits in u16");
                let delta = i16::from_ne_bytes(delta_bits.to_ne_bytes());
                let root = unsafe {
                    windows::Win32::UI::WindowsAndMessaging::WindowFromPoint(POINT {
                        x: hook.pt.x,
                        y: hook.pt.y,
                    })
                };
                let root = unsafe { GetAncestor(root, GA_ROOT) };
                if root.0.is_null() {
                    reset_wheel_accumulator(&WHEEL_REMAINDER, &WHEEL_TARGET);
                } else {
                    let target = NativeWindowId(root.0 as usize as u64);
                    let wheel_steps = accumulate_targeted_wheel_steps(
                        &WHEEL_REMAINDER,
                        &WHEEL_TARGET,
                        target.0,
                        i32::from(delta),
                    );
                    let queued = wheel_steps == 0
                        || dispatch_priority(InputEvent::OpacityWheel {
                            target,
                            wheel_steps,
                            cursor_x: hook.pt.x,
                            cursor_y: hook.pt.y,
                        });
                    if queued && CONSUME.load(Ordering::Acquire) {
                        return LRESULT(1);
                    }
                }
            } else {
                reset_wheel_accumulator(&WHEEL_REMAINDER, &WHEEL_TARGET);
            }
        }
        unsafe { CallNextHookEx(None, code, wparam, lparam) }
    }

    unsafe extern "system" fn window_event_proc(
        _hook: HWINEVENTHOOK,
        event: u32,
        hwnd: HWND,
        object_id: i32,
        child_id: i32,
        _event_thread: u32,
        _event_time: u32,
    ) {
        if hwnd.0.is_null() || object_id != OBJID_WINDOW.0 || child_id != 0 {
            return;
        }
        let root = unsafe { GetAncestor(hwnd, GA_ROOT) };
        if root.0 != hwnd.0 {
            return;
        }
        let target = NativeWindowId(root.0 as usize as u64);
        let watch_window_events = WATCH_WINDOW_EVENTS.load(Ordering::Acquire);
        if !should_forward_window_event(event, watch_window_events) {
            return;
        }
        let input = if event == EVENT_SYSTEM_FOREGROUND {
            InputEvent::ForegroundChanged { target }
        } else {
            InputEvent::WindowAvailable { target }
        };
        if event == EVENT_SYSTEM_FOREGROUND {
            dispatch_priority(input);
        } else {
            dispatch_window(input);
        }
    }

    fn should_forward_window_event(event: u32, watch_window_events: bool) -> bool {
        event == EVENT_SYSTEM_FOREGROUND || watch_window_events
    }

    fn accumulate_wheel_steps(remainder: &AtomicI32, delta: i32) -> i16 {
        let mut current = remainder.load(Ordering::Acquire);
        loop {
            let total = current + delta;
            let steps = total / 120;
            let next_remainder = total % 120;
            match remainder.compare_exchange_weak(
                current,
                next_remainder,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => {
                    return i16::try_from(steps)
                        .expect("a single Windows wheel delta always fits in i16")
                }
                Err(updated) => current = updated,
            }
        }
    }

    fn accumulate_targeted_wheel_steps(
        remainder: &AtomicI32,
        previous_target: &AtomicU64,
        target: u64,
        delta: i32,
    ) -> i16 {
        if previous_target.swap(target, Ordering::AcqRel) != target {
            remainder.store(0, Ordering::Release);
        }
        accumulate_wheel_steps(remainder, delta)
    }

    fn reset_wheel_accumulator(remainder: &AtomicI32, target: &AtomicU64) {
        remainder.store(0, Ordering::Release);
        target.store(0, Ordering::Release);
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn high_resolution_wheel_deltas_accumulate_into_steps() {
            let remainder = AtomicI32::new(0);
            assert_eq!(accumulate_wheel_steps(&remainder, 30), 0);
            assert_eq!(accumulate_wheel_steps(&remainder, 30), 0);
            assert_eq!(accumulate_wheel_steps(&remainder, 30), 0);
            assert_eq!(accumulate_wheel_steps(&remainder, 30), 1);
            assert_eq!(remainder.load(Ordering::Acquire), 0);
        }

        #[test]
        fn wheel_remainder_reverses_without_a_false_step() {
            let remainder = AtomicI32::new(0);
            assert_eq!(accumulate_wheel_steps(&remainder, 60), 0);
            assert_eq!(accumulate_wheel_steps(&remainder, -60), 0);
            assert_eq!(remainder.load(Ordering::Acquire), 0);
        }

        #[test]
        fn wheel_remainder_does_not_cross_window_targets() {
            let remainder = AtomicI32::new(0);
            let target = AtomicU64::new(0);
            assert_eq!(
                accumulate_targeted_wheel_steps(&remainder, &target, 10, 60),
                0
            );
            assert_eq!(
                accumulate_targeted_wheel_steps(&remainder, &target, 20, 60),
                0
            );
            assert_eq!(remainder.load(Ordering::Acquire), 60);
            assert_eq!(
                accumulate_targeted_wheel_steps(&remainder, &target, 20, 60),
                1
            );
        }

        #[test]
        fn window_title_and_show_events_sleep_when_restore_watching_is_disabled() {
            assert!(should_forward_window_event(EVENT_SYSTEM_FOREGROUND, false));
            assert!(!should_forward_window_event(EVENT_OBJECT_SHOW, false));
            assert!(!should_forward_window_event(EVENT_OBJECT_NAMECHANGE, false));
            assert!(should_forward_window_event(EVENT_OBJECT_SHOW, true));
            assert!(should_forward_window_event(EVENT_OBJECT_NAMECHANGE, true));
        }
    }
}

#[cfg(target_os = "macos")]
mod macos_tap {
    use std::sync::Arc;

    use anyhow::Result;
    use crossbeam_channel::Sender;

    use super::InputEvent;

    pub fn install(
        _priority_sender: Sender<InputEvent>,
        _window_sender: Sender<InputEvent>,
        _consume: bool,
        _wake: Arc<dyn Fn() + Send + Sync>,
    ) -> Result<()> {
        // macOS wheel capture is installed by the ScreenCaptureKit backend after Accessibility
        // permission is granted. Keeping it there lets permission failures surface in one place.
        Ok(())
    }

    pub fn set_consume(_consume: bool) {}
}
