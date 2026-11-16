use std::{ffi::c_void, sync::Arc, thread, time::Duration};

use anyhow::{Context, Result};
use crossbeam_channel::{bounded, Receiver};
use tracing::warn;
use windows::{
    core::{w, PCWSTR},
    Win32::{
        Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0},
        System::Threading::{
            CreateEventW, OpenEventW, SetEvent, WaitForMultipleObjects, EVENT_MODIFY_STATE,
            INFINITE,
        },
    },
};

const ACTIVATION_EVENT_NAME: PCWSTR = w!("Local\\TopFade.Activate.v1");

pub struct ActivationListener {
    receiver: Receiver<()>,
    thread: Option<thread::JoinHandle<()>>,
    activation_event: usize,
    stop_event: usize,
}

impl ActivationListener {
    pub fn install(wake: Arc<dyn Fn() + Send + Sync>) -> Result<Self> {
        let activation_handle = unsafe { CreateEventW(None, false, false, ACTIVATION_EVENT_NAME) }
            .context("failed to create the single-instance activation event")?;
        let stop_handle = match unsafe { CreateEventW(None, true, false, PCWSTR::null()) } {
            Ok(event) => event,
            Err(error) => {
                let _ = unsafe { CloseHandle(activation_handle) };
                return Err(error)
                    .context("failed to create the activation-listener shutdown event");
            }
        };
        let activation_event = activation_handle.0 as usize;
        let stop_event = stop_handle.0 as usize;
        let (sender, receiver) = bounded(1);
        let thread = match thread::Builder::new()
            .name("topfade-activation".into())
            .spawn(move || {
                let activation_handle = HANDLE(activation_event as *mut c_void);
                let stop_handle = HANDLE(stop_event as *mut c_void);
                loop {
                    let wait = unsafe {
                        WaitForMultipleObjects(&[activation_handle, stop_handle], false, INFINITE)
                    };
                    if wait == WAIT_OBJECT_0 {
                        if sender.try_send(()).is_ok() {
                            wake();
                        }
                    } else if wait.0 == WAIT_OBJECT_0.0 + 1 {
                        break;
                    } else {
                        warn!(result = wait.0, "single-instance activation wait failed");
                        break;
                    }
                }
            }) {
            Ok(thread) => thread,
            Err(error) => {
                let _ = unsafe { CloseHandle(stop_handle) };
                let _ = unsafe { CloseHandle(activation_handle) };
                return Err(error).context("failed to spawn the activation-listener thread");
            }
        };

        Ok(Self {
            receiver,
            thread: Some(thread),
            activation_event,
            stop_event,
        })
    }

    pub fn take_pending(&self) -> bool {
        let mut pending = false;
        while self.receiver.try_recv().is_ok() {
            pending = true;
        }
        pending
    }
}

impl Drop for ActivationListener {
    fn drop(&mut self) {
        let stop_event = HANDLE(self.stop_event as *mut c_void);
        let activation_event = HANDLE(self.activation_event as *mut c_void);
        let _ = unsafe { SetEvent(stop_event) };
        if let Some(thread) = self.thread.take() {
            if thread.join().is_err() {
                warn!("single-instance activation thread panicked during shutdown");
            }
        }
        let _ = unsafe { CloseHandle(stop_event) };
        let _ = unsafe { CloseHandle(activation_event) };
    }
}

pub fn signal_existing() -> Result<()> {
    let mut last_error = None;
    for _ in 0..40 {
        match unsafe { OpenEventW(EVENT_MODIFY_STATE, false, ACTIVATION_EVENT_NAME) } {
            Ok(event) => {
                let result = unsafe { SetEvent(event) }
                    .context("failed to signal the running TopFade instance");
                let close = unsafe { CloseHandle(event) }
                    .context("failed to close the activation-event handle");
                result?;
                close?;
                return Ok(());
            }
            Err(error) => last_error = Some(error),
        }
        thread::sleep(Duration::from_millis(50));
    }
    Err(last_error.map_or_else(
        || anyhow::anyhow!("the activation event was unavailable"),
        anyhow::Error::from,
    ))
    .context("TopFade is running, but its activation channel could not be reached")
}
