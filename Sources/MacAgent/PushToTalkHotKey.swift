import Carbon.HIToolbox
import Foundation

enum PushToTalkHotKeyError: Error, LocalizedError {
    case installHandlerFailed(OSStatus)
    case registerFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .installHandlerFailed(status):
            return "Could not install the push-to-talk hotkey handler. macOS returned \(status)."
        case let .registerFailed(status):
            return "Could not register \u{2303}\u{2325}Space for push-to-talk. macOS returned \(status)."
        }
    }
}

final class PushToTalkHotKey: @unchecked Sendable {
    static let displayName = "\u{2303}\u{2325}Space"

    private let signature = OSType(0x534F4E59) // SONY
    private let identifier = UInt32(1)
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let onPress: @MainActor () -> Void
    private let onRelease: @MainActor () -> Void
    private var isPressed = false

    @MainActor
    init(
        onPress: @escaping @MainActor () -> Void,
        onRelease: @escaping @MainActor () -> Void
    ) throws {
        self.onPress = onPress
        self.onRelease = onRelease
        try register()
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @MainActor
    private func register() throws {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handleEvent,
            eventTypes.count,
            &eventTypes,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            throw PushToTalkHotKeyError.installHandlerFailed(installStatus)
        }

        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey) | UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            UInt32(kEventHotKeyNoOptions),
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
            throw PushToTalkHotKeyError.registerFailed(registerStatus)
        }
    }

    private static let handleEvent: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else {
            return OSStatus(eventNotHandledErr)
        }

        var hotKeyID = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard parameterStatus == noErr else {
            return OSStatus(eventNotHandledErr)
        }

        let hotKey = Unmanaged<PushToTalkHotKey>
            .fromOpaque(userData)
            .takeUnretainedValue()

        guard hotKeyID.signature == hotKey.signature, hotKeyID.id == hotKey.identifier else {
            return OSStatus(eventNotHandledErr)
        }

        let eventKind = GetEventKind(event)
        DispatchQueue.main.async {
            hotKey.handle(eventKind: eventKind)
        }
        return noErr
    }

    @MainActor
    private func handle(eventKind: UInt32) {
        switch eventKind {
        case UInt32(kEventHotKeyPressed):
            guard !isPressed else {
                return
            }
            isPressed = true
            onPress()
        case UInt32(kEventHotKeyReleased):
            guard isPressed else {
                return
            }
            isPressed = false
            onRelease()
        default:
            break
        }
    }
}
