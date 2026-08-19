import Foundation
import Testing

/// **The premise a forced-filesystem-failure test needs: a process that permission bits apply to**
/// (SONNY-123 finding 2).
///
/// Four tests in this repository force a write or a delete to fail by `chmod`-ing a directory to
/// `0o500` and then requiring the operation inside it to fail. Root bypasses directory permission
/// bits entirely, so under a root-running test process that premise silently stops holding. This is
/// process identity deciding a test result, which is machine state in exactly the sense SONNY-106
/// section D forbids. It does not affect the founder's Mac or a normal agent session; it affects any
/// container or CI runner that runs tests as root.
///
/// **What it actually does when the premise fails, enumerated rather than assumed.** Not a
/// flattering green. Each of the four asserts on the *consequence* of the failure — a file left
/// unrewritten, a failed path reported by name, a history row that survived — so an operation that
/// unexpectedly succeeds makes the test fail. The damage is a red suite naming a defect that is not
/// there, on a machine where nothing is wrong. That is the opposite direction from SONNY-103, which
/// failed flatteringly, and it is still machine state deciding the result.
///
/// **Why a skip rather than a failure root cannot bypass.** Forcing the write to fail for root too
/// is possible — the `uchg` flag blocks even root until it is cleared — but it changes what each
/// test pins (an immutable file, not a read-only directory), needs cleanup that can itself fail, and
/// leaves undeletable litter in the temp directory when it does. What these tests need is an
/// unprivileged process. Saying so is smaller, and truer, than simulating a different failure.
///
/// **What cannot be shown from the machine that runs this.** Nothing here executes as root, so the
/// skip is reasoned from `chmod(2)`'s documented root bypass rather than observed. On an
/// unprivileged process the trait is a no-op by construction and all four tests run exactly as they
/// did before it existed — which is what an unchanged suite count demonstrates, and the only half of
/// this that a non-root run can demonstrate at all.
///
/// Twinned with `Tests/MacAgentCoreTests/UnprivilegedProcess.swift` because SwiftPM gives a source file to exactly one target. Keep them in
/// step.
extension Trait where Self == ConditionTrait {
    static var requiresUnprivilegedProcess: Self {
        .enabled(
            if: geteuid() != 0,
            "Forces a filesystem failure with directory permission bits, which root bypasses."
        )
    }
}
