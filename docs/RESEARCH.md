# External Research And Decisions

Research was refreshed on 2026-08-19. External projects were used only when they improved reliability or prevented a known design mistake. Source was not copied unless it arrived through a declared package dependency in `Cargo.lock`.

## Accepted

| Source | License | Decision used |
| --- | --- | --- |
| [tauri-apps/global-hotkey](https://github.com/tauri-apps/global-hotkey) | MIT OR Apache-2.0 | Used as the Windows Rust dependency for exact native global accelerator registration and event delivery. |
| [tauri-apps/tray-icon](https://github.com/tauri-apps/tray-icon) | MIT OR Apache-2.0 | Used as the Windows Rust dependency for a native tray/menu owner tied to the existing event loop. |
| [soffes/HotKey](https://github.com/soffes/HotKey) | MIT | Its small Carbon event-handler pattern was reviewed as a reference. TopFade implements the required one hotkey directly and adds no Mac package dependency. |
| [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) | Platform SDK | `SCShareableContent`, `SCContentFilter`, `SCStream`, and `SCStreamConfiguration` are the public capture foundation for Mac replicas. |
| [Apple AVSampleBufferDisplayLayer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer) | Platform SDK | Used for direct display of ScreenCaptureKit sample buffers without a custom render engine. |
| [Apple CGEvent tapCreate](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate%28tap%3Aplace%3Aoptions%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29) | Platform SDK | Used for event-driven modified-scroll input with listen-only fallback when suppressing input is not permitted. |
| [Apple CGEvent post](https://developer.apple.com/documentation/coregraphics/cgevent/post%28tap%3A%29) | Platform SDK | Used by the bounded Mac verifier to post exact keyboard and wheel events before the production session tap instead of asserting through direct manager calls. |
| [Apple event-input permission guidance](https://developer.apple.com/forums/thread/828052) | Platform guidance | Accessibility grants posting and listening; Input Monitoring grants listening only. TopFade does not demand both grants for one input path. |
| [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) | Platform SDK | Used for an opt-in, user-visible launch-at-login preference on macOS. |
| [Apple SMAppService `requiresApproval`](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval) | Platform SDK | A pending user approval is a successful registration request, so TopFade keeps the preference on and does not call `register()` again. |

## Reference Only

| Source | License/status | Useful conclusion |
| --- | --- | --- |
| [WindowTop](https://github.com/WindowTop/WindowTop-App) | Repository distributes product information/releases; application implementation is not a reusable source base | Feature baseline only. TopFade does not patch, automate, reverse engineer, or read WindowTop settings/licenses. |
| [lihaoyun6/Topit](https://github.com/lihaoyun6/Topit) | AGPL-3.0 | Confirmed that ScreenCaptureKit replicas plus explicit Screen Recording/Accessibility permissions are a practical public-API Mac design. No code was copied. |
| [OnTopReplica](https://github.com/LorenzCK/OnTopReplica) | MS-RL | Confirmed the replica model and click-through use case. Its Windows DWM/.NET architecture is unnecessary because Windows already permits direct control. |

## Rejected

| Candidate | Reason rejected |
| --- | --- |
| [screencapturekit-rs](https://github.com/svtlabs/screencapturekit-rs) | Capable bindings, but a Rust-to-Apple-framework bridge would add dependencies and ownership complexity without improving this small native Swift target. |
| [GlazeWM](https://github.com/glzr-io/glazewm) | A full tiling window manager overlaps far beyond this workflow and would add architecture, process, configuration, and license complexity. |
| [yabai](https://github.com/asmvik/yabai) | Some advanced window-level behavior depends on private APIs, process injection, or reduced SIP protections. That security tradeoff is not acceptable here. |
| AutoHotkey or PowerShell key translation | The original failure came from translating or misrepresenting shortcuts. TopFade must register `Ctrl+Win+T` itself and receive the native event directly. |
| Periodic restore watcher | Replaced by OS window-show/workspace notifications. A resident utility should not enumerate windows on a fixed interval when the OS can report the relevant event. |
| Electron/Tauri application shell | The product has no web or server requirement. Native Rust/egui on Windows and AppKit on Mac keep runtime size, startup, and failure surface smaller. |
| Built-in updater, telemetry, cloud sync, or database | None improves the requested pin/fade workflow. Releases, settings, logs, and remembered state remain local and inspectable. |
| Requiring both Accessibility and Input Monitoring | Apple documents that Accessibility already covers event posting and listening. Requiring both would add permission bloat and make valid installations look broken. |

## Reconsideration Standard

A rejected option should be reconsidered only with a measured gap that the existing owner cannot solve safely. Record the benchmark, platform limitation, license effect, migration path, and rollback plan before changing the decision.
