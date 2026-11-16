import AppKit
import SwiftUI

@MainActor
final class TopFadeViewModel: ObservableObject {
    @Published private(set) var windows: [SourceWindow] = []
    @Published private(set) var activeWindowIDs = Set<CGWindowID>()
    @Published var searchText = ""
    @Published var statusMessage = "Ready"
    @Published private(set) var refreshing = false
    @Published private(set) var screenRecordingGranted = PermissionStatus.screenRecordingGranted
    @Published private(set) var accessibilityGranted = PermissionStatus.accessibilityGranted
    @Published private(set) var inputMonitoringGranted = PermissionStatus.inputMonitoringGranted
    @Published private(set) var inputMode: ModifiedScrollMode = .inactive

    let manager: ReplicaManager
    private var observers: [NSObjectProtocol] = []
    private let restartInputMonitoring: () -> ModifiedScrollMode
    private let readInputMonitoringMode: () -> ModifiedScrollMode
    private let preferences: PreferencesStore

    init(
        manager: ReplicaManager,
        restartInputMonitoring: @escaping () -> ModifiedScrollMode = { .inactive },
        inputMonitoringMode: @escaping () -> ModifiedScrollMode = { .inactive },
        preferences: PreferencesStore = .shared
    ) {
        self.manager = manager
        self.restartInputMonitoring = restartInputMonitoring
        readInputMonitoringMode = inputMonitoringMode
        self.preferences = preferences
        manager.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.statusMessage = message
            }
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .topFadeCatalogChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.syncFromOwners()
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .topFadeReplicasChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.syncFromOwners()
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshPermissionState(restartIfChanged: true)
                }
            }
        )
        syncFromOwners()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var filteredWindows: [SourceWindow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return windows }
        return windows.filter {
            $0.applicationName.localizedCaseInsensitiveContains(query)
                || $0.title.localizedCaseInsensitiveContains(query)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    var activeCount: Int {
        manager.activeReplicas.count
    }

    var rememberedCount: Int {
        preferences.rememberedReplicas.count
    }

    var consumesModifiedScroll: Bool {
        preferences.consumeModifiedScroll
    }

    var inputPermissionActionTitle: String {
        if consumesModifiedScroll {
            if !accessibilityGranted {
                return "Allow Accessibility"
            }
            return "Retry Suppression"
        }
        if !accessibilityGranted, !inputMonitoringGranted {
            return "Allow Input Monitoring"
        }
        return "Retry Input"
    }

    var inputPermissionSatisfied: Bool {
        switch inputMode {
        case .consume:
            return true
        case .listenOnly:
            return !consumesModifiedScroll
        case .inactive:
            return false
        }
    }

    func refresh() {
        screenRecordingGranted = PermissionStatus.screenRecordingGranted
        accessibilityGranted = PermissionStatus.accessibilityGranted
        inputMonitoringGranted = PermissionStatus.inputMonitoringGranted
        guard screenRecordingGranted else {
            statusMessage = "Screen Recording permission is required before window discovery."
            return
        }
        refreshing = true
        statusMessage = "Refreshing capturable windows..."
        manager.catalog.refresh { [weak self] result in
            guard let self else { return }
            self.refreshing = false
            switch result {
            case let .success(windows):
                self.windows = windows
                self.statusMessage = "Found \(windows.count) capturable windows."
            case let .failure(error):
                self.statusMessage = "Refresh failed: \(error.localizedDescription)"
            }
        }
    }

    func toggle(_ source: SourceWindow) {
        manager.toggle(source)
        syncFromOwners()
    }

    func isActive(_ source: SourceWindow) -> Bool {
        activeWindowIDs.contains(source.windowID)
    }

    func opacity(for source: SourceWindow) -> Int {
        manager.replicas[source.windowID]?.opacityPercent ?? 100
    }

    func clickThrough(for source: SourceWindow) -> Bool {
        manager.replicas[source.windowID]?.clickThrough ?? false
    }

    func setOpacity(_ opacity: Int, for source: SourceWindow) {
        manager.setOpacity(windowID: source.windowID, percent: opacity)
        syncFromOwners()
    }

    func toggleClickThrough(for source: SourceWindow) {
        manager.toggleClickThrough(windowID: source.windowID)
        syncFromOwners()
    }

    func unpinAll() {
        manager.unpinAll(forget: true)
        statusMessage = "All live replicas were unpinned and forgotten."
        syncFromOwners()
    }

    func requestScreenRecording() {
        let granted = PermissionStatus.requestScreenRecording()
        screenRecordingGranted = granted || PermissionStatus.screenRecordingGranted
        if screenRecordingGranted {
            statusMessage = "Screen Recording access is available."
            refresh()
        } else {
            statusMessage = "Enable TopFade in Privacy & Security > Screen Recording, then restart it."
            PermissionStatus.openScreenRecordingSettings()
        }
    }

    func requestInputPermissions() {
        let requiresSuppression = consumesModifiedScroll
        if requiresSuppression, !accessibilityGranted {
            _ = PermissionStatus.requestAccessibility()
        } else if !requiresSuppression, !accessibilityGranted, !inputMonitoringGranted {
            _ = PermissionStatus.requestInputMonitoring()
        }
        refreshPermissionState()
        inputMode = restartInputMonitoring()
        statusMessage = inputModeStatus
        if requiresSuppression, inputMode != .consume, !accessibilityGranted {
            PermissionStatus.openAccessibilitySettings()
        } else if !requiresSuppression,
                  inputMode == .inactive,
                  !accessibilityGranted,
                  !inputMonitoringGranted {
            PermissionStatus.openInputMonitoringSettings()
        }
    }

    func exportDiagnostics() -> URL? {
        do {
            let url = try DiagnosticReporter.export(
                activeReplicas: manager.diagnosticSnapshots(),
                modifiedScrollMode: inputMode
            )
            statusMessage = "Diagnostic report exported to \(url.path)"
            return url
        } catch {
            statusMessage = "Diagnostic export failed: \(error.localizedDescription)"
            TopFadeLogger.shared.error("Diagnostic export failed", metadata: [
                "error": error.localizedDescription,
            ])
            return nil
        }
    }

    func syncFromOwners() {
        windows = manager.catalog.windows
        activeWindowIDs = Set(manager.replicas.keys)
        inputMode = readInputMonitoringMode()
        refreshPermissionState()
    }

    func syncInputMonitoringMode(announce: Bool = false) {
        inputMode = readInputMonitoringMode()
        if announce {
            statusMessage = inputModeStatus
        }
    }

    private func refreshPermissionState(restartIfChanged: Bool = false) {
        let previousAccessibility = accessibilityGranted
        let previousInputMonitoring = inputMonitoringGranted
        screenRecordingGranted = PermissionStatus.screenRecordingGranted
        accessibilityGranted = PermissionStatus.accessibilityGranted
        inputMonitoringGranted = PermissionStatus.inputMonitoringGranted
        let changed = previousAccessibility != accessibilityGranted
            || previousInputMonitoring != inputMonitoringGranted
        if restartIfChanged, changed {
            inputMode = restartInputMonitoring()
            statusMessage = inputModeStatus
        } else {
            inputMode = readInputMonitoringMode()
        }
    }

    private var inputModeStatus: String {
        switch inputMode {
        case .consume:
            return "Input is active; handled Option+Shift+scroll events are suppressed."
        case .listenOnly:
            if consumesModifiedScroll {
                return "Input is active in listen-only mode; handled scroll still reaches the underlying app."
            }
            return "Input is active in listen-only mode."
        case .inactive:
            if consumesModifiedScroll, !accessibilityGranted {
                return "Enable TopFade under Accessibility to suppress handled Option+Shift+scroll events."
            }
            if !consumesModifiedScroll, !accessibilityGranted, !inputMonitoringGranted {
                return "Enable Input Monitoring or Accessibility, then retry input."
            }
            return "Input permission is available, but the modified-scroll monitor could not start. Retry input."
        }
    }
}

struct ControlCenterView: View {
    @ObservedObject var model: TopFadeViewModel
    let showPreferences: () -> Void

    var body: some View {
        ZStack {
            TopFadePalette.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(TopFadePalette.border)
                permissionArea
                toolbar
                windowList
                footer
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .preferredColorScheme(.dark)
        .onAppear {
            model.refresh()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .fill(
                        LinearGradient(
                            colors: [TopFadePalette.accent, Color(red: 0.76, green: 0.22, blue: 0.13)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("TOPFADE")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .tracking(2.2)
                Text("Pin what matters. Fade everything else.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TopFadePalette.muted)
            }
            Spacer()
            metric(title: "LIVE", value: "\(model.activeCount)")
            metric(title: "REMEMBERED", value: "\(model.rememberedCount)")
            Button(action: showPreferences) {
                Label("Preferences", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(TopFadeSecondaryButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var permissionArea: some View {
        if !model.screenRecordingGranted || !model.inputPermissionSatisfied {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(TopFadePalette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("macOS permissions")
                        .font(.system(size: 13, weight: .bold))
                    Text(permissionMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(TopFadePalette.muted)
                }
                Spacer()
                if !model.screenRecordingGranted {
                    Button("Allow Capture") {
                        model.requestScreenRecording()
                    }
                    .buttonStyle(TopFadeAccentButtonStyle())
                }
                if !model.inputPermissionSatisfied {
                    Button(model.inputPermissionActionTitle) {
                        model.requestInputPermissions()
                    }
                    .buttonStyle(TopFadeSecondaryButtonStyle())
                }
            }
            .padding(12)
            .background(TopFadePalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(TopFadePalette.border, lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    private var permissionMessage: String {
        if !model.screenRecordingGranted, !model.inputPermissionSatisfied {
            return "Capture access creates live replicas. Accessibility suppresses handled scroll; Input Monitoring supports listen-only input."
        }
        if !model.screenRecordingGranted {
            return "Screen Recording access is required for live window replicas."
        }
        if model.inputMode == .listenOnly, model.consumesModifiedScroll {
            return "Modified scroll is running in listen-only mode, so handled scroll still reaches the underlying app."
        }
        if model.inputMode == .inactive,
           model.accessibilityGranted || model.inputMonitoringGranted {
            return "Input permission is granted, but the modified-scroll monitor is not running. Retry input."
        }
        if model.consumesModifiedScroll {
            return "Accessibility access is required to consume Option+Shift+scroll cleanly."
        }
        return "Input Monitoring or Accessibility is required to receive Option+Shift+scroll."
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(TopFadePalette.muted)
                TextField("Find an application or window", text: $model.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(TopFadePalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(TopFadePalette.border, lineWidth: 1)
            )

            Button {
                model.refresh()
            } label: {
                Label(model.refreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(TopFadeSecondaryButtonStyle())
            .disabled(model.refreshing)

            if model.activeCount > 0 {
                Button("Unpin All") {
                    model.unpinAll()
                }
                .buttonStyle(TopFadeSecondaryButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var windowList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if model.filteredWindows.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.on.rectangle.slash")
                            .font(.system(size: 34))
                            .foregroundStyle(TopFadePalette.muted)
                        Text(model.screenRecordingGranted ? "No matching windows" : "Capture access is not enabled")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Open a normal application window, grant access if needed, and refresh.")
                            .font(.system(size: 12))
                            .foregroundStyle(TopFadePalette.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 70)
                } else {
                    ForEach(model.filteredWindows, id: \.windowID) { source in
                        WindowRow(model: model, source: source)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private var footer: some View {
        HStack {
            Circle()
                .fill(model.statusMessage.lowercased().contains("failed") ? Color.red : TopFadePalette.accent)
                .frame(width: 7, height: 7)
            Text(model.statusMessage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TopFadePalette.muted)
                .lineLimit(1)
            Spacer()
            Text("Ctrl + Cmd + T")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Text("toggle frontmost")
                .font(.system(size: 11))
                .foregroundStyle(TopFadePalette.muted)
            Text("Ctrl + Shift + Scroll")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Text("fade")
                .font(.system(size: 11))
                .foregroundStyle(TopFadePalette.muted)
        }
        .padding(.horizontal, 24)
        .frame(height: 42)
        .background(TopFadePalette.panel.opacity(0.72))
        .overlay(alignment: .top) {
            Rectangle().fill(TopFadePalette.border).frame(height: 1)
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(TopFadePalette.muted)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
        }
        .frame(minWidth: 58)
    }
}

private struct WindowRow: View {
    @ObservedObject var model: TopFadeViewModel
    let source: SourceWindow

    private var active: Bool {
        model.isActive(source)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(active ? TopFadePalette.accent.opacity(0.18) : TopFadePalette.raised)
                    Text(String(source.applicationName.prefix(1)).uppercased())
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(active ? TopFadePalette.accent : TopFadePalette.muted)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(source.applicationName)
                        Text("PID \(source.processID)")
                        Text("\(Int(source.frame.width)) x \(Int(source.frame.height))")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TopFadePalette.muted)
                }
                Spacer()
                if active {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(TopFadePalette.accent)
                }
                if active {
                    Button("Unpin") {
                        model.toggle(source)
                    }
                    .buttonStyle(TopFadeSecondaryButtonStyle())
                } else {
                    Button("Pin on Top") {
                        model.toggle(source)
                    }
                    .buttonStyle(TopFadeAccentButtonStyle())
                }
            }
            .padding(12)

            if active {
                Divider().overlay(TopFadePalette.border)
                HStack(spacing: 12) {
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundStyle(TopFadePalette.muted)
                    Text("\(model.opacity(for: source))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(width: 38, alignment: .trailing)
                    Slider(
                        value: Binding(
                            get: { Double(model.opacity(for: source)) },
                            set: { model.setOpacity(Int($0.rounded()), for: source) }
                        ),
                        in: Double(PreferencesStore.shared.minimumOpacity) ... 100,
                        step: 1
                    )
                    .tint(TopFadePalette.accent)
                    Toggle(
                        "Click-through",
                        isOn: Binding(
                            get: { model.clickThrough(for: source) },
                            set: { _ in model.toggleClickThrough(for: source) }
                        )
                    )
                    .toggleStyle(.switch)
                    .font(.system(size: 11, weight: .semibold))
                    .help("Ignore mouse input so clicks reach the window underneath.")
                }
                .padding(.horizontal, 13)
                .frame(height: 48)
                .background(TopFadePalette.raised.opacity(0.45))
            }
        }
        .background(TopFadePalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(active ? TopFadePalette.accent.opacity(0.55) : TopFadePalette.border, lineWidth: 1)
        )
    }
}

struct PreferencesView: View {
    let manager: ReplicaManager
    let scrollSettingsChanged: () -> Void
    let currentInputMode: () -> ModifiedScrollMode
    let exportDiagnostics: () -> Void

    @State private var minimumOpacity: Double
    @State private var opacityStep: Int
    @State private var overlayDuration: Double
    @State private var showOverlay: Bool
    @State private var consumeScroll: Bool
    @State private var showCursor: Bool
    @State private var maxFPS: Int
    @State private var restoreRemembered: Bool
    @State private var defaultClickThrough: Bool
    @State private var startHidden: Bool
    @State private var launchAtLogin: Bool
    @State private var logLevel: String
    @State private var retentionDays: Double
    @State private var maxLogMB: Double
    @State private var saveStatus = ""

    init(
        manager: ReplicaManager,
        scrollSettingsChanged: @escaping () -> Void,
        currentInputMode: @escaping () -> ModifiedScrollMode,
        exportDiagnostics: @escaping () -> Void
    ) {
        self.manager = manager
        self.scrollSettingsChanged = scrollSettingsChanged
        self.currentInputMode = currentInputMode
        self.exportDiagnostics = exportDiagnostics
        let preferences = PreferencesStore.shared
        _minimumOpacity = State(initialValue: Double(preferences.minimumOpacity))
        _opacityStep = State(initialValue: preferences.opacityStep)
        _overlayDuration = State(initialValue: preferences.overlayDuration)
        _showOverlay = State(initialValue: preferences.showOverlay)
        _consumeScroll = State(initialValue: preferences.consumeModifiedScroll)
        _showCursor = State(initialValue: preferences.showCursor)
        _maxFPS = State(initialValue: preferences.maxFramesPerSecond)
        _restoreRemembered = State(initialValue: preferences.restoreRemembered)
        _defaultClickThrough = State(initialValue: preferences.defaultClickThrough)
        _startHidden = State(initialValue: preferences.startHidden)
        _launchAtLogin = State(initialValue: preferences.launchAtLoginRequested)
        _logLevel = State(initialValue: preferences.logLevel)
        _retentionDays = State(initialValue: Double(preferences.logRetentionDays))
        _maxLogMB = State(initialValue: Double(preferences.maxLogMegabytes))
    }

    var body: some View {
        ZStack {
            TopFadePalette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    preferenceHeader
                    section("FADER", icon: "circle.lefthalf.filled") {
                        labeledSlider(
                            "Minimum opacity",
                            value: $minimumOpacity,
                            range: 10 ... 95,
                            step: 5,
                            valueText: "\(Int(minimumOpacity))%"
                        )
                        Picker("Scroll step", selection: $opacityStep) {
                            ForEach([1, 2, 5, 10, 15, 20, 25], id: \.self) {
                                Text("\($0)%").tag($0)
                            }
                        }
                        Toggle("Show the on-screen fader", isOn: $showOverlay)
                        labeledSlider(
                            "Fader display time",
                            value: $overlayDuration,
                            range: 0.3 ... 5.0,
                            step: 0.1,
                            valueText: String(format: "%.1fs", overlayDuration)
                        )
                        Toggle("Consume Option+Shift+scroll instead of passing it through", isOn: $consumeScroll)
                    }

                    section("CAPTURE", icon: "rectangle.inset.filled") {
                        Picker("Maximum frame rate", selection: $maxFPS) {
                            Text("15 FPS - lowest power").tag(15)
                            Text("30 FPS - balanced").tag(30)
                            Text("60 FPS - smoothest").tag(60)
                        }
                        Toggle("Include the pointer in live replicas", isOn: $showCursor)
                        Toggle("Restore remembered windows when their app activates", isOn: $restoreRemembered)
                        Toggle("New replicas ignore mouse input by default", isOn: $defaultClickThrough)
                    }

                    section("STARTUP", icon: "power") {
                        Toggle("Launch TopFade at login", isOn: $launchAtLogin)
                        Toggle("Start with only the menu-bar icon visible", isOn: $startHidden)
                    }

                    section("DIAGNOSTICS", icon: "waveform.path.ecg") {
                        Picker("Log detail", selection: $logLevel) {
                            Text("Debug").tag("debug")
                            Text("Info").tag("info")
                            Text("Warnings").tag("warn")
                            Text("Errors only").tag("error")
                        }
                        labeledSlider(
                            "Log retention",
                            value: $retentionDays,
                            range: 1 ... 90,
                            step: 1,
                            valueText: "\(Int(retentionDays)) days"
                        )
                        labeledSlider(
                            "Maximum log storage",
                            value: $maxLogMB,
                            range: 2 ... 100,
                            step: 1,
                            valueText: "\(Int(maxLogMB)) MB"
                        )
                        HStack {
                            Button("Open Logs") {
                                NSWorkspace.shared.open(TopFadeLogger.shared.logDirectory)
                            }
                            Button("Export Diagnostic Report", action: exportDiagnostics)
                            Button("Accessibility Settings") {
                                PermissionStatus.openAccessibilitySettings()
                            }
                            Button("Input Monitoring Settings") {
                                PermissionStatus.openInputMonitoringSettings()
                            }
                        }
                        .buttonStyle(TopFadeSecondaryButtonStyle())
                    }

                    HStack {
                        Button("Reset Behavior Defaults") {
                            reset()
                        }
                        .buttonStyle(TopFadeSecondaryButtonStyle())
                        Spacer()
                        Text(saveStatus)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TopFadePalette.muted)
                        Button("Apply") {
                            apply()
                        }
                        .buttonStyle(TopFadeAccentButtonStyle())
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 620, minHeight: 620)
        .preferredColorScheme(.dark)
    }

    private var preferenceHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("PREFERENCES")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .tracking(1.8)
                Text("Native controls, persistence, permissions, and diagnostics.")
                    .font(.system(size: 12))
                    .foregroundStyle(TopFadePalette.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Label(
                    PermissionStatus.screenRecordingGranted ? "Capture allowed" : "Capture blocked",
                    systemImage: PermissionStatus.screenRecordingGranted ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                Label(
                    inputPermissionSummary,
                    systemImage: currentInputMode() != .inactive
                        ? "checkmark.circle.fill"
                        : "exclamationmark.circle.fill"
                )
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(TopFadePalette.muted)
        }
    }

    private var inputPermissionSummary: String {
        switch currentInputMode() {
        case .consume:
            return "Scroll suppression active"
        case .listenOnly:
            return "Input active, listen-only"
        case .inactive:
            if PermissionStatus.accessibilityGranted || PermissionStatus.inputMonitoringGranted {
                return "Input permission granted; monitor inactive"
            }
            return "Input limited"
        }
    }

    private func section<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .black))
                .tracking(1.2)
                .foregroundStyle(TopFadePalette.accent)
            content()
                .font(.system(size: 12, weight: .medium))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TopFadePalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(TopFadePalette.border, lineWidth: 1)
        )
    }

    private func labeledSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 150, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .tint(TopFadePalette.accent)
            Text(valueText)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(width: 70, alignment: .trailing)
        }
    }

    private func apply() {
        let preferences = PreferencesStore.shared
        let previousFPS = preferences.maxFramesPerSecond
        let previousCursor = preferences.showCursor
        let previousConsume = preferences.consumeModifiedScroll

        do {
            try preferences.setLaunchAtLogin(launchAtLogin)
        } catch {
            launchAtLogin = preferences.launchAtLoginRequested
            saveStatus = "Login item failed; no preferences were changed: \(error.localizedDescription)"
            TopFadeLogger.shared.error("Launch-at-login update failed", metadata: [
                "error": error.localizedDescription,
            ])
            return
        }

        preferences.minimumOpacity = Int(minimumOpacity.rounded())
        preferences.opacityStep = opacityStep
        preferences.overlayDuration = overlayDuration
        preferences.showOverlay = showOverlay
        preferences.consumeModifiedScroll = consumeScroll
        preferences.showCursor = showCursor
        preferences.maxFramesPerSecond = maxFPS
        preferences.restoreRemembered = restoreRemembered
        preferences.defaultClickThrough = defaultClickThrough
        preferences.startHidden = startHidden
        preferences.logLevel = logLevel
        preferences.logRetentionDays = Int(retentionDays.rounded())
        preferences.maxLogMegabytes = Int(maxLogMB.rounded())

        if previousFPS != preferences.maxFramesPerSecond || previousCursor != preferences.showCursor {
            manager.reconfigureActiveCaptures()
        }
        if previousConsume != preferences.consumeModifiedScroll {
            scrollSettingsChanged()
        }
        TopFadeLogger.shared.cleanup()
        TopFadeLogger.shared.info("Preferences applied")
        saveStatus = preferences.launchAtLoginNeedsApproval
            ? "Saved. Approve TopFade under Login Items."
            : "Saved"
    }

    private func reset() {
        let defaults = PreferencesStore.behaviorDefaults
        minimumOpacity = Double(defaults.minimumOpacity)
        opacityStep = defaults.opacityStep
        overlayDuration = defaults.overlayDuration
        showOverlay = defaults.showOverlay
        consumeScroll = defaults.consumeModifiedScroll
        showCursor = defaults.showCursor
        maxFPS = defaults.maxFramesPerSecond
        restoreRemembered = defaults.restoreRemembered
        defaultClickThrough = defaults.defaultClickThrough
        startHidden = defaults.startHidden
        logLevel = defaults.logLevel
        retentionDays = Double(defaults.logRetentionDays)
        maxLogMB = Double(defaults.maxLogMegabytes)
        saveStatus = "Defaults loaded; press Apply."
    }
}

final class ControlWindowController: NSWindowController, NSWindowDelegate {
    init(model: TopFadeViewModel, showPreferences: @escaping () -> Void) {
        let rootView = ControlCenterView(
            model: model,
            showPreferences: showPreferences
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "TopFade"
        window.setContentSize(NSSize(width: 860, height: 640))
        window.minSize = NSSize(width: 720, height: 520)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.055, green: 0.061, blue: 0.071, alpha: 1)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    init(
        manager: ReplicaManager,
        scrollSettingsChanged: @escaping () -> Void,
        currentInputMode: @escaping () -> ModifiedScrollMode,
        exportDiagnostics: @escaping () -> Void
    ) {
        let rootView = PreferencesView(
            manager: manager,
            scrollSettingsChanged: scrollSettingsChanged,
            currentInputMode: currentInputMode,
            exportDiagnostics: exportDiagnostics
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "TopFade Preferences"
        window.setContentSize(NSSize(width: 680, height: 720))
        window.minSize = NSSize(width: 620, height: 620)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.055, green: 0.061, blue: 0.071, alpha: 1)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private final class FaderViewModel: ObservableObject {
    @Published var title = ""
    @Published var applicationName = ""
    @Published var opacityPercent = 100
}

private struct FaderView: View {
    @ObservedObject var model: FaderViewModel

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(TopFadePalette.accent.opacity(0.18))
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(TopFadePalette.accent)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.applicationName.uppercased())
                            .font(.system(size: 9, weight: .black))
                            .tracking(1)
                            .foregroundStyle(TopFadePalette.muted)
                        Text(model.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(model.opacityPercent)%")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(TopFadePalette.raised)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [TopFadePalette.accent, Color.orange],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(
                                width: max(
                                    8,
                                    geometry.size.width * CGFloat(model.opacityPercent) / 100
                                )
                            )
                    }
                }
                .frame(height: 8)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 360, height: 86)
        .background(.ultraThickMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(TopFadePalette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .preferredColorScheme(.dark)
    }
}

final class FaderPanelController {
    private let model = FaderViewModel()
    private let panel: NSPanel
    private let preferences: PreferencesStore
    private var hideWorkItem: DispatchWorkItem?

    init(preferences: PreferencesStore = .shared) {
        self.preferences = preferences
        let hosting = NSHostingController(rootView: FaderView(model: model))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 86),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "TopFade opacity"
        panel.contentViewController = hosting
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
    }

    func show(for replica: ReplicaController, force: Bool = false) {
        guard force || preferences.showOverlay else { return }
        hideWorkItem?.cancel()
        model.title = replica.source.title
        model.applicationName = replica.source.applicationName
        model.opacityPercent = replica.opacityPercent

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let desired = NSPoint(
            x: min(max(mouse.x - 180, visible.minX + 12), visible.maxX - 372),
            y: min(max(mouse.y + 24, visible.minY + 12), visible.maxY - 98)
        )
        panel.setFrameOrigin(desired)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.18
                    self.panel.animator().alphaValue = 0
                },
                completionHandler: {
                    self.panel.orderOut(nil)
                }
            )
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + preferences.overlayDuration,
            execute: workItem
        )
    }
}

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let manager: ReplicaManager
    private let showControl: () -> Void
    private let showPreferences: () -> Void
    private let exportDiagnostics: () -> Void

    init(
        manager: ReplicaManager,
        showControl: @escaping () -> Void,
        showPreferences: @escaping () -> Void,
        exportDiagnostics: @escaping () -> Void
    ) {
        self.manager = manager
        self.showControl = showControl
        self.showPreferences = showPreferences
        self.exportDiagnostics = exportDiagnostics
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "pin.square.fill",
            accessibilityDescription: "TopFade"
        )
        statusItem.button?.toolTip = "TopFade"
        let menu = NSMenu(title: "TopFade")
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Show TopFade", action: #selector(openControl), key: ","))
        menu.addItem(item("Toggle Frontmost Window", action: #selector(toggleFrontmost), key: "t"))
        menu.items.last?.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(.separator())

        let active = manager.activeReplicas
        if active.isEmpty {
            let none = NSMenuItem(title: "No live replicas", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            let replicasItem = NSMenuItem(title: "Live Replicas (\(active.count))", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Live Replicas")
            for replica in active {
                let parent = NSMenuItem(
                    title: "\(replica.source.applicationName): \(replica.source.title) - \(replica.opacityPercent)%",
                    action: nil,
                    keyEquivalent: ""
                )
                let controls = NSMenu(title: replica.source.displayName)
                controls.addItem(replicaItem(
                    replica.clickThrough ? "Disable Click-through" : "Enable Click-through",
                    action: #selector(toggleClickThrough(_:)),
                    windowID: replica.source.windowID
                ))
                controls.addItem(replicaItem(
                    "Unpin",
                    action: #selector(unpinReplica(_:)),
                    windowID: replica.source.windowID
                ))
                parent.submenu = controls
                submenu.addItem(parent)
            }
            replicasItem.submenu = submenu
            menu.addItem(replicasItem)
            menu.addItem(item("Unpin All", action: #selector(unpinAll)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Preferences", action: #selector(openPreferences)))
        menu.addItem(item("Export Diagnostic Report", action: #selector(exportReport)))
        menu.addItem(item("Open Logs", action: #selector(openLogs)))
        menu.addItem(.separator())
        menu.addItem(item("Quit TopFade", action: #selector(quit), key: "q"))
    }

    @objc private func openControl() {
        showControl()
    }

    @objc private func toggleFrontmost() {
        manager.toggleFrontmostWindow()
    }

    @objc private func openPreferences() {
        showPreferences()
    }

    @objc private func exportReport() {
        exportDiagnostics()
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(TopFadeLogger.shared.logDirectory)
    }

    @objc private func unpinAll() {
        manager.unpinAll(forget: true)
    }

    @objc private func unpinReplica(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        manager.unpin(CGWindowID(number.uint32Value), forget: true)
    }

    @objc private func toggleClickThrough(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        manager.toggleClickThrough(windowID: CGWindowID(number.uint32Value))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func item(
        _ title: String,
        action: Selector,
        key: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func replicaItem(
        _ title: String,
        action: Selector,
        windowID: CGWindowID
    ) -> NSMenuItem {
        let item = self.item(title, action: action)
        item.representedObject = NSNumber(value: windowID)
        return item
    }
}

private enum TopFadePalette {
    static let background = Color(red: 0.055, green: 0.061, blue: 0.071)
    static let panel = Color(red: 0.087, green: 0.095, blue: 0.109)
    static let raised = Color(red: 0.125, green: 0.135, blue: 0.153)
    static let border = Color.white.opacity(0.105)
    static let muted = Color(red: 0.58, green: 0.61, blue: 0.66)
    static let accent = Color(red: 0.91, green: 0.36, blue: 0.25)
}

private struct TopFadeAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 13)
            .frame(height: 32)
            .foregroundStyle(.white)
            .background(
                TopFadePalette.accent.opacity(configuration.isPressed ? 0.72 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TopFadeSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 13)
            .frame(height: 32)
            .foregroundStyle(.white)
            .background(
                TopFadePalette.raised.opacity(configuration.isPressed ? 0.65 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(TopFadePalette.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
