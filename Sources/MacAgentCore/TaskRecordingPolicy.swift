import Foundation

/// Whether a run leaves a record of itself — the local half of "Don't save this task".
///
/// **The name is the mechanism, not decoration** (founder, 2026-08-16, on SONNY-14). The feature is
/// not called Incognito, because incognito borrows a promise from browsers that this cannot keep:
/// files still get created, apps still open, and the command still goes to the model provider. The
/// usual remedy for a name that over-promises is a clarifying sentence, and the 2026-08-14 decision
/// forbids exactly that sentence — so the name was narrowed until none is needed. "Don't save this
/// task" promises what this does and nothing more. Do not reintroduce the word "incognito" in any
/// user-facing string.
///
/// **What it suppresses is a rule, not a list.** `allowsWriting(to:)` reads `LocalStore.kind`, so
/// the reach is defined by the classification SONNY-115 built rather than by whichever leak someone
/// happened to remember. That matters because the writing sites live in five separate layers, and a
/// boolean checked at each of them is precisely how this feature would quietly stop being true.
///
/// The classification-enumerating test is what actually defines done here — see
/// `TaskRecordingPolicyTests`. A trace store added later is covered by it the day it is classified,
/// whether or not anyone remembered to guard its call site.
public enum TaskRecordingPolicy: Equatable, Sendable, CaseIterable {
    /// Every store a task writes to is written normally. The default, and what every run that does
    /// not opt out gets.
    case record

    /// Traces are withheld for this one run. Artifacts are not.
    case suppressTraces

    /// Whether this run may write to `store`.
    ///
    /// The inner switch is exhaustive over `LocalStoreKind` on purpose: a fourth kind cannot be
    /// added without someone deciding, here, whether "Don't save this task" withholds it.
    public func allowsWriting(to store: LocalStore) -> Bool {
        switch self {
        case .record:
            return true
        case .suppressTraces:
            switch store.kind {
            case .trace:
                // An incidental record of what happened. This is the whole feature.
                return false
            case .artifact:
                // The thing the user actually asked for. Someone who says "save this as a routine"
                // with the switch on still wants the routine — and the switch never promised
                // otherwise, since it cannot hide a task's effects and a saved routine is an effect.
                return true
            case .notWrittenByTasks:
                // No task writes here, so there is nothing to withhold. Returning `true` is the
                // honest answer to a question that never gets asked rather than a decision.
                return true
            }
        }
    }

    /// Convenience for the many call sites that only ever ask about one store.
    public var suppressesTraces: Bool {
        self == .suppressTraces
    }
}
