import Foundation
import MacAgentCore

/// The one screen-permission stub for this target (SONNY-123).
///
/// **The twin of `Tests/MacAgentCoreTests/DeterministicPermissions.swift`, deliberately.** SwiftPM
/// gives a source file to exactly one target, and a test target cannot depend on another test
/// target, so a single file shared by both is not available without adding a test-support target to
/// `Package.swift` — a build-graph change this ticket was not scoped to make, and one the founder
/// would decide rather than a session. One shared stub per target is the most consolidation there
/// is short of that; it replaced the three private stubs this target used to carry
/// (`FakePermissionChecker`, `RevocablePermissions`, `GrantedPermissions`). Keep the two files in
/// step: they are the same type, and a behaviour added to one belongs in the other.
///
/// The microphone half of the seam lives only in the core copy, because
/// `PermissionReadinessService.currentStatus(hasAPIKey:hotKeyReady:)` — the only thing that reads
/// it — is unreachable from this target's tests. `AgentViewModel.refreshPermissions()` is called
/// from `CommandCenterView` and `AppDelegate` only, and no test here builds a
/// `.showPermissionReadiness` plan.
///
/// **Grants everything by default, deliberately.** A test about a refusal says so at its call site.
final class DeterministicScreenPermissions: ScreenCapturePermissionChecking, @unchecked Sendable {
    var accessibilityTrusted: Bool
    var screenRecordingGranted: Bool

    /// When true, `requestAccessibilityTrust()` flips the grant — which is what the live
    /// Accessibility grant does: it takes effect in-process, with no relaunch. There is deliberately
    /// no matching flag for Screen Recording, because that grant never lands in the process that
    /// asked for it, and a stub that let it would let a test pin behaviour the product cannot have.
    /// `ScreenAccessOnboardingModel`'s whole relaunch-guidance step exists for that asymmetry.
    var accessibilityGrantsOnRequest: Bool

    private(set) var accessibilityRequestCount = 0
    private(set) var screenRecordingRequestCount = 0

    init(
        accessibilityTrusted: Bool = true,
        screenRecordingGranted: Bool = true,
        accessibilityGrantsOnRequest: Bool = false
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityGrantsOnRequest = accessibilityGrantsOnRequest
    }

    func hasScreenRecordingPermission() -> Bool { screenRecordingGranted }

    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        screenRecordingRequestCount += 1
        return screenRecordingGranted
    }

    func isAccessibilityTrusted() -> Bool { accessibilityTrusted }

    @discardableResult
    func requestAccessibilityTrust() -> Bool {
        accessibilityRequestCount += 1
        if accessibilityGrantsOnRequest {
            accessibilityTrusted = true
        }
        return accessibilityTrusted
    }
}
