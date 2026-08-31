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
        model.requestScreenRecording()
        #expect(model.needsRelaunchGuidance)

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
        #expect(MacAgentSource.count(of: "if model.relaunchFailed {", inText: guidance) == 1)
        // And it is not on screen the rest of the time: the sentence sits inside that conditional,
        // not at the guidance block's own top level.
        #expect(MacAgentSource.count(of: "Couldn't restart Sonny.", inText: MacAgentSource.topLevel(of: guidance)) == 0)
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
