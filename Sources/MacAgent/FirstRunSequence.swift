import Foundation
import MacAgentCore
import SwiftUI

// MARK: - The steps

/// The ordered steps of first run, and the whole of it.
///
/// **Two steps, not the four beats the user experiences**, and the difference is deliberate. What a
/// new user walks through is sign in, Screen Recording, the relaunch macOS forces, then
/// Accessibility — but the last three are one sheet, `ScreenAccessOnboardingView`, which already
/// owns that ordering and the relaunch between them (SONNY-137 triggers and sequences that view; it
/// does not rebuild it). **A step finer than the thing the user can close produces a loop**: mark
/// only `screenRecording` skipped when the sheet is dismissed and `accessibility` is next, so the
/// same sheet re-opens on the same launch. The unit of skipping has to be the unit of presentation.
///
/// **Order is the property this ticket exists to hold.** `signIn` is first because the Screen
/// Recording grant restarts the app, and a session that is not in the Keychain when that happens is
/// gone — the user grants a permission and comes back signed out, on their first run.
/// `FirstRunSequence.step(...)` can never answer `.screenAccess` while `.signIn` is outstanding, and
/// `FirstRunSequenceTests.screenAccessIsNeverReachedWhileSignInIsStillOutstanding` asserts that over
/// every combination of inputs rather than over the two a reader would think of.
///
/// **Nothing here names a sign-in method.** The step is satisfied by "a session is held", which is
/// what every method produces — the §3.2 token response `SonnyAccountModel` already adopts — so
/// Google (SONNY-129) and Apple arrive as buttons inside `SignInDialogView`'s address step and
/// change nothing in this file. `theSequenceNamesNoSignInMethod` is that claim as a scan.
///
/// **There is no consent step, and there will not be one.** Training consent is captured in the
/// website signup flow, never as an in-app toggle (founder, 2026-08-16) — a toggle would have to
/// explain itself and would collide with the no-explanatory-copy rule. So it sits *before* this
/// sequence entirely: a person has an account before the app can take a code for it. A user who has
/// not given it is handled by the app doing nothing about it — nothing here reads a consent state,
/// asks for one, or renders a control for one, and `allCases` is asserted by exact equality so a
/// third step cannot arrive quietly.
enum FirstRunStep: String, CaseIterable, Sendable {
    /// Sign in. First, because everything after it can restart the app.
    case signIn
    /// Screen Recording, the relaunch, and Accessibility — `ScreenAccessOnboardingView`'s own
    /// sequence, presented whole.
    case screenAccess
}

// MARK: - The resolver

/// Which step a launch lands on, as a pure function of what this Mac is and what the user has
/// already said.
///
/// **A resolver rather than a stored position, and that is what makes the sequence survive the
/// relaunch.** A position would have to be written before the restart and read after it, which is
/// one more thing to get wrong at exactly the moment that matters. This asks the live state instead:
/// after the relaunch the Keychain holds a session and `CGPreflightScreenCaptureAccess` answers
/// true, so the same function that answered `.signIn` on a clean machine answers `.screenAccess`
/// without anything having been written down about where the user was.
///
/// What *is* written down is only what live state cannot say: which steps the user declined, and
/// whether the sequence has ended. See `FirstRunStore`.
enum FirstRunSequence {
    /// The next step to present, or `nil` when there is nothing left to ask.
    ///
    /// `hasFinished` is checked first and alone: a user who has been through this once is never put
    /// through it again, whatever their grants say afterwards. Signing out later is not a new first
    /// run.
    static func step(
        isSignedIn: Bool,
        screenRecordingGranted: Bool,
        accessibilityTrusted: Bool,
        skipped: Set<FirstRunStep>,
        hasFinished: Bool
    ) -> FirstRunStep? {
        guard !hasFinished else { return nil }
        return FirstRunStep.allCases.first { step in
            if skipped.contains(step) { return false }
            return !isSatisfied(
                step,
                isSignedIn: isSignedIn,
                screenRecordingGranted: screenRecordingGranted,
                accessibilityTrusted: accessibilityTrusted
            )
        }
    }

    /// Whether a step's outcome already exists on this Mac — nothing to do with whether the user
    /// ever saw it. This is what lets the sequence resume rather than replay.
    static func isSatisfied(
        _ step: FirstRunStep,
        isSignedIn: Bool,
        screenRecordingGranted: Bool,
        accessibilityTrusted: Bool
    ) -> Bool {
        switch step {
        case .signIn:
            return isSignedIn
        case .screenAccess:
            return screenRecordingGranted && accessibilityTrusted
        }
    }
}

// MARK: - Persistence

/// What the sequence remembers between launches: the steps the user declined, and whether it is
/// over.
///
/// **Plain `UserDefaults`, following the Preferences rule in `.claude/rules/macagent-ui-conventions.md`**
/// and `MemorySettingsStore`'s reasoning: two booleans about Sonny's own behaviour, not a word of
/// the user's content, so there is nothing here for `LocalStorageEncryption` to protect and nothing
/// for a decrypt failure to take away. It also has to survive **Delete Local Data**, for the same
/// reason the memory switches do — a wipe that reset this would restart first run for a user who
/// had already been through it.
///
/// **`userDefaults` has no default**, for SONNY-240's reason applied to something small: a default
/// resolving to `.standard` is invisible at every call site that predates the parameter, and a test
/// that reached it would flip the founder's own "first run is over" flag in the one domain every
/// packaged build on this Mac shares. `main.swift` names `.standard` where a reader can see it.
struct FirstRunStore {
    private enum Keys {
        static let hasFinished = "com.sonny.state.firstRunFinished"
        static let skippedSteps = "com.sonny.state.firstRunSkippedSteps"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    /// Read with `object(forKey:) as? Bool ?? false`, not `.bool(forKey:)` — the convention the
    /// Preferences rule states. The missing-key answer here is `false` deliberately, and it is the
    /// one place in this file where that is the *right* default rather than the convenient one: a
    /// Mac with no key has never run first run, and must.
    var hasFinished: Bool {
        userDefaults.object(forKey: Keys.hasFinished) as? Bool ?? false
    }

    /// A raw value this build does not recognise is dropped rather than guessed at, which fails in
    /// the safe direction: an unknown step reads as not-skipped, so the worst case is asking again.
    var skippedSteps: Set<FirstRunStep> {
        let raw = userDefaults.array(forKey: Keys.skippedSteps) as? [String] ?? []
        return Set(raw.compactMap(FirstRunStep.init(rawValue:)))
    }

    func markSkipped(_ step: FirstRunStep) {
        let updated = skippedSteps.union([step]).map(\.rawValue).sorted()
        userDefaults.set(updated, forKey: Keys.skippedSteps)
    }

    func markFinished() {
        userDefaults.set(true, forKey: Keys.hasFinished)
    }
}

// MARK: - Coordinator

/// Holds the one live answer to "is first run showing, and on what step" — observed by
/// `CommandCenterView`, driven by `AppDelegate` at launch.
///
/// **Its own object rather than a field on `AgentViewModel`**, for the reason `SonnyAccountModel`
/// gives: the view model owns the run loop and thirteen local stores, and a launch-time sequence
/// shares none of that.
///
/// **`begin` is separate from `refresh`, and the separation is the ticket's headline property in
/// code.** Nothing is decided until `begin` is called, and `AppDelegate` calls it only after
/// `await accountModel.restore()` has read the Keychain. Deciding before that read would show the
/// sign-in step to a user who is already signed in — which on the launch that follows the Screen
/// Recording grant is exactly "the user granted a permission and came back to a sign-in screen",
/// the failure this whole sequence exists to prevent, arriving through the front door.
@MainActor
final class FirstRunCoordinator: ObservableObject {
    /// The step on screen, or `nil` for "first run is not showing".
    @Published private(set) var presentedStep: FirstRunStep?
    private(set) var hasBegun = false

    private let store: FirstRunStore
    private var isSignedIn = false
    private var screenRecordingGranted = false
    private var accessibilityTrusted = false

    init(store: FirstRunStore) {
        self.store = store
    }

    /// Decide, once, on the state the caller has just finished reading. Later calls are ignored: a
    /// second `begin` would re-enter a sequence the user may have skipped out of during this launch.
    func begin(isSignedIn: Bool, screenRecordingGranted: Bool, accessibilityTrusted: Bool) {
        guard !hasBegun else { return }
        hasBegun = true
        resolve(
            isSignedIn: isSignedIn,
            screenRecordingGranted: screenRecordingGranted,
            accessibilityTrusted: accessibilityTrusted
        )
    }

    /// Re-read live state while the sequence is up — a sign-in that completed, a grant that landed.
    /// Does nothing before `begin`, so no view's `onChange` can start the sequence ahead of the
    /// Keychain read.
    func refresh(isSignedIn: Bool, screenRecordingGranted: Bool, accessibilityTrusted: Bool) {
        guard hasBegun else { return }
        resolve(
            isSignedIn: isSignedIn,
            screenRecordingGranted: screenRecordingGranted,
            accessibilityTrusted: accessibilityTrusted
        )
    }

    /// The user declined the step on screen. Recorded so it is not asked again — on this launch or
    /// any later one — and the sequence moves on rather than ending.
    func skipCurrentStep() {
        guard let step = presentedStep else { return }
        store.markSkipped(step)
        resolve(
            isSignedIn: isSignedIn,
            screenRecordingGranted: screenRecordingGranted,
            accessibilityTrusted: accessibilityTrusted
        )
    }

    private func resolve(isSignedIn: Bool, screenRecordingGranted: Bool, accessibilityTrusted: Bool) {
        self.isSignedIn = isSignedIn
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityTrusted = accessibilityTrusted
        let next = FirstRunSequence.step(
            isSignedIn: isSignedIn,
            screenRecordingGranted: screenRecordingGranted,
            accessibilityTrusted: accessibilityTrusted,
            skipped: store.skippedSteps,
            hasFinished: store.hasFinished
        )
        presentedStep = next
        if next == nil {
            // Reached with nothing left to ask — every step satisfied, declined, or both. Written
            // here rather than at the end of the last step so that a Mac already set up before this
            // sequence existed is marked done on its first launch instead of being walked through a
            // sequence with nothing in it.
            store.markFinished()
        }
    }
}

// MARK: - Copy

/// Every user-facing string first run adds, which is two labels.
///
/// **Functional labels, and the sequence writes nothing else** (founder, 2026-08-14). It adds no
/// title, no step counter, no welcome and no explanation: the two steps are the existing sign-in
/// and screen-access dialogs, which carry their own words.
/// `AgentActivityPresentation.firstRunApprovalExplainerLines` remains the single founder-approved
/// exception to the no-explanatory-copy rule and is not extended here.
///
/// **Why one of the two names a destination and the other does not.** Requirement 4 asks that a user
/// who declines a step be told how to finish later. Screen access is finished in Settings → Security
/// & Access, which is behind two clicks and nothing on screen points at it, so the label says where.
/// Sign-in is finished from the account row in Command Center's bottom-left, which reads "Sign in"
/// and is permanently visible — including directly behind this sheet — so naming it in the label
/// would be describing something already on screen, which is the explanatory copy the rule forbids.
enum FirstRunCopy {
    static func deferralLabel(for step: FirstRunStep) -> String {
        switch step {
        case .signIn:
            return "Sign in later"
        case .screenAccess:
            return "Set up later in Settings"
        }
    }
}

// MARK: - Presentation

/// First run, presented as the two existing dialogs in order with one control added beneath them.
///
/// **It hosts them; it does not reimplement them.** `SignInDialogView` and
/// `ScreenAccessOnboardingView` are the same views Command Center's account menu and Settings open,
/// with the same models — so a fix to either lands in both places, and neither had to grow a
/// first-run mode. The step swaps inside one sheet rather than dismissing and re-presenting, so the
/// user does not watch a panel disappear on the way to the next question.
///
/// **The deferral bar is the only thing added, and it is here rather than inside the two dialogs**
/// so that neither is touched. The dialogs' own close controls already skip a step; what they cannot
/// say is where the step is finished later, which is what this one control says. How any of this
/// looks is SONNY-109's — this ticket owns that the sequence exists, is ordered, and does not lose
/// the user.
struct FirstRunSequenceView: View {
    @ObservedObject var coordinator: FirstRunCoordinator
    @ObservedObject var accountModel: SonnyAccountModel
    @ObservedObject var screenAccessModel: ScreenAccessOnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            stepContent
            if let step = coordinator.presentedStep {
                deferralBar(step)
            }
        }
        .background(SonnyTheme.ink)
        // Live state moved: a session was verified, or a grant landed. The sequence advances off the
        // same values it was begun with rather than off anything it recorded about the user's
        // progress, which is what makes the post-relaunch launch and this one take the same path.
        .onChange(of: accountModel.isSignedIn) { _, _ in advance() }
        .onChange(of: screenAccessModel.screenRecordingGranted) { _, _ in advance() }
        .onChange(of: screenAccessModel.accessibilityTrusted) { _, _ in advance() }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch coordinator.presentedStep {
        case .signIn:
            SignInDialogView(model: accountModel, isPresented: skipBinding)
        case .screenAccess:
            ScreenAccessOnboardingView(model: screenAccessModel, isPresented: skipBinding)
        case nil:
            EmptyView()
        }
    }

    /// The hosted dialog's own close control, read as "skip this step". Both dialogs take an
    /// `isPresented` binding and set it false to close; here that is the one thing it can mean.
    private var skipBinding: Binding<Bool> {
        Binding(
            get: { true },
            set: { isPresented in
                if !isPresented { coordinator.skipCurrentStep() }
            }
        )
    }

    private func deferralBar(_ step: FirstRunStep) -> some View {
        HStack {
            Spacer()
            Button(FirstRunCopy.deferralLabel(for: step)) {
                coordinator.skipCurrentStep()
            }
            .buttonStyle(SonnyButtonStyle(tone: .secondary))
            .accessibilityLabel(FirstRunCopy.deferralLabel(for: step))
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SonnyTheme.border)
                .frame(height: 1)
        }
    }

    private func advance() {
        coordinator.refresh(
            isSignedIn: accountModel.isSignedIn,
            screenRecordingGranted: screenAccessModel.screenRecordingGranted,
            accessibilityTrusted: screenAccessModel.accessibilityTrusted
        )
    }
}
