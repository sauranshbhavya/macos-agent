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
/// **It reports the session and nothing else, and the entitled half is ``PlanReadiness``**
/// (SONNY-336). SONNY-136 left that half unbuilt rather than approximated: SONNY-135's signed claim
/// had not merged, and inventing a second notion of entitlement here would have been a second answer
/// to a question that gets exactly one. It has merged, so the answer now comes from the one source
/// — `EntitlementService.claimConfirmation()` — and it arrives as a separate value rather than as a
/// fourth case here, because "is a session held" and "does this Mac hold a claim it can verify" are
/// two questions with two answers. One row still renders both; `modelAccessStatus` is where they
/// meet.
public enum ModelAccessReadiness: Equatable, Sendable {
    /// A session is stored on this Mac.
    case signedIn
    /// No session is stored on this Mac, so every gateway route will refuse.
    case signedOut
    /// Not asked yet, or the stored session could not be read. **Never reported as ready**: a check
    /// that could not be completed is not a check that passed.
    case undetermined
}

/// Whether this Mac holds an entitlement claim it can verify offline, right now (SONNY-336).
///
/// **There is exactly one source for this and this type does not become a second one.**
/// `EntitlementService.claimConfirmation()` is it: a cached, signed claim checked against a public
/// key this build holds, with no network call and none possible. Every value below is that call's
/// answer or the absence of it — nothing here computes an entitlement, infers one from a session, or
/// decides what a plan grants. That last part is row 18's (SONNY-23) and this asks the one question
/// that does not need it: `claimConfirmation()` deliberately cannot name a capability, so a readiness
/// row cannot mint a capability key to ask about, which is the door SONNY-136 refused to open.
///
/// **Why it is not folded into ``ModelAccessReadiness``.** The two are read from different places at
/// different moments — the session from the backend client's Keychain, the claim from the
/// entitlement actor — and they can disagree. A single enum would have to pick one reading to
/// believe; two values let the row say what each one actually answered.
public enum PlanReadiness: Equatable, Sendable {
    /// The one source confirmed a claim about this Mac's own session.
    case confirmed
    /// The one source answered, and the answer was a refusal. Carried whole rather than collapsed to
    /// a Bool, because two of these have a specific thing the user can do and the rest do not.
    case unconfirmed(EntitlementRefusal)
    /// Nothing has asked yet, or nothing is wired to ask. **Never reported as ready**, for the same
    /// reason ``ModelAccessReadiness/undetermined`` is not: a check that could not be completed is
    /// not a check that passed.
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

    /// **`planAccess` has no default, deliberately.** A defaulted `.undetermined` would let a call
    /// site reach the never-asked answer by saying nothing, so the readiness tool and the Settings
    /// page could silently disagree about whether the plan was consulted at all. Undefaulted, the
    /// compiler names every caller — the same reason SONNY-350 took the defaults off the store
    /// parameters.
    public func currentStatus(
        modelAccess: ModelAccessReadiness,
        planAccess: PlanReadiness,
        hotKeyReady: Bool
    ) -> [PermissionReadinessItem] {
        [
            modelAccessStatus(modelAccess, planAccess),
            microphoneStatus(),
            PermissionReadinessItem(
                id: "hotkey",
                title: "Voice hotkey",
                state: hotKeyReady ? .ready : .needsAction,
                detail: hotKeyReady ? "\u{2303}\u{2325}Space is registered." : "Another app is using \u{2303}\u{2325}Space."
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

    /// The row that replaced "OpenAI". ``ModelAccessReadiness`` and ``PlanReadiness`` carry the
    /// reasoning.
    ///
    /// **The id changes with the meaning.** It was `openai`, and an id is what a caller keys a row
    /// by — leaving it while the row came to mean something else is how a surface goes on rendering
    /// the old thing under a new sentence.
    ///
    /// **One row for two readings, not two rows** (SONNY-336). A signed-out Mac's plan question has
    /// exactly one answer and it is the advice the session half already gives, so a second row would
    /// have said "sign in" twice; and the row count is pinned at eight by
    /// `PermissionReadinessModelAccessTests`, which is that decision written down where a change to
    /// it has to argue with something.
    ///
    /// **The plan is asked only once a session is held**, which is not a shortcut: every refusal
    /// `claimConfirmation()` can give a signed-out Mac reduces to "sign in", and reporting it as a
    /// plan problem would send the user after the wrong thing.
    ///
    /// **`.ready` needs both halves known-good, and that is the whole rule this row carries.**
    /// ``ModelAccessReadiness/undetermined``'s own doc states it for the session — a check that
    /// could not be completed is not a check that passed — and the plan half is held to it
    /// identically. What the plan half never does is push the row to `.needsAction`. That is
    /// deliberate and it is the product call SONNY-336 asked for: no capability is gated anywhere in
    /// this repository today (row 18, SONNY-23, owns which ones will be), so an unconfirmed plan
    /// blocks nothing a user is trying to do, and a red row demanding action on something that is
    /// not stopping them is the one lie a readiness page must not tell. `.unknown` renders as
    /// *"Check when used"*, which is the literal truth: Sonny checks the plan at the moment
    /// something needs it. The day row 18 gates a capability, this is the line that changes.
    private func modelAccessStatus(
        _ readiness: ModelAccessReadiness,
        _ plan: PlanReadiness
    ) -> PermissionReadinessItem {
        func row(_ state: PermissionReadinessState, _ detail: String) -> PermissionReadinessItem {
            PermissionReadinessItem(
                id: "sonny-account",
                title: "Sonny account",
                state: state,
                detail: detail
            )
        }

        switch readiness {
        case .signedIn:
            switch plan {
            case .confirmed:
                return row(.ready, "Signed in, and your plan is confirmed.")
            case .undetermined:
                return row(.unknown, "Signed in. Sonny checks your plan when it needs it.")
            case .unconfirmed(let refusal):
                return row(.unknown, "Signed in. \(Self.planSentence(for: refusal))")
            }
        case .signedOut:
            return row(.needsAction, "Sign in to Sonny in Command Center.")
        case .undetermined:
            return row(.unknown, "Sonny checks this when it needs it.")
        }
    }

    /// The row's own words for a refusal, and **not `EntitlementCopy.message(for:)`** (SONNY-336's
    /// first decision).
    ///
    /// That type's sentences are a *gate's*: they finish the thought "you cannot do this because…"
    /// — "Sign in to Sonny to use this.", "This isn't part of your plan." — and a status row has no
    /// *this* to refer to. Sharing them would also tie a settings row's wording to a refusal
    /// dialog's, so the next edit made for gate reasons would silently reword this page. Two
    /// surfaces, two registers, one source of the *answer* — which is the part that must not be
    /// duplicated and is not.
    ///
    /// Three sentences for seven refusals, because what a user can do about them collapses to three
    /// things: connect once, fix the clock, or nothing at all. `.notSignedIn` and `.notEntitled`
    /// cannot arrive here — the first is handled a level up and the second is a question
    /// `claimConfirmation()` declines to ask — but they are values of the enum, so they are answered
    /// rather than defaulted, and what they get is the honest sentence for two readings that
    /// disagree.
    private static func planSentence(for refusal: EntitlementRefusal) -> String {
        switch refusal {
        case .noClaim:
            return "Connect once so Sonny can check your plan."
        case .clockUnusable:
            return "Your Mac's date and time are too far off to check your plan."
        case .unreadableClaim, .claimIsForAnotherSession, .lapsed, .notSignedIn, .notEntitled:
            return "Sonny couldn't check your plan."
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
