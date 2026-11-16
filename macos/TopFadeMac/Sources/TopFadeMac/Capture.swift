import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

extension Notification.Name {
    static let topFadeActivationRequested = Notification.Name(
        "com.tavito.topfade.activation-requested"
    )
    static let topFadeCatalogChanged = Notification.Name("TopFadeCatalogChanged")
    static let topFadeReplicasChanged = Notification.Name("TopFadeReplicasChanged")
    static let topFadeReplicaError = Notification.Name("TopFadeReplicaError")
}

final class SourceWindow {
    let captureWindow: SCWindow
    let windowID: CGWindowID
    let processID: pid_t
    let title: String
    let applicationName: String
    let bundleIdentifier: String
    let frame: CGRect

    init?(captureWindow: SCWindow) {
        guard let owner = captureWindow.owningApplication else { return nil }
        let title = captureWindow.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, captureWindow.frame.width >= 80, captureWindow.frame.height >= 60 else {
            return nil
        }
        self.captureWindow = captureWindow
        windowID = captureWindow.windowID
        processID = owner.processID
        self.title = title
        applicationName = owner.applicationName
        bundleIdentifier = owner.bundleIdentifier
        frame = captureWindow.frame
    }

    var displayName: String {
        "\(applicationName) - \(title)"
    }

    var id: CGWindowID {
        windowID
    }
}

final class WindowCatalog {
    private(set) var windows: [SourceWindow] = []
    private var refreshInFlight = false
    private var queuedCompletions: [(Result<[SourceWindow], Error>) -> Void] = []

    func refresh(
        completion: @escaping (Result<[SourceWindow], Error>) -> Void
    ) {
        queuedCompletions.append(completion)
        guard !refreshInFlight else { return }
        refreshInFlight = true

        SCShareableContent.getExcludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        ) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                let callbacks = self.queuedCompletions
                self.queuedCompletions.removeAll()

                if let error {
                    TopFadeLogger.shared.error("Window catalog refresh failed", metadata: [
                        "error": error.localizedDescription,
                    ])
                    callbacks.forEach { $0(.failure(error)) }
                    return
                }

                let ownPID = ProcessInfo.processInfo.processIdentifier
                let excludedApplications = Set([
                    "Control Center",
                    "Dock",
                    "Notification Center",
                    "Spotlight",
                    "SystemUIServer",
                    "TopFade",
                    "Window Server",
                ])
                let filtered = (content?.windows ?? [])
                    .compactMap(SourceWindow.init)
                    .filter {
                        $0.processID != ownPID
                            && !excludedApplications.contains($0.applicationName)
                    }
                    .sorted {
                        if $0.applicationName.localizedCaseInsensitiveCompare(
                            $1.applicationName
                        ) == .orderedSame {
                            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                        }
                        return $0.applicationName.localizedCaseInsensitiveCompare(
                            $1.applicationName
                        ) == .orderedAscending
                    }

                self.windows = filtered
                TopFadeLogger.shared.debug("Window catalog refreshed", metadata: [
                    "window_count": String(filtered.count),
                ])
                NotificationCenter.default.post(name: .topFadeCatalogChanged, object: self)
                callbacks.forEach { $0(.success(filtered)) }
            }
        }
    }

    func frontmostWindow(
        completion: @escaping (Result<SourceWindow?, Error>) -> Void
    ) {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        refresh { result in
            completion(result.map { windows in
                guard let frontmostPID else { return nil }
                let candidates = windows.filter { $0.processID == frontmostPID }
                guard candidates.count > 1 else { return candidates.first }

                let candidatesByID = Dictionary(
                    uniqueKeysWithValues: candidates.map { ($0.windowID, $0) }
                )
                for windowID in Self.frontToBackWindowIDs(for: frontmostPID) {
                    if let source = candidatesByID[windowID] {
                        return source
                    }
                }

                TopFadeLogger.shared.warn(
                    "The frontmost app had multiple capturable windows, but Quartz ordering was unavailable; using the first catalog match.",
                    metadata: [
                        "process_id": String(frontmostPID),
                        "candidate_count": String(candidates.count),
                    ]
                )
                return candidates.first
            })
        }
    }

    private static func frontToBackWindowIDs(for processID: pid_t) -> [CGWindowID] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return windowInfo.compactMap { entry in
            guard
                let ownerPID = entry[kCGWindowOwnerPID as String] as? NSNumber,
                ownerPID.int32Value == processID,
                let windowNumber = entry[kCGWindowNumber as String] as? NSNumber
            else {
                return nil
            }
            return CGWindowID(windowNumber.uint32Value)
        }
    }
}

final class SampleBufferView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer = displayLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if #available(macOS 14.0, *) {
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                TopFadeLogger.shared.warn("Video renderer failed; flushing queued frames", metadata: [
                    "error": renderer.error?.localizedDescription ?? "unknown",
                ])
                renderer.flush()
            }
            renderer.enqueue(sampleBuffer)
        } else {
            if displayLayer.status == .failed {
                TopFadeLogger.shared.warn("Display layer failed; flushing queued frames", metadata: [
                    "error": displayLayer.error?.localizedDescription ?? "unknown",
                ])
                displayLayer.flush()
            }
            displayLayer.enqueue(sampleBuffer)
        }
    }

    func clear() {
        if #available(macOS 14.0, *) {
            displayLayer.sampleBufferRenderer.flush()
        } else {
            displayLayer.flushAndRemoveImage()
        }
    }
}

// ScreenCaptureKit invokes output/delegate callbacks from its own queues.
// Mutable stream ownership and queued frames are protected by stateLock and
// frameLock; renderer updates are dispatched to the main queue. The Sendable
// conformance is explicitly unchecked because this class also owns AppKit
// objects that must never be mutated off the main queue.
final class WindowCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let source: SourceWindow
    let displayView: SampleBufferView
    var onUnexpectedStop: ((Error) -> Void)?

    private let preferences: PreferencesStore
    private let outputQueue: DispatchQueue
    private let stateLock = NSLock()
    private let frameLock = NSLock()
    private var stream: SCStream?
    private var startingGeneration: UInt64?
    private var lifecycleGeneration: UInt64 = 0
    private var acceptingFrames = false
    private var pendingSampleBuffer: CMSampleBuffer?
    private var frameDeliveryScheduled = false

    init(
        source: SourceWindow,
        displayView: SampleBufferView,
        preferences: PreferencesStore
    ) {
        self.source = source
        self.displayView = displayView
        self.preferences = preferences
        outputQueue = DispatchQueue(
            label: "com.tavito.topfade.capture.\(source.windowID)",
            qos: .userInitiated
        )
        super.init()
    }

    func start() async throws {
        guard let generation = beginStarting() else { return }

        let filter = SCContentFilter(desktopIndependentWindow: source.captureWindow)
        let configuration = makeConfiguration(filter: filter)
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        } catch {
            clearStartingGeneration(generation)
            throw error
        }

        if !publishStarting(newStream, generation: generation) {
            try? newStream.removeStreamOutput(self, type: .screen)
            throw CancellationError()
        }

        setAcceptingFrames(true)
        guard isCurrent(newStream, generation: generation) else {
            setAcceptingFrames(false)
            try? newStream.removeStreamOutput(self, type: .screen)
            throw CancellationError()
        }
        do {
            try await newStream.startCapture()
            guard isCurrent(newStream, generation: generation) else {
                setAcceptingFrames(false)
                try? await newStream.stopCapture()
                try? newStream.removeStreamOutput(self, type: .screen)
                throw CancellationError()
            }
            TopFadeLogger.shared.info("Window capture started", metadata: [
                "application": source.applicationName,
                "title": source.title,
                "window_id": String(source.windowID),
                "frames_per_second": String(preferences.maxFramesPerSecond),
            ])
        } catch {
            let owned = clearCurrent(newStream, generation: generation)
            setAcceptingFrames(false)
            if owned {
                try? newStream.removeStreamOutput(self, type: .screen)
            }
            throw error
        }
    }

    func reconfigure() async throws {
        guard let (stream, generation) = currentStreamSnapshot() else { return }
        let filter = SCContentFilter(desktopIndependentWindow: source.captureWindow)
        do {
            try await stream.updateConfiguration(makeConfiguration(filter: filter))
        } catch {
            guard isCurrent(stream, generation: generation) else { return }
            throw error
        }
        guard isCurrent(stream, generation: generation) else { return }
        TopFadeLogger.shared.info("Window capture configuration updated", metadata: [
            "window_id": String(source.windowID),
            "frames_per_second": String(preferences.maxFramesPerSecond),
        ])
    }

    func stop() {
        let (stream, stoppedGeneration) = detachCurrentForStop()
        setAcceptingFrames(false)
        guard let stream else {
            DispatchQueue.main.async { [weak self, weak displayView] in
                guard self?.isStoppedGeneration(stoppedGeneration) == true else { return }
                displayView?.clear()
            }
            return
        }
        let displayView = displayView
        let windowID = source.windowID
        Task { [weak self] in
            do {
                try await stream.stopCapture()
            } catch {
                TopFadeLogger.shared.warn("Window capture stop returned an error", metadata: [
                    "error": error.localizedDescription,
                    "window_id": String(windowID),
                ])
            }
            if let self {
                try? stream.removeStreamOutput(self, type: .screen)
            }
            DispatchQueue.main.async { [weak self] in
                guard self?.isStoppedGeneration(stoppedGeneration) == true else { return }
                displayView.clear()
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let frameInfo = attachments.first,
            let rawStatus = frameInfo[.status] as? Int,
            SCFrameStatus(rawValue: rawStatus) == .complete
        else {
            return
        }

        queueLatestFrame(sampleBuffer, from: stream)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard clearCurrentIfOwned(stream) else { return }
        setAcceptingFrames(false)
        try? stream.removeStreamOutput(self, type: .screen)
        TopFadeLogger.shared.error("Window capture stopped unexpectedly", metadata: [
            "application": source.applicationName,
            "title": source.title,
            "window_id": String(source.windowID),
            "error": error.localizedDescription,
        ])
        DispatchQueue.main.async { [weak self] in
            self?.displayView.clear()
            self?.onUnexpectedStop?(error)
        }
    }

    private func queueLatestFrame(_ sampleBuffer: CMSampleBuffer, from candidate: SCStream) {
        // Keep the stream identity check and frame queue mutation atomic.
        // A delayed callback from a stopped capture must not overwrite the
        // first frames of a replacement stream.
        stateLock.lock()
        guard stream === candidate else {
            stateLock.unlock()
            return
        }
        frameLock.lock()
        guard acceptingFrames else {
            frameLock.unlock()
            stateLock.unlock()
            return
        }
        pendingSampleBuffer = sampleBuffer
        guard !frameDeliveryScheduled else {
            frameLock.unlock()
            stateLock.unlock()
            return
        }
        frameDeliveryScheduled = true
        frameLock.unlock()
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.deliverLatestFrame()
        }
    }

    private func deliverLatestFrame() {
        frameLock.lock()
        let sampleBuffer = acceptingFrames ? pendingSampleBuffer : nil
        pendingSampleBuffer = nil
        frameDeliveryScheduled = false
        frameLock.unlock()

        if let sampleBuffer {
            displayView.enqueue(sampleBuffer)
        }
    }

    private func setAcceptingFrames(_ accepting: Bool) {
        frameLock.lock()
        acceptingFrames = accepting
        if !accepting {
            pendingSampleBuffer = nil
        }
        frameLock.unlock()
    }

    private func clearStartingGeneration(_ generation: UInt64) {
        stateLock.lock()
        if startingGeneration == generation {
            startingGeneration = nil
        }
        stateLock.unlock()
    }

    private func beginStarting() -> UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard stream == nil, startingGeneration == nil else { return nil }
        lifecycleGeneration &+= 1
        startingGeneration = lifecycleGeneration
        return lifecycleGeneration
    }

    private func publishStarting(_ candidate: SCStream, generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard lifecycleGeneration == generation, startingGeneration == generation else {
            return false
        }
        stream = candidate
        startingGeneration = nil
        return true
    }

    private func currentStreamSnapshot() -> (SCStream, UInt64)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let stream else { return nil }
        return (stream, lifecycleGeneration)
    }

    private func detachCurrentForStop() -> (SCStream?, UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        lifecycleGeneration &+= 1
        startingGeneration = nil
        let detached = stream
        stream = nil
        return (detached, lifecycleGeneration)
    }

    private func isStoppedGeneration(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lifecycleGeneration == generation
            && stream == nil
            && startingGeneration == nil
    }

    private func clearCurrentIfOwned(_ candidate: SCStream) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard stream === candidate else { return false }
        stream = nil
        lifecycleGeneration &+= 1
        startingGeneration = nil
        return true
    }

    private func isCurrent(_ candidate: SCStream, generation: UInt64) -> Bool {
        stateLock.lock()
        let current = lifecycleGeneration == generation && stream === candidate
        stateLock.unlock()
        return current
    }

    @discardableResult
    private func clearCurrent(_ candidate: SCStream, generation: UInt64) -> Bool {
        stateLock.lock()
        let owned = lifecycleGeneration == generation && stream === candidate
        if owned {
            stream = nil
            lifecycleGeneration &+= 1
        }
        if startingGeneration == generation {
            startingGeneration = nil
        }
        stateLock.unlock()
        return owned
    }

    private func makeConfiguration(filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale: CGFloat
        if #available(macOS 14.0, *) {
            scale = CGFloat(filter.pointPixelScale)
        } else {
            scale = displayScale(for: source.frame)
        }
        configuration.width = max(1, Int(source.frame.width * scale))
        configuration.height = max(1, Int(source.frame.height * scale))
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(preferences.maxFramesPerSecond)
        )
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = preferences.showCursor
        configuration.scalesToFit = true
        configuration.capturesAudio = false
        return configuration
    }
}

final class ReplicaPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ReplicaController: NSObject, NSWindowDelegate {
    let source: SourceWindow
    let panel: ReplicaPanel
    let captureSession: WindowCaptureSession
    private let rememberedID: UUID
    private(set) var opacityPercent: Int
    private(set) var clickThrough: Bool
    private let preferences: PreferencesStore
    var onStateChanged: ((ReplicaController) -> Void)?
    var onUnexpectedStop: ((ReplicaController, Error) -> Void)?

    init(
        source: SourceWindow,
        remembered: RememberedReplica?,
        preferences: PreferencesStore
    ) {
        self.source = source
        self.preferences = preferences
        rememberedID = remembered?.id ?? UUID()
        let initialFrame = Self.initialFrame(source: source, remembered: remembered)
        let displayView = SampleBufferView(frame: NSRect(origin: .zero, size: initialFrame.size))
        captureSession = WindowCaptureSession(
            source: source,
            displayView: displayView,
            preferences: preferences
        )
        panel = ReplicaPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        opacityPercent = (remembered?.opacityPercent ?? 100).clamped(to: 10 ... 100)
        clickThrough = remembered?.clickThrough ?? preferences.defaultClickThrough
        super.init()

        panel.title = "TopFade replica - \(source.displayName)"
        panel.identifier = NSUserInterfaceItemIdentifier("topfade-replica-\(source.windowID)")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = displayView
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 160, height: 90)
        panel.alphaValue = CGFloat(opacityPercent) / 100.0
        panel.ignoresMouseEvents = clickThrough
        panel.delegate = self

        captureSession.onUnexpectedStop = { [weak self] error in
            guard let self else { return }
            self.onUnexpectedStop?(self, error)
        }
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                try await captureSession.start()
                DispatchQueue.main.async {
                    completion(.success(Void()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func stop() {
        captureSession.stop()
        panel.orderOut(nil)
    }

    func setOpacity(_ percent: Int) {
        let minimum = preferences.minimumOpacity
        let clamped = percent.clamped(to: minimum ... 100)
        guard clamped != opacityPercent else { return }
        opacityPercent = clamped
        panel.alphaValue = CGFloat(clamped) / 100.0
        onStateChanged?(self)
    }

    func setClickThrough(_ enabled: Bool) {
        guard enabled != clickThrough else { return }
        clickThrough = enabled
        panel.ignoresMouseEvents = enabled
        onStateChanged?(self)
    }

    func reconfigureCapture() {
        Task {
            do {
                try await captureSession.reconfigure()
            } catch {
                TopFadeLogger.shared.error("Active capture could not be reconfigured", metadata: [
                    "application": source.applicationName,
                    "title": source.title,
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    func rememberedState() -> RememberedReplica {
        let frame = panel.frame
        return RememberedReplica(
            id: rememberedID,
            bundleIdentifier: source.bundleIdentifier,
            applicationName: source.applicationName,
            titleHint: source.title,
            opacityPercent: opacityPercent,
            clickThrough: clickThrough,
            frameX: frame.origin.x,
            frameY: frame.origin.y,
            frameWidth: frame.width,
            frameHeight: frame.height,
            sourceFrameX: source.frame.origin.x,
            sourceFrameY: source.frame.origin.y,
            sourceFrameWidth: source.frame.width,
            sourceFrameHeight: source.frame.height
        )
    }

    func diagnosticSnapshot() -> [String: Any] {
        [
            "application": source.applicationName,
            "bundle_identifier": source.bundleIdentifier,
            "title": source.title,
            "process_id": source.processID,
            "window_id": source.windowID,
            "opacity_percent": opacityPercent,
            "click_through": clickThrough,
            "panel_frame": NSStringFromRect(panel.frame),
        ]
    }

    func windowDidMove(_ notification: Notification) {
        onStateChanged?(self)
    }

    func windowDidResize(_ notification: Notification) {
        onStateChanged?(self)
    }

    private static func initialFrame(
        source: SourceWindow,
        remembered: RememberedReplica?
    ) -> NSRect {
        if let remembered,
           remembered.frameWidth >= 160,
           remembered.frameHeight >= 90 {
            let saved = NSRect(
                x: remembered.frameX,
                y: remembered.frameY,
                width: remembered.frameWidth,
                height: remembered.frameHeight
            )
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(saved) }) {
                return clamp(saved, to: screen.visibleFrame)
            }
        }
        return appKitFrame(fromQuartzFrame: source.frame)
    }
}

private struct RestorationRequest {
    var preferredProcessID: pid_t?
    var ignoringPreference: Bool
}

final class ReplicaManager {
    let catalog: WindowCatalog
    private(set) var replicas: [CGWindowID: ReplicaController] = [:]
    private let preferences: PreferencesStore
    private var restorationInFlight = false
    private var pendingRestorationRequest: RestorationRequest?
    private var pendingRememberWorkItems: [CGWindowID: DispatchWorkItem] = [:]
    private var pendingRememberTokens: [CGWindowID: UUID] = [:]

    var onError: ((String) -> Void)?
    var onOpacityChanged: ((ReplicaController) -> Void)?

    init(
        catalog: WindowCatalog,
        preferences: PreferencesStore = .shared
    ) {
        self.catalog = catalog
        self.preferences = preferences
    }

    var activeReplicas: [ReplicaController] {
        replicas.values.sorted {
            $0.source.applicationName.localizedCaseInsensitiveCompare(
                $1.source.applicationName
            ) == .orderedAscending
        }
    }

    func toggleFrontmostWindow() {
        catalog.frontmostWindow { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(source?):
                if self.replicas[source.windowID] != nil {
                    self.unpin(source.windowID, forget: true)
                } else {
                    self.pin(source)
                }
            case .success(nil):
                self.reportError(
                    "No capturable frontmost window was found. Open a normal application window and try again."
                )
            case let .failure(error):
                self.reportError("Window lookup failed: \(error.localizedDescription)")
            }
        }
    }

    func toggle(_ source: SourceWindow) {
        if replicas[source.windowID] != nil {
            unpin(source.windowID, forget: true)
        } else {
            pin(source)
        }
    }

    func pin(_ source: SourceWindow, remembered: RememberedReplica? = nil) {
        guard replicas[source.windowID] == nil else {
            return
        }
        guard PermissionStatus.screenRecordingGranted else {
            let granted = PermissionStatus.requestScreenRecording()
            let message = granted
                ? "Screen Recording access was granted. If capture does not start, restart TopFade once."
                : "TopFade needs Screen Recording permission to create a safe live window replica."
            reportError(message)
            return
        }

        let controller = ReplicaController(
            source: source,
            remembered: remembered,
            preferences: preferences
        )
        controller.onStateChanged = { [weak self] controller in
            self?.scheduleRemember(controller)
        }
        controller.onUnexpectedStop = { [weak self] controller, error in
            self?.handleUnexpectedStop(controller, error: error)
        }
        replicas[source.windowID] = controller

        controller.start { [weak self, weak controller] result in
            guard let self, let controller else { return }
            guard let active = self.replicas[source.windowID], active === controller else {
                controller.stop()
                return
            }
            switch result {
            case .success:
                controller.panel.orderFrontRegardless()
                self.cancelScheduledRemember(for: source.windowID)
                self.rememberImmediately(controller)
                TopFadeLogger.shared.info("Window pinned with a live replica", metadata: [
                    "application": source.applicationName,
                    "title": source.title,
                    "window_id": String(source.windowID),
                ])
                NotificationCenter.default.post(name: .topFadeReplicasChanged, object: self)
            case let .failure(error):
                self.cancelScheduledRemember(for: source.windowID)
                self.replicas.removeValue(forKey: source.windowID)
                controller.stop()
                self.reportError("Capture could not start for \(source.displayName): \(error.localizedDescription)")
            }
        }
    }

    func unpin(_ windowID: CGWindowID, forget: Bool) {
        guard let controller = replicas.removeValue(forKey: windowID) else { return }
        cancelScheduledRemember(for: windowID)
        if !forget {
            rememberImmediately(controller)
        }
        controller.stop()
        if forget {
            removeRemembered(controller.rememberedState())
        }
        TopFadeLogger.shared.info("Window replica unpinned", metadata: [
            "application": controller.source.applicationName,
            "title": controller.source.title,
            "window_id": String(windowID),
            "forgotten": String(forget),
        ])
        NotificationCenter.default.post(name: .topFadeReplicasChanged, object: self)
    }

    func unpinAll(forget: Bool) {
        for id in Array(replicas.keys) {
            unpin(id, forget: forget)
        }
    }

    func unpinReplicas(forProcessID processID: pid_t) {
        // Release capture streams when their source app exits, while keeping
        // remembered settings available when that app is reopened.
        let windowIDs = replicas.values
            .filter { $0.source.processID == processID }
            .map { $0.source.windowID }
        for windowID in windowIDs {
            unpin(windowID, forget: false)
        }
    }

    @discardableResult
    func adjustOpacity(direction: Int, mouseLocation: NSPoint) -> Bool {
        guard let target = opacityTarget(at: mouseLocation) else { return false }
        let delta = direction >= 0 ? preferences.opacityStep : -preferences.opacityStep
        target.setOpacity(target.opacityPercent + delta)
        onOpacityChanged?(target)
        TopFadeLogger.shared.debug("Replica opacity changed", metadata: [
            "application": target.source.applicationName,
            "title": target.source.title,
            "opacity_percent": String(target.opacityPercent),
        ])
        return true
    }

    func setOpacity(windowID: CGWindowID, percent: Int) {
        guard let target = replicas[windowID] else { return }
        target.setOpacity(percent)
        onOpacityChanged?(target)
        NotificationCenter.default.post(name: .topFadeReplicasChanged, object: self)
    }

    func canAdjustOpacity(at mouseLocation: NSPoint) -> Bool {
        opacityTarget(at: mouseLocation) != nil
    }

    func toggleClickThrough(windowID: CGWindowID) {
        guard let target = replicas[windowID] else { return }
        target.setClickThrough(!target.clickThrough)
        NotificationCenter.default.post(name: .topFadeReplicasChanged, object: self)
    }

    func reconfigureActiveCaptures() {
        activeReplicas.forEach { $0.reconfigureCapture() }
    }

    func restoreRemembered(
        preferredProcessID: pid_t? = nil,
        ignoringPreference: Bool = false
    ) {
        guard preferences.restoreRemembered || ignoringPreference else { return }
        if restorationInFlight {
            queueRestoration(
                preferredProcessID: preferredProcessID,
                ignoringPreference: ignoringPreference
            )
            return
        }
        guard !preferences.rememberedReplicas.isEmpty else { return }
        restorationInFlight = true

        catalog.refresh { [weak self] result in
            guard let self else { return }
            self.restorationInFlight = false
            defer { self.runPendingRestoration() }
            guard self.preferences.restoreRemembered || ignoringPreference else { return }
            let remembered = self.preferences.rememberedReplicas
            guard !remembered.isEmpty else { return }
            switch result {
            case let .failure(error):
                TopFadeLogger.shared.warn("Remembered replica scan failed", metadata: [
                    "error": error.localizedDescription,
                ])
            case let .success(windows):
                var claimedIDs = Set(self.replicas.keys)
                for record in remembered {
                    let candidates = windows.filter {
                        !claimedIDs.contains($0.windowID)
                            && $0.bundleIdentifier == record.bundleIdentifier
                            && (preferredProcessID == nil || $0.processID == preferredProcessID)
                    }
                    guard let source = self.bestMatch(for: record, candidates: candidates) else {
                        continue
                    }
                    claimedIDs.insert(source.windowID)
                    self.pin(source, remembered: record)
                }
            }
        }
    }

    func diagnosticSnapshots() -> [[String: Any]] {
        activeReplicas.map { $0.diagnosticSnapshot() }
    }

    func hasRememberedReplica(forBundleIdentifier bundleIdentifier: String) -> Bool {
        preferences.restoreRemembered && preferences.rememberedReplicas.contains {
            $0.bundleIdentifier == bundleIdentifier
        }
    }

    private func opacityTarget(at point: NSPoint) -> ReplicaController? {
        for window in NSApp.orderedWindows where window.isVisible && window.frame.contains(point) {
            if let controller = replicas.values.first(where: { $0.panel === window }) {
                return controller
            }
        }
        return nil
    }

    private func scheduleRemember(_ controller: ReplicaController) {
        let windowID = controller.source.windowID
        guard replicas[windowID] === controller else { return }

        pendingRememberWorkItems[windowID]?.cancel()
        let token = UUID()
        pendingRememberTokens[windowID] = token
        let workItem = DispatchWorkItem { [weak self, weak controller] in
            guard
                let self,
                let controller,
                self.pendingRememberTokens[windowID] == token,
                self.replicas[windowID] === controller
            else {
                return
            }
            self.pendingRememberTokens.removeValue(forKey: windowID)
            self.pendingRememberWorkItems.removeValue(forKey: windowID)
            self.rememberImmediately(controller)
        }
        pendingRememberWorkItems[windowID] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(350),
            execute: workItem
        )
    }

    private func cancelScheduledRemember(for windowID: CGWindowID) {
        pendingRememberWorkItems.removeValue(forKey: windowID)?.cancel()
        pendingRememberTokens.removeValue(forKey: windowID)
    }

    private func rememberImmediately(_ controller: ReplicaController) {
        let state = controller.rememberedState()
        var remembered = preferences.rememberedReplicas
        if let index = remembered.firstIndex(where: { $0.id == state.id }) {
            guard remembered[index] != state else { return }
            remembered[index] = state
        } else {
            remembered.append(state)
        }
        preferences.rememberedReplicas = remembered
    }

    private func removeRemembered(_ state: RememberedReplica) {
        var remembered = preferences.rememberedReplicas
        let previousCount = remembered.count
        remembered.removeAll { $0.id == state.id }
        if remembered.count != previousCount {
            preferences.rememberedReplicas = remembered
        }
    }

    private func queueRestoration(
        preferredProcessID: pid_t?,
        ignoringPreference: Bool
    ) {
        if var pending = pendingRestorationRequest {
            if pending.preferredProcessID != preferredProcessID {
                pending.preferredProcessID = nil
            }
            pending.ignoringPreference = pending.ignoringPreference || ignoringPreference
            pendingRestorationRequest = pending
        } else {
            pendingRestorationRequest = RestorationRequest(
                preferredProcessID: preferredProcessID,
                ignoringPreference: ignoringPreference
            )
        }
    }

    private func runPendingRestoration() {
        guard let request = pendingRestorationRequest else { return }
        pendingRestorationRequest = nil
        DispatchQueue.main.async { [weak self] in
            self?.restoreRemembered(
                preferredProcessID: request.preferredProcessID,
                ignoringPreference: request.ignoringPreference
            )
        }
    }

    private func bestMatch(
        for record: RememberedReplica,
        candidates: [SourceWindow]
    ) -> SourceWindow? {
        let exact = candidates.filter {
            $0.title.caseInsensitiveCompare(record.titleHint) == .orderedSame
        }
        if let match = bestGeometricMatch(for: record, candidates: exact) {
            return match
        }
        let partial = candidates.filter {
            $0.title.localizedCaseInsensitiveContains(record.titleHint)
                || record.titleHint.localizedCaseInsensitiveContains($0.title)
        }
        if let match = bestGeometricMatch(for: record, candidates: partial) {
            return match
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func bestGeometricMatch(
        for record: RememberedReplica,
        candidates: [SourceWindow]
    ) -> SourceWindow? {
        guard !candidates.isEmpty else { return nil }
        guard candidates.count > 1 else { return candidates[0] }
        guard let rememberedFrame = record.sourceFrame else { return nil }
        return candidates.min { first, second in
            let firstDistance = frameDistance(first.frame, rememberedFrame)
            let secondDistance = frameDistance(second.frame, rememberedFrame)
            if firstDistance == secondDistance {
                return first.windowID < second.windowID
            }
            return firstDistance < secondDistance
        }
    }

    private func handleUnexpectedStop(_ controller: ReplicaController, error: Error) {
        guard replicas.removeValue(forKey: controller.source.windowID) != nil else { return }
        cancelScheduledRemember(for: controller.source.windowID)
        rememberImmediately(controller)
        controller.stop()
        let message = "Capture stopped for \(controller.source.displayName). TopFade kept it remembered and will retry when the app is activated."
        reportError("\(message) \(error.localizedDescription)")
        NotificationCenter.default.post(name: .topFadeReplicasChanged, object: self)
    }

    private func reportError(_ message: String) {
        TopFadeLogger.shared.error(message)
        onError?(message)
        NotificationCenter.default.post(
            name: .topFadeReplicaError,
            object: self,
            userInfo: ["message": message]
        )
    }
}

private func displayScale(for quartzFrame: CGRect) -> CGFloat {
    let midpoint = CGPoint(x: quartzFrame.midX, y: quartzFrame.midY)
    for screen in NSScreen.screens {
        guard
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        else {
            continue
        }
        if CGDisplayBounds(CGDirectDisplayID(number.uint32Value)).contains(midpoint) {
            return screen.backingScaleFactor
        }
    }
    return NSScreen.main?.backingScaleFactor ?? 2
}

private func appKitFrame(fromQuartzFrame frame: CGRect) -> NSRect {
    let midpoint = CGPoint(x: frame.midX, y: frame.midY)
    for screen in NSScreen.screens {
        guard
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        else {
            continue
        }
        let quartzBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        guard quartzBounds.contains(midpoint) else { continue }

        let localX = frame.minX - quartzBounds.minX
        let localTop = frame.minY - quartzBounds.minY
        let converted = NSRect(
            x: screen.frame.minX + localX,
            y: screen.frame.maxY - localTop - frame.height,
            width: frame.width,
            height: frame.height
        )
        return clamp(converted, to: screen.visibleFrame)
    }

    let fallback = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
    return NSRect(
        x: fallback.midX - min(frame.width, fallback.width) / 2,
        y: fallback.midY - min(frame.height, fallback.height) / 2,
        width: min(frame.width, fallback.width),
        height: min(frame.height, fallback.height)
    )
}

private func clamp(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
    var result = frame
    result.size.width = min(max(result.width, 160), visibleFrame.width)
    result.size.height = min(max(result.height, 90), visibleFrame.height)
    result.origin.x = min(
        max(result.origin.x, visibleFrame.minX),
        visibleFrame.maxX - result.width
    )
    result.origin.y = min(
        max(result.origin.y, visibleFrame.minY),
        visibleFrame.maxY - result.height
    )
    return result
}

private func frameDistance(_ first: CGRect, _ second: CGRect) -> CGFloat {
    let referenceScale = max(second.width, second.height, 1)
    let centerDistance = hypot(first.midX - second.midX, first.midY - second.midY)
        / referenceScale
    let sizeDistance = (
        abs(first.width - second.width)
            + abs(first.height - second.height)
    ) / referenceScale
    return centerDistance + sizeDistance * 0.5
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
