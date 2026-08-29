import AVFoundation
import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// **The microphone row answers from its injected checker, not from this Mac** (SONNY-123).
///
/// Before this, `microphoneStatus()` called `AVCaptureDevice.authorizationStatus(for: .audio)`
/// directly, with no seam to inject, so every test that reached `currentStatus` made a live
/// authorization read and the row it produced was a fact about the machine running the suite.
/// SONNY-106 section D forbids that on the reasoning that a suite whose result changes with the
/// machine cannot be evidence.
@Suite
struct PermissionReadinessMicrophoneTests {
    private func microphoneRow(_ status: AVAuthorizationStatus) throws -> PermissionReadinessItem {
        let items = PermissionReadinessService
            .deterministic(microphoneStatus: status)
            .currentStatus(modelAccess: .signedIn, hotKeyReady: true)
        return try #require(items.first { $0.id == "microphone" })
    }

    /// **This one does detect the seam being ignored, on every machine — and that is a stronger
    /// claim than its screen-side sibling can make, for a structural reason worth stating.**
    ///
    /// `permissionReadinessAnswersFromTheInjectedCheckerRatherThanThisMac` cannot tell an injected
    /// `true` from a machine that genuinely has the grant, because the screen seam vends a boolean
    /// and a machine is always in one of the two states a test can ask for. The microphone seam
    /// vends four cases mapping to three distinct rows, and this test asks for all four in one run.
    /// A service that ignored its checker would answer every one of them with the single live
    /// status, and no single status satisfies more than two of these four expectations — `.denied`
    /// and `.restricted` share a row, and nothing else shares one. So at least two assertions fail
    /// whatever this Mac has granted, including a machine in a state macOS does not currently
    /// produce: an unrecognized future case yields "Microphone status is unknown." and satisfies
    /// none of the four.
    ///
    /// Proved rather than argued: reverting `microphoneStatus()` to the direct `AVCaptureDevice`
    /// call is a mutant this test kills.
    ///
    /// **What it still cannot do, and a correction worth keeping.** The first draft of this
    /// paragraph claimed that `deterministic(microphoneStatus:)` substituting a live checker would
    /// survive, by the same inheritance-not-detection argument the screen-side pin records. The
    /// mutation disproved it: that mutant makes all four expectations here answer from one live
    /// status, and it dies. Ignoring an argument and defaulting an argument are different mutations,
    /// and only running both told them apart.
    ///
    /// What genuinely is not detectable from inside a test is a *fixture's* readiness default being
    /// reverted to a live service — `makeExecutor`'s and `VisionTestContext`'s, mutated to
    /// `PermissionReadinessService()`, both left the whole suite green. No assertion can catch that,
    /// because the deterministic default is a state a real Mac can also be in. That gap is closed in
    /// the source instead, by `LivePermissionCheckerScanTests`, and those two mutants die against
    /// it.
    @Test
    func theMicrophoneRowAnswersFromTheInjectedStatusRatherThanThisMac() throws {
        let authorized = try microphoneRow(.authorized)
        #expect(authorized.state == .ready)
        #expect(authorized.detail == "Voice input is authorized.")

        let denied = try microphoneRow(.denied)
        #expect(denied.state == .needsAction)
        #expect(denied.detail == "Enable microphone access for the launcher in System Settings.")

        // Distinct from `.denied` in AVFoundation and deliberately not distinct here: a restriction
        // the user cannot lift still leaves them looking at System Settings, and a separate sentence
        // would only be a longer way to say the same thing.
        let restricted = try microphoneRow(.restricted)
        #expect(restricted.state == .needsAction)
        #expect(restricted.detail == "Enable microphone access for the launcher in System Settings.")

        // `.unknown`, not `.needsAction`: nothing has been refused yet, and a readiness row that
        // said "needs action" before the user has ever been asked would be inventing a problem.
        let notDetermined = try microphoneRow(.notDetermined)
        #expect(notDetermined.state == .unknown)
        #expect(notDetermined.detail == "Sonny will ask for microphone access the first time you speak.")
    }

    /// The row is present and named, whatever the status — the thing every readiness surface indexes
    /// by. A `currentStatus` that dropped the row entirely would leave the assertions above vacuous
    /// through `#require`, which is a failure rather than a pass, but this pins the count directly
    /// so the reason a run went red is legible.
    @Test
    func exactlyOneMicrophoneRowIsPublishedForEveryStatus() throws {
        for status in [AVAuthorizationStatus.authorized, .denied, .restricted, .notDetermined] {
            let items = PermissionReadinessService
                .deterministic(microphoneStatus: status)
                .currentStatus(modelAccess: .signedIn, hotKeyReady: true)
            #expect(items.filter { $0.id == "microphone" }.count == 1)
            #expect(items.first { $0.id == "microphone" }?.title == "Microphone")
        }
    }
}
