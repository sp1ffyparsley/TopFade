import AppKit
import Darwin

if CommandLine.arguments.contains("--unregister-login") {
    do {
        try PreferencesStore.setLaunchAtLoginRegistration(false)
        print("TopFade launch-at-login registration removed.")
        exit(EXIT_SUCCESS)
    } catch {
        fputs("TopFade could not remove launch at login: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if !CommandLine.arguments.contains("--self-test") {
    let currentProcessID = ProcessInfo.processInfo.processIdentifier
    if let existing = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.tavito.topfade"
    ).first(where: { $0.processIdentifier != currentProcessID }) {
        DistributedNotificationCenter.default().post(
            name: .topFadeActivationRequested,
            object: "com.tavito.topfade",
            userInfo: nil
        )
        _ = existing.activate(options: [.activateAllWindows])
        exit(EXIT_SUCCESS)
    }
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.setActivationPolicy(.accessory)
application.run()
exit(applicationDelegate.processExitCode)
