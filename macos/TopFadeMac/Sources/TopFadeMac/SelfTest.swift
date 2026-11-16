import AppKit
import Carbon
import CoreGraphics
import CryptoKit
import Foundation

final class MacIntegrationSelfTest {
    private let catalog = WindowCatalog()
    private let preferenceSuiteName: String
    private let preferenceDefaults: UserDefaults
    let preferences: PreferencesStore
    private lazy var manager = ReplicaManager(catalog: catalog, preferences: preferences)
    private var hotKey: GlobalHotKeyManager?
    private var scrollMonitor: ModifiedScrollMonitor?
    private var faderPanel: FaderPanelController?
    private var ownedTextEdit: NSRunningApplication?
    private var targetDirectory: URL?
    private var targetTitle = ""
    private var expectedRestoredOpacity = 100
    private var productionPreferencesAtStart: [String: Any] = [:]
    private var hotKeyEventCount = 0
    private var scrollEventCount = 0
    private var completion: ((Bool) -> Void)?
    private var finished = false
    private var result: [String: Any] = [
        "product": "TopFade",
        "platform": "macOS",
        "created_utc": ISO8601DateFormatter().string(from: Date()),
        "passed": false,
    ]

    init() {
        let suiteName = "com.tavito.topfade.self-test.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("TopFade could not create an isolated self-test preferences suite")
        }
        preferenceSuiteName = suiteName
        preferenceDefaults = defaults
        defaults.removePersistentDomain(forName: suiteName)
        preferences = PreferencesStore(defaults: defaults)
    }

    func run(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        productionPreferencesAtStart = UserDefaults.standard.persistentDomain(
            forName: "com.tavito.topfade"
        ) ?? [:]
        if let identityError = recordExecutableIdentity() {
            finish(passed: false, error: identityError)
            return
        }
        if let persistenceError = verifyRememberedStateContracts() {
            finish(passed: false, error: persistenceError)
            return
        }
        result["screen_recording_permission"] = PermissionStatus.screenRecordingGranted
        result["accessibility_permission"] = PermissionStatus.accessibilityGranted
        result["input_monitoring_permission"] = PermissionStatus.inputMonitoringGranted

        guard PermissionStatus.screenRecordingGranted else {
            _ = PermissionStatus.requestScreenRecording()
            finish(
                passed: false,
                error: "Screen Recording permission is required. Allow the built TopFade app in Privacy & Security, restart it, and rerun the integration test."
            )
            return
        }
        guard PermissionStatus.accessibilityGranted else {
            _ = PermissionStatus.requestAccessibility()
            finish(
                passed: false,
                error: "Accessibility permission is required to post and consume the native integration-test events. Allow the built TopFade app in Privacy & Security, restart it, and rerun the integration test."
            )
            return
        }
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.TextEdit"
        ).isEmpty else {
            finish(
                passed: false,
                error: "TextEdit was already running. Close it so the integration test cannot disturb an existing session."
            )
            return
        }

        do {
            let hotKey = GlobalHotKeyManager { [weak self] in
                guard let self else { return }
                self.hotKeyEventCount += 1
                self.result["hotkey_events_received"] = self.hotKeyEventCount
                self.manager.toggleFrontmostWindow()
            }
            try hotKey.start()
            self.hotKey = hotKey
            result["hotkey_registered"] = true
        } catch {
            result["hotkey_registered"] = false
            finish(
                passed: false,
                error: "Native Control+Command+T registration failed: \(error.localizedDescription)"
            )
            return
        }

        let faderPanel = FaderPanelController(preferences: preferences)
        self.faderPanel = faderPanel
        manager.onOpacityChanged = { replica in
            faderPanel.show(for: replica, force: true)
        }
        manager.onError = { [weak self] message in
            self?.result["last_manager_error"] = message
        }

        let scrollMonitor = ModifiedScrollMonitor(
            canHandle: { [weak self] point in
                self?.manager.canAdjustOpacity(at: point) == true
            },
            onScroll: { [weak self] direction, point in
                guard let self else { return false }
                self.scrollEventCount += 1
                self.result["scroll_events_received"] = self.scrollEventCount
                return self.manager.adjustOpacity(direction: direction, mouseLocation: point)
            },
            preferences: preferences
        )
        self.scrollMonitor = scrollMonitor
        let scrollStarted = scrollMonitor.start(consumingEvents: true)
        result["scroll_event_tap_started"] = scrollStarted
        result["scroll_event_tap_consumes"] = scrollMonitor.currentlyConsumesEvents
        guard scrollStarted, scrollMonitor.currentlyConsumesEvents else {
            finish(
                passed: false,
                error: "The production Option+Shift+scroll event filter did not start in consume mode despite Accessibility permission."
            )
            return
        }

        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "topfade-macos-self-test-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            targetDirectory = directory
            targetTitle = "TopFade Integration \(UUID().uuidString.prefix(8))"
            let target = directory.appendingPathComponent("\(targetTitle).txt")
            try """
            TopFade production macOS integration target.
            This file is created and removed by the bounded self-test.
            """.write(to: target, atomically: true, encoding: .utf8)
            launchTextEdit(target: target) { [weak self] source in
                self?.runInitialCapture(source: source, target: target)
            }
        } catch {
            finish(passed: false, error: "Test fixture creation failed: \(error.localizedDescription)")
        }
    }

    private func recordExecutableIdentity() -> String? {
        guard let executableURL = Bundle.main.executableURL else {
            return "The running TopFade executable URL is unavailable."
        }
        do {
            let executable = try Data(contentsOf: executableURL, options: .mappedIfSafe)
            let digest = SHA256.hash(data: executable)
            result["executable_path"] = executableURL.path
            result["executable_bytes"] = executable.count
            result["executable_sha256"] = digest.map { String(format: "%02x", $0) }.joined()
            return nil
        } catch {
            return "The running TopFade executable identity could not be measured: \(error.localizedDescription)"
        }
    }

    private func verifyRememberedStateContracts() -> String? {
        let suiteName = "com.tavito.topfade.persistence-self-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return "The remembered-state self-test could not create an isolated preferences suite."
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        do {
            let legacyRecord: [[String: Any]] = [[
                "bundleIdentifier": "com.tavito.topfade.fixture",
                "applicationName": "Fixture",
                "titleHint": "Shared title",
                "opacityPercent": 80,
                "clickThrough": false,
                "frameX": 20.0,
                "frameY": 30.0,
                "frameWidth": 640.0,
                "frameHeight": 360.0,
            ]]
            let legacyData = try JSONSerialization.data(withJSONObject: legacyRecord)
            defaults.set(legacyData, forKey: PreferencesStore.Key.rememberedReplicas)

            let store = PreferencesStore(defaults: defaults)
            let migrated = store.rememberedReplicas
            guard migrated.count == 1 else {
                return "Legacy remembered state did not decode into one record."
            }
            guard
                let migratedData = defaults.data(forKey: PreferencesStore.Key.rememberedReplicas),
                let migratedJSON = try JSONSerialization.jsonObject(with: migratedData)
                    as? [[String: Any]],
                migratedJSON.first?["id"] as? String != nil
            else {
                return "Legacy remembered state did not persist a stable replica identity."
            }
            result["remembered_state_legacy_migrated"] = true

            var second = migrated[0]
            second.id = UUID()
            second.opacityPercent = 55
            second.clickThrough = true
            store.rememberedReplicas = [migrated[0], second]

            let reloaded = PreferencesStore(defaults: defaults).rememberedReplicas
            let distinctIDs = Set(reloaded.map(\.id))
            guard reloaded.count == 2, distinctIDs.count == 2 else {
                return "Two same-title remembered replicas were collapsed during persistence."
            }
            result["remembered_same_title_records_preserved"] = true
            return nil
        } catch {
            return "Remembered-state contract checks failed: \(error.localizedDescription)"
        }
    }

    private func runInitialCapture(source: SourceWindow, target: URL) {
        result["textedit_launched"] = true
        result["initial_window_id"] = source.windowID
        waitUntil(timeout: 5, predicate: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == source.processID
        }) { [weak self] isFrontmost in
            guard let self else { return }
            self.result["textedit_frontmost_before_pin"] = isFrontmost
            guard isFrontmost else {
                self.finish(
                    passed: false,
                    error: "The owned TextEdit fixture did not become frontmost, so the native hotkey target could not be proven safely."
                )
                return
            }
            let eventsBefore = self.hotKeyEventCount
            guard self.postToggleHotKey() else {
                self.finish(
                    passed: false,
                    error: "The native Control+Command+T test event could not be created."
                )
                return
            }
            self.result["hotkey_pin_event_posted"] = true
            self.waitForReplica(
                matching: { $0.source.windowID == source.windowID },
                timeout: 10
            ) { [weak self] controller in
                guard let self else { return }
                guard let controller else {
                    self.finish(
                        passed: false,
                        error: "Control+Command+T was posted, but the initial TextEdit capture did not become active within 10 seconds."
                    )
                    return
                }
                self.result["hotkey_pin_event_received"] = self.hotKeyEventCount > eventsBefore
                self.verifyInitialReplica(controller, target: target)
            }
        }
    }

    private func verifyInitialReplica(
        _ controller: ReplicaController,
        target: URL
    ) {
        result["capture_started"] = true
        result["panel_floating"] = controller.panel.level == .floating
        result["panel_visible"] = controller.panel.isVisible

        let requestedOpacity = max(82, preferences.minimumOpacity)
        expectedRestoredOpacity = requestedOpacity
        controller.setOpacity(expectedRestoredOpacity)
        controller.setClickThrough(true)
        result["opacity_set_percent"] = controller.opacityPercent
        result["opacity_alpha_matches"] =
            abs(controller.panel.alphaValue - CGFloat(requestedOpacity) / 100) < 0.01
        result["click_through_enabled"] = controller.panel.ignoresMouseEvents

        controller.setOpacity(100)
        verifyScrollOutsideReplica(controller, target: target)
    }

    private func verifyScrollOutsideReplica(
        _ controller: ReplicaController,
        target: URL
    ) {
        let opacityBefore = controller.opacityPercent
        let eventsBefore = scrollEventCount
        result["replica_positioned_away_from_pointer"] = positionAwayFromPointer(controller)
        guard controller.panel.frame.contains(NSEvent.mouseLocation) == false else {
            finish(
                passed: false,
                error: "The replica could not be positioned away from the pointer for the outside-scroll safety check."
            )
            return
        }
        guard postModifiedScroll(delta: -1) else {
            finish(
                passed: false,
                error: "The outside-replica Option+Shift scroll test event could not be created."
            )
            return
        }
        result["scroll_outside_event_posted"] = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let ignored = controller.opacityPercent == opacityBefore
                && self.scrollEventCount == eventsBefore
            self.result["scroll_outside_replica_ignored"] = ignored
            guard ignored else {
                self.finish(
                    passed: false,
                    error: "Option+Shift scroll outside every replica changed or targeted a remembered panel."
                )
                return
            }
            self.verifyScrollOverReplica(controller, target: target)
        }
    }

    private func verifyScrollOverReplica(
        _ controller: ReplicaController,
        target: URL
    ) {
        let beforeScroll = controller.opacityPercent
        result["replica_positioned_under_pointer"] = positionUnderPointer(controller)
        let scrollEventsBefore = scrollEventCount
        guard postModifiedScroll(delta: -1) else {
            finish(
                passed: false,
                error: "The native Option+Shift scroll-down test event could not be created."
            )
            return
        }
        result["scroll_down_event_posted"] = true
        waitUntil(timeout: 4, predicate: {
            controller.opacityPercent < beforeScroll
        }) { [weak self] decreased in
            guard let self else { return }
            self.result["scroll_down_event_received"] =
                decreased && self.scrollEventCount > scrollEventsBefore
            self.result["scroll_event_decreased"] = decreased
            self.result["opacity_after_scroll_down"] = controller.opacityPercent
            self.result["fader_window_seen_from_scroll"] = NSApp.windows.contains {
                $0.title == "TopFade opacity" && $0.isVisible
            }
            guard decreased else {
                self.finish(
                    passed: false,
                    error: "Option+Shift scroll-down was posted, but the production event tap did not reduce replica opacity."
                )
                return
            }

            let eventsBeforeUp = self.scrollEventCount
            guard self.postModifiedScroll(delta: 1) else {
                self.finish(
                    passed: false,
                    error: "The native Option+Shift scroll-up test event could not be created."
                )
                return
            }
            self.result["scroll_up_event_posted"] = true
            self.waitUntil(timeout: 4, predicate: {
                controller.opacityPercent == beforeScroll
            }) { [weak self] restored in
                guard let self else { return }
                self.result["scroll_up_event_received"] =
                    restored && self.scrollEventCount > eventsBeforeUp
                self.result["scroll_event_restored"] = restored
                self.result["opacity_after_scroll_up"] = controller.opacityPercent
                guard restored else {
                    self.finish(
                        passed: false,
                        error: "Option+Shift scroll-up was posted, but the production event tap did not restore replica opacity."
                    )
                    return
                }
                self.continueWithPersistence(controller, target: target)
            }
        }
    }

    private func continueWithPersistence(
        _ controller: ReplicaController,
        target: URL
    ) {
        controller.setOpacity(expectedRestoredOpacity)
        waitUntil(timeout: 2, predicate: {
            self.preferences.rememberedReplicas.contains {
                $0.bundleIdentifier == "com.apple.TextEdit"
                    && $0.titleHint.localizedCaseInsensitiveContains(self.targetTitle)
                    && $0.opacityPercent == self.expectedRestoredOpacity
                    && $0.clickThrough
            }
        }) { [weak self] remembered in
            guard let self else { return }
            self.result["remembered_after_pin"] = remembered
            guard remembered else {
                self.finish(
                    passed: false,
                    error: "The coalesced remembered replica state was not committed within two seconds."
                )
                return
            }

            // Exercise the same process-scoped cleanup used when a pinned
            // source application exits. The original window preference
            // must survive so reopening can restore the replica.
            self.manager.unpinReplicas(forProcessID: controller.source.processID)
            let released = !self.manager.activeReplicas.contains {
                $0.source.windowID == controller.source.windowID
            }
            let retained = self.preferences.rememberedReplicas.contains {
                $0.bundleIdentifier == "com.apple.TextEdit"
                    && $0.titleHint.localizedCaseInsensitiveContains(self.targetTitle)
                    && $0.opacityPercent == self.expectedRestoredOpacity
                    && $0.clickThrough
            }
            self.result["process_scoped_unpin_released_replica"] = released
            self.result["process_scoped_unpin_kept_remembered_state"] = retained
            guard released && retained else {
                self.finish(
                    passed: false,
                    error: "Process-scoped unpin did not both release the capture and preserve remembered state."
                )
                return
            }
            self.terminateOwnedTextEdit { [weak self] terminated in
                guard let self else { return }
                guard terminated else {
                    self.finish(
                        passed: false,
                        error: "The owned TextEdit fixture did not terminate before the reopen test."
                    )
                    return
                }
                self.launchTextEdit(target: target) { [weak self] reopenedSource in
                    self?.verifyRestoration(reopenedSource)
                }
            }
        }
    }

    private func verifyRestoration(_ reopenedSource: SourceWindow) {
        result["textedit_reopened"] = true
        result["reopened_window_id"] = reopenedSource.windowID
        manager.restoreRemembered(
            preferredProcessID: reopenedSource.processID,
            ignoringPreference: true
        )
        waitForReplica(
            matching: {
                $0.source.bundleIdentifier == "com.apple.TextEdit"
                    && $0.source.title.localizedCaseInsensitiveContains(self.targetTitle)
            },
            timeout: 10
        ) { [weak self] restored in
            guard let self else { return }
            guard let restored else {
                self.finish(
                    passed: false,
                    error: "The remembered TextEdit replica was not restored after reopening."
                )
                return
            }
            self.result["restored_after_reopen"] = true
            self.result["restored_opacity_percent"] = restored.opacityPercent
            self.result["restored_click_through"] = restored.clickThrough
            self.result["restored_new_window_identity"] =
                restored.source.processID != 0
                    && restored.source.windowID == reopenedSource.windowID
            self.verifyNativeUnpin(reopenedSource)
        }
    }

    private func verifyNativeUnpin(_ reopenedSource: SourceWindow) {
        waitUntil(timeout: 5, predicate: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == reopenedSource.processID
        }) { [weak self] isFrontmost in
            guard let self else { return }
            self.result["textedit_frontmost_before_unpin"] = isFrontmost
            guard isFrontmost else {
                self.finish(
                    passed: false,
                    error: "The reopened TextEdit fixture was not frontmost, so the native unpin hotkey could not be proven safely."
                )
                return
            }

            let eventsBefore = self.hotKeyEventCount
            guard self.postToggleHotKey() else {
                self.finish(
                    passed: false,
                    error: "The second native Control+Command+T test event could not be created."
                )
                return
            }
            self.result["hotkey_unpin_event_posted"] = true
            self.waitUntil(timeout: 10, predicate: {
                !self.manager.activeReplicas.contains {
                    $0.source.windowID == reopenedSource.windowID
                }
            }) { [weak self] unpinned in
                guard let self else { return }
                self.result["hotkey_unpin_event_received"] =
                    unpinned && self.hotKeyEventCount > eventsBefore
                self.result["hotkey_unpinned_target"] = unpinned
                self.result["hotkey_forgot_remembered_target"] =
                    !self.preferences.rememberedReplicas.contains {
                        $0.bundleIdentifier == "com.apple.TextEdit"
                            && $0.titleHint.localizedCaseInsensitiveContains(self.targetTitle)
                    }
                self.evaluateRequiredChecks()
            }
        }
    }

    private func evaluateRequiredChecks() {
        let requiredChecks = [
            result["remembered_state_legacy_migrated"] as? Bool == true,
            result["remembered_same_title_records_preserved"] as? Bool == true,
            result["screen_recording_permission"] as? Bool == true,
            result["accessibility_permission"] as? Bool == true,
            result["hotkey_registered"] as? Bool == true,
            result["hotkey_pin_event_posted"] as? Bool == true,
            result["hotkey_pin_event_received"] as? Bool == true,
            result["hotkey_unpin_event_posted"] as? Bool == true,
            result["hotkey_unpin_event_received"] as? Bool == true,
            hotKeyEventCount >= 2,
            result["scroll_event_tap_started"] as? Bool == true,
            result["scroll_event_tap_consumes"] as? Bool == true,
            result["replica_positioned_away_from_pointer"] as? Bool == true,
            result["scroll_outside_event_posted"] as? Bool == true,
            result["scroll_outside_replica_ignored"] as? Bool == true,
            result["scroll_down_event_posted"] as? Bool == true,
            result["scroll_down_event_received"] as? Bool == true,
            result["scroll_up_event_posted"] as? Bool == true,
            result["scroll_up_event_received"] as? Bool == true,
            scrollEventCount >= 2,
            result["capture_started"] as? Bool == true,
            result["panel_floating"] as? Bool == true,
            result["panel_visible"] as? Bool == true,
            result["opacity_set_percent"] as? Int == expectedRestoredOpacity,
            result["opacity_alpha_matches"] as? Bool == true,
            result["click_through_enabled"] as? Bool == true,
            result["replica_positioned_under_pointer"] as? Bool == true,
            result["scroll_event_decreased"] as? Bool == true,
            result["scroll_event_restored"] as? Bool == true,
            result["fader_window_seen_from_scroll"] as? Bool == true,
            result["remembered_after_pin"] as? Bool == true,
            result["process_scoped_unpin_released_replica"] as? Bool == true,
            result["process_scoped_unpin_kept_remembered_state"] as? Bool == true,
            result["restored_after_reopen"] as? Bool == true,
            result["restored_opacity_percent"] as? Int == expectedRestoredOpacity,
            result["restored_click_through"] as? Bool == true,
            result["restored_new_window_identity"] as? Bool == true,
            result["hotkey_unpinned_target"] as? Bool == true,
            result["hotkey_forgot_remembered_target"] as? Bool == true,
        ]
        if requiredChecks.allSatisfy({ $0 }) {
            finish(passed: true, error: nil)
        } else {
            finish(
                passed: false,
                error: "One or more macOS integration assertions failed. Inspect the receipt fields."
            )
        }
    }

    private func postToggleHotKey() -> Bool {
        guard
            let keyDown = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(kVK_ANSI_T),
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(kVK_ANSI_T),
                keyDown: false
            )
        else {
            return false
        }
        let flags: CGEventFlags = [.maskControl, .maskCommand]
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func postModifiedScroll(delta: Int32) -> Bool {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else {
            return false
        }
        event.flags = [.maskAlternate, .maskShift]
        event.post(tap: .cghidEventTap)
        return true
    }

    private func positionUnderPointer(_ controller: ReplicaController) -> Bool {
        let point = NSEvent.mouseLocation
        var frame = controller.panel.frame
        frame.origin = NSPoint(
            x: point.x - frame.width / 2,
            y: point.y - frame.height / 2
        )
        controller.panel.setFrame(frame, display: true)
        controller.panel.orderFrontRegardless()
        return controller.panel.frame.contains(point)
    }

    private func positionAwayFromPointer(_ controller: ReplicaController) -> Bool {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return false }
        var frame = controller.panel.frame
        let candidates = [
            NSPoint(x: visible.minX, y: visible.minY),
            NSPoint(x: visible.maxX - frame.width, y: visible.minY),
            NSPoint(x: visible.minX, y: visible.maxY - frame.height),
            NSPoint(x: visible.maxX - frame.width, y: visible.maxY - frame.height),
        ]
        guard let origin = candidates.first(where: {
            var candidate = frame
            candidate.origin = $0
            return !candidate.contains(point)
        }) else {
            return false
        }
        frame.origin = origin
        controller.panel.setFrame(frame, display: true)
        controller.panel.orderFrontRegardless()
        return !controller.panel.frame.contains(point)
    }

    private func waitUntil(
        timeout: TimeInterval,
        predicate: @escaping () -> Bool,
        completion: @escaping (Bool) -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if predicate() {
                completion(true)
                return
            }
            guard Date() < deadline else {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: check)
        }
        check()
    }

    private func launchTextEdit(
        target: URL,
        completion: @escaping (SourceWindow) -> Void
    ) {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", "-a", "TextEdit", target.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                finish(
                    passed: false,
                    error: "/usr/bin/open could not launch TextEdit (exit \(process.terminationStatus))."
                )
                return
            }
            findTargetWindow(deadline: Date().addingTimeInterval(12)) { [weak self] source in
                guard let self else { return }
                guard let source else {
                    self.finish(
                        passed: false,
                        error: "The real TextEdit test window was not discoverable within 12 seconds."
                    )
                    return
                }
                self.ownedTextEdit = NSRunningApplication(
                    processIdentifier: source.processID
                )
                completion(source)
            }
        } catch {
            finish(passed: false, error: "TextEdit launch failed: \(error.localizedDescription)")
        }
    }

    private func findTargetWindow(
        deadline: Date,
        completion: @escaping (SourceWindow?) -> Void
    ) {
        catalog.refresh { [weak self] result in
            guard let self else { return }
            if case let .success(windows) = result,
               let source = windows.first(where: {
                   $0.bundleIdentifier == "com.apple.TextEdit"
                       && $0.title.localizedCaseInsensitiveContains(self.targetTitle)
               }) {
                completion(source)
                return
            }
            guard Date() < deadline else {
                completion(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.findTargetWindow(deadline: deadline, completion: completion)
            }
        }
    }

    private func waitForReplica(
        matching predicate: @escaping (ReplicaController) -> Bool,
        timeout: TimeInterval,
        completion: @escaping (ReplicaController?) -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if let replica = manager.activeReplicas.first(where: predicate) {
                completion(replica)
                return
            }
            guard Date() < deadline else {
                completion(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: check)
        }
        check()
    }

    private func terminateOwnedTextEdit(completion: @escaping (Bool) -> Void) {
        guard let ownedTextEdit else {
            completion(true)
            return
        }
        _ = ownedTextEdit.terminate()
        func wait(until deadline: Date, mayForce: Bool) {
            if ownedTextEdit.isTerminated {
                self.ownedTextEdit = nil
                completion(true)
                return
            }
            if Date() >= deadline {
                guard mayForce else {
                    completion(false)
                    return
                }
                let requested = ownedTextEdit.forceTerminate()
                TopFadeLogger.shared.warn("TextEdit required forced cleanup", metadata: [
                    "force_terminate_requested": String(requested),
                    "process_id": String(ownedTextEdit.processIdentifier),
                ])
                let forceDeadline = Date().addingTimeInterval(2)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    wait(until: forceDeadline, mayForce: false)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                wait(until: deadline, mayForce: mayForce)
            }
        }
        wait(until: Date().addingTimeInterval(6), mayForce: true)
    }

    private func finish(passed: Bool, error: String?) {
        guard !finished else { return }
        finished = true
        manager.unpinAll(forget: true)
        preferenceDefaults.removePersistentDomain(forName: preferenceSuiteName)
        let productionPreferencesNow = UserDefaults.standard.persistentDomain(
            forName: "com.tavito.topfade"
        ) ?? [:]
        let productionPreferencesUnchanged = NSDictionary(
            dictionary: productionPreferencesNow
        ).isEqual(NSDictionary(dictionary: productionPreferencesAtStart))
        let isolatedPreferencesRemoved =
            preferenceDefaults.persistentDomain(forName: preferenceSuiteName)?.isEmpty ?? true
        result["production_preferences_unchanged"] = productionPreferencesUnchanged
        result["isolated_preferences_removed"] = isolatedPreferencesRemoved
        var completionErrors = error.map { [$0] } ?? []
        if !productionPreferencesUnchanged {
            completionErrors.append("The isolated self-test changed production preferences.")
        }
        if !isolatedPreferencesRemoved {
            completionErrors.append("The isolated self-test preferences suite could not be removed.")
        }
        hotKey?.stop()
        scrollMonitor?.stop()
        terminateOwnedTextEdit { [weak self] textEditTerminated in
            self?.writeFinalReceipt(
                requestedPass: passed
                    && productionPreferencesUnchanged
                    && isolatedPreferencesRemoved,
                error: completionErrors.isEmpty
                    ? nil
                    : completionErrors.joined(separator: " "),
                textEditTerminated: textEditTerminated
            )
        }
    }

    private func writeFinalReceipt(
        requestedPass: Bool,
        error: String?,
        textEditTerminated: Bool
    ) {
        var finalPass = requestedPass && textEditTerminated
        var errors = error.map { [$0] } ?? []
        if !textEditTerminated {
            errors.append("The owned TextEdit fixture remained running after normal and forced termination attempts.")
        }

        var fixtureRemoved = targetDirectory == nil
        if let targetDirectory {
            if textEditTerminated {
                do {
                    if FileManager.default.fileExists(atPath: targetDirectory.path) {
                        try FileManager.default.removeItem(at: targetDirectory)
                    }
                    fixtureRemoved = true
                    self.targetDirectory = nil
                } catch {
                    errors.append("The temporary TextEdit fixture could not be removed: \(error.localizedDescription)")
                }
            } else {
                result["retained_fixture_path"] = targetDirectory.path
            }
        }
        finalPass = finalPass && fixtureRemoved
        result["textedit_cleanup_completed"] = textEditTerminated
        result["fixture_cleanup_completed"] = fixtureRemoved
        result["passed"] = finalPass
        result["completed_utc"] = ISO8601DateFormatter().string(from: Date())
        result["error"] = errors.isEmpty ? NSNull() : errors.joined(separator: " ")

        let receipt = ProcessInfo.processInfo.environment["TOPFADE_SELF_TEST_RECEIPT"]
            .map(URL.init(fileURLWithPath:))
            ?? TopFadeLogger.shared.reportDirectory.appendingPathComponent(
                "macos-integration-self-test.json"
            )
        var processPassed = finalPass
        do {
            let data = try JSONSerialization.data(
                withJSONObject: result,
                options: [.prettyPrinted, .sortedKeys]
            )
            try FileManager.default.createDirectory(
                at: receipt.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: receipt, options: .atomic)
            TopFadeLogger.shared.info("macOS integration self-test completed", metadata: [
                "fixture_cleanup_completed": String(fixtureRemoved),
                "passed": String(finalPass),
                "receipt": receipt.path,
                "textedit_cleanup_completed": String(textEditTerminated),
            ])
        } catch {
            processPassed = false
            TopFadeLogger.shared.error("macOS integration receipt could not be written", metadata: [
                "error": error.localizedDescription,
                "path": receipt.path,
            ])
        }
        TopFadeLogger.shared.flush()
        let exitPass = processPassed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [completion] in
            completion?(exitPass)
        }
    }
}
