import AVFoundation
import Foundation

// MARK: - Permission seam

/// Live TCC state for the microphone (SONNY-123).
///
/// **Separate from `ScreenCapturePermissionChecking` rather than folded into it.** That protocol
/// vends preflight booleans because macOS exposes no "not determined vs. denied" distinction for
/// Screen Recording or Accessibility. The microphone does expose one, and the readiness row has
/// three distinct states because of it, so the seam vends `AVAuthorizationStatus` itself rather
/// than re-encoding four cases into a boolean that would lose the two the UI depends on.
///
/// The platform type is deliberate too: a domain enum here would be a one-to-one re-spelling of
/// `AVAuthorizationStatus` whose only effect is that `@unknown default` stops meaning what it
/// means.
public protocol MicrophonePermissionChecking: Sendable {
    func microphoneAuthorizationStatus() -> AVAuthorizationStatus
}

public struct SystemMicrophonePermissionChecker: MicrophonePermissionChecking {
    public init() {}

    public func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
}

public enum PermissionReadinessState: String, Codable, Equatable, Sendable {
    case ready
    case needsAction
    case unknown

    public var displayName: String {
        switch self {
        case .ready:
            return "Ready"
        case .needsAction:
            return "Needs action"
        case .unknown:
            return "Check when used"
        }
    }
}

public struct PermissionReadinessItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var state: PermissionReadinessState
    public var detail: String

    public init(id: String, title: String, state: PermissionReadinessState, detail: String) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
    }
}

public struct PermissionReadinessService: Sendable {
    private let screenPermissionChecker: any ScreenCapturePermissionChecking
    private let microphonePermissionChecker: any MicrophonePermissionChecking

    public init(
        screenPermissionChecker: any ScreenCapturePermissionChecking = SystemScreenCapturePermissionChecker(),
        microphonePermissionChecker: any MicrophonePermissionChecking = SystemMicrophonePermissionChecker()
    ) {
        self.screenPermissionChecker = screenPermissionChecker
        self.microphonePermissionChecker = microphonePermissionChecker
    }

    public func currentStatus(hasAPIKey: Bool, hotKeyReady: Bool) -> [PermissionReadinessItem] {
        [
            PermissionReadinessItem(
                id: "openai",
                title: "OpenAI",
                state: hasAPIKey ? .ready : .needsAction,
                detail: hasAPIKey ? "OPENAI_API_KEY is set." : "Export OPENAI_API_KEY before launching Sonny."
            ),
            microphoneStatus(),
            PermissionReadinessItem(
                id: "hotkey",
                title: "Voice hotkey",
                state: hotKeyReady ? .ready : .needsAction,
                detail: hotKeyReady ? "Control-Option-Space is registered." : "Another app is using Control-Option-Space."
            ),
            PermissionReadinessItem(
                id: "desktop-documents",
                title: "Desktop/Documents",
                state: .unknown,
                detail: "Sonny validates paths first; macOS may ask the launcher for file access when used."
            ),
            PermissionReadinessItem(
                id: "finder-automation",
                title: "Finder automation",
                state: .unknown,
                detail: "Finder context may trigger an Automation prompt the first time it reads selection."
            ),
            PermissionReadinessItem(
                id: "word-automation",
                title: "Microsoft Word automation",
                state: .unknown,
                detail: "DOCX conversion may trigger an Automation prompt when Word is controlled."
            ),
            accessibilityStatus(),
            screenRecordingStatus()
        ]
    }

    private func accessibilityStatus() -> PermissionReadinessItem {
        let trusted = screenPermissionChecker.isAccessibilityTrusted()
        return PermissionReadinessItem(
            id: "accessibility",
            title: "Accessibility",
            state: trusted ? .ready : .needsAction,
            detail: trusted
                ? "Accessibility is trusted for the current process."
                : "Screen-acting tools need Accessibility. Enable Sonny in System Settings › Privacy & Security › Accessibility."
        )
    }

    private func screenRecordingStatus() -> PermissionReadinessItem {
        let granted = screenPermissionChecker.hasScreenRecordingPermission()
        return PermissionReadinessItem(
            id: "screen-recording",
            title: "Screen Recording",
            state: granted ? .ready : .needsAction,
            detail: granted
                ? "Screen Recording is granted."
                : "Screen-aware tools need Screen Recording. Enable Sonny in System Settings › Privacy & Security › Screen Recording, then relaunch Sonny."
        )
    }

    private func microphoneStatus() -> PermissionReadinessItem {
        switch microphonePermissionChecker.microphoneAuthorizationStatus() {
        case .authorized:
            return PermissionReadinessItem(
                id: "microphone",
                title: "Microphone",
                state: .ready,
                detail: "Voice input is authorized."
            )
        case .denied, .restricted:
            return PermissionReadinessItem(
                id: "microphone",
                title: "Microphone",
                state: .needsAction,
                detail: "Enable microphone access for the launcher in System Settings."
            )
        case .notDetermined:
            return PermissionReadinessItem(
                id: "microphone",
                title: "Microphone",
                state: .unknown,
                detail: "Sonny will ask for microphone access the first time you speak."
            )
        @unknown default:
            return PermissionReadinessItem(
                id: "microphone",
                title: "Microphone",
                state: .unknown,
                detail: "Microphone status is unknown."
            )
        }
    }
}
