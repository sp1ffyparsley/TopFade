# Troubleshooting

## Windows

### `Ctrl+Win+T` Does Nothing

1. Confirm `TopFade.exe` is running in Task Manager or the TopFade tray icon is present.
2. Open `%LOCALAPPDATA%\TopFade\logs` and find the latest `global hotkeys registered` line.
3. Confirm it reports `toggle=Control+Super+KeyT`. `Super` is the library name for the Windows key.
4. If registration failed, close the application currently owning that exact shortcut and restart TopFade.

Windows permits only one global owner for the same accelerator. TopFade registers the full `Ctrl+Win+T` combination, not `Win+T` and not `Alt+Z`; it cannot safely steal an accelerator already registered by another process.

If a Windows notification surface temporarily owns raw foreground focus, TopFade uses the last real controllable foreground window reported by native events. It does not use the window under the cursor for the hotkey.

### An Elevated Application Is Not Changed

Windows integrity levels prevent a normal process from controlling some elevated windows. Close TopFade and run it elevated only when the target application is also elevated. Normal operation should remain non-elevated.

### A Window Returns After Reopening

That is remembered-state behavior. Focus the window and press `Ctrl+Win+T` until it is unpinned, then return opacity to 100%. TopFade removes the remembered entry only when both conditions are off. You can also disable `Restore when apps reopen`, or open Diagnostics and forget that application without altering its currently open window.

### A Window Does Not Restore

- Ensure `Remember pinned windows` and `Restore when apps reopen` are enabled.
- The executable path must match. A product upgrade that moves its executable is treated as a different application.
- If the application exposes one candidate window, its title may change. If it exposes multiple windows, the stored title hint must identify the intended one.
- Check exclusion rules, then inspect logs for `restored target=` or a window mutation error.

Restoration is event-driven. TopFade reacts when Windows reports that a top-level window became visible, waits briefly for its title to settle, then runs one match scan.

### Opacity Does Not Change

- Hold both `Alt` and `Shift` before scrolling.
- By default, the target is the root window under the cursor.
- TopFade skips its own visible fader during hit testing, so consecutive wheel steps should keep changing the original window.
- Some protected, elevated, hardware-overlay, or custom-composited windows may reject layered styles. TopFade deliberately refuses per-pixel layered windows whose native transparency cannot be restored safely.
- Disable `Consume Alt+Shift+wheel` if the target application also needs that gesture.

### The Old Log Contains A Transparent GL Error

An early pre-release build attempted a transparent renderer viewport. Current fader windows are opaque, and validation fails if a new error line appears. Old dated logs are intentionally retained until the configured age/size cleanup removes them.

### TopFade Did Not Start Hidden Or Close To The Tray

TopFade hides only after the native tray icon is successfully created. If tray initialization fails, it remains visible and shows a warning instead of creating an unreachable background process. Resolve the tray or shell problem, then restart TopFade; Diagnostics and the current log include the initialization error.

### Quit Shows A Save Or Discard Prompt

Preferences and Rules edit the same staged configuration. Choosing Quit from the tray, or closing the last visible window when close-to-tray is unavailable or disabled, asks whether to save, discard, or cancel when either page contains unsaved changes. This prevents a rule edited on one page from being silently lost while quitting from another.

### Settings Or State JSON Is Invalid

TopFade preserves the unreadable file as `config.json.invalid` or `state.json.invalid`, repairs the active JSON with a sanitized value, and keeps the last valid `.bak` file. Inspect the invalid copy before deleting it; WindowTop settings are unrelated and must not be moved or edited.

## macOS

### No Windows Appear In The Catalog

Grant TopFade Screen Recording access in System Settings, then quit and reopen it. `NSScreenCaptureUsageDescription` is embedded in the app bundle. ScreenCaptureKit does not expose capturable content until TCC permits it.

### `Control+Command+T` Does Nothing

Check the menu-bar status and `~/Library/Logs/TopFade`. If Carbon registration reports a conflict, close the owner of that exact shortcut and restart TopFade.

### Modified Scroll Changes Opacity But Also Scrolls The App

TopFade fell back to a listen-only event tap. Grant Accessibility permission, then return to TopFade; it refreshes the permission state and rebuilds the event tap in suppression mode. Input Monitoring alone permits listening but not event posting/suppression. Modified scroll outside every visible replica always passes through unchanged.

### Launch At Login Says Approval Is Required

TopFade is already registered but macOS is waiting for user approval. Enable TopFade under System Settings > General > Login Items. Do not toggle the preference repeatedly; pending approval is intentionally preserved as the requested-on state.

### The Replica Is Blank Or Stops Updating

- Confirm Screen Recording permission is still enabled.
- Unminimize the source application window.
- Unpin and repin the source after display, Space, or application changes.
- Export diagnostics and inspect capture-stop and renderer entries.

The Mac build displays a live capture replica. It cannot turn another application's original window into a floating AppKit window through public APIs.

## Diagnostics

### Export A Report

- Windows: open TopFade, choose Diagnostics, then `Export report`; or run `topfade.exe --diagnostic-report`.
- macOS: choose `Export Diagnostics` from the menu bar or Preferences.

Reports include versions, paths, permissions, sanitized preferences, current window/replica state, and recent events. Window titles and application paths may be private; review a report before posting it.

### Reset Only TopFade

Do not delete or edit WindowTop files. To clear only remembered Windows applications, use the per-app or clear-all controls in TopFade Diagnostics. For a complete TopFade reset, quit it and rename `%LOCALAPPDATA%\TopFade` so the folder remains available for rollback. On macOS, export diagnostics first, then remove TopFade's `com.tavito.topfade` preferences and its own Application Support folder only.
