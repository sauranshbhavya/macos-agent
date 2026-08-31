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

/// Stands where `/usr/bin/open` and `NSApp.terminate` stand, so `DefaultAppRelauncher` itself can
/// be driven in a test process at all (SONNY-379). Before the seam it could not be: reaching its
/// terminate ended the test run rather than failing it, which is why every property it has was held
/// by a source scan.
@MainActor
private final class RelaunchCollaborators {
    private(set) var reopenedBundles: [URL] = []
    private(set) var terminateCount = 0
    /// What the reopen reports back. `0` is `open` starting the new instance; anything else is the
    /// refusal SONNY-348 exists for — a bundle that moved, is quarantined, or is unreadable.
    var reopenStatus: Int32 = 0

    func reopen(_ bundleURL: URL) -> Int32 {
        reopenedBundles.append(bundleURL)
        return reopenStatus
    }

    func terminate() {
        terminateCount += 1
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
        relauncher.pending = {
            await model.relaunchNow()
            // **The refused press must not close the window it was refused by** (PR #180's cycle-3
            // review, G1). The shipped order returns from the `guard` *before* the `defer` is
            // registered, so a refused press runs no cleanup. Moving the `defer` above the guard is
            // behaviourally identical for one press and wrong for three: the second press would
            // clear `isRelaunching` on its way out, and a third would proceed while the first
            // reopen is still in flight and run a second `open -n` — the two Sonnys over one
            // Keychain that this guard exists to prevent, reached one press later. Nothing else
            // here can see it, because `pending` fires exactly once and there is no press after
            // the refused one.
            #expect(model.isRelaunching)
        }

        await model.relaunchNow()

        #expect(relauncher.relaunchCount == 1, "the second press reopened the bundle a second time")
        // And the window closes behind it, so a real retry after the reopen has finished is not
        // refused — which is the property the test below drives twice.
        #expect(!model.isRelaunching)
    }

    // MARK: - The real relauncher, driven rather than read (SONNY-379)

    /// **The bundle reopened, then the process ended — in that order and only in that order.**
    /// `DefaultAppRelauncher` used to name `Bundle.main`, `/usr/bin/open` and `NSApp.terminate`
    /// inline, so this decision could only ever be read as text: a test reaching it terminated the
    /// test process rather than failing. With the three collaborators handed in it is behaviour,
    /// and the scans below keep only what a test process still cannot run.
    @Test
    func theRealRelauncherTerminatesOnceTheReopenHasWorked() async throws {
        let collaborators = RelaunchCollaborators()
        let bundle = URL(fileURLWithPath: "/Applications/Sonny.app")
        let relauncher = DefaultAppRelauncher(
            bundleURL: bundle,
            reopen: { collaborators.reopen($0) },
            terminate: { collaborators.terminate() }
        )

        try await relauncher.relaunch()

        #expect(collaborators.reopenedBundles == [bundle])
        #expect(collaborators.terminateCount == 1)
    }

    /// **The failure SONNY-348 exists for, now asserted rather than read off the guard's text.**
    /// A reopen that was refused must leave this process alive and say so — terminating anyway is
    /// what left a user with no Sonny at all, seconds after they granted it a screen-recording
    /// permission. The status travels into the error, so a guard that reported a fixed code would
    /// fail here too.
    @Test
    func theRealRelauncherThrowsAndDoesNotTerminateWhenTheReopenIsRefused() async {
        let collaborators = RelaunchCollaborators()
        collaborators.reopenStatus = 1
        let bundle = URL(fileURLWithPath: "/Applications/Sonny.app")
        let relauncher = DefaultAppRelauncher(
            bundleURL: bundle,
            reopen: { collaborators.reopen($0) },
            terminate: { collaborators.terminate() }
        )

        await #expect(throws: AppRelaunchFailure.reopenRefused(status: 1)) {
            try await relauncher.relaunch()
        }

        #expect(collaborators.reopenedBundles == [bundle])
        #expect(collaborators.terminateCount == 0, "a refused reopen ended the only Sonny there was")
    }

    /// **A bare `swift run` binary has no bundle to reopen**, so it terminates without one — the
    /// case whose inversion is SONNY-348's original symptom for every real user: a packaged app
    /// skipping the reopen and falling straight to the terminate.
    ///
    /// The refusal is armed deliberately. If the `.app` condition were inverted this path would run
    /// the reopen, be refused, and throw — so the test fails on the `try` rather than only on the
    /// recorder, and a reader of the failure sees the reopen that should not have happened.
    @Test
    func theRealRelauncherSkipsTheReopenWhenThereIsNoBundleToReopen() async throws {
        let collaborators = RelaunchCollaborators()
        collaborators.reopenStatus = 1
        let relauncher = DefaultAppRelauncher(
            bundleURL: URL(fileURLWithPath: "/usr/local/bin/MacAgent"),
            reopen: { collaborators.reopen($0) },
            terminate: { collaborators.terminate() }
        )

        try await relauncher.relaunch()

        #expect(collaborators.reopenedBundles.isEmpty)
        #expect(collaborators.terminateCount == 1)
    }

    /// **What no runtime assertion in this process can reach, and the seam does not change it**: a
    /// test that ran this reopen would start a second Sonny over one Keychain and one set of
    /// encrypted stores, and one that ran this terminate would end the test run. So the wiring
    /// `forTheRunningApp()` names stays pinned as source, while the decisions it feeds are the three
    /// tests above.
    @Test
    func theShippingRelaunchersWiringIsOpenMinusNOnTheRunningBundle() throws {
        let source = try MacAgentSource.read("ScreenAccessOnboarding.swift")
        let wiring = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "static func forTheRunningApp() -> DefaultAppRelauncher {"
        )

        // **The mechanism** (SONNY-348's F5, unchanged by the seam). Dropping `-n` makes the
        // relaunch reuse the running instance instead of starting a new one, which is the entire
        // point of the flag on a TCC relaunch — the user would be handed back the same process with
        // the same grant still denied.
        #expect(MacAgentSource.count(of: "\"/usr/bin/open\"", inText: wiring) == 1)
        #expect(MacAgentSource.count(of: "[\"-n\", bundleURL.path]", inText: wiring) == 1)
        // The bundle reopened is the running app's own, and the terminate is the app's own.
        #expect(MacAgentSource.count(of: "Bundle.main.bundleURL", inText: wiring) == 1)
        #expect(MacAgentSource.count(of: "NSApp.terminate(nil)", inText: wiring) == 1)
        // **The discarded failure stays gone.** Not merely the compiler's job: `try?` alone would
        // not type-check here, and `try? … ?? 0` would — reporting a spawn failure as a reopen that
        // worked and terminating on it, which is SONNY-348's defect restored through the seam.
        #expect(MacAgentSource.count(of: "try?", inText: wiring) == 0)
        #expect(MacAgentSource.count(of: "AsyncProcessRunner.run", inText: wiring) == 1)
        // **And the shipping app is handed that wiring rather than a seam pointing at nothing.**
        // This is the hazard a seam introduces and the reason it is scanned: `main.swift` builds the
        // model with no arguments, so this one default line is the whole of what makes a real
        // relaunch real, and a double left here would be invisible to every test in this file.
        #expect(MacAgentSource.count(
            of: "relauncher: any AppRelaunching = DefaultAppRelauncher.forTheRunningApp()",
            inText: source
        ) == 1)
    }

    /// **The guidance's half of the same problem**: this target has no SwiftUI harness, so what the
    /// block says and when it says it are pinned as source.
    @Test
    func theGuidanceSaysTheRestartFailedOnlyOnTheFailure() throws {
        let source = try MacAgentSource.read("ScreenAccessOnboarding.swift")
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
        // (SONNY-348's F2). That assertion used to read `count(… inText: topLevel(of: guidance)) == 0`,
        // and it was vacuous: this block's whole content is one `VStack { … }`, so `topLevel` strips
        // every view in it at every depth and searches a string that can never contain the sentence
        // wherever the sentence sits. A mutant that left `if model.relaunchFailed { }` in place and
        // moved the `Text` out beside it — the sentence rendered unconditionally — passed all three
        // of the old assertions and the whole suite. The pair below needs no knowledge of the
        // container: the sentence appears exactly once in the block, and that once is inside the
        // conditional, so it can be nowhere else.
        let failureBranch = try MacAgentSource.braceBlock(of: guidance, openedBy: "if model.relaunchFailed {")
        #expect(MacAgentSource.count(of: "Text(\"Couldn't restart Sonny.\")", inText: failureBranch) == 1)
        #expect(MacAgentSource.count(of: "Couldn't restart Sonny.", inText: guidance) == 1)
        // **The button is wired to the thing SONNY-348 is about** (F3). Nothing in this repository
        // scanned this block before that branch, so a Relaunch button wired to `Task { }` did
        // nothing at all on the first-run path with the whole suite green.
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
