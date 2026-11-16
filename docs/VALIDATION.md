# Validation Record

## Release Gates

| Gate | Windows | macOS |
| --- | --- | --- |
| Format/static syntax | Required | Required |
| Unit tests | `cargo test --locked` | Logic is covered by the integration owner; Swift package must compile cleanly |
| Strict lint | `cargo clippy --locked --all-targets -- -D warnings` | Swift compiler warnings are treated as release findings |
| Optimized build | `cargo build --release --locked` | `scripts/Build-Mac.sh` |
| Real application test | `scripts/Test-WindowsIntegration.ps1` with a dedicated local editor window | `scripts/Test-MacIntegration.sh` with a dedicated TextEdit session |
| Install receipt/hash | `scripts/Install-Windows.ps1` | `scripts/Install-Mac.sh` |

## Current Evidence

### Windows

The current local candidate passed the complete Windows release gate on 2026-09-10:

```powershell
cargo fmt --all -- --check
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
cargo build --release --locked
.\scripts\Test-WindowsIntegration.ps1 -Executable .\target\release\topfade.exe
```

Rust formatting and strict Clippy completed without findings, all 22 unit tests passed, the optimized build completed, and the real desktop verifier exited `0`. The final receipt reported:

```json
{
  "created_utc": "2026-09-10T15:08:01.6719991Z",
  "executable_bytes": 7032832,
  "executable_sha256": "F541567CD03CF34369F8556F7C221E030B3A94540752C5100970239917B5506A",
  "bootstrap_failure_exit_code": 1,
  "fatal_exit_code_nonzero": true,
  "self_test": true,
  "self_test_process_exited": true,
  "self_test_fixture_removed": true,
  "hotkey_topmost_on": true,
  "restored_after_reopen": true,
  "hotkey_topmost_off": true,
  "hotkey_targets_foreground_not_cursor": true,
  "cursor_decoy_remained_topmost": true,
  "faded_percent": 95,
  "restored_percent": 100,
  "fader_window_seen": true,
  "crash_recovery_marker_before_kill": true,
  "crash_recovery_marker_after_kill": true,
  "crash_recovery_marker_cleared": true,
  "opacity_survived_forced_exit": true,
  "opacity_recovered_after_restart": true,
  "duplicate_exit_code": 0,
  "duplicate_activated_existing": true,
  "hidden_one_core_percent": 0,
  "new_error_lines": [],
  "passed": true
}
```

The exact tested artifact is 7,032,832 bytes with SHA-256 `F541567CD03CF34369F8556F7C221E030B3A94540752C5100970239917B5506A`. The built-in real-window self-test presets alpha plus color-key layered attributes, fades the fixture, verifies those flags remain intact while faded, restores the exact original alpha/key/style, and closes the fixture. Unit coverage now also proves transactional restore rollback, future-schema backup recovery, high-resolution wheel isolation between targets, rule-pattern whitespace semantics, dead-window cache pruning, tray-availability hiding decisions, and staged-change quit detection.

The desktop verifier used `target/validation/integration-profile` through `TOPFADE_DATA_DIR`, refused existing Notepad/WindPad sessions, restored its window mutations, removed its fixtures, and recorded no new error lines. It proved the two-lane event path still handles exact hotkey input, foreground-not-cursor targeting, repeated wheel input while the fader is visible, close/reopen restoration, crash-recovery metadata across a forced exit, activation of the existing instance by a duplicate launch, and a sleeping hidden UI. The authoritative current receipt is `target/validation/windows-integration.json`.

This pass did not run the installer, alter launch-at-login, edit AutoHotkey, or touch WindowTop. Installation remains a separate explicit operation using the exact tested candidate.

On 2026-09-28, the source contract changed the opacity gesture to `Alt+Shift+wheel` and made Windows launch-at-login plus hidden tray startup the defaults. `cargo fmt --all -- --check`, all 23 locked unit tests, strict Clippy, the locked release build, both Windows PowerShell AST parses, and the old-modifier reference audit passed. The bounded desktop integration and installation were deliberately not run because an existing managed TopFade process (PID 26988 at inspection time) was live from `%LOCALAPPDATA%\Programs\TopFade\TopFade.exe`; the transactional installer must stop that process before replacement. Its existing receipt identifies the installed 6,957,568-byte binary with SHA-256 `538D5F2149E9E1A704BBF3A635B417FC13CE37220D39FAC44F3BD99CF5A9A209`, with launch-at-login false and no current Run value. That installed binary therefore remains the older build until a maintenance window permits the managed stop/replacement/integration sequence.

### macOS

On the 2026-09-10 Windows host, all four macOS shell scripts pass `bash -n`, both Windows PowerShell scripts pass AST parsing, `Info.plist` parses as XML, `.github/workflows/ci.yml` parses as YAML, `git diff --check` reports no whitespace errors, and a source-wide lexical scanner reports balanced comments, strings, parentheses, brackets, and braces across `Package.swift` plus all eight Swift sources. Constructor/reference searches also confirm the isolated preference owner is injected into capture, replica, input, fader, and logger paths.

The current Mac source coalesces ScreenCaptureKit output to one newest pending AppKit frame, uses user-initiated rather than user-interactive capture work, caches decoded remembered records, delays high-frequency replica-state commits for 350 ms, commits immediately before unpin/shutdown, and clamps remembered panels to visible screen space. Restoration scans are limited to activated bundles that actually have remembered entries, overlapping requests are replayed, callbacks re-read current state, and stale asynchronous pin completions cannot recreate a forgotten replica. Capture lifecycle generations now explicitly stop and detach a stream that finishes starting after cancellation, preventing stop-during-start from leaving an orphan capture. Modified-scroll targeting follows visible AppKit Z order and returns no target outside every replica. Permission transitions restart or stop the existing event tap, with actual consume/listen-only/inactive mode surfaced instead of inferring behavior only from permission flags.

The bounded Mac verifier refuses existing TopFade or TextEdit sessions, posts the exact `Control+Command+T` key events through the registered Carbon owner for pin and unpin, and posts `Option+Shift+scroll` through the production Core Graphics event tap. It first positions the replica away from the pointer and proves the event passes through without an opacity callback, then verifies opacity down/up and the visible fader over the replica. It closes and reopens its owned TextEdit fixture, validates remembered restoration, hotkey-unpins and forgets it, waits for process termination, and removes the fixture. A unique `UserDefaults` suite plus `dist/macos/integration-profile` isolate preferences, logs, reports, and the receipt; the final receipt must prove the production domain stayed unchanged, the temporary suite was removed, legacy remembered state gained stable identities, and two same-title replica records remained distinct. A failed assertion or receipt write returns a nonzero process code.

The Mac logger rotates against the configured total budget while reserving room for its active segment. `Install-Mac.sh` compares source, staged, and installed executable sizes and SHA-256 hashes, preserves an older rollback app until the new promotion and receipt both verify, and restores app/rollback/receipt state on handled interruption. `Test-MacInstallerTransaction.sh` injects five interruption checkpoints plus clean-install rollback and successful-rotation checks inside a temporary home; CI now runs that script after the native build. Normal launches also notify and activate the existing process instead of silently exiting behind a hidden control window.

No Swift compiler, Xcode, SourceKit, or current Swift parser is available on this Windows host. Shell/YAML/XML success, lexical balance, and source review are not substitutes for Swift type checking, app-bundle command execution, Screen Recording TCC, Accessibility/Input Monitoring behavior, capture rendering, installer fault injection on APFS, or a real TextEdit integration run.

No physical Mac host was available during the current audit. Until `scripts/Test-MacIntegration.sh` passes on macOS and produces both the integration and installer-transaction receipts under `dist/macos/integration-profile`, the Mac target must be described as implemented but unverified.

### Pending Native Mac Receipt

Status: `PENDING_EXTERNAL_MAC_HOST`

1. Close TopFade and TextEdit, then run `bash scripts/Test-MacIntegration.sh` from the repository on macOS 13 or newer.
2. Grant the built `TopFade.app` Screen Recording and Accessibility access when macOS requests them, restart the command, and rerun it.
3. Run `bash scripts/Install-Mac.sh --skip-build --launch`, open Preferences, enable launch at login, and approve TopFade under Login Items if macOS reports that approval is pending.
4. Export one diagnostic report, disable launch at login again, and run `bash scripts/Install-Mac.sh --uninstall` without `--remove-data`.

Expected result: build, codesign, integration, and install commands exit `0`; the integration receipt has `passed: true`, at least two hotkey events and two handled scroll events, `scroll_outside_replica_ignored: true`, pin/unpin/forget fields true, restored opacity/click-through fields correct, `production_preferences_unchanged: true`, `isolated_preferences_removed: true`, `textedit_cleanup_completed: true`, and `fixture_cleanup_completed: true`. No owned TopFade/TextEdit process, test suite, or fixture may survive. Pending Login Item approval must display as requested-on rather than trigger a duplicate registration error.

Artifacts: `dist/macos/TopFade.app`, `dist/macos/build-receipt.json`, `dist/macos/integration-profile/integration-receipt.json`, isolated test logs/reports under that same profile, `~/Library/Application Support/TopFade/install-receipt.json`, and the exported production report under `~/Library/Application Support/TopFade/Reports`.

Pass only if every expected result is observed and the generated receipts identify the tested artifact. Otherwise record `FAIL` with the failing command, receipt field, and relevant log line; Windows-host static evidence cannot override that result.

## CI Scope

`.github/workflows/ci.yml` provides locked Windows format/test/lint/release-build gates, verifies that a fatal bootstrap error returns nonzero, and runs a native macOS package/app build, isolated installer interruption/rollback checks, and command/install/uninstall lifecycle checks. Hosted CI cannot grant interactive Screen Recording permission or reliably inject global input, so it does not replace either real desktop integration script.

## Release Procedure

1. Run every platform's static, optimized build, and real desktop integration gate.
2. Inspect the integration receipt and ensure `passed` is true with no new error lines.
3. Install from the exact tested artifact and compare SHA-256 hashes.
4. Launch the installed copy and export one diagnostic report.
5. Verify launch-at-login remains opt-in and WindowTop files/settings remain unchanged.
6. Record platform, OS version, architecture, compiler versions, artifact size/hash, and receipt path in the release notes.

Do not call a cross-platform release complete from Windows-only evidence.
