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

/// Whether this Mac is set up to reach the models Sonny's non-local capabilities run on
/// (SONNY-136).
///
/// **This replaces a check on `OPENAI_API_KEY`, and the replacement is a different question rather
/// than the same question asked better.** Until SONNY-130 the readiness row asked whether one
/// environment variable was set, and answered `.ready` or `.needsAction` on it. Both of its
/// sentences were wrong the moment planning, transcription, search and screen control moved behind
/// Sonny's own gateway: nothing reads that variable, so a user who had never exported it — everyone
/// launching the packaged app from Finder, which inherits no shell environment — was told to go and
/// set something that changes nothing, and a user who had one was shown a green row for a credential
/// that does nothing. The second is the worse of the two, because it reports readiness that is not
/// readiness (PR #139, F10).
///
/// **It stays a presence check and does not become a reachability check**, which is the choice
/// SONNY-136's third requirement asks to be made explicitly. Three reasons, and the first is the one
/// that decides it:
///
/// - Readiness is about what this Mac has been set up to do, and reachability is about whether the
///   backend is up right now. They are different questions with different answers and different
///   next actions, and the second already has a surface — the sentence a failed run shows, which
///   `SonnyBackendCopy` owns. A readiness row that went red because the Wi-Fi is off would be
///   reporting an outage in a list of settings.
/// - It would put a network call behind rendering a Settings page and behind
///   `PermissionReadinessCapabilityAdapter`, a tier-0 capability whose whole character is that it
///   reads local state and prompts for nothing.
/// - Spec §16.3 guarantees free local capabilities keep working with no network. A page that
///   reported "needs action" while offline would contradict that in the one place a user goes to
///   find out what works.
///
/// **What it does *not* yet report is entitlement**, and that is left rather than approximated.
/// SONNY-135 builds the signed claim this Mac verifies offline (`EntitlementDecision`,
/// `EntitlementService`), which is the only thing that can answer "is this account allowed to do
/// this" without a network call; it had not merged when SONNY-136 ran, and inventing a second
/// notion of entitlement here to fill the gap would have been a second answer to a question that
/// gets exactly one. So this reports the half that is answerable today — a session is held — and the
/// entitled half is owed. **SONNY-336 is the landing spot**, filed with what the wiring needs and
/// the three decisions it has to make; nothing here approximates it and nothing reports ready on
/// its behalf.
public enum ModelAccessReadiness: Equatable, Sendable {
    /// A session is stored on this Mac.
    case signedIn
    /// No session is stored on this Mac, so every gateway route will refuse.
    case signedOut
    /// Not asked yet, or the stored session could not be read. **Never reported as ready**: a check
    /// that could not be completed is not a check that passed.
    case undetermined
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

    public func currentStatus(
        modelAccess: ModelAccessReadiness,
        hotKeyReady: Bool
    ) -> [PermissionReadinessItem] {
        [
            modelAccessStatus(modelAccess),
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

    /// The row that replaced "OpenAI". ``ModelAccessReadiness`` carries the reasoning.
    ///
    /// **The id changes with the meaning.** It was `openai`, and an id is what a caller keys a row
    /// by — leaving it while the row came to mean something else is how a surface goes on rendering
    /// the old thing under a new sentence.
    private func modelAccessStatus(_ readiness: ModelAccessReadiness) -> PermissionReadinessItem {
        switch readiness {
        case .signedIn:
            return PermissionReadinessItem(
                id: "sonny-account",
                title: "Sonny account",
                state: .ready,
                detail: "Signed in."
            )
        case .signedOut:
            return PermissionReadinessItem(
                id: "sonny-account",
                title: "Sonny account",
                state: .needsAction,
                detail: "Sign in to Sonny in Command Center."
            )
        case .undetermined:
            return PermissionReadinessItem(
                id: "sonny-account",
                title: "Sonny account",
                state: .unknown,
                detail: "Sonny checks this when it needs it."
            )
        }
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
