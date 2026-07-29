import Foundation

public enum InstantCommandResolution: Equatable, Sendable {
    case plan(AgentPlan)
    case clarify(AgentPlan)
}

public struct InstantCommandResolver: Sendable {
    private let snippetStore: SnippetStore
    private let recentArtifactStore: RecentArtifactStore
    private let routineStore: RoutineStore
    private let workspaceStore: WorkspaceStore
    private let shortcutCatalog: any ShortcutCatalogProviding
    private let appCatalog: MacAppCatalog

    public init(
        snippetStore: SnippetStore = SnippetStore(),
        recentArtifactStore: RecentArtifactStore = RecentArtifactStore(),
        routineStore: RoutineStore = RoutineStore(),
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        shortcutCatalog: any ShortcutCatalogProviding = ProcessShortcutCatalog(),
        appCatalog: MacAppCatalog = .default
    ) {
        self.snippetStore = snippetStore
        self.recentArtifactStore = recentArtifactStore
        self.routineStore = routineStore
        self.workspaceStore = workspaceStore
        self.shortcutCatalog = shortcutCatalog
        self.appCatalog = appCatalog
    }

    public func resolve(command rawCommand: String) -> InstantCommandResolution? {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return nil
        }

        if let expression = prefixedCalculatorExpression(in: command) {
            guard !expression.isEmpty else {
                return .clarify(calculatorClarificationPlan())
            }
            return .plan(calculatorPlan(expression: expression))
        }

        if let query = prefixedClipboardHistoryQuery(in: command) {
            return .plan(clipboardHistoryPlan(query: query))
        }

        if let snippetSave = snippetSaveResolution(in: command) {
            return snippetSave
        }

        if let quickDispatch = quickDispatchResolution(in: command) {
            return quickDispatch
        }

        if let shortcut = shortcutResolution(in: command) {
            return shortcut
        }

        if let query = prefixedRunningAppQuery(in: command) {
            guard !query.isEmpty else {
                return .clarify(runningAppClarificationPlan())
            }
            return .plan(runningAppSwitchPlan(query: query))
        }

        if let request = recentArtifactRequest(in: command) {
            switch request {
            case .lookup(let query):
                return .plan(recentArtifactsPlan(query: query))
            case .open(let query):
                return recentArtifactOpenResolution(query: query)
            }
        }

        if let snippet = try? snippetStore.findExactTrigger(command) {
            return .plan(snippetPlan(snippet))
        }

        if looksLikeBareArithmetic(command) || looksLikeBareConversion(command) {
            return .plan(calculatorPlan(expression: command))
        }

        return nil
    }

    private enum RecentArtifactRequest {
        case lookup(String?)
        case open(String?)
    }

    private struct ShortcutLaunchRequest {
        var name: String
        var input: String?
    }

    private func snippetSaveResolution(in command: String) -> InstantCommandResolution? {
        let lowered = command.lowercased()
        let prefixes = ["snippet save", "save snippet"]
        for prefix in prefixes {
            if lowered == prefix {
                return .clarify(snippetSaveClarificationPlan())
            }
            if lowered.hasPrefix("\(prefix) ") {
                let body = String(command.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let delimiter = body.range(of: "=") else {
                    return .clarify(snippetSaveClarificationPlan())
                }
                let trigger = String(body[..<delimiter.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let expansion = String(body[delimiter.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trigger.isEmpty, !expansion.isEmpty else {
                    return .clarify(snippetSaveClarificationPlan())
                }
                return .plan(saveSnippetPlan(trigger: trigger, expansion: expansion))
            }
        }
        return nil
    }

    private func quickDispatchResolution(in command: String) -> InstantCommandResolution? {
        let routineCandidates = routineLaunchCandidates(in: command)
        let workspaceCandidates = workspaceLaunchCandidates(in: command)

        // Kind-prefixed forms ("run routine X", "open workspace X") are unambiguous and stay
        // instant.
        if let routine = savedRoutine(matching: routineCandidates.explicit) {
            return .plan(runRoutinePlan(routine))
        }
        if let workspace = savedWorkspace(matching: workspaceCandidates.explicit) {
            return .plan(openWorkspacePlan(workspace))
        }

        // Direct-prefixed forms ("open X", "run X", "start X", "launch X") are ambiguous: the
        // same name can be a saved routine, a saved workspace, or an allowlisted app. On any
        // collision, step aside (nil) so the planner interprets the command instead of one
        // meaning silently auto-running.
        let directRoutine = savedRoutine(matching: routineCandidates.direct)
        let directWorkspace = savedWorkspace(matching: workspaceCandidates.direct)
        let namesAllowlistedApp = (routineCandidates.direct + workspaceCandidates.direct)
            .contains { (try? appCatalog.resolve($0)) != nil }

        switch (directRoutine, directWorkspace) {
        case (.some, .some):
            return nil
        case (.some(let routine), nil):
            return namesAllowlistedApp ? nil : .plan(runRoutinePlan(routine))
        case (nil, .some(let workspace)):
            return namesAllowlistedApp ? nil : .plan(openWorkspacePlan(workspace))
        case (nil, nil):
            break
        }

        let routine = savedRoutine(matching: [command])
        let workspace = savedWorkspace(matching: [command])
        switch (routine, workspace) {
        case (.some(let routine), nil):
            return .plan(runRoutinePlan(routine))
        case (nil, .some(let workspace)):
            return .plan(openWorkspacePlan(workspace))
        case (.some(let routine), .some(let workspace)):
            return .clarify(quickDispatchClarificationPlan(name: routine.name, workspaceName: workspace.name))
        case (nil, nil):
            return nil
        }
    }

    private func routineLaunchCandidates(in command: String) -> LaunchCandidateSet {
        launchCandidates(
            in: command,
            kind: "routine",
            directPrefixes: ["run", "start", "launch"],
            kindPrefixes: ["run routine", "start routine", "launch routine", "routine"]
        )
    }

    private func workspaceLaunchCandidates(in command: String) -> LaunchCandidateSet {
        launchCandidates(
            in: command,
            kind: "workspace",
            directPrefixes: ["open", "start", "launch"],
            kindPrefixes: ["open workspace", "start workspace", "launch workspace", "workspace"]
        )
    }

    private struct LaunchCandidateSet {
        var explicit: [String]
        var direct: [String]
    }

    private func launchCandidates(
        in command: String,
        kind: String,
        directPrefixes: [String],
        kindPrefixes: [String]
    ) -> LaunchCandidateSet {
        let lowered = command.lowercased()
        var explicitCandidates: [String] = []
        var directCandidates: [String] = []

        for prefix in kindPrefixes {
            if lowered.hasPrefix("\(prefix) ") {
                explicitCandidates.append(String(command.dropFirst(prefix.count)))
            }
        }

        for prefix in directPrefixes {
            if lowered.hasPrefix("\(prefix) ") {
                let remainder = String(command.dropFirst(prefix.count))
                directCandidates.append(remainder)
                if remainder.lowercased().hasSuffix(" \(kind)") {
                    // "run X routine" names its kind just like "run routine X" does.
                    explicitCandidates.append(String(remainder.dropLast(kind.count + 1)))
                }
            }
        }

        return LaunchCandidateSet(
            explicit: uniqueLaunchCandidates(explicitCandidates.flatMap { [$0, strippedLaunchArticle($0)] }),
            direct: uniqueLaunchCandidates(directCandidates.flatMap { [$0, strippedLaunchArticle($0)] })
        )
    }

    private func savedRoutine(matching candidates: [String]) -> StoredRoutine? {
        guard let routines = try? routineStore.loadAll() else {
            return nil
        }
        for candidate in candidates {
            if let routine = routines[normalizedLaunchName(candidate)] {
                return routine
            }
        }
        return nil
    }

    private func savedWorkspace(matching candidates: [String]) -> StoredWorkspace? {
        guard let workspaces = try? workspaceStore.loadAll() else {
            return nil
        }
        for candidate in candidates {
            if let workspace = workspaces[normalizedLaunchName(candidate)] {
                return workspace
            }
        }
        return nil
    }

    private func shortcutResolution(in command: String) -> InstantCommandResolution? {
        guard let request = shortcutLaunchRequest(in: command) else {
            return nil
        }

        do {
            let resolvedName = try shortcutCatalog.resolveShortcutName(request.name)
            return .plan(invokeShortcutPlan(name: resolvedName, input: request.input))
        } catch ShortcutsBridgeError.missingShortcutName {
            return .clarify(shortcutClarificationPlan(question: "Which Shortcut should I run?"))
        } catch ShortcutsBridgeError.unknownShortcut(let name, let available) {
            let suffix = available.isEmpty ? "" : " Available Shortcuts include: \(available.prefix(5).joined(separator: ", "))."
            return .clarify(shortcutClarificationPlan(question: "I could not find a Shortcut named \(name). Which Shortcut should I run?\(suffix)"))
        } catch {
            return .clarify(shortcutClarificationPlan(question: "I could not read your Shortcuts list. Which Shortcut should I run?"))
        }
    }

    private func shortcutLaunchRequest(in command: String) -> ShortcutLaunchRequest? {
        let lowered = command.lowercased()
        let explicitPrefixes = ["run shortcut", "invoke shortcut", "shortcut"]
        for prefix in explicitPrefixes {
            if lowered == prefix {
                return ShortcutLaunchRequest(name: "", input: nil)
            }
            if lowered.hasPrefix("\(prefix) ") {
                return shortcutRequest(from: String(command.dropFirst(prefix.count)))
            }
        }

        for prefix in ["run", "start", "launch"] where lowered.hasPrefix("\(prefix) ") {
            let remainder = String(command.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.lowercased().hasSuffix(" shortcut") || remainder.lowercased().contains(" shortcut with input ") {
                return shortcutRequest(from: remainder)
            }
        }

        return nil
    }

    private func shortcutRequest(from rawValue: String) -> ShortcutLaunchRequest {
        var value = strippedLaunchArticle(rawValue)
        var input: String?
        if let range = value.range(of: " with input ", options: [.caseInsensitive]) {
            input = String(value[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            value = String(value[..<range.lowerBound])
        }
        if value.lowercased().hasSuffix(" shortcut") {
            value = String(value.dropLast(" shortcut".count))
        }
        return ShortcutLaunchRequest(
            name: value.trimmingCharacters(in: .whitespacesAndNewlines),
            input: input?.isEmpty == true ? nil : input
        )
    }

    private func prefixedRunningAppQuery(in command: String) -> String? {
        let lowered = command.lowercased()
        for prefix in ["switch to", "switch", "focus", "activate"] {
            if lowered == prefix {
                return ""
            }
            if lowered.hasPrefix("\(prefix) ") {
                let remainder = String(command.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return looksLikeRunningAppName(remainder) ? remainder : nil
            }
        }
        return nil
    }

    /// Heuristic guard so the broad verbs ("focus", "activate", bare "switch") only claim
    /// commands whose object plausibly names an app. "focus on writing my essay" or
    /// "activate dark mode" must fall through to the planner instead of dead-ending on
    /// running-app matching.
    private func looksLikeRunningAppName(_ remainder: String) -> Bool {
        let words = remainder.split(separator: " ")
        guard !words.isEmpty, words.count <= 3 else {
            return false
        }
        let leadingStopWords: Set<String> = ["on", "to", "in", "at", "the", "a", "an", "my"]
        if leadingStopWords.contains(words[0].lowercased()) {
            return false
        }
        return words.last?.lowercased() != "mode"
    }

    private func recentArtifactRequest(in command: String) -> RecentArtifactRequest? {
        let lowered = command.lowercased()
        for prefix in ["open recent artifact", "open recent file", "open recent result"] {
            if lowered == prefix {
                return .open(nil)
            }
            if lowered.hasPrefix("\(prefix) ") {
                let query = String(command.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .open(query.isEmpty ? nil : query)
            }
        }

        for prefix in ["recent artifacts", "recent artifact", "recent results", "recent files", "artifacts"] {
            if lowered == prefix {
                return .lookup(nil)
            }
            if lowered.hasPrefix("\(prefix) ") {
                let query = String(command.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .lookup(query.isEmpty ? nil : query)
            }
        }

        return nil
    }

    private func prefixedClipboardHistoryQuery(in command: String) -> String? {
        let lowered = command.lowercased()
        for prefix in ["clipboard history", "clipboard", "clip"] {
            if lowered == prefix {
                return ""
            }
            if lowered.hasPrefix("\(prefix) ") {
                return String(command.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func prefixedCalculatorExpression(in command: String) -> String? {
        let lowered = command.lowercased()
        for prefix in ["calc", "calculate"] {
            if lowered == prefix {
                return ""
            }
            if lowered.hasPrefix("\(prefix) ") {
                return String(command.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if command.hasPrefix("=") {
            return String(command.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func looksLikeBareArithmetic(_ command: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/() \t\n")
        let scalars = command.unicodeScalars
        guard scalars.allSatisfy({ allowed.contains($0) }) else {
            return false
        }
        let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        let hasOperator = scalars.contains { ["+", "-", "*", "/"].contains(String($0)) }
        return hasDigit && hasOperator
    }

    private func looksLikeBareConversion(_ command: String) -> Bool {
        let parts = command
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
        guard parts.count == 4,
              Double(parts[0]) != nil,
              ["to", "in"].contains(parts[2].lowercased()) else {
            return false
        }
        return true
    }

    private func calculatorPlan(expression: String) -> AgentPlan {
        AgentPlan(
            summary: "Calculate \(expression).",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "calculate",
                    operation: .calculateUtility,
                    description: "Calculate \(expression).",
                    searchQuery: expression
                )
            ]
        )
    }

    private func clipboardHistoryPlan(query: String?) -> AgentPlan {
        let summary: String
        if let query, !query.isEmpty {
            summary = "Search clipboard history for \(query)."
        } else {
            summary = "Show clipboard history."
        }
        return AgentPlan(
            summary: summary,
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clipboard-history",
                    operation: .lookupClipboardHistory,
                    description: summary,
                    count: 10,
                    searchQuery: query?.isEmpty == true ? nil : query
                )
            ]
        )
    }

    private func runningAppSwitchPlan(query: String) -> AgentPlan {
        AgentPlan(
            summary: "Switch to \(query).",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "switch-running-app",
                    operation: .switchRunningApp,
                    description: "Switch to running app \(query).",
                    appName: query
                )
            ]
        )
    }

    private func recentArtifactsPlan(query: String?) -> AgentPlan {
        let summary: String
        if let query, !query.isEmpty {
            summary = "Search recent artifacts for \(query)."
        } else {
            summary = "Show recent artifacts."
        }
        return AgentPlan(
            summary: summary,
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "recent-artifacts",
                    operation: .lookupRecentArtifacts,
                    description: summary,
                    count: 10,
                    searchQuery: query?.isEmpty == true ? nil : query
                )
            ]
        )
    }

    private func recentArtifactOpenResolution(query: String?) -> InstantCommandResolution {
        let artifacts = (try? recentArtifactStore.recent(matching: query, limit: 2)) ?? []
        guard let artifact = artifacts.first else {
            return .clarify(recentArtifactClarificationPlan(query: query))
        }
        return .plan(openRecentArtifactPlan(artifact))
    }

    private func openRecentArtifactPlan(_ artifact: RecentArtifact) -> AgentPlan {
        AgentPlan(
            summary: "Open recent artifact \(artifact.title).",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "open-recent-artifact",
                    operation: .openGeneratedArtifact,
                    description: "Open recent artifact \(artifact.title).",
                    outputPath: artifact.path
                )
            ]
        )
    }

    private func runRoutinePlan(_ routine: StoredRoutine) -> AgentPlan {
        AgentPlan(
            summary: "Run routine \(routine.name).",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "run-routine",
                    operation: .runRoutine,
                    description: "Run saved routine \(routine.name).",
                    routineName: routine.name
                )
            ]
        )
    }

    private func openWorkspacePlan(_ workspace: StoredWorkspace) -> AgentPlan {
        AgentPlan(
            summary: "Open workspace \(workspace.name).",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "open-workspace",
                    operation: .openWorkspace,
                    description: "Open saved workspace \(workspace.name).",
                    workspaceName: workspace.name
                )
            ]
        )
    }

    private func invokeShortcutPlan(name: String, input: String?) -> AgentPlan {
        AgentPlan(
            summary: "Run Shortcut \(name).",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "invoke-shortcut",
                    operation: .invokeShortcut,
                    description: "Run Shortcut \(name).",
                    shortcutName: name,
                    shortcutInput: input
                )
            ]
        )
    }

    private func snippetPlan(_ snippet: StoredSnippet) -> AgentPlan {
        AgentPlan(
            summary: "Expand snippet \(snippet.trigger).",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "snippet-expansion",
                    operation: .expandSnippet,
                    description: "Expand snippet \(snippet.trigger).",
                    searchQuery: snippet.trigger
                )
            ]
        )
    }

    private func saveSnippetPlan(trigger: String, expansion: String) -> AgentPlan {
        AgentPlan(
            summary: "Save snippet \(trigger).",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "snippet-save",
                    operation: .saveSnippet,
                    description: "Save snippet \(trigger).",
                    searchQuery: trigger,
                    draftContent: expansion
                )
            ]
        )
    }

    private func snippetSaveClarificationPlan() -> AgentPlan {
        AgentPlan(
            summary: "Clarification needed.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify-snippet-save",
                    operation: .clarify,
                    description: "Ask for snippet trigger and expansion.",
                    question: "Use the format snippet save ;trigger = expansion."
                )
            ]
        )
    }

    private func shortcutClarificationPlan(question: String) -> AgentPlan {
        AgentPlan(
            summary: "Clarification needed.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify-shortcut",
                    operation: .clarify,
                    description: "Ask which Shortcut to run.",
                    question: question
                )
            ]
        )
    }

    private func quickDispatchClarificationPlan(name: String, workspaceName: String) -> AgentPlan {
        AgentPlan(
            summary: "Clarification needed.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify-quick-dispatch",
                    operation: .clarify,
                    description: "Ask whether to run a routine or open a workspace.",
                    question: "I found both a routine named \(name) and a workspace named \(workspaceName). Which should I launch?"
                )
            ]
        )
    }

    private func runningAppClarificationPlan() -> AgentPlan {
        AgentPlan(
            summary: "Clarification needed.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify-running-app",
                    operation: .clarify,
                    description: "Ask which running app to switch to.",
                    question: "Which running app should I switch to?"
                )
            ]
        )
    }

    private func recentArtifactClarificationPlan(query: String?) -> AgentPlan {
        let question: String
        if let query, !query.isEmpty {
            question = "I could not find a recent artifact matching \(query). Which artifact should I open?"
        } else {
            question = "Which recent artifact should I open?"
        }
        return AgentPlan(
            summary: "Clarification needed.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify-recent-artifact",
                    operation: .clarify,
                    description: "Ask which recent artifact to open.",
                    question: question
                )
            ]
        )
    }

    private func calculatorClarificationPlan() -> AgentPlan {
        AgentPlan(
            summary: "Clarification needed.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify-calculator",
                    operation: .clarify,
                    description: "Ask what to calculate.",
                    question: "What would you like me to calculate?"
                )
            ]
        )
    }

    private func strippedLaunchArticle(_ candidate: String) -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["my ", "the "] where trimmed.lowercased().hasPrefix(article) {
            return String(trimmed.dropFirst(article.count))
        }
        return trimmed
    }

    private func normalizedLaunchName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func uniqueLaunchCandidates(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let key = normalizedLaunchName(trimmed)
            guard seen.insert(key).inserted else {
                continue
            }
            result.append(trimmed)
        }
        return result
    }
}
