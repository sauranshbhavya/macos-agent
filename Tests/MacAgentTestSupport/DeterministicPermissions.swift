import AVFoundation
import Foundation
import MacAgentCore

/// The one permission stub for the whole suite (SONNY-123, consolidated by SONNY-172).
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
/// **Why one shared stub rather than a private copy per file.** There were six conforming types
/// across the two test targets, five of them private to a single file, and a seventh was the path of
/// least resistance for the next test that needed one — which is exactly what makes a test reach for
/// the live default instead. A stub that is easy to find is the thing that removes the incentive.
///
/// **Why this file lives in a target of its own.** SONNY-123 left it twinned — one copy per test
/// target, kept in step by hand — on the stated reason that a source file belongs to exactly one
/// target *and* that a test target cannot depend on another test target. The first half is true; the
/// second was not. SONNY-172 built the probe: a `.testTarget` may name another `.testTarget` in its
/// `dependencies`, it compiles, the `import` resolves, and it passes. That made a shared target the
/// cheap option, and `MacAgentTestSupport` is it. `Package.swift` records why that target is a
/// `.testTarget` rather than a plain one.
///
/// Everything here is `public` for that reason and no other: `MacAgentCoreTests` and `MacAgentTests`
/// are separate modules, and only a module's public surface crosses into them.
///
/// **Grants everything by default, deliberately.** The tests that reach this seam assert on other
/// items entirely (the voice-hotkey copy, titles and counts), so a granted machine is the state they
/// were written against and the one that keeps them meaning what they meant. A test about a refusal
/// says so at its call site.
public final class DeterministicScreenPermissions: ScreenCapturePermissionChecking, @unchecked Sendable {
    public var accessibilityTrusted: Bool
    public var screenRecordingGranted: Bool

    /// When true, `requestAccessibilityTrust()` flips the grant — which is what the live
    /// Accessibility grant does: it takes effect in-process, with no relaunch. There is deliberately
    /// no matching flag for Screen Recording, because that grant never lands in the process that
    /// asked for it, and a stub that let it would let a test pin behaviour the product cannot have.
    /// `ScreenAccessOnboardingModel`'s whole relaunch-guidance step exists for that asymmetry.
    public var accessibilityGrantsOnRequest: Bool

    public private(set) var accessibilityRequestCount = 0
    public private(set) var screenRecordingRequestCount = 0

    public init(
        accessibilityTrusted: Bool = true,
        screenRecordingGranted: Bool = true,
        accessibilityGrantsOnRequest: Bool = false
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityGrantsOnRequest = accessibilityGrantsOnRequest
    }

    public func hasScreenRecordingPermission() -> Bool { screenRecordingGranted }

    @discardableResult
    public func requestScreenRecordingPermission() -> Bool {
        screenRecordingRequestCount += 1
        return screenRecordingGranted
    }

    public func isAccessibilityTrusted() -> Bool { accessibilityTrusted }

    @discardableResult
    public func requestAccessibilityTrust() -> Bool {
        accessibilityRequestCount += 1
        if accessibilityGrantsOnRequest {
            accessibilityTrusted = true
        }
        return accessibilityTrusted
    }
}

/// The microphone half of the same seam, which exists in production only since SONNY-123.
public struct DeterministicMicrophonePermission: MicrophonePermissionChecking {
    public var status: AVAuthorizationStatus = .authorized

    public init(status: AVAuthorizationStatus = .authorized) {
        self.status = status
    }

    public func microphoneAuthorizationStatus() -> AVAuthorizationStatus { status }
}

extension PermissionReadinessService {
    /// A readiness service whose every answer comes from its arguments rather than from this Mac.
    ///
    /// Both seams are covered as of SONNY-123. The earlier version of this helper could only close
    /// the screen half and said so; `microphoneStatus()` now reads an injectable
    /// `MicrophonePermissionChecking` instead of calling `AVCaptureDevice` directly, so a service
    /// built here makes no live authorization read at all.
    public static func deterministic(
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
