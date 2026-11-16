import AppKit

private func topFadeUncaughtExceptionHandler(_ exception: NSException) {
    TopFadeLogger.shared.error("Uncaught Objective-C exception", metadata: [
        "name": exception.name.rawValue,
        "reason": exception.reason ?? "unknown",
        "call_stack": exception.callStackSymbols.joined(separator: " | "),
    ])
    TopFadeLogger.shared.flush()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var processExitCode: Int32 = 0
    private var catalog: WindowCatalog?
    private var manager: ReplicaManager?
    private var viewModel: TopFadeViewModel?
    private var controlWindow: ControlWindowController?
    private var preferencesWindow: PreferencesWindowController?
    private var faderPanel: FaderPanelController?
    private var menuBar: MenuBarController?
    private var hotKey: GlobalHotKeyManager?
    private var scrollMonitor: ModifiedScrollMonitor?
    private var integrationSelfTest: MacIntegrationSelfTest?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var pendingActivationRequest = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let selfTest = CommandLine.arguments.contains("--self-test")
            ? MacIntegrationSelfTest()
            : nil
        let preferences = selfTest?.preferences ?? PreferencesStore.shared
        do {
            try TopFadeLogger.shared.start(preferences: preferences)
        } catch {
            if selfTest != nil {
                processExitCode = 1
                let message = "TopFade self-test could not initialize its isolated log folder: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(message.utf8))
                NSApp.terminate(nil)
                return
            }
            presentFatalStartupError(
                "TopFade could not initialize its log folder.",
                detail: error.localizedDescription
            )
            return
        }
        NSSetUncaughtExceptionHandler(topFadeUncaughtExceptionHandler)

        TopFadeLogger.shared.info("TopFade starting", metadata: [
            "version": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "development",
            "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
            "executable": Bundle.main.executableURL?.path ?? CommandLine.arguments[0],
        ])

        if let selfTest {
            integrationSelfTest = selfTest
            selfTest.run { [weak self] passed in
                self?.processExitCode = passed ? 0 : 1
                NSApp.terminate(nil)
            }
            return
        }

        distributedObservers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: .topFadeActivationRequested,
                object: "com.tavito.topfade",
                queue: .main
            ) { [weak self] _ in
                self?.presentControlWindowFromActivationRequest()
            }
        )

        let catalog = WindowCatalog()
        let manager = ReplicaManager(catalog: catalog, preferences: preferences)
        let faderPanel = FaderPanelController(preferences: preferences)
        self.catalog = catalog
        self.manager = manager
        self.faderPanel = faderPanel

        manager.onOpacityChanged = { [weak faderPanel] replica in
            faderPanel?.show(for: replica)
        }

        let scrollMonitor = ModifiedScrollMonitor(
            canHandle: { [weak manager] point in
                manager?.canAdjustOpacity(at: point) == true
            },
            onScroll: { [weak manager] direction, point in
                manager?.adjustOpacity(direction: direction, mouseLocation: point) == true
            },
            preferences: preferences
        )
        self.scrollMonitor = scrollMonitor
        _ = scrollMonitor.start()

        let viewModel = TopFadeViewModel(
            manager: manager,
            restartInputMonitoring: { [weak scrollMonitor] in
                scrollMonitor?.restart() ?? .inactive
            },
            inputMonitoringMode: { [weak scrollMonitor] in
                scrollMonitor?.mode ?? .inactive
            },
            preferences: preferences
        )
        self.viewModel = viewModel

        let hotKey = GlobalHotKeyManager { [weak manager] in
            manager?.toggleFrontmostWindow()
        }
        self.hotKey = hotKey
        do {
            try hotKey.start()
        } catch {
            let message = "Control+Command+T is unavailable: \(error.localizedDescription)"
            TopFadeLogger.shared.error(message)
            viewModel.statusMessage = message
        }

        let preferencesWindow = PreferencesWindowController(
            manager: manager,
            scrollSettingsChanged: { [weak scrollMonitor, weak viewModel] in
                _ = scrollMonitor?.restart()
                viewModel?.syncInputMonitoringMode(announce: true)
            },
            currentInputMode: { [weak scrollMonitor] in
                scrollMonitor?.mode ?? .inactive
            },
            exportDiagnostics: { [weak viewModel] in
                if let url = viewModel?.exportDiagnostics() {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        )
        self.preferencesWindow = preferencesWindow

        let controlWindow = ControlWindowController(
            model: viewModel,
            showPreferences: { [weak preferencesWindow] in
                preferencesWindow?.present()
            }
        )
        self.controlWindow = controlWindow
        if pendingActivationRequest {
            presentControlWindowFromActivationRequest()
        }

        menuBar = MenuBarController(
            manager: manager,
            showControl: { [weak controlWindow] in
                controlWindow?.present()
            },
            showPreferences: { [weak preferencesWindow] in
                preferencesWindow?.present()
            },
            exportDiagnostics: { [weak viewModel] in
                if let url = viewModel?.exportDiagnostics() {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        )

        installWorkspaceObservers()

        let shouldShowControl = !preferences.startHidden || !preferences.completedOnboarding
        if shouldShowControl {
            controlWindow.present()
        }
        if !preferences.completedOnboarding {
            preferences.completedOnboarding = true
            viewModel.statusMessage = PermissionStatus.screenRecordingGranted
                ? "Ready. Press Control+Command+T on a normal application window."
                : "Allow Screen Recording to create your first live replica."
        }

        if preferences.restoreRemembered, PermissionStatus.screenRecordingGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak manager] in
                manager?.restoreRemembered()
            }
        }
        TopFadeLogger.shared.info("TopFade startup completed", metadata: [
            "screen_recording_permission": String(PermissionStatus.screenRecordingGranted),
            "accessibility_permission": String(PermissionStatus.accessibilityGranted),
            "input_monitoring_permission": String(PermissionStatus.inputMonitoringGranted),
            "modified_scroll_mode": scrollMonitor.mode.rawValue,
            "remembered_replica_count": String(preferences.rememberedReplicas.count),
        ])
    }

    func applicationWillTerminate(_ notification: Notification) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspaceCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers.forEach { distributedCenter.removeObserver($0) }
        distributedObservers.removeAll()
        hotKey?.stop()
        scrollMonitor?.stop()
        manager?.unpinAll(forget: false)
        TopFadeLogger.shared.info("TopFade shutdown completed")
        TopFadeLogger.shared.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        presentControlWindowFromActivationRequest()
        return true
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication else {
                    return
                }
                self?.manager?.unpinReplicas(forProcessID: application.processIdentifier)
            }
        )
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let application = notification.userInfo?[
                        NSWorkspace.applicationUserInfoKey
                    ] as? NSRunningApplication,
                    application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                    let bundleIdentifier = application.bundleIdentifier,
                    self?.manager?.hasRememberedReplica(
                        forBundleIdentifier: bundleIdentifier
                    ) == true
                else {
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    self?.manager?.restoreRemembered(
                        preferredProcessID: application.processIdentifier
                    )
                }
            }
        )
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self?.manager?.restoreRemembered()
                }
            }
        )
    }

    private func presentControlWindowFromActivationRequest() {
        guard let controlWindow else {
            pendingActivationRequest = true
            return
        }
        pendingActivationRequest = false
        controlWindow.present()
        TopFadeLogger.shared.info("Existing TopFade instance activated")
    }

    private func presentFatalStartupError(_ message: String, detail: String) {
        processExitCode = 1
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = "\(detail)\n\nCheck ~/Library/Logs and folder permissions."
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }
}
