import AppKit
import Carbon
import CoreGraphics

private let topFadeHotKeySignature: OSType = 0x5446_4445 // "TFDE"
private let topFadeHotKeyID: UInt32 = 1

enum ModifiedScrollMode: String, Equatable {
    case inactive
    case listenOnly = "listen-only"
    case consume
}

private func topFadeCarbonHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == topFadeHotKeySignature,
          hotKeyID.id == topFadeHotKeyID
    else {
        return OSStatus(eventNotHandledErr)
    }

    let manager = Unmanaged<GlobalHotKeyManager>
        .fromOpaque(userData)
        .takeUnretainedValue()
    manager.invoke()
    return noErr
}

final class GlobalHotKeyManager {
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func start() throws {
        guard hotKeyReference == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            topFadeCarbonHotKeyHandler,
            1,
            &eventType,
            pointer,
            &eventHandlerReference
        )
        guard handlerStatus == noErr else {
            throw inputError(
                code: handlerStatus,
                description: "The global hotkey event handler could not be installed."
            )
        }

        let identifier = EventHotKeyID(
            signature: topFadeHotKeySignature,
            id: topFadeHotKeyID
        )
        let modifiers = UInt32(controlKey | cmdKey)
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            modifiers,
            identifier,
            GetEventDispatcherTarget(),
            OptionBits(0),
            &hotKeyReference
        )
        guard registrationStatus == noErr else {
            if let eventHandlerReference {
                RemoveEventHandler(eventHandlerReference)
                self.eventHandlerReference = nil
            }
            throw inputError(
                code: registrationStatus,
                description: "Control+Command+T could not be registered. Another application may own that exact shortcut."
            )
        }
        TopFadeLogger.shared.info("Global hotkey registered", metadata: [
            "hotkey": "Control+Command+T",
        ])
    }

    func stop() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
            self.eventHandlerReference = nil
        }
    }

    fileprivate func invoke() {
        TopFadeLogger.shared.debug("Global hotkey received", metadata: [
            "hotkey": "Control+Command+T",
        ])
        action()
    }

    deinit {
        stop()
    }
}

private func topFadeScrollEventCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<ModifiedScrollMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return manager.handle(type: type, event: event)
}

final class ModifiedScrollMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var continuousAccumulator = 0.0
    private(set) var mode: ModifiedScrollMode = .inactive

    var currentlyConsumesEvents: Bool {
        mode == .consume
    }

    private let canHandle: (NSPoint) -> Bool
    private let onScroll: (Int, NSPoint) -> Bool
    private let preferences: PreferencesStore

    init(
        canHandle: @escaping (NSPoint) -> Bool,
        onScroll: @escaping (Int, NSPoint) -> Bool,
        preferences: PreferencesStore = .shared
    ) {
        self.canHandle = canHandle
        self.onScroll = onScroll
        self.preferences = preferences
    }

    @discardableResult
    func start(consumingEvents: Bool? = nil) -> Bool {
        stop()
        let wantsFilter = consumingEvents ?? preferences.consumeModifiedScroll
        if wantsFilter, install(options: .defaultTap) {
            mode = .consume
            TopFadeLogger.shared.info("Modified scroll event filter started", metadata: [
                "mode": "consume",
            ])
            return true
        }
        if install(options: .listenOnly) {
            mode = .listenOnly
            let level: LogLevel = wantsFilter ? .warn : .info
            let message = wantsFilter
                ? "Modified scroll started in listen-only mode; grant Accessibility to suppress the underlying scroll. Input Monitoring remains listen-only."
                : "Modified scroll event listener started"
            switch level {
            case .warn:
                TopFadeLogger.shared.warn(message, metadata: ["mode": "listen-only"])
            default:
                TopFadeLogger.shared.info(message, metadata: ["mode": "listen-only"])
            }
            return true
        }

        TopFadeLogger.shared.error(
            "Option+Shift scroll monitoring could not start. Grant Accessibility for suppression or Input Monitoring for listen-only use, then restart TopFade."
        )
        return false
    }

    @discardableResult
    func restart() -> ModifiedScrollMode {
        _ = start()
        return mode
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        mode = .inactive
        continuousAccumulator = 0
    }

    fileprivate func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                TopFadeLogger.shared.warn("Modified scroll event tap was disabled and has been re-enabled", metadata: [
                    "reason": type == .tapDisabledByTimeout ? "timeout" : "user-input",
                ])
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        guard flags.contains(.maskAlternate), flags.contains(.maskShift) else {
            continuousAccumulator = 0
            return Unmanaged.passUnretained(event)
        }

        let point = NSEvent.mouseLocation
        guard canHandle(point) else {
            continuousAccumulator = 0
            return Unmanaged.passUnretained(event)
        }

        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        var rawDelta: Double
        if continuous {
            rawDelta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            if continuousAccumulator != 0,
               rawDelta != 0,
               (continuousAccumulator > 0) != (rawDelta > 0) {
                continuousAccumulator = 0
            }
            continuousAccumulator += rawDelta
            guard abs(continuousAccumulator) >= 3 else {
                return currentlyConsumesEvents ? nil : Unmanaged.passUnretained(event)
            }
            rawDelta = continuousAccumulator
            continuousAccumulator = 0
        } else {
            rawDelta = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        }

        guard rawDelta != 0 else {
            return currentlyConsumesEvents ? nil : Unmanaged.passUnretained(event)
        }
        let handled = onScroll(rawDelta > 0 ? 1 : -1, point)
        return handled && currentlyConsumesEvents ? nil : Unmanaged.passUnretained(event)
    }

    deinit {
        stop()
    }

    private func install(options: CGEventTapOptions) -> Bool {
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: topFadeScrollEventCallback,
            userInfo: pointer
        ) else {
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
}

private func inputError(code: OSStatus, description: String) -> NSError {
    NSError(
        domain: "com.tavito.topfade.input",
        code: Int(code),
        userInfo: [NSLocalizedDescriptionKey: "\(description) (OSStatus \(code))"]
    )
}
