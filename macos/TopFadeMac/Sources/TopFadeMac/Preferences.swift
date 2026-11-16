import Foundation
import ServiceManagement

struct RememberedReplica: Codable, Equatable {
    var id: UUID
    var bundleIdentifier: String
    var applicationName: String
    var titleHint: String
    var opacityPercent: Int
    var clickThrough: Bool
    var frameX: Double
    var frameY: Double
    var frameWidth: Double
    var frameHeight: Double

    var sourceFrameX: Double?
    var sourceFrameY: Double?
    var sourceFrameWidth: Double?
    var sourceFrameHeight: Double?

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        applicationName: String,
        titleHint: String,
        opacityPercent: Int,
        clickThrough: Bool,
        frameX: Double,
        frameY: Double,
        frameWidth: Double,
        frameHeight: Double,
        sourceFrameX: Double? = nil,
        sourceFrameY: Double? = nil,
        sourceFrameWidth: Double? = nil,
        sourceFrameHeight: Double? = nil
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.titleHint = titleHint
        self.opacityPercent = opacityPercent
        self.clickThrough = clickThrough
        self.frameX = frameX
        self.frameY = frameY
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.sourceFrameX = sourceFrameX
        self.sourceFrameY = sourceFrameY
        self.sourceFrameWidth = sourceFrameWidth
        self.sourceFrameHeight = sourceFrameHeight
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case bundleIdentifier
        case applicationName
        case titleHint
        case opacityPercent
        case clickThrough
        case frameX
        case frameY
        case frameWidth
        case frameHeight
        case sourceFrameX
        case sourceFrameY
        case sourceFrameWidth
        case sourceFrameHeight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        applicationName = try container.decode(String.self, forKey: .applicationName)
        titleHint = try container.decode(String.self, forKey: .titleHint)
        opacityPercent = try container.decode(Int.self, forKey: .opacityPercent)
        clickThrough = try container.decode(Bool.self, forKey: .clickThrough)
        frameX = try container.decode(Double.self, forKey: .frameX)
        frameY = try container.decode(Double.self, forKey: .frameY)
        frameWidth = try container.decode(Double.self, forKey: .frameWidth)
        frameHeight = try container.decode(Double.self, forKey: .frameHeight)
        sourceFrameX = try container.decodeIfPresent(Double.self, forKey: .sourceFrameX)
        sourceFrameY = try container.decodeIfPresent(Double.self, forKey: .sourceFrameY)
        sourceFrameWidth = try container.decodeIfPresent(Double.self, forKey: .sourceFrameWidth)
        sourceFrameHeight = try container.decodeIfPresent(Double.self, forKey: .sourceFrameHeight)
    }

    var sourceFrame: CGRect? {
        guard
            let sourceFrameX,
            let sourceFrameY,
            let sourceFrameWidth,
            let sourceFrameHeight,
            sourceFrameWidth > 0,
            sourceFrameHeight > 0
        else {
            return nil
        }
        return CGRect(
            x: sourceFrameX,
            y: sourceFrameY,
            width: sourceFrameWidth,
            height: sourceFrameHeight
        )
    }
}

final class PreferencesStore {
    static let shared = PreferencesStore()

    struct BehaviorDefaults {
        let minimumOpacity = 20
        let opacityStep = 5
        let overlayDuration: TimeInterval = 1.25
        let showOverlay = true
        let consumeModifiedScroll = true
        let showCursor = false
        let maxFramesPerSecond = 30
        let restoreRemembered = true
        let defaultClickThrough = false
        let startHidden = false
        let logLevel = "info"
        let logRetentionDays = 14
        let maxLogMegabytes = 20
    }

    static let behaviorDefaults = BehaviorDefaults()

    enum Key {
        static let minimumOpacity = "minimumOpacity"
        static let opacityStep = "opacityStep"
        static let overlayDuration = "overlayDuration"
        static let showOverlay = "showOverlay"
        static let consumeModifiedScroll = "consumeModifiedScroll"
        static let showCursor = "showCursor"
        static let maxFramesPerSecond = "maxFramesPerSecond"
        static let restoreRemembered = "restoreRemembered"
        static let defaultClickThrough = "defaultClickThrough"
        static let startHidden = "startHidden"
        static let logLevel = "logLevel"
        static let logRetentionDays = "logRetentionDays"
        static let maxLogMegabytes = "maxLogMegabytes"
        static let rememberedReplicas = "rememberedReplicas"
        static let completedOnboarding = "completedOnboarding"
    }

    private let defaults: UserDefaults
    private var rememberedReplicaCache: [RememberedReplica]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let behavior = Self.behaviorDefaults
        defaults.register(defaults: [
            Key.minimumOpacity: behavior.minimumOpacity,
            Key.opacityStep: behavior.opacityStep,
            Key.overlayDuration: behavior.overlayDuration,
            Key.showOverlay: behavior.showOverlay,
            Key.consumeModifiedScroll: behavior.consumeModifiedScroll,
            Key.showCursor: behavior.showCursor,
            Key.maxFramesPerSecond: behavior.maxFramesPerSecond,
            Key.restoreRemembered: behavior.restoreRemembered,
            Key.defaultClickThrough: behavior.defaultClickThrough,
            Key.startHidden: behavior.startHidden,
            Key.logLevel: behavior.logLevel,
            Key.logRetentionDays: behavior.logRetentionDays,
            Key.maxLogMegabytes: behavior.maxLogMegabytes,
            Key.completedOnboarding: false,
        ])
        sanitize()
    }

    var minimumOpacity: Int {
        get { defaults.integer(forKey: Key.minimumOpacity).clamped(to: 10 ... 95) }
        set { defaults.set(newValue.clamped(to: 10 ... 95), forKey: Key.minimumOpacity) }
    }

    var opacityStep: Int {
        get { defaults.integer(forKey: Key.opacityStep).clamped(to: 1 ... 25) }
        set { defaults.set(newValue.clamped(to: 1 ... 25), forKey: Key.opacityStep) }
    }

    var overlayDuration: TimeInterval {
        get { defaults.double(forKey: Key.overlayDuration).clamped(to: 0.3 ... 5.0) }
        set { defaults.set(newValue.clamped(to: 0.3 ... 5.0), forKey: Key.overlayDuration) }
    }

    var showOverlay: Bool {
        get { defaults.bool(forKey: Key.showOverlay) }
        set { defaults.set(newValue, forKey: Key.showOverlay) }
    }

    var consumeModifiedScroll: Bool {
        get { defaults.bool(forKey: Key.consumeModifiedScroll) }
        set { defaults.set(newValue, forKey: Key.consumeModifiedScroll) }
    }

    var showCursor: Bool {
        get { defaults.bool(forKey: Key.showCursor) }
        set { defaults.set(newValue, forKey: Key.showCursor) }
    }

    var maxFramesPerSecond: Int {
        get {
            let value = defaults.integer(forKey: Key.maxFramesPerSecond)
            return [15, 30, 60].contains(value) ? value : 30
        }
        set { defaults.set([15, 30, 60].contains(newValue) ? newValue : 30, forKey: Key.maxFramesPerSecond) }
    }

    var restoreRemembered: Bool {
        get { defaults.bool(forKey: Key.restoreRemembered) }
        set { defaults.set(newValue, forKey: Key.restoreRemembered) }
    }

    var defaultClickThrough: Bool {
        get { defaults.bool(forKey: Key.defaultClickThrough) }
        set { defaults.set(newValue, forKey: Key.defaultClickThrough) }
    }

    var startHidden: Bool {
        get { defaults.bool(forKey: Key.startHidden) }
        set { defaults.set(newValue, forKey: Key.startHidden) }
    }

    var logLevel: String {
        get {
            let value = defaults.string(forKey: Key.logLevel)?.lowercased() ?? "info"
            return ["debug", "info", "warn", "error"].contains(value) ? value : "info"
        }
        set {
            let value = newValue.lowercased()
            defaults.set(["debug", "info", "warn", "error"].contains(value) ? value : "info", forKey: Key.logLevel)
        }
    }

    var logRetentionDays: Int {
        get { defaults.integer(forKey: Key.logRetentionDays).clamped(to: 1 ... 90) }
        set { defaults.set(newValue.clamped(to: 1 ... 90), forKey: Key.logRetentionDays) }
    }

    var maxLogMegabytes: Int {
        get { defaults.integer(forKey: Key.maxLogMegabytes).clamped(to: 2 ... 250) }
        set { defaults.set(newValue.clamped(to: 2 ... 250), forKey: Key.maxLogMegabytes) }
    }

    var rememberedReplicas: [RememberedReplica] {
        get {
            if let rememberedReplicaCache {
                return rememberedReplicaCache
            }
            guard let data = defaults.data(forKey: Key.rememberedReplicas) else {
                rememberedReplicaCache = []
                return []
            }
            do {
                let decoded = try JSONDecoder().decode([RememberedReplica].self, from: data)
                if Self.rememberedReplicaDataNeedsIdentityMigration(data) {
                    let migrated = try JSONEncoder().encode(decoded)
                    defaults.set(migrated, forKey: Key.rememberedReplicas)
                    TopFadeLogger.shared.info("Remembered replica identities were migrated")
                }
                rememberedReplicaCache = decoded
                return decoded
            } catch {
                TopFadeLogger.shared.error("Remembered replica state could not be decoded", metadata: [
                    "error": error.localizedDescription,
                ])
                preserveInvalidState(data)
                defaults.removeObject(forKey: Key.rememberedReplicas)
                rememberedReplicaCache = []
                return []
            }
        }
        set {
            guard rememberedReplicaCache != newValue else { return }
            do {
                let encoded = try JSONEncoder().encode(newValue)
                defaults.set(encoded, forKey: Key.rememberedReplicas)
                rememberedReplicaCache = newValue
            } catch {
                TopFadeLogger.shared.error("Remembered replica state could not be encoded", metadata: [
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    var completedOnboarding: Bool {
        get { defaults.bool(forKey: Key.completedOnboarding) }
        set { defaults.set(newValue, forKey: Key.completedOnboarding) }
    }

    var launchAtLoginRequested: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            true
        case .notRegistered, .notFound:
            false
        @unknown default:
            false
        }
    }

    var launchAtLoginNeedsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        try Self.setLaunchAtLoginRegistration(enabled)
    }

    static func setLaunchAtLoginRegistration(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            switch service.status {
            case .enabled, .requiresApproval:
                return
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                try service.register()
            }
        } else {
            switch service.status {
            case .notRegistered, .notFound:
                return
            case .enabled, .requiresApproval:
                try service.unregister()
            @unknown default:
                try service.unregister()
            }
        }
    }

    func resetBehaviorDefaultsPreservingRememberedWindows() {
        let remembered = rememberedReplicas
        let behavior = Self.behaviorDefaults
        for key in [
            Key.minimumOpacity,
            Key.opacityStep,
            Key.overlayDuration,
            Key.showOverlay,
            Key.consumeModifiedScroll,
            Key.showCursor,
            Key.maxFramesPerSecond,
            Key.restoreRemembered,
            Key.defaultClickThrough,
            Key.startHidden,
            Key.logLevel,
            Key.logRetentionDays,
            Key.maxLogMegabytes,
        ] {
            defaults.removeObject(forKey: key)
        }
        defaults.register(defaults: [
            Key.minimumOpacity: behavior.minimumOpacity,
            Key.opacityStep: behavior.opacityStep,
            Key.overlayDuration: behavior.overlayDuration,
            Key.showOverlay: behavior.showOverlay,
            Key.consumeModifiedScroll: behavior.consumeModifiedScroll,
            Key.showCursor: behavior.showCursor,
            Key.maxFramesPerSecond: behavior.maxFramesPerSecond,
            Key.restoreRemembered: behavior.restoreRemembered,
            Key.defaultClickThrough: behavior.defaultClickThrough,
            Key.startHidden: behavior.startHidden,
            Key.logLevel: behavior.logLevel,
            Key.logRetentionDays: behavior.logRetentionDays,
            Key.maxLogMegabytes: behavior.maxLogMegabytes,
        ])
        rememberedReplicas = remembered
        sanitize()
    }

    func diagnosticSnapshot() -> [String: Any] {
        [
            "minimum_opacity": minimumOpacity,
            "opacity_step": opacityStep,
            "overlay_duration_seconds": overlayDuration,
            "show_overlay": showOverlay,
            "consume_modified_scroll": consumeModifiedScroll,
            "show_cursor": showCursor,
            "max_frames_per_second": maxFramesPerSecond,
            "restore_remembered": restoreRemembered,
            "default_click_through": defaultClickThrough,
            "start_hidden": startHidden,
            "log_level": logLevel,
            "log_retention_days": logRetentionDays,
            "max_log_megabytes": maxLogMegabytes,
            "remembered_replica_count": rememberedReplicas.count,
            "launch_at_login_status": String(describing: SMAppService.mainApp.status),
        ]
    }

    private func sanitize() {
        minimumOpacity = minimumOpacity
        opacityStep = opacityStep
        overlayDuration = overlayDuration
        maxFramesPerSecond = maxFramesPerSecond
        logLevel = logLevel
        logRetentionDays = logRetentionDays
        maxLogMegabytes = maxLogMegabytes
    }

    private func preserveInvalidState(_ data: Data) {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("TopFade", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true
            )
            try data.write(
                to: supportDirectory.appendingPathComponent("remembered-replicas.invalid.json"),
                options: .atomic
            )
        } catch {
            TopFadeLogger.shared.error("Invalid replica state backup failed", metadata: [
                "error": error.localizedDescription,
            ])
        }
    }

    private static func rememberedReplicaDataNeedsIdentityMigration(_ data: Data) -> Bool {
        guard let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return false
        }
        return records.contains { $0["id"] == nil }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
