import Foundation

/// The rule for a step that takes whatever the unit before it produced.
///
/// **One home for a predicate two callers need, because the two arrive at it from opposite ends.**
/// `AgentActionExecutor.executeChain` carries a path from each finished unit to the next and applies
/// this to the segment it is about to run. A *resumed* run (row 13, SONNY-210) has the other half of
/// the same problem: the earlier attempt's file is named nowhere in the steps that are left, so the
/// remainder has to be given it before it is dispatched. Two copies of "which steps consume a
/// previous artifact" is exactly the shape this repository consolidates — one copy gets a new
/// operation added to it and the other does not.
///
/// **Why a resumed run bakes the path into the plan rather than handing it to the executor.**
/// Threading it as an execution parameter was tried first and is wrong, and the reason is an
/// ordering rather than a preference: `AgentRunner.prepare` runs `AgentActionExecutor.prepare`, which
/// previews every step — and previewing a bare `open_generated_artifact` throws
/// "needs outputPath or a previous chained artifact" long before anything reaches `execute`. A value
/// supplied at execution time cannot be seen by the gate that runs first. So the plan that is
/// dispatched carries the path, and the assessment, the approval prompt and the run all see the same
/// complete plan — which is also what keeps a resumed run's risk assessment honest, since the file it
/// is about to open is part of what is being assessed.
public enum ChainedArtifactCarry {
    /// Whether this step would take the previous unit's output.
    ///
    /// Two operations, and both path fields empty: a step that names its own `outputPath` or
    /// `inputPath` is already satisfied and must not have either overwritten.
    public static func consumesPreviousArtifact(_ step: AgentStep) -> Bool {
        guard [.revealInFinder, .openGeneratedArtifact].contains(step.operation) else {
            return false
        }
        return isBlank(step.outputPath) && isBlank(step.inputPath)
    }

    /// `plan` with `path` written onto its leading step, when that step is one that would take it.
    ///
    /// **The leading step, and that is exactly the same thing as "the first unit" for these two
    /// operations.** `AgentActionExecutor.chainSegments` cuts a plan into maximal runs of one
    /// workflow, and each of these operations is a workflow of its own — so a following step of a
    /// different workflow cuts, and a following step of the *same* operation is a repeat, which also
    /// cuts. Either way the leading step is a segment by itself, which is the shape the executor's
    /// own `steps.count == 1` rule tests for.
    ///
    /// Returns `plan` unchanged for a `nil` path, for an empty plan, and for a leading step that
    /// names its own file — so an ordinary dispatch that calls this is a no-op rather than a special
    /// case somebody has to remember not to make.
    public static func applying(_ path: String?, toLeadingStepOf plan: AgentPlan) -> AgentPlan {
        guard let path,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let first = plan.steps.first,
              consumesPreviousArtifact(first) else {
            return plan
        }
        var resolved = plan
        resolved.steps[0].outputPath = path
        return resolved
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }
}
