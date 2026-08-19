import Foundation
import Testing
import MacAgentCore
@testable import MacAgent

private final class FakeRelauncher: AppRelaunching {
    private(set) var relaunchCount = 0

    func relaunch() {
        relaunchCount += 1
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
    func relaunchNowDrivesTheRelauncherSeam() {
        let relauncher = FakeRelauncher()
        let model = ScreenAccessOnboardingModel(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: false, screenRecordingGranted: false),
            relauncher: relauncher,
            settingsOpener: { _ in }
        )

        model.relaunchNow()

        #expect(relauncher.relaunchCount == 1)
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
