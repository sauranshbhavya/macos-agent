import Foundation

/// Narrow task-to-workspace tagging: a task's `CompletedTaskRecord.workspaceName` is set only
/// when it was explicitly dispatched to a workspace, ran a routine that itself opens/creates a
/// workspace, or the raw command contains an explicit "in workspace X" phrase naming a real saved
/// workspace — never on an implicit/ambiguous signal. This is deliberately conservative: no
/// persistent active-workspace concept, no guessing.
public enum WorkspaceTaskTagging {
    /// An explicit workspace clause found in a command, and what the command says once it is
    /// removed.
    ///
    /// Exists so the instant resolver can subtract the clause from an app query using the *same*
    /// recognizer that binds the task's scope from it (SONNY-68). The invariant that buys: a word
    /// the resolver drops from the query is never a word Sonny then ignores — it is exactly the
    /// phrase `resolveTaskScope` consumes as the workspace binding.
    struct WorkspaceClause: Equatable, Sendable {
        /// The saved workspace's canonical name, not the raw typed text.
        var workspaceName: String
        /// The command with the clause removed, original casing preserved.
        var remainingCommand: String

        init(workspaceName: String, remainingCommand: String) {
            self.workspaceName = workspaceName
            self.remainingCommand = remainingCommand
        }
    }

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

    private static func freeTextWorkspaceName(in command: String, workspaceStore: WorkspaceStore) -> String? {
        workspaceClause(in: command, workspaceStore: workspaceStore)?.workspaceName
    }

    /// Matches an explicit "in workspace X" / "in the workspace X" / "in my workspace X" phrase —
    /// or the same phrase with the name ahead of the noun, "in my X workspace" — against real saved
    /// workspace names only, never tagging on a name that isn't actually saved.
    ///
    /// Both sides are folded case/diacritic-insensitively (the same folding `WorkspaceStore`/
    /// `RoutineStore` use for name lookups) rather than through a second, regex-only
    /// case-insensitivity scheme, so "café" and "Cafe" match here the same way they'd match as a
    /// saved workspace name anywhere else. The folding is built one character at a time alongside
    /// an index map, so a match found in the folded text can be subtracted from the *original*
    /// command with its casing intact — `normalized(_:)`'s whole-string fold gives no way back to
    /// the caller's text. Tie-break: the leftmost phrase match in the command wins; when two
    /// candidate names would match starting at the exact same position (one is a prefix of the
    /// other, e.g. "Client" vs. "Client Alpha"), the longer name wins at that position.
    ///
    /// **Both word orders are recognized because the resolver subtracts exactly what this binds.**
    /// Before SONNY-68 only "in [the|my] workspace X" bound a scope, so "switch to zoom in my
    /// Switch workspace" named a workspace Sonny never saw. Recognizing the second order can only
    /// *add* an escalation — an unscoped task escalates for no boundary at all, and a scoped one
    /// escalates when a resource sits outside it — so widening what binds never widens what runs.
    static func workspaceClause(in command: String, workspaceStore: WorkspaceStore) -> WorkspaceClause? {
        // Every pattern below contains the literal word "workspace", so a command without it cannot
        // match whatever is saved — worth checking before reading and decrypting the store, since
        // this runs on the instant-resolver path for every switch phrasing as well as once per task.
        guard command.range(of: "workspace", options: [.caseInsensitive, .diacriticInsensitive]) != nil,
              let workspaces = try? workspaceStore.loadAll(),
              !workspaces.isEmpty else {
            return nil
        }
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = FoldedText(trimmedCommand)

        var best: (range: Range<String.Index>, name: String, nameLength: Int)?
        for workspace in workspaces.values {
            let foldedName = FoldedText.fold(workspace.name)
            guard let range = firstValidPhraseMatchRange(forFoldedWorkspaceName: foldedName, in: folded.text) else {
                continue
            }
            let isBetter: Bool
            if let current = best {
                isBetter = range.lowerBound < current.range.lowerBound
                    || (range.lowerBound == current.range.lowerBound && foldedName.count > current.nameLength)
            } else {
                isBetter = true
            }
            if isBetter {
                best = (range, workspace.name, foldedName.count)
            }
        }

        guard let best else {
            return nil
        }
        return WorkspaceClause(
            workspaceName: best.name,
            remainingCommand: folded.originalTextRemoving(best.range, from: trimmedCommand)
        )
    }

    /// A case/diacritic-folded copy of a string plus, for every folded character, the index of the
    /// original character it came from. Folding one character at a time keeps the two sides of a
    /// match in step even when a character's folded form is not the same length as the character
    /// itself, which a whole-string fold silently loses.
    private struct FoldedText {
        var text: String
        /// One entry per character of `text`, holding that character's source index in the original.
        private var sourceIndices: [String.Index]

        init(_ original: String) {
            var text = ""
            var sourceIndices: [String.Index] = []
            var index = original.startIndex
            while index < original.endIndex {
                let folded = Self.fold(original[index])
                text += folded
                sourceIndices.append(contentsOf: Array(repeating: index, count: folded.count))
                index = original.index(after: index)
            }
            self.text = text
            self.sourceIndices = sourceIndices
        }

        /// The folded text alone, for the pattern side of a match, which needs no index map back
        /// into anything. Character-by-character through the same `fold` the map is built from, so
        /// the two sides of a comparison can never fold differently.
        static func fold(_ original: String) -> String {
            original.reduce(into: "") { partial, character in
                partial += fold(character)
            }
        }

        private static func fold(_ character: Character) -> String {
            String(character)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
        }

        /// Cuts the original characters that produced `foldedRange` out of `original`, joining what
        /// survives on either side with a single space so removing a mid-sentence clause does not
        /// leave a double one.
        func originalTextRemoving(_ foldedRange: Range<String.Index>, from original: String) -> String {
            let lowerOffset = text.distance(from: text.startIndex, to: foldedRange.lowerBound)
            let upperOffset = text.distance(from: text.startIndex, to: foldedRange.upperBound)
            let start = lowerOffset < sourceIndices.count ? sourceIndices[lowerOffset] : original.endIndex
            let end = upperOffset < sourceIndices.count ? sourceIndices[upperOffset] : original.endIndex
            let prefix = String(original[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(original[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return [prefix, suffix].filter { !$0.isEmpty }.joined(separator: " ")
        }
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
        forFoldedWorkspaceName foldedName: String,
        in foldedCommand: String
    ) -> Range<String.Index>? {
        let escapedName = NSRegularExpression.escapedPattern(for: foldedName)
        let pattern = "in\\s+(?:the\\s+|my\\s+)?(?:workspace\\s+\(escapedName)|\(escapedName)\\s+workspace)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsRange = NSRange(foldedCommand.startIndex..., in: foldedCommand)
        for match in regex.matches(in: foldedCommand, options: [], range: nsRange) {
            guard let range = Range(match.range, in: foldedCommand),
                  hasValidBoundary(before: range.lowerBound, in: foldedCommand),
                  hasValidBoundary(after: range.upperBound, in: foldedCommand) else {
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
