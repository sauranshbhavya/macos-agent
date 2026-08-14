import Foundation
import Testing
import MacAgentCore
@testable import MacAgent

private final class FakePermissionChecker: ScreenCapturePermissionChecking, @unchecked Sendable {
    var screenRecordingGranted: Bool
    var accessibilityTrusted: Bool
    /// When true, a request call flips the corresponding grant — Accessibility behaves this way
    /// live (the grant takes effect immediately); Screen Recording never does (relaunch-gated).
    var grantsOnRequest: Bool
    private(set) var screenRecordingRequestCount = 0
    private(set) var accessibilityRequestCount = 0

    init(screenRecordingGranted: Bool, accessibilityTrusted: Bool, grantsOnRequest: Bool = false) {
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityTrusted = accessibilityTrusted
        self.grantsOnRequest = grantsOnRequest
    }

    func hasScreenRecordingPermission() -> Bool { screenRecordingGranted }

    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        screenRecordingRequestCount += 1
        // Deliberately never flips `screenRecordingGranted`, matching the live behavior the
        // whole relaunch-guidance step exists for.
        return screenRecordingGranted
    }

    func isAccessibilityTrusted() -> Bool { accessibilityTrusted }

    @discardableResult
    func requestAccessibilityTrust() -> Bool {
        accessibilityRequestCount += 1
        if grantsOnRequest {
            accessibilityTrusted = true
        }
        return accessibilityTrusted
    }
}

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
            permissionChecker: FakePermissionChecker(screenRecordingGranted: true, accessibilityTrusted: false),
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
        let checker = FakePermissionChecker(screenRecordingGranted: false, accessibilityTrusted: false)
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
        let checker = FakePermissionChecker(screenRecordingGranted: true, accessibilityTrusted: false)
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
        let checker = FakePermissionChecker(screenRecordingGranted: false, accessibilityTrusted: true)
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
        let checker = FakePermissionChecker(
            screenRecordingGranted: true,
            accessibilityTrusted: false,
            grantsOnRequest: true
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
        let checker = FakePermissionChecker(screenRecordingGranted: false, accessibilityTrusted: true)
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
            permissionChecker: FakePermissionChecker(screenRecordingGranted: false, accessibilityTrusted: false),
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
            permissionChecker: FakePermissionChecker(screenRecordingGranted: false, accessibilityTrusted: false),
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
