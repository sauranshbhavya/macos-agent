import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

private final class FakeRelauncher: AppRelaunching {
    private(set) var relaunchCount = 0
    /// What the reopen does. `nil` is the relaunch that worked — which in the real app never
    /// returns, because `DefaultAppRelauncher` ends in `NSApp.terminate`.
    var reopenFailure: (any Error)?

    func relaunch() async throws {
        relaunchCount += 1
        if let reopenFailure {
            throw reopenFailure
        }
    }
}

/// Presses the button a second time from inside the first press's own reopen — the second press
/// lands while the first is still in flight, which is the whole of what a double-click is here.
///
/// **Driven from inside `relaunch()` rather than from a second `Task`, deliberately.** Two tasks
/// racing would need a wall-clock window to make the overlap happen, which `CLAUDE.md` records as
/// the shape that manufactures mutation kills; this arranges the overlap by construction and reads
/// the same property. `pending` fires once and is cleared before it runs, so a build with no guard
/// counts two presses and returns rather than recursing forever.
@MainActor
private final class ReentrantRelauncher: AppRelaunching {
    private(set) var relaunchCount = 0
    var pending: (() async -> Void)?

    func relaunch() async throws {
        relaunchCount += 1
        let secondPress = pending
        pending = nil
        await secondPress?()
    }
}

@MainActor
struct ScreenAccessOnboardingTests {
    @Test
    func initialStateReadsTheLiveGrants() {
        let model = ScreenAccessOnboardingModel(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: false, screenRecordingGranted: true),
            relauncher: FakeRelauncher(),
            settingsOpener: { _ in }
        )
        #expect(model.screenRecordingGranted)
        #expect(!model.accessibilityTrusted)
        #expect(!model.screenRecordingRequestedThisLaunch)
        #expect(!model.needsRelaunchGuidance)
        #expect(!model.allGranted)
    }

    @Test
    func requestingScreenRecordingRegistersAndRevealsRelaunchGuidance() {
        let checker = DeterministicScreenPermissions(accessibilityTrusted: false, screenRecordingGranted: false)
        let model = ScreenAccessOnboardingModel(
            permissionChecker: checker,
            relauncher: FakeRelauncher(),
            settingsOpener: { _ in }
        )

        model.requestScreenRecording()

        #expect(checker.screenRecordingRequestCount == 1)
        #expect(model.screenRecordingRequestedThisLaunch)
        // The grant cannot flip in this process — guidance, not a granted state, is the honest UI.
        #expect(!model.screenRecordingGranted)
        #expect(model.needsRelaunchGuidance)
    }

    @Test
    func requestingScreenRecordingWhenAlreadyGrantedDoesNothing() {
        let checker = DeterministicScreenPermissions(accessibilityTrusted: false, screenRecordingGranted: true)
        let model = ScreenAccessOnboardingModel(
            permissionChecker: checker,
            relauncher: FakeRelauncher(),
            settingsOpener: { _ in }
        )

        model.requestScreenRecording()

        #expect(checker.screenRecordingRequestCount == 0)
        #expect(!model.screenRecordingRequestedThisLaunch)
        #expect(!model.needsRelaunchGuidance)
    }

    @Test
    func guidanceClearsWhenAFreshProcessSeesTheGrant() {
        // Simulates the post-relaunch confirm step: the checker now answers true and a refresh
        // (the modal re-preflights on appear) lands on the confirmed state.
        let checker = DeterministicScreenPermissions(accessibilityTrusted: true, screenRecordingGranted: false)
        let model = ScreenAccessOnboardingModel(
            permissionChecker: checker,
            relauncher: FakeRelauncher(),
            settingsOpener: { _ in }
        )
        model.requestScreenRecording()
        #expect(model.needsRelaunchGuidance)

        checker.screenRecordingGranted = true
        model.refresh()

        #expect(model.screenRecordingGranted)
        #expect(!model.needsRelaunchGuidance)
        #expect(model.allGranted)
    }

    @Test
    func accessibilityGrantLandsImmediatelyWithoutARelaunchStep() {
        // The asymmetry the model owns: Accessibility takes effect in-process, so a granted
        // request is visible on the very next read with no guidance step anywhere.
        let checker = DeterministicScreenPermissions(
            accessibilityTrusted: false,
            screenRecordingGranted: true,
            accessibilityGrantsOnRequest: true
        )
        let model = ScreenAccessOnboardingModel(
            permissionChecker: checker,
            relauncher: FakeRelauncher(),
            settingsOpener: { _ in }
        )

        model.requestAccessibility()

        #expect(checker.accessibilityRequestCount == 1)
        #expect(model.accessibilityTrusted)
        #expect(!model.needsRelaunchGuidance)
        #expect(model.allGranted)
    }

    @Test
    func requestingAccessibilityWhenAlreadyTrustedDoesNothing() {
        let checker = DeterministicScreenPermissions(accessibilityTrusted: true, screenRecordingGranted: false)
        let model = ScreenAccessOnboardingModel(
            permissionChecker: checker,
            relauncher: FakeRelauncher(),
            settingsOpener: { _ in }
        )

        model.requestAccessibility()

        #expect(checker.accessibilityRequestCount == 0)
    }

    @Test
    func relaunchNowDrivesTheRelauncherSeam() async {
        let relauncher = FakeRelauncher()
        let model = ScreenAccessOnboardingModel(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: false, screenRecordingGranted: false),
            relauncher: relauncher,
            settingsOpener: { _ in }
        )

        await model.relaunchNow()

        #expect(relauncher.relaunchCount == 1)
        // The reopen worked, so nothing is said. In the real app this line is unreachable.
        #expect(!model.relaunchFailed)
    }

    // MARK: - The relaunch that cannot come back (SONNY-348)

    /// **The failure this ticket exists for.** `DefaultAppRelauncher` used to terminate whatever
    /// happened to the reopen, so a bundle that could not be started left the user with no Sonny at
    /// all — on the first-run path, seconds after they granted it a screen-recording permission.
    /// The founders' answer (2026-08-30) was to stay running and say so, so the two things asserted
    /// here are that the app is still in the state it was in, and that it is now saying the one
    /// functional sentence it is allowed to say.
    @Test
    func aReopenThatFailedLeavesTheAppRunningAndSaysSo() async {
        let relauncher = FakeRelauncher()
        relauncher.reopenFailure = AppRelaunchFailure.reopenRefused(status: 1)
        let model = ScreenAccessOnboardingModel(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: false, screenRecordingGranted: false),
            relauncher: relauncher,
            settingsOpener: { _ in }
        )
        // Before anything has been attempted the guidance says nothing (F4). Flipping the property's
        // initial value survived the whole suite: every user reaching this step would be told the
        // restart failed before touching the button, which is the app lying about a restart at the
        // one moment this ticket exists to stop it. Nothing else here can see the default —
        // `relaunchNow()` clears the flag on entry.
        #expect(!model.relaunchFailed)
        model.requestScreenRecording()
        #expect(model.needsRelaunchGuidance)
        #expect(!model.relaunchFailed)

        await model.relaunchNow()

        #expect(relauncher.relaunchCount == 1)
        #expect(model.relaunchFailed)
        // Nothing else moved: the guidance is still the step being shown, with the button still on
        // it, so the user can try again rather than being left somewhere new.
        #expect(model.needsRelaunchGuidance)
        #expect(model.screenRecordingRequestedThisLaunch)
        #expect(!model.screenRecordingGranted)
    }

    /// A retry that works must not leave the last failure on screen. The clear happens before the
    /// attempt rather than after it, because after a reopen that worked there is no "after".
    @Test
    func aRetryThatReopensClearsTheFailureItLeftOnScreen() async {
        let relauncher = FakeRelauncher()
        relauncher.reopenFailure = AppRelaunchFailure.reopenRefused(status: 1)
        let model = ScreenAccessOnboardingModel(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: false, screenRecordingGranted: false),
            relauncher: relauncher,
            settingsOpener: { _ in }
        )

        await model.relaunchNow()
        #expect(model.relaunchFailed)

        relauncher.reopenFailure = nil
        await model.relaunchNow()

        #expect(relauncher.relaunchCount == 2)
        #expect(!model.relaunchFailed)
    }

    /// **A second press while the first reopen is still running is refused** (PR #180's review, F7).
    /// Before this branch the relaunch reached `NSApp.terminate` synchronously and there was no
    /// window to press into; the async seam opens one, and `/usr/bin/open -n` starts a *new*
    /// instance every time it is called, so two presses would leave two Sonnys over one Keychain and
    /// one set of encrypted stores.
    @Test
    func asecondPressWhileTheReopenIsStillRunningIsRefused() async {
        let relauncher = ReentrantRelauncher()
        let model = ScreenAccessOnboardingModel(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: false, screenRecordingGranted: false),
            relauncher: relauncher,
            settingsOpener: { _ in }
        )
        #expect(!model.isRelaunching)
        relauncher.pending = { await model.relaunchNow() }

        await model.relaunchNow()

        #expect(relauncher.relaunchCount == 1, "the second press reopened the bundle a second time")
        // And the window closes behind it, so a real retry after the reopen has finished is not
        // refused — which is the property the test below drives twice.
        #expect(!model.isRelaunching)
    }

    /// **What no runtime assertion in this process can reach**, pinned as source instead: driving
    /// `DefaultAppRelauncher` would terminate the test process rather than fail, and there is no
    /// SwiftUI harness here to render the guidance. Two properties, both of them the whole fix:
    /// the terminate sits downstream of a checked reopen, and the sentence is gated on the failure
    /// rather than always on screen.
    @Test
    func theRealRelauncherChecksTheReopenBeforeTerminatingAndTheGuidanceSaysSoOnlyOnFailure() throws {
        let source = try MacAgentSource.read("ScreenAccessOnboarding.swift")
        let relaunchBody = try MacAgentSource.braceBlock(of: source, openedBy: "func relaunch() async throws {")

        // The discarded failure is gone, and the reopen's own exit status is what decides.
        #expect(MacAgentSource.count(of: "try?", inText: relaunchBody) == 0)
        #expect(MacAgentSource.count(of: "AsyncProcessRunner.run", inText: relaunchBody) == 1)
        #expect(MacAgentSource.count(of: "NSApp.terminate(nil)", inText: relaunchBody) == 1)
        // **The success condition itself, by value** (PR #180's review, F1). Everything else in this
        // block is satisfied by an inverted comparison: `== 0` flipped to `!= 0` keeps every token
        // above exactly where it is, and it ships this ticket's original defect — a refused reopen
        // falls through to the terminate — with a new one on top, because a reopen that worked then
        // throws and the app says "Couldn't restart Sonny." on every successful relaunch. `>= 0` is
        // the same hole from the other side: every exit code and every signal number is
        // non-negative, so the guard can never fire. Both survived the whole suite until this line.
        #expect(MacAgentSource.count(of: "guard reopen.terminationStatus == 0 else {", inText: relaunchBody) == 1)
        // **The mechanism, which no behavioural test in this repository can see** (F5): a fake
        // relauncher is what every other test here injects, so `/usr/bin/open` and its `-n` are
        // reachable only as source. Dropping `-n` makes the relaunch reuse the running instance
        // instead of starting a new one, which is the entire point of the flag on a TCC relaunch.
        #expect(MacAgentSource.count(of: "\"/usr/bin/open\"", inText: relaunchBody) == 1)
        #expect(MacAgentSource.count(of: "[\"-n\", bundleURL.path]", inText: relaunchBody) == 1)
        // Ordering, not mere presence: the refusal is raised between the reopen and the terminate,
        // so a terminate moved above the check fails this by losing its anchor.
        let betweenReopenAndTerminate = try MacAgentSource.region(
            of: relaunchBody,
            from: "AsyncProcessRunner.run",
            to: "NSApp.terminate(nil)"
        )
        #expect(betweenReopenAndTerminate.contains("throw AppRelaunchFailure.reopenRefused"))

        let guidance = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "private var relaunchGuidance: some View {"
        )
        // Pinned whole, by value. The founders' decision (2026-08-30) is that this is a functional
        // label and not an explanation — "nothing about why or what to do next" — and the sentence
        // the ticket itself suggested, "Couldn't restart Sonny. Quit and open it again.", is the
        // thing that decision ruled out. A scan for the first half alone accepts it back.
        #expect(MacAgentSource.count(of: "Text(\"Couldn't restart Sonny.\")", inText: guidance) == 1)
        // **And it is on screen only on the failure, said directly rather than through `topLevel`**
        // (F2). This assertion used to read `count(… inText: topLevel(of: guidance)) == 0`, and it
        // was vacuous: this block's whole content is one `VStack { … }`, so `topLevel` strips every
        // view in it at every depth and searches a string that can never contain the sentence
        // wherever the sentence sits. A mutant that left `if model.relaunchFailed { }` in place and
        // moved the `Text` out beside it — the sentence rendered unconditionally — passed all three
        // of the old assertions and the whole suite. The pair below needs no knowledge of the
        // container: the sentence appears exactly once in the block, and that once is inside the
        // conditional, so it can be nowhere else.
        let failureBranch = try MacAgentSource.braceBlock(of: guidance, openedBy: "if model.relaunchFailed {")
        #expect(MacAgentSource.count(of: "Text(\"Couldn't restart Sonny.\")", inText: failureBranch) == 1)
        #expect(MacAgentSource.count(of: "Couldn't restart Sonny.", inText: guidance) == 1)
        // **The button is wired to the thing this ticket is about** (F3). Nothing in this repository
        // scanned this block before the branch, so a Relaunch button wired to `Task { }` did nothing
        // at all on the first-run path with the whole suite green. Pre-existing rather than a
        // regression, and this is the first scan that can hold it.
        #expect(MacAgentSource.count(of: "Task { await model.relaunchNow() }", inText: guidance) == 1)
        // And the press cannot be repeated while the reopen it started is still running (F7).
        #expect(MacAgentSource.count(of: ".disabled(model.isRelaunching)", inText: guidance) == 1)
    }

    @Test
    func settingsShortcutsOpenTheRightPrivacyPanes() {
        var opened: [URL] = []
        let model = ScreenAccessOnboardingModel(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: false, screenRecordingGranted: false),
            relauncher: FakeRelauncher(),
            settingsOpener: { opened.append($0) }
        )

        model.openScreenRecordingSettings()
        model.openAccessibilitySettings()

        #expect(opened == [
            ScreenAccessOnboardingModel.screenRecordingSettingsURL,
            ScreenAccessOnboardingModel.accessibilitySettingsURL
        ])
        #expect(opened[0].absoluteString.contains("Privacy_ScreenCapture"))
        #expect(opened[1].absoluteString.contains("Privacy_Accessibility"))
    }
}
