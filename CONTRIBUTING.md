# Contributing to TopFade

TopFade is a small utility. Changes should solve real pinning, opacity, reliability, accessibility, or performance problems without adding unnecessary resident services.

## Development

- **Windows:** Rust 1.85+, MSVC build tools, Windows 10/11 x64.
- **macOS:** macOS 13+, Swift 5.9+, AppKit, ScreenCaptureKit.
- Open an issue with expected behavior, steps to reproduce, operating-system version, and whether the problem reproduces with another window/application.
- Keep Win32 changes under `src/`, the Swift app under `macos/`, and install/test logic under `scripts/`.
- Use public OS APIs. Do not bypass System Integrity Protection, inject into another app, or modify an unrelated program's settings.
- Do not include user configuration, captured window titles, log files, activation material, or desktop screenshots containing personal information in issues or commits.

## Before a pull request

On Windows:

```powershell
cargo fmt --all -- --check
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
cargo build --release --locked
```

When testing input/hooks, also use `scripts/Test-WindowsIntegration.ps1` on a disposable editor window. This test actively sends hotkeys and changes test-window properties; don't run it while an important foreground task needs focus.

On macOS:

```bash
bash scripts/Build-Mac.sh
bash scripts/Test-MacIntegration.sh
bash scripts/Test-MacInstallerTransaction.sh
```

The Mac integration test requires a real logged-in desktop session and permissions. CI build success does not prove that Screen Recording, Accessibility, multi-display behavior, or real opacity works correctly.

Include before/after CPU and memory measurements when introducing a persistent event monitor, capture stream, or animation. Prefer event-driven work over background polling.
