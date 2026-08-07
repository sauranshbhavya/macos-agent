import Foundation

/// Whether the task being assessed is bound to a workspace, and to which one.
///
/// Two cases rather than `WorkspaceScope?` so that "no workspace is bound" is a value a caller has
/// to *write*, not one it can forget. `AgentActionExecutor.assessRisk(plan:scope:)` takes this
/// non-optional and non-defaulted for the reason `.claude/rules/macagentcore-conventions.md`
/// already records for the three nested-plan closures: a defaulted parameter is how a check
/// silently stops running, and that failure is invisible precisely because everything still
/// compiles and every existing test still passes.
public enum TaskWorkspaceScope: Equatable, Sendable {
    /// No workspace is bound. Assessment is byte-identical to what it was before scope existed —
    /// no findings, no scope escalations, and a `nil` roll-up.
    case unscoped
    /// The task is bound to this workspace; every resource its plan touches is compared against it.
    case scoped(WorkspaceScope)

    /// The bound scope, or `nil` when unscoped. Deliberately not public: callers outside this
    /// module should be choosing a case, not unwrapping one.
    var workspaceScope: WorkspaceScope? {
        switch self {
        case .unscoped:
            return nil
        case .scoped(let scope):
            return scope
        }
    }
}
