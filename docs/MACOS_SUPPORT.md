# macOS support and limitations

TopFade's macOS build is a Swift/AppKit companion to the Windows tool. It is **experimental source**, not a verified production Mac app.

## Platform differences

Windows exposes Win32 APIs for a process to set another window's topmost flag and layered alpha. AppKit only controls windows owned by the calling process. The Mac build instead captures another app's pixels with **ScreenCaptureKit** and displays them in a floating **AppKit panel**.

This preserves macOS System Integrity Protection and avoids private WindowServer APIs, but it also creates limitations:

- The floating image is not the original interactive window. Click-through is available; forwarding complete input to the source is not implemented.
- Changing the floating panel's alpha **does not make the original underlying app window transparent**. If the replica sits above the original, that original may show through. Do not mistake this for direct in-place transparency.
- Capturing protected or DRM content may fail or show blank output.
- Window placement, fullscreen Spaces, multiple displays, Retina scale changes, sleep/wake, and input permission transitions need physical Mac testing.
- Continuous capture consumes some GPU and power. The default frame rate is 30 fps, and the app keeps only the most recent unrendered frame for AppKit.

## Privacy and permissions

- **Screen Recording:** needed to capture target windows.
- **Accessibility:** needed when modified scroll is consumed and for native integration tests.
- **Input Monitoring:** supported as a listen-only alternative in the appropriate input mode.

TopFade should never ask to disable System Integrity Protection or install a privileged helper merely to show a window replica.

## Upstream research

TopFade's design was compared with [Seethru](https://github.com/paulintheclub/seethru), [PinWindow](https://github.com/justwy/PinWindow), and [Topsy](https://github.com/andhikapraa/topsy). Their source implementations were not imported.

- **Seethru:** closest to real see-through behavior; it uses an excluded-window backdrop and additional compositing, at a possible capture/performance cost. Some modes use undocumented APIs.
- **PinWindow:** always-on-top live mirrors; 60 fps capture per pinned window could cost more GPU power with several mirrors.
- **Topsy:** view-only floating mirror, keeps interactions separate and avoids many input permissions.

TopFade selectively implements automatic cleanup on GUI source-process exit and generation checks for late/stale frames. These changes also require a Mac build and runtime verification.

## Test on a Mac

```bash
bash scripts/Build-Mac.sh
bash scripts/Test-MacIntegration.sh
bash scripts/Test-MacInstallerTransaction.sh
```

The integration test uses disposable TextEdit content and checks remembered state, hotkeys, modified scrolling, and cleanup. Validate with actual permission dialogs and report observed CPU/GPU/RAM before considering a signed release. CI compilation cannot establish real user-session behavior or true in-place transparency.
