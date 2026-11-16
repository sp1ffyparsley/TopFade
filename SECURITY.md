# Security and privacy

TopFade operates locally. Its Windows build changes window properties through Win32; its Mac companion needs Screen Recording for mirrors, and optionally Accessibility or Input Monitoring for modified-scroll controls.

It does not need administrator rights for its normal per-user Windows install, nor should it ask you to disable macOS System Integrity Protection.

TopFade can read visible application/window titles for selection and diagnostics. Diagnostic exports can contain titles, process identifiers, and executable paths. **Review and redact reports before sharing them.** Do not publish raw configuration files, registry exports, crash dumps, or screenshots containing private documents.

If you discover a security issue, avoid posting working exploits or personal logs in a public issue. Use the repository's GitHub private vulnerability reporting if available, or contact the maintainer privately through GitHub.

No official signed release or notarized macOS distribution is currently provided. Verify the repository and build output before executing it.
