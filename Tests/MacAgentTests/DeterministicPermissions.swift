import Foundation
import MacAgentCore

/// The one screen-permission stub for this target (SONNY-123).
///
/// **The twin of `Tests/MacAgentCoreTests/DeterministicPermissions.swift`, deliberately.** Both test
/// targets declare an explicit `path:`, so a source file belongs to exactly one of them and a single
/// shared file needs a `Package.swift` edit — a build-graph change this ticket was not scoped to
/// make, and the founder's call rather than a session's. One shared stub per target is the most
/// consolidation available without it; it replaced the three private stubs this target used to carry
/// (`FakePermissionChecker`, `RevocablePermissions`, `GrantedPermissions`).
///
/// **A correction, because the first version of this comment justified the duplication with
/// something false** (PR #72 F2): it said a test target cannot depend on another test target. It
/// can. Building a minimal package on this repository's own settings — `swift-tools-version: 6.0`,
/// `platforms: [.macOS(.v14)]` — with `.testTarget(name: "BTests", dependencies: ["Lib", "ATests"])`
/// compiles, `import ATests` resolves, and a B test calling an A helper links and passes. So the
/// cheap option is real: one line adding `"MacAgentCoreTests"` to this target's dependencies, plus
/// making the stub `public`. A dedicated test-support target is probably still the better design,
/// but the founder should get that choice on true premises.
///
/// Until then, keep the two files in step: they are the same type, and a behaviour added to one
/// belongs in the other. `TwinnedTestSupportTests` is what makes that a mechanism rather than a
/// request — drift in the class body fails the suite.
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
