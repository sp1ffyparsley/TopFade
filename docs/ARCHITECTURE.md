# Architecture

## Design Goals

TopFade owns one focused workflow: pin windows, fade them, remember that state, and make failures diagnosable. It deliberately avoids a browser runtime, local server, database, AutoHotkey layer, PowerShell watcher, telemetry service, updater, or private operating-system APIs.

The two operating systems share product behavior and data concepts, but not a forced runtime abstraction. Windows direct-control code is Rust/Win32. macOS capture and UI code is Swift/AppKit because those are the smallest reliable owners for each platform.

## Windows Runtime

| Owner | Responsibility |
| --- | --- |
| `src/main.rs` | Process startup, single-instance guard, command modes, and eframe lifecycle |
| `src/activation.rs` | Named-event duplicate-launch signaling and bounded activation delivery |
| `src/app.rs` | State machine, preferences UI, rules, persistence orchestration, fader, and OS event handling |
| `src/platform/windows.rs` | Window enumeration and direct Win32 topmost, opacity, and click-through mutations |
| `src/input.rs` | Low-level modified-wheel hook plus foreground, show, and title-change WinEvent hooks |
| `src/config.rs` | Versioned configuration/state schemas, sanitization, atomic replacement, and backups |
| `src/diagnostics.rs` | Structured logs, retention limits, panic/fatal files, recent-event ring, and report export |
| `src/tray.rs` | Native tray menu and event forwarding |
| `src/self_test.rs` | Real local window mutation checks with restoration on every exit path |

### Event Flow

1. `global-hotkey` registers the exact configured accelerator with Windows.
2. Hotkey, tray, and duplicate-launch callbacks wake the eframe event loop instead of polling. Each hotkey event carries the raw foreground HWND. Hotkeys, foreground changes, and opacity input use a bounded priority lane; show/title notifications use a separate bounded lane; tray and duplicate-activation queues are bounded independently.
3. `Alt+Shift+wheel` is received by `WH_MOUSE_LL`; the callback captures the original screen coordinates, sends one compact event, and immediately returns. It suppresses the underlying scroll only when the event was accepted.
4. `EVENT_SYSTEM_FOREGROUND` remembers the last controllable application window. This prevents a shell notification or non-activating overlay from replacing the user's target.
5. `EVENT_OBJECT_SHOW` and `EVENT_OBJECT_NAMECHANGE` wake restoration only for a candidate top-level window. Bursts are coalesced for 400 ms before one matching scan, and excess low-priority notifications are safely dropped rather than growing memory without a bound.
6. Cursor lookup uses the wheel event's captured point and walks bounded top-level Z order behind TopFade-owned or noncandidate overlays, so pointer movement or the visible fader cannot redirect delayed wheel handling.
7. The UI thread performs all state transitions and asks `WindowsBackend` to mutate a validated controllable HWND.
8. Infrequent pin/unpin and explicit forget operations are persisted immediately. Rapid opacity changes are coalesced for 350 ms, retried visibly after write failure, and synchronously flushed during shutdown.
9. `WindowsEventHooks` owns its event-thread lifecycle; shutdown posts `WM_QUIT`, waits for unhooking, and joins the thread so closing TopFade cannot leave a resident native hook thread.
10. Window refresh and restoration scans prune dead identities from the transient opacity/restoration caches, so repeated application churn cannot grow process memory indefinitely.

Topmost uses `SetWindowPos(HWND_TOPMOST/HWND_NOTOPMOST)` with no activation, move, or resize. Opacity and click-through preserve the target's original extended style. Existing constant-alpha/color-key layered attributes are retained while fading and restored exactly at 100%; TopFade removes only a layered style it added. A per-pixel layered window whose attributes cannot be recovered is refused rather than destructively rewritten. Managed styles include the owning process ID and are discarded when Windows reuses an HWND for another process.

Preference saves register the requested hotkeys and update the current-user Run value through direct Win32 registry APIs before committing JSON. If either the external side effect or the atomic config write fails, the prior hotkeys and launch state are restored. Click-through can require an explicit in-app confirmation. Staged preferences and rules share one explicit save/discard transaction, and quit requests require a save-or-discard decision before those edits can be lost. Start-hidden and close-to-tray behavior are allowed only while the native tray owner exists, preventing an unreachable hidden process after tray initialization failure. Every serialized Windows option is connected to runtime behavior or a preferences control; obsolete fullscreen and compact-mode fields were removed rather than left as fake settings.

## macOS Runtime

| Owner | Responsibility |
| --- | --- |
| `AppDelegate.swift` | App lifecycle, owner wiring, workspace activation/wake events, and fatal startup handling |
| `Capture.swift` | ScreenCaptureKit catalog, stream, floating replica panels, matching, and restore behavior |
| `Input.swift` | Carbon `Control+Command+T` registration and Core Graphics modified-scroll event tap |
| `Preferences.swift` | Sanitized UserDefaults schema, remembered replicas, and `SMAppService` login registration |
| `Logger.swift` | Bounded logs, uncaught error context, and JSON diagnostic reports |
| `UI.swift` | Control center, preferences, fader, replica controls, and menu bar |
| `SelfTest.swift` | Real TextEdit capture plus posted native hotkey/scroll integration checks |

### Why A Replica

AppKit lets an application set the level of windows it owns. It does not offer a public API to set another application's native window level. TopFade therefore captures the selected `SCWindow` with ScreenCaptureKit and displays frames in an `AVSampleBufferDisplayLayer` inside an `NSPanel` at floating level.

This preserves System Integrity Protection and avoids code injection/private WindowServer APIs. The tradeoff is explicit: the floating Mac surface is a live replica, not the original interactive application window. Click-through is supported; click forwarding is not.

The Mac restore path is event-driven through `NSWorkspace` application activation and wake notifications. Activations trigger a catalog scan only when the activated bundle has remembered state. Requests that arrive during an active scan are coalesced and replayed, and every callback re-reads current preferences before applying results so a concurrent forget/disable action cannot resurrect stale state. Capture lifecycle generations serialize start/stop ownership; a start that completes after cancellation explicitly stops its stale `SCStream` and removes the output before returning. Asynchronous capture-start callbacks must still own the same live replica entry before they may persist success. The global hotkey captures the application that was frontmost when the key was pressed, then uses public Quartz front-to-back window ordering to select the actual foremost capturable window without disturbing the alphabetically sorted catalog UI.

Modified scroll uses one session event tap. Accessibility permits listening and suppression; Input Monitoring is a listen-only alternative. Permission changes rebuild or stop that same owner when TopFade becomes active again. Hit testing follows `NSApp.orderedWindows`, selects only a visible replica under the pointer, and deliberately has no fallback target outside all replicas. Active streams run only for pinned windows. The default frame limit is 30 fps, the cursor is excluded, and capture output retains at most one pending frame for AppKit so stale frames cannot backlog the main thread.

## Persistence

Windows stores versioned JSON in `%LOCALAPPDATA%\TopFade`:

- `config.json` contains preferences and rules.
- `state.json` contains remembered window identities and visual state.
- `config.bak` and `state.bak` retain the previous valid write.
- Invalid configuration is preserved as `config.json.invalid` before defaults load.
- Invalid runtime state is preserved as `state.json.invalid` before a clean active state is written.

Writes are staged, flushed, and atomically moved into place. Rapid opacity updates share one delayed write instead of creating and flushing a file for every wheel tick. Windows remembered matching uses executable path plus a title hint. A single live window for an application may restore after its title changes; multiple same-application windows require the title hint to disambiguate. Explicitly toggling a remembered window off at 100% removes it, so it will not return on the next launch. Rule matching trims accidental surrounding whitespace so the runtime agrees with the editor's match-all warning. Diagnostics exposes the same forget/clear operations without requiring manual JSON edits.

TopFade disables eframe's persistence feature, so there is no second active `app.ron` settings owner. A file left by an older development build under `%APPDATA%\TopFade` is legacy-only and is removed solely by explicit `-Uninstall -RemoveData`.

macOS stores scalar preferences and encoded remembered-replica records in `UserDefaults`. Remembered records are decoded once per process, identical assignments are skipped, and rapid opacity/frame changes are committed after a 350 ms quiet period; unpin and shutdown paths force the latest state immediately. The integration verifier injects a unique temporary suite into the same preference, capture, input, fader, and replica owners rather than touching the production domain. Invalid remembered data is copied to `~/Library/Application Support/TopFade/remembered-replicas.invalid.json` and removed from the active defaults domain so it is not decoded repeatedly. Matching uses bundle identifier and a title similarity score. The fallible login-item update runs before preference values are committed. `SMAppService.Status.requiresApproval` is retained as a requested-on state and surfaced to the user instead of being registered twice or displayed as off. The default click-through preference affects only new replicas rather than overwriting active per-window choices.

Neither platform reads or writes WindowTop settings, license state, registry values, files, or processes.

## Diagnostics And Safety

- Startup, paths, config operations, hook registration, major actions, permission state, failures, and clean shutdown are logged.
- Bootstrap, command, and UI failures exit nonzero after buffered logs are flushed, so CI and scripts cannot mistake a fatal error for success.
- Logs default to 14-day retention and a 20 MB total cap; both are configurable within bounded ranges. macOS reserves room for the current rotation segment before retaining older files, so the configured cap remains a working bound rather than a cleanup-only target.
- Windows installs verify source, staged, and installed hashes and transact promotion, the previous binary, shortcut, Run value, and install receipt together. They create missing clean-profile shortcut directories, verify managed paths, keep user data by default, and remove failed staging residue.
- Mac installs verify source-to-stage-to-installed executable identity, preserve both the current app and any older rollback slot until promotion succeeds, and transact app promotion plus the install receipt. Promotion, post-install verification failure, or a handled interruption restores the prior layout. `Test-MacInstallerTransaction.sh` fault-injects every promotion checkpoint in an isolated temporary home and verifies exact rollback with no transaction debris. Uninstall asks a side-effect-free command path to unregister the app's own `SMAppService` login item before removal.
- Self-tests use dedicated local documents/windows, restore remembered, topmost, opacity, click-through, and pre-existing layered attributes in cleanup paths, and remove disposable Windows fixtures after their child process exits. The Mac verifier posts native keyboard and wheel events instead of calling pin/fade logic directly, uses isolated preferences/log/report paths, proves outside-replica scroll is ignored, and exits nonzero on test or receipt failure.
- Both app bundles enforce a single resident owner. A second normal macOS launch activates the existing instance; self-test and command paths remain independently executable.
- No network code, analytics, cloud account, or automatic deletion exists in the runtime.

## Extension Rules

Add platform-specific capability behind the existing owner instead of starting another resident helper. New window mutations belong in `WindowBackend` on Windows or `ReplicaManager` on macOS. New persisted values belong in the existing sanitized config/preferences schema. New diagnostics belong in the existing logger/report path. Any new resident behavior must be event-driven or justified with measured evidence.
