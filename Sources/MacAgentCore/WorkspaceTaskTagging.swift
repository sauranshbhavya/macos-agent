import Foundation

/// Narrow task-to-workspace tagging: a task's `CompletedTaskRecord.workspaceName` is set only
/// when it was explicitly dispatched to a workspace, ran a routine that itself opens/creates a
/// workspace, or the raw command contains an explicit "in workspace X" phrase naming a real saved
/// workspace — never on an implicit/ambiguous signal. This is deliberately conservative: no
/// persistent active-workspace concept, no guessing.
public enum WorkspaceTaskTagging {
    public static func resolvedWorkspaceName(
        command: String,
        plan: AgentPlan?,
        routineStore: RoutineStore,
        workspaceStore: WorkspaceStore
    ) -> String? {
        if let plan {
            if let direct = directWorkspaceName(in: plan.steps) {
                return direct
            }
            if let nested = nestedRoutineWorkspaceName(in: plan.steps, routineStore: routineStore) {
                return nested
            }
        }
        return freeTextWorkspaceName(in: command, workspaceStore: workspaceStore)
    }

    /// Data already exists on `AgentStep.workspaceName` for the open/create-workspace operations —
    /// this just reads it, rather than re-deriving anything.
    private static func directWorkspaceName(in steps: [AgentStep]) -> String? {
        steps.compactMap(\.workspaceName).first
    }

    /// A routine's own saved steps are ground truth for what it does — more reliable than
    /// inferring from command text — but they aren't visible on `plan.steps` for a `run_routine`
    /// step (only the routine's name is), so this resolves and scans them explicitly. Mirrors
    /// `RunRoutineCapabilityAdapter.routineRunSpec()`'s exact lookup. Routines can't nest other
    /// routines (enforced at save time), so one level of scanning is complete — no recursion needed.
    private static func nestedRoutineWorkspaceName(in steps: [AgentStep], routineStore: RoutineStore) -> String? {
        for step in steps where step.operation == .runRoutine {
            guard let routineName = step.routineName,
                  let routine = try? routineStore.routine(named: routineName) else {
                continue
            }
            if let nested = directWorkspaceName(in: routine.steps) {
                return nested
            }
        }
        return nil
    }

    /// Matches an explicit "in workspace X" / "in the workspace X" / "in my workspace X" phrase
    /// against real saved workspace names only — never tags on a name that isn't actually saved.
    /// Both sides are run through `normalized(_:)` (the same case/diacritic-insensitive folding
    /// `WorkspaceStore`/`RoutineStore` already use for name lookups elsewhere in this file) rather
    /// than a second, regex-only case-insensitivity scheme, so "café" and "Cafe" match here the
    /// same way they'd match as a saved workspace name anywhere else. Tie-break: the leftmost
    /// phrase match in the command wins; when two candidate names would match starting at the
    /// exact same position (one is a prefix of the other, e.g. "Client" vs. "Client Alpha"), the
    /// longer name wins at that position.
    private static func freeTextWorkspaceName(in command: String, workspaceStore: WorkspaceStore) -> String? {
        guard let workspaces = try? workspaceStore.loadAll(), !workspaces.isEmpty else {
            return nil
        }
        let normalizedCommand = normalized(command)

        var best: (start: String.Index, name: String)?
        for workspace in workspaces.values {
            let normalizedName = normalized(workspace.name)
            guard let range = firstValidPhraseMatchRange(forNormalizedWorkspaceName: normalizedName, in: normalizedCommand) else {
                continue
            }
            if let current = best {
                if range.lowerBound < current.start {
                    best = (range.lowerBound, workspace.name)
                } else if range.lowerBound == current.start, normalizedName.count > normalized(current.name).count {
                    best = (range.lowerBound, workspace.name)
                }
            } else {
                best = (range.lowerBound, workspace.name)
            }
        }
        return best?.name
    }

    /// Deliberately does not use `\b` for boundaries — `\b` requires a word/non-word character
    /// transition on *both* sides, which fails for a name ending in punctuation (e.g. "r&d (2024)"
    /// ends in ")", a non-word character, so `\b` right after it would never match unless a word
    /// character happens to follow in the surrounding text). Checking each side independently —
    /// not alphanumeric, or start/end of string — is correct regardless of what the name itself
    /// starts or ends with. Both boundaries matter for different false-positive shapes: the
    /// trailing check rejects a shorter name matching only as a prefix of an unrelated longer word
    /// ("client" inside "clientele"); the leading check rejects the phrase's own "in" matching
    /// inside an unrelated word ("within workspace Client Alpha" contains a literal "in" right
    /// before "workspace", from "with-IN", which would otherwise spuriously match).
    private static func firstValidPhraseMatchRange(
        forNormalizedWorkspaceName normalizedName: String,
        in normalizedCommand: String
    ) -> Range<String.Index>? {
        let escapedName = NSRegularExpression.escapedPattern(for: normalizedName)
        let pattern = "in\\s+(?:the\\s+|my\\s+)?workspace\\s+\(escapedName)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsRange = NSRange(normalizedCommand.startIndex..., in: normalizedCommand)
        for match in regex.matches(in: normalizedCommand, options: [], range: nsRange) {
            guard let range = Range(match.range, in: normalizedCommand),
                  hasValidBoundary(before: range.lowerBound, in: normalizedCommand),
                  hasValidBoundary(after: range.upperBound, in: normalizedCommand) else {
                continue
            }
            return range
        }
        return nil
    }

    private static func hasValidBoundary(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else {
            return true
        }
        let character = text[text.index(before: index)]
        return !character.isLetter && !character.isNumber
    }

    private static func hasValidBoundary(after index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else {
            return true
        }
        let character = text[index]
        return !character.isLetter && !character.isNumber
    }
}
