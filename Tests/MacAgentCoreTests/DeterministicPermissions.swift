import AVFoundation
import Foundation
@testable import MacAgentCore

/// The one permission stub for this target (SONNY-123).
///
/// **Why it exists.** `AgentActionExecutor.init` defaults its `permissionReadinessService` to a live
/// `PermissionReadinessService`, which defaults its checkers to `SystemScreenCapturePermissionChecker`
/// and `SystemMicrophonePermissionChecker` — real `AXIsProcessTrusted()`,
/// `CGPreflightScreenCaptureAccess()` and `AVCaptureDevice.authorizationStatus(for: .audio)` calls.
/// Nothing in the suite injected anything else, so every readiness path answered from whatever this
/// Mac happens to have granted. SONNY-103 was one instance of that going wrong; SONNY-106 section D
/// states the rule generally, on the reasoning that a suite whose result changes with the machine
/// running it cannot be evidence.
///
/// **Why a shared one rather than another private copy.** There were six conforming types across the
/// two test targets, five of them private to a single file, and a seventh was the path of least
/// resistance for the next test that needed one — which is exactly what makes a test reach for the
/// live default instead. A stub that is easy to find is the thing that removes the incentive.
/// `Tests/MacAgentTests/DeterministicPermissions.swift` is this file's twin: SwiftPM gives a source
/// file to exactly one target, so one shared stub *per target* is the most consolidation available
/// without adding a test-support target to `Package.swift`, which is a build-graph change this
/// ticket was not scoped to make. Keep the two in step.
///
/// **Grants everything by default, deliberately.** The tests that reach this seam assert on other
/// items entirely (the voice-hotkey copy, titles and counts), so a granted machine is the state they
/// were written against and the one that keeps them meaning what they meant. A test about a refusal
/// says so at its call site.
final class DeterministicScreenPermissions: ScreenCapturePermissionChecking, @unchecked Sendable {
    var accessibilityTrusted: Bool
    var screenRecordingGranted: Bool

    /// When true, `requestAccessibilityTrust()` flips the grant — which is what the live
    /// Accessibility grant does: it takes effect in-process, with no relaunch. There is deliberately
    /// no matching flag for Screen Recording, because that grant never lands in the process that
    /// asked for it, and a stub that let it would let a test pin behaviour the product cannot have.
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

/// The microphone half of the same seam, which exists in production only since SONNY-123.
struct DeterministicMicrophonePermission: MicrophonePermissionChecking {
    var status: AVAuthorizationStatus = .authorized

    func microphoneAuthorizationStatus() -> AVAuthorizationStatus { status }
}

extension PermissionReadinessService {
    /// A readiness service whose every answer comes from its arguments rather than from this Mac.
    ///
    /// Both seams are covered as of SONNY-123. The earlier version of this helper could only close
    /// the screen half and said so; `microphoneStatus()` now reads an injectable
    /// `MicrophonePermissionChecking` instead of calling `AVCaptureDevice` directly, so a service
    /// built here makes no live authorization read at all.
    static func deterministic(
        accessibilityTrusted: Bool = true,
        screenRecordingGranted: Bool = true,
        microphoneStatus: AVAuthorizationStatus = .authorized
    ) -> PermissionReadinessService {
        PermissionReadinessService(
            screenPermissionChecker: DeterministicScreenPermissions(
                accessibilityTrusted: accessibilityTrusted,
                screenRecordingGranted: screenRecordingGranted
            ),
            microphonePermissionChecker: DeterministicMicrophonePermission(status: microphoneStatus)
        )
    }
}
