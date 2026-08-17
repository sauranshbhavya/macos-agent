import Foundation
@testable import MacAgentCore

/// The one screen-permission stub for this target (SONNY-123).
///
/// **Why it exists.** `AgentActionExecutor.init` defaults its `permissionReadinessService` to a live
/// `PermissionReadinessService`, which defaults its checker to `SystemScreenCapturePermissionChecker`
/// — real `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()` calls. Nothing in the suite
/// injected anything else, so every readiness path answered from whatever this Mac happens to have
/// granted. SONNY-103 was one instance of that going wrong; SONNY-106 section D states the rule
/// generally, on the reasoning that a suite whose result changes with the machine running it cannot
/// be evidence.
///
/// **Why a shared one rather than a fifth private copy.** There were already four hand-rolled
/// `ScreenCapturePermissionChecking` stubs, each private to its own file, and a fifth was the path
/// of least resistance for the next test that needed one — which is exactly what makes a test reach
/// for the live default instead. A stub that is easy to find is the thing that removes the
/// incentive.
///
/// **Grants everything by default, deliberately.** The tests that reach this seam assert on other
/// items entirely (the voice-hotkey copy, titles and counts), so a granted machine is the state they
/// were written against and the one that keeps them meaning what they meant. A test about a refusal
/// says so at its call site.
struct DeterministicScreenPermissions: ScreenCapturePermissionChecking {
    var accessibilityTrusted: Bool = true
    var screenRecordingGranted: Bool = true

    func isAccessibilityTrusted() -> Bool { accessibilityTrusted }
    func requestAccessibilityTrust() -> Bool { accessibilityTrusted }
    func hasScreenRecordingPermission() -> Bool { screenRecordingGranted }
    func requestScreenRecordingPermission() -> Bool { screenRecordingGranted }
}

extension PermissionReadinessService {
    /// A readiness service whose screen answers come from the argument rather than from this Mac.
    ///
    /// **This does not make the service fully deterministic, and the gap is named rather than
    /// implied.** `microphoneStatus()` calls `AVCaptureDevice.authorizationStatus(for: .audio)`
    /// directly (`PermissionReadinessService.swift:106-107`) with no seam to inject — closing that
    /// needs a production change, which SONNY-123 records and this test-only helper cannot do. So a
    /// suite using this still makes one live authorization read; it no longer makes the two
    /// screen-related ones.
    static func deterministic(
        accessibilityTrusted: Bool = true,
        screenRecordingGranted: Bool = true
    ) -> PermissionReadinessService {
        PermissionReadinessService(
            screenPermissionChecker: DeterministicScreenPermissions(
                accessibilityTrusted: accessibilityTrusted,
                screenRecordingGranted: screenRecordingGranted
            )
        )
    }
}
