# Changelog

TopFade is under active development. There has not yet been an official binary release on GitHub.

## Unreleased — initial GitHub source publication

- Native Windows always-on-top, opacity and click-through control, searchable picker, rules, tray, remembered windows, event-driven input, and recoverable configuration.
- macOS Swift/AppKit companion based on ScreenCaptureKit floating replicas; experimental and not feature-equivalent to Windows direct opacity.
- Local Windows source checks and integration fixtures; CI builds Windows and macOS source artifacts.
- Mac source hardening for process-scoped capture cleanup and late-frame generation checks, pending native Mac validation.
- Source structure, documentation, security notes, and diagrams prepared for public review.
- GitHub Actions macOS compilation moved to the supported `macos-15` runner after the `macos-14` image retirement.

For detailed implementation history, see the Git commit log and [validation notes](docs/VALIDATION.md). Build artifacts are not automatically considered production releases.
