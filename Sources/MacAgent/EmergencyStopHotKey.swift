import Carbon.HIToolbox
import Foundation

enum EmergencyStopHotKeyError: Error, LocalizedError {
    case installHandlerFailed(OSStatus)
    case registerFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .installHandlerFailed(status):
            return "Could not install the emergency-stop hotkey handler. macOS returned \(status)."
        case let .registerFailed(status):
            return "Could not register \(EmergencyStopHotKey.displayName) for emergency stop. macOS returned \(status)."
        }
    }
}

/// The registration itself, as a seam.
///
/// **Exists so the wiring can be tested without any test taking a real global shortcut** (PR #50
/// review, F4). A test process that called `RegisterEventHotKey` would either steal `Ctrl-Opt-Esc`
/// from the developer's machine for the duration of the suite or fail in CI — so no test may
/// construct the real one, and that is exactly why removing the registration call from
/// `visionSessionDidProgress` left the whole suite green while `Ctrl-Opt-Esc` silently never
/// registered for any session.
protocol EmergencyStopHotKeyRegistering: AnyObject {
    // `@MainActor` on the requirement rather than the protocol: isolating the whole protocol
    // isolates every conformer, and this class's `deinit` unregisters Carbon handles from a
    // nonisolated context — which a main-actor class may not do.
    @MainActor init(onStop: @escaping @MainActor () -> Void) throws
}

/// The global hotkey that stops a screen-control session from anywhere.
///
/// **Registered only while a session is live, and that is a deliberate bound rather than a
/// convenience.** A permanently-held global shortcut is a key combination taken away from every
/// other app on the machine forever, in exchange for a control that matters for the seconds Sonny is
/// actually moving the cursor. It is registered when a vision session starts and unregistered when
/// it ends, so outside a session the combination belongs to whatever the user's own apps want it
/// for.
///
/// **Why a hotkey at all, when the widget already has a stop button.** During a session Sonny is
/// clicking and typing into another app, which means the user's pointer is not theirs to aim and the
/// frontmost window is not the one they chose. Reaching for a button on a floating panel while a
/// program is moving the cursor is exactly the moment a mouse-driven control is least reliable. The
/// keyboard is the one input path the session does not contend for.
///
/// Escape rather than a letter: it is the one key every user already reads as "stop", it needs no
/// learning, and Control-Option-Escape is close enough to macOS's own force-quit shortcut to feel
/// like the same category of action without colliding with it (that one is Command-Option-Escape).
final class EmergencyStopHotKey: EmergencyStopHotKeyRegistering, @unchecked Sendable {
    static let displayName = "\u{2303}\u{2325}\u{238B}"

    /// Distinct from `PushToTalkHotKey`'s identifier under the same signature, so the shared handler
    /// dispatch can tell the two apart.
    private let signature = OSType(0x534F4E59) // SONY
    private let identifier = UInt32(2)
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let onStop: @MainActor () -> Void

    @MainActor
    init(onStop: @escaping @MainActor () -> Void) throws {
        self.onStop = onStop
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
        // Press only. A stop is a single event — there is no held state to track, unlike
        // push-to-talk, and handling the release too would fire the stop twice.
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
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
            throw EmergencyStopHotKeyError.installHandlerFailed(installStatus)
        }

        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Escape),
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
            throw EmergencyStopHotKeyError.registerFailed(registerStatus)
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

        let hotKey = Unmanaged<EmergencyStopHotKey>
            .fromOpaque(userData)
            .takeUnretainedValue()

        guard hotKeyID.signature == hotKey.signature, hotKeyID.id == hotKey.identifier else {
            return OSStatus(eventNotHandledErr)
        }

        DispatchQueue.main.async {
            hotKey.onStop()
        }
        return noErr
    }
}
