import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func parse(_ value: String) -> LogLevel {
        switch value.lowercased() {
        case "debug": .debug
        case "warn": .warn
        case "error": .error
        default: .info
        }
    }
}

final class TopFadeLogger {
    static let shared = TopFadeLogger()

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let timestampFormatter = ISO8601DateFormatter()
    private let dayFormatter: DateFormatter
    private var fileHandle: FileHandle?
    private var currentLogURL: URL?
    private var preferences: PreferencesStore?
    private var initialized = false

    let logDirectory: URL
    let reportDirectory: URL

    private init() {
        dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let environment = ProcessInfo.processInfo.environment
        let selfTestRoot: URL?
        if CommandLine.arguments.contains("--self-test") {
            selfTestRoot = environment["TOPFADE_SELF_TEST_ROOT"].map {
                URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
            } ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "TopFade-SelfTest-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        } else {
            selfTestRoot = nil
        }
        logDirectory = selfTestRoot?.appendingPathComponent("Logs", isDirectory: true)
            ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/TopFade", isDirectory: true)
        reportDirectory = selfTestRoot?.appendingPathComponent("Reports", isDirectory: true)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TopFade/Reports", isDirectory: true)
    }

    func start(preferences: PreferencesStore) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !initialized else { return }

        self.preferences = preferences
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        try openCurrentLogLocked()
        try rotateIfNeededLocked()
        cleanupLocked()
        initialized = true
        writeLocked(level: .info, message: "TopFade logging started", metadata: [
            "log_directory": logDirectory.path,
            "process_id": String(ProcessInfo.processInfo.processIdentifier),
        ])
    }

    func debug(_ message: String, metadata: [String: String] = [:]) {
        write(level: .debug, message: message, metadata: metadata)
    }

    func info(_ message: String, metadata: [String: String] = [:]) {
        write(level: .info, message: message, metadata: metadata)
    }

    func warn(_ message: String, metadata: [String: String] = [:]) {
        write(level: .warn, message: message, metadata: metadata)
    }

    func error(_ message: String, metadata: [String: String] = [:]) {
        write(level: .error, message: message, metadata: metadata)
    }

    func cleanup() {
        lock.lock()
        defer { lock.unlock() }
        cleanupLocked()
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        try? fileHandle?.synchronize()
    }

    func recentLogFiles() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? fileManager.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return left > right
            }
            .prefix(20)
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return [
                    "name": url.lastPathComponent,
                    "bytes": values?.fileSize ?? 0,
                    "modified": values?.contentModificationDate.map(timestampFormatter.string(from:)) ?? "",
                ]
            }
    }

    private func write(level: LogLevel, message: String, metadata: [String: String]) {
        guard level >= LogLevel.parse(preferences?.logLevel ?? "info") else { return }
        lock.lock()
        defer { lock.unlock() }
        if !initialized {
            fputs("[TopFade] \(level) \(message)\n", stderr)
            return
        }
        do {
            try rotateIfNeededLocked()
            writeLocked(level: level, message: message, metadata: metadata)
        } catch {
            fputs("[TopFade] log write failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func writeLocked(level: LogLevel, message: String, metadata: [String: String]) {
        var payload: [String: Any] = [
            "timestamp": timestampFormatter.string(from: Date()),
            "level": String(describing: level),
            "message": message,
            "thread": Thread.isMainThread ? "main" : "background",
        ]
        if !metadata.isEmpty {
            payload["metadata"] = metadata
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8)
        else {
            return
        }
        line.append("\n")
        guard let encoded = line.data(using: .utf8) else { return }
        do {
            try fileHandle?.write(contentsOf: encoded)
        } catch {
            fputs("[TopFade] log write failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func openCurrentLogLocked() throws {
        let day = dayFormatter.string(from: Date())
        let url = logDirectory.appendingPathComponent("topfade-\(day).log")
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try FileHandle(forWritingTo: url)
        try fileHandle?.seekToEnd()
        currentLogURL = url
    }

    private func rotateIfNeededLocked() throws {
        let expectedDay = dayFormatter.string(from: Date())
        let currentDayMatches = currentLogURL?.lastPathComponent.contains(expectedDay) == true
        let size = currentLogURL.flatMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
        } ?? 0
        let rotationLimit = currentRotationByteLimit()
        guard !currentDayMatches || size >= rotationLimit else { return }

        try fileHandle?.close()
        fileHandle = nil
        if size >= rotationLimit, let currentLogURL {
            let rotated = currentLogURL.deletingPathExtension()
                .appendingPathExtension("\(Int(Date().timeIntervalSince1970)).log")
            try? fileManager.moveItem(at: currentLogURL, to: rotated)
        }
        try openCurrentLogLocked()
        cleanupLocked()
    }

    private func cleanupLocked() {
        let retention = TimeInterval((preferences?.logRetentionDays ?? 14) * 86_400)
        let sizeLimit = (preferences?.maxLogMegabytes ?? 20) * 1_024 * 1_024
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = ((try? fileManager.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.pathExtension == "log" }
            .compactMap { url -> (URL, Date, Int)? in
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }
            .sorted { $0.1 > $1.1 }

        let now = Date()
        let currentBytes = currentLogURL.flatMap { current in
            files.first(where: { $0.0 == current })?.2
        } ?? 0
        let reservedCurrentBytes = max(
            currentBytes,
            min(currentRotationByteLimit(), sizeLimit)
        )
        var retainedBytes = reservedCurrentBytes
        for (url, modified, bytes) in files {
            if currentLogURL.map({ $0 == url }) == true {
                continue
            }
            let expired = now.timeIntervalSince(modified) > retention
            let overBudget = retainedBytes + bytes > sizeLimit
            if expired || overBudget {
                try? fileManager.removeItem(at: url)
            } else {
                retainedBytes += bytes
            }
        }
    }

    private func currentRotationByteLimit() -> Int {
        let totalLimit = (preferences?.maxLogMegabytes ?? 20) * 1_024 * 1_024
        return max(256 * 1_024, min(5 * 1_024 * 1_024, totalLimit / 2))
    }
}

enum PermissionStatus {
    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    static func openScreenRecordingSettings() {
        openPrivacySettings("Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        openPrivacySettings("Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        openPrivacySettings("Privacy_ListenEvent")
    }

    private static func openPrivacySettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

enum DiagnosticReporter {
    static func export(
        activeReplicas: [[String: Any]],
        modifiedScrollMode: ModifiedScrollMode
    ) throws -> URL {
        let logger = TopFadeLogger.shared
        let processInfo = ProcessInfo.processInfo
        let payload: [String: Any] = [
            "created_utc": ISO8601DateFormatter().string(from: Date()),
            "product": "TopFade",
            "version": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "development",
            "platform": "macOS",
            "operating_system": processInfo.operatingSystemVersionString,
            "process_id": processInfo.processIdentifier,
            "physical_memory_bytes": processInfo.physicalMemory,
            "uptime_seconds": processInfo.systemUptime,
            "screen_recording_permission": PermissionStatus.screenRecordingGranted,
            "accessibility_permission": PermissionStatus.accessibilityGranted,
            "input_monitoring_permission": PermissionStatus.inputMonitoringGranted,
            "modified_scroll_mode": modifiedScrollMode.rawValue,
            "preferences": PreferencesStore.shared.diagnosticSnapshot(),
            "active_replicas": activeReplicas,
            "recent_logs": logger.recentLogFiles(),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = logger.reportDirectory.appendingPathComponent(
            "topfade-diagnostic-\(formatter.string(from: Date())).json"
        )
        try data.write(to: url, options: .atomic)
        logger.info("Diagnostic report exported", metadata: ["path": url.path])
        return url
    }
}
