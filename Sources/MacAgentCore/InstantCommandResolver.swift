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
    /// Only ever asked one question — "does this saved name also name an app?" — and only to step
    /// aside to the planner when it does. Repointed from `MacAppCatalog` at SONNY-83: while the
    /// catalog answered, a workspace called "Figma" and the installed Figma stopped disambiguating
    /// the moment SONNY-82 made Figma openable, because the collision the check exists to catch had
    /// become invisible to it.
    private let installedAppResolver: any InstalledAppResolving

    public init(
        snippetStore: SnippetStore,
        recentArtifactStore: RecentArtifactStore,
        routineStore: RoutineStore,
        workspaceStore: WorkspaceStore,
        shortcutCatalog: any ShortcutCatalogProviding = ProcessShortcutCatalog(),
        installedAppResolver: any InstalledAppResolving = InstalledAppResolver.shared
    ) {
        self.snippetStore = snippetStore
        self.recentArtifactStore = recentArtifactStore
        self.routineStore = routineStore
        self.workspaceStore = workspaceStore
        self.shortcutCatalog = shortcutCatalog
        self.installedAppResolver = installedAppResolver
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

        // **A sum is allowed to end with `=`, and the rule that says so lives in the evaluator**
        // (SONNY-281). This used to read the raw command against its own character set, and `=` was
        // not in it — so `2 + 2` was answered here and `2 + 2 =` fell through to a planner with no
        // calculator to offer, one character apart. The sum is read the way the evaluator will read
        // it, and the plan carries that form so its own summary says `2 + 2` too.
        //
        // **And a calculation phrased as a sentence is still a calculation** (SONNY-284) — the
        // filler around it is dropped here before the same two rules read what is left.
        if let expression = calculatorExpression(in: command) {
            return .plan(calculatorPlan(expression: expression))
        }

        return nil
    }

    private enum RecentArtifactRequest {
        case lookup(String?)
        case open(String?)
    }

    /// **Candidates, not a name** (PR #106 review, F3). Original first, article-stripped second.
    /// This path used to discard the original, so "run my standup shortcut" could only ever find a
    /// Shortcut called `Standup` and never one called `My Standup` — a hazard that predates
    /// SONNY-242 for `my`/`the` and that SONNY-242 widened to `our`/`your` when it merged the
    /// article lists. Keeping both is the shape `launchCandidates` already uses for routines and
    /// workspaces, and it closes the pre-existing half as well as the widened one. Empty means
    /// the user named no Shortcut at all.
    private struct ShortcutLaunchRequest {
        var nameCandidates: [String]
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
        // same name can be a saved routine, a saved workspace, or an installed app. On any
        // collision, step aside (nil) so the planner interprets the command instead of one
        // meaning silently auto-running.
        let directRoutine = savedRoutine(matching: routineCandidates.direct)
        let directWorkspace = savedWorkspace(matching: workspaceCandidates.direct)
        let namesInstalledApp = (routineCandidates.direct + workspaceCandidates.direct)
            .contains { installedAppResolver.resolve($0) != nil }

        switch (directRoutine, directWorkspace) {
        case (.some, .some):
            return nil
        case (.some(let routine), nil):
            return namesInstalledApp ? nil : .plan(runRoutinePlan(routine))
        case (nil, .some(let workspace)):
            return namesInstalledApp ? nil : .plan(openWorkspacePlan(workspace))
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
            return crossKindQuickDispatchResolution(
                routineCandidates: routineCandidates,
                workspaceCandidates: workspaceCandidates
            )
        }
    }

    /// The kind-locked verbs' blind spot: "run" only ever looks its name up as a routine and
    /// "open" only as a workspace, so "run hehe" where hehe is a saved *workspace* fell through
    /// to the planner — which has no knowledge of saved names and can only ask generic questions,
    /// never mentioning the item that exists. ("start"/"launch" sit in both direct-prefix lists
    /// and already resolved cross-kind before reaching this point.) This is the resolver-side
    /// sibling of `AgentActionExecutor.missingAutomationTargetQuestion`'s cross-kind check, which
    /// sits behind the planner and so never fires for this input shape.
    ///
    /// Deliberately clarifies rather than silently cross-resolving — the user named a kind and
    /// meant something else, and auto-running the other kind would contradict the collision
    /// handling above. Exact-name match only; runs after the same-kind switches so a same-kind
    /// match and an exact whole-command name both still win unchanged, and a name saved nowhere
    /// still returns nil to the planner.
    private func crossKindQuickDispatchResolution(
        routineCandidates: LaunchCandidateSet,
        workspaceCandidates: LaunchCandidateSet
    ) -> InstantCommandResolution? {
        // Explicit candidates included on purpose: "run routine hehe" where hehe is only a
        // workspace is the same miss and gets the same clarification.
        let routineSide = routineCandidates.explicit + routineCandidates.direct
        let workspaceSide = workspaceCandidates.explicit + workspaceCandidates.direct

        if let workspace = savedWorkspace(matching: routineSide) {
            let namesApp = routineSide.contains { installedAppResolver.resolve($0) != nil }
            // Three-way ambiguity (the name is also an installed app) steps aside to the planner,
            // same as the direct-form collision handling above.
            return namesApp ? nil : .clarify(crossKindQuickDispatchClarificationPlan(
                missingKind: "routine",
                foundKind: "workspace",
                foundName: workspace.name,
                verb: "open"
            ))
        }
        if let routine = savedRoutine(matching: workspaceSide) {
            let namesApp = workspaceSide.contains { installedAppResolver.resolve($0) != nil }
            return namesApp ? nil : .clarify(crossKindQuickDispatchClarificationPlan(
                missingKind: "workspace",
                foundKind: "routine",
                foundName: routine.name,
                verb: "run"
            ))
        }
        return nil
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
            let resolvedName = try resolvedShortcutName(from: request.nameCandidates)
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

    /// The first candidate the catalog recognises, or the **last** candidate's error.
    ///
    /// Last, deliberately: the candidates run original-then-stripped, so surfacing the last error
    /// leaves every existing clarification string byte-identical — "I could not find a Shortcut
    /// named standup", not "…named my standup". The only behaviour that changes is a name that
    /// used to be unfindable now being found.
    private func resolvedShortcutName(from candidates: [String]) throws -> String {
        var lastError: Error = ShortcutsBridgeError.missingShortcutName
        for candidate in candidates {
            do {
                return try shortcutCatalog.resolveShortcutName(candidate)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func shortcutLaunchRequest(in command: String) -> ShortcutLaunchRequest? {
        let lowered = command.lowercased()
        let explicitPrefixes = ["run shortcut", "invoke shortcut", "shortcut"]
        for prefix in explicitPrefixes {
            if lowered == prefix {
                return ShortcutLaunchRequest(nameCandidates: [], input: nil)
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

    /// The article is stripped **after** the input clause and the "shortcut" suffix come off, not
    /// before, so that both candidates are built from the same finished name. Reordered with the
    /// candidate change above; the primary candidate is what the old single-name code produced,
    /// with the article back on the front.
    private func shortcutRequest(from rawValue: String) -> ShortcutLaunchRequest {
        var value = rawValue
        var input: String?
        if let range = value.range(of: " with input ", options: [.caseInsensitive]) {
            input = String(value[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            value = String(value[..<range.lowerBound])
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasSuffix(" shortcut") {
            value = String(value.dropLast(" shortcut".count))
        }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShortcutLaunchRequest(
            nameCandidates: uniqueLaunchCandidates([name, strippedLaunchArticle(name)]),
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
                let candidate = runningAppCandidate(from: remainder)
                return looksLikeRunningAppName(candidate) ? candidate : nil
            }
        }
        return nil
    }

    /// Narrows the post-verb remainder to the part that actually names an app, before the
    /// plausibility guard reads it (SONNY-68).
    ///
    /// The remainder used to be handed to `looksLikeRunningAppName` whole, so a workspace clause —
    /// "switch to code **in the workspace Switch**" — pushed every such phrasing past the
    /// three-word ceiling and out of the resolver, into a planner with no app-switch operation,
    /// which absorbed the intent into the nearest-sounding one it did have: `edit_workspace`, a
    /// destructive boundary edit nobody typed. The clause is not noise, which is why it is
    /// subtracted rather than tolerated: `WorkspaceTaskTagging` recognises it as the phrase that
    /// binds the *task's* workspace scope, so the words removed here are exactly the words Sonny
    /// acts on elsewhere — the scoped switch this makes reachable is the case SONNY-58's
    /// verdict-binding was built for.
    ///
    /// **The ordering contract, which the first version of this function got wrong.**
    ///
    /// `looksLikeRunningAppName` is the sole authority on whether a candidate names an app, and the
    /// only word it may never see is a word belonging to a recognised workspace clause. The first
    /// version also stripped a leading article unconditionally, which quietly disabled two of the
    /// guard's eight leading stop words — `the` and `my` — on this path, and the phrasings that
    /// rejection existed to protect are workspace-opening ones: "switch to my Research workspace"
    /// and "switch to the workspace Switch" reached the planner's `open_workspace` rule before
    /// SONNY-68 and were captured as doomed app queries after it (PR #39 review, cycle 1, F1).
    ///
    /// So: **with no clause recognised, this function must leave the remainder alone.** The guard
    /// then sees exactly what it saw before this ticket existed, and every one of its rejections —
    /// all eight leading stop words, the three-word ceiling, the "mode" suffix — behaves identically.
    /// `PlannerBoundaryTests` is not where that is checked; `SwitchInWorkspaceRoutingTests`'
    /// base-parity table is, case by case, with the measurement at `48d0150` recorded beside each.
    ///
    /// **With a clause recognised, one normalisation is allowed, and it is a naming form rather
    /// than an article rule.** A residue of the shape `[the|my] NAME app` names an app: the trailing
    /// noun is what says so, which is why the article may come off in that shape and only in it.
    /// "the code app in the workspace Switch" is the recorded observation 2, and it resolves; "my
    /// essay in the workspace Switch" has no such noun, keeps its leading stop word, and is refused
    /// by the guard exactly as its clause-free form is. A clause-carrying phrasing could not reach
    /// the resolver at all before this ticket — the clause put every one of them past the ceiling —
    /// so nothing here can regress a phrasing that used to work.
    ///
    /// Edge punctuation comes off both ends first, on either path. A typed full stop used to strand
    /// itself in the query — "switch to code in the workspace Switch." asked to activate `code .`,
    /// and the bare "switch to chrome." asked for `chrome.` long before this ticket — and the
    /// matcher normalises spaces but not punctuation, so both failed by name. This is the one place
    /// the no-clause path is deliberately *not* byte-identical to `48d0150`: it fixes that older
    /// kind too (PR #39 review, cycle 1, F3).
    private func runningAppCandidate(from remainder: String) -> String {
        let cleaned = edgePunctuationTrimmed(remainder)
        guard let clause = WorkspaceTaskTagging.workspaceClause(in: cleaned, workspaceStore: workspaceStore) else {
            return cleaned
        }
        let residue = edgePunctuationTrimmed(clause.remainingCommand)
        guard residue.lowercased().hasSuffix(" app") else {
            return residue
        }
        return edgePunctuationTrimmed(
            SpokenName.withoutLeadingArticle(
                String(residue.dropLast(" app".count)),
                from: Self.strippableRunningAppArticles
            )
        )
    }

    /// The articles `runningAppCandidate` may strip: the ones its own plausibility guard would
    /// otherwise reject (PR #106 review, F3).
    ///
    /// **Derived, not chosen.** A plan carries one `appName`, so this is the one article site that
    /// cannot keep the original beside the stripped one — every word it strips is a word an app can
    /// no longer be called. SONNY-242 merged the article lists and widened this site from two words
    /// to four without noticing, so "switch to our standup app in the workspace X" stopped being
    /// able to reach an app called `Our Standup` and would silently activate a `Standup` if one were
    /// running. The intersection restores the two-word behaviour *and* says why it is two: the strip
    /// exists only to undo `runningAppLeadingStopWords`, which is what rejects "the code app". A stop
    /// word added there later becomes strippable here without anyone remembering to come back.
    private static let strippableRunningAppArticles = SpokenName.leadingArticles
        .filter(runningAppLeadingStopWords.contains)

    /// Punctuation and whitespace at either end of a candidate, removed before it is judged or
    /// matched. Interior punctuation is left alone: "zoom.us" is a real bundle-ish name and
    /// `RunningAppMatcher` matches on it.
    private func edgePunctuationTrimmed(_ value: String) -> String {
        value.trimmingCharacters(
            in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        )
    }

    /// Heuristic guard so the broad verbs ("focus", "activate", bare "switch") only claim
    /// commands whose object plausibly names an app. "focus on writing my essay" or
    /// "activate dark mode" must fall through to the planner instead of dead-ending on
    /// running-app matching.
    /// Hoisted out of `looksLikeRunningAppName` so `runningAppCandidate` can derive its strippable
    /// article set from it rather than hold a constant that drifts away (PR #106 review, F3).
    private static let runningAppLeadingStopWords: Set<String> = ["on", "to", "in", "at", "the", "a", "an", "my"]

    private func looksLikeRunningAppName(_ remainder: String) -> Bool {
        let words = remainder.split(separator: " ")
        guard !words.isEmpty, words.count <= 3 else {
            return false
        }
        if Self.runningAppLeadingStopWords.contains(words[0].lowercased()) {
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

    /// The expression after `calc`, `calculate` or a leading `=`, read the way the evaluator will
    /// read it — a trailing `=` or `?` dropped along with the whitespace (SONNY-281) — so `= 2 + 2 =`
    /// plans as `2 + 2`, and `= =` is the question rather than a plan to calculate `=`.
    ///
    /// **It takes the *trailing* filler off too, and only the trailing filler** (SONNY-284's fix
    /// round). This path plans whatever follows the prefix without asking whether it is arithmetic,
    /// so `calculate 2 + 2 please` did not fall through to a planner — it planned `2 + 2 please`
    /// and the evaluator answered *"Could not calculate that expression: Unexpected token p."*, a
    /// parser message naming a letter, on the same sentence `2 + 2 please` is answered on.
    ///
    /// **`takingLeadIns: false` is load-bearing and was found by a battery's baseline going red.**
    /// Taking lead-ins here too costs `ResumableTaskRunTests.anAnswerThatRestatesTheCommandIsTakenAsTheWholeCommand`,
    /// and the mechanism is worth stating because nothing about this function hints at it: when a
    /// user answers the `calc` question by restating the prefix — `Calc 2 + 2` — PR #118's F2 tries
    /// the joined candidate `calc Calc 2 + 2` first and picks the answer alone *because the joined
    /// one fails the dry run's evaluation*. Stripping `calc` as a lead-in makes the joined candidate
    /// evaluate cleanly, so it wins, and the task history records `calc Calc 2 + 2` as the command
    /// the user gave. A discrimination that works by one candidate failing is silently defeated by
    /// anything that makes it succeed. It is also the right rule on its own terms: after `calc` the
    /// command has already said it is a calculation, so a word at the front is part of what the user
    /// wrote rather than filler in front of it, while politeness and punctuation on the end are
    /// filler either way.
    private func prefixedCalculatorExpression(in command: String) -> String? {
        let lowered = command.lowercased()
        for prefix in ["calc", "calculate"] {
            if lowered == prefix {
                return ""
            }
            if lowered.hasPrefix("\(prefix) ") {
                return withoutCalculationFiller(
                    String(command.dropFirst(prefix.count)),
                    takingLeadIns: false
                )
            }
        }
        if command.hasPrefix("=") {
            return withoutCalculationFiller(String(command.dropFirst()), takingLeadIns: false)
        }
        return nil
    }

    /// The words people wrap a calculation in when they say it out loud rather than type it
    /// (SONNY-284). `what is 2 + 2`, `how much is 5 times 5`, `convert 5 km to miles`,
    /// `5 km in miles please` — each of these is a calculation and each reached a planner that has
    /// no calculator to offer (`CalculatorCapabilityAdapter.metadata.plannerTools` is empty), so
    /// the answer a first user got in their first ten minutes was "Calculation is unsupported by
    /// the registered local tools".
    ///
    /// **Bounded and explicit, never a general "strip the words and see".** Widening the
    /// calculator's reach is only safe because the two rules underneath it — `looksLikeBareArithmetic`
    /// and `looksLikeBareConversion` — are unchanged in their strictness: what is left after the
    /// filler comes off must be *entirely* digits and operators, or exactly a four-token conversion
    /// naming a unit this calculator knows. So `what is my ip address` strips to `my ip address`,
    /// matches neither, and stays the planner's, which is the whole constraint this ticket carried.
    ///
    /// **Longest phrase first, and that ordering is load-bearing**: `how much is 5 times 5` stripped
    /// by `how much` leaves `is 5 times 5`, which matches nothing and reaches the planner. Both
    /// lists are written alphabetically — which is *not* longest-first, deliberately, so the
    /// ordering is the sort's doing rather than a hand-kept invariant a later phrase can break
    /// silently — and `longestFirst` is one function so one test covers both.
    ///
    /// `sorted(by:)` is not stable, and it does not need to be: instability can only reorder phrases
    /// of *equal* length, and two strings of equal length cannot be proper prefixes of one another,
    /// so no tie in either list can flip a match (PR #176 review).
    private static let calculationLeadIns = longestFirst([
        "calc", "calculate", "compute", "convert", "how much", "how much is",
        "please", "solve", "what is", "what's", "whats", "work out"
    ])

    /// The other end of the same sentence — `5 km in miles please`.
    private static let calculationTailOffs = longestFirst([
        "for me", "please", "thank you", "thanks"
    ])

    private static func longestFirst(_ phrases: [String]) -> [String] {
        phrases.sorted { $0.count > $1.count }
    }

    /// The command with its calculation filler removed, or nil when what is left is not a
    /// calculation at all. Zero filler is the ordinary case and costs one pass: a bare `2 + 2` or
    /// `10 cm to in` reaches the same two rules it always did.
    ///
    /// The expression handed back is a slice of what the user actually wrote, not the normalized
    /// form — the plan's summary says `Calculate five times five.` for the same reason
    /// `calc five times five` has always said it, and `CalculatorService.evaluate` normalizes again
    /// on its own way to the answer. Normalization here is only ever asked whether this *is* a
    /// calculation.
    ///
    /// **The stripping lives here and not in `CalculatorService`**, deliberately: this is command
    /// recognition, and the evaluator's refusal to strip filler from an expression it is handed is a
    /// stated boundary with a test on it (`CalculatorServiceTests.doesNotStripFillerWordsByDesign`).
    /// A resolver that hands over `two plus two` leaves that boundary exactly where it was.
    private func calculatorExpression(in command: String) -> String? {
        let expression = withoutCalculationFiller(command)
        let normalized = SpokenArithmeticNormalizer.normalize(expression)
        guard looksLikeBareArithmetic(normalized) || looksLikeBareConversion(normalized) else {
            return nil
        }
        return expression
    }

    /// The stripping half on its own, because `prefixedCalculatorExpression` wants it without the
    /// recognition step — and without the lead-ins, for the reason recorded there.
    ///
    /// **The trailing trim runs inside the loop, not once before it, and that placement is the
    /// whole of why `what's 2+2? thanks` works** (PR #176 review, F2): the `?` is not at the end
    /// until ` thanks` has come off, so a version that trimmed once up front would answer the
    /// planner's refusal to a sentence a person plainly typed at a calculator. Every trailing-sign
    /// case that predates this branch already has its sign at the end before any strip, so the
    /// suite stays green under that rearrangement — which is exactly why it is pinned by name.
    private func withoutCalculationFiller(_ command: String, takingLeadIns: Bool = true) -> String {
        var expression = command
        // Each pass removes at least one character, so the loop is bounded by the command's length;
        // the count is the guard against a phrase that could ever strip to itself.
        for _ in 0...command.count {
            let trimmed = withoutTrailingCalculationNoise(expression)
            if let shorter = withoutOneCalculationFillerPhrase(trimmed, takingLeadIns: takingLeadIns) {
                expression = shorter
                continue
            }
            expression = trimmed
            break
        }
        return expression
    }

    /// What a dictated or typed sentence may end with and still be the calculation it began as.
    ///
    /// Two rules, applied until neither changes anything. `withoutTrailingEqualsOrQuestionMark` is
    /// the evaluator's own statement of what a *sum* may end with (SONNY-281) and stays exactly
    /// that; `SpokenArithmeticNormalizer.trimmablePunctuation` is the one list of what a
    /// transcriber appends to a *sentence*, read here rather than copied. They interleave — `2 + 2
    /// =,` and `2 + 2 , =` are both reachable — so neither alone settles the text.
    ///
    /// **The trailing end only.** `trimmingCharacters` would take both, and a leading `.` is a
    /// decimal point: `.5 + 1` trimmed at both ends is `6` rather than `1.5`.
    ///
    /// Trigger (PR #176 review, F1): `What is 5 times 5, please?` reached a planner with no
    /// calculator and came back "Calculation is unsupported by the registered local tools" — the
    /// exact sentence SONNY-284 exists to remove, on the phrasing its own manual-test row asks the
    /// founders to speak. Its word-number twin `what is five times five, please` was answered, and
    /// carried the comma into the card as `Calculate five times five,.`
    private func withoutTrailingCalculationNoise(_ text: String) -> String {
        var settled = text
        while true {
            var shortened = Substring(CalculatorService.withoutTrailingEqualsOrQuestionMark(settled))
            while let last = shortened.last,
                  last.unicodeScalars.allSatisfy(SpokenArithmeticNormalizer.trimmablePunctuation.contains) {
                shortened.removeLast()
            }
            let next = String(shortened)
            if next == settled {
                return next
            }
            settled = next
        }
    }

    /// One lead-in or one tail-off, or nil when the text begins and ends with neither. Matched
    /// whole-word against a lowercased copy with the curly apostrophe folded to the straight one,
    /// because `what’s` is what dictation produces and `what's` is what the list holds.
    private func withoutOneCalculationFillerPhrase(
        _ text: String,
        takingLeadIns: Bool
    ) -> String? {
        let lowered = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        for phrase in Self.calculationLeadIns where takingLeadIns && lowered.hasPrefix("\(phrase) ") {
            return String(text.dropFirst(phrase.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for phrase in Self.calculationTailOffs where lowered.hasSuffix(" \(phrase)") {
            return String(text.dropLast(phrase.count))
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

    /// **At least one side has to name a unit** (SONNY-284). Four tokens with a number in front and
    /// `to`/`in` in the middle is also the shape of `convert 5 docs to pdf` and `10 files in folder`,
    /// and while nothing but a bare command could reach this rule that cost only a confusing error,
    /// `convert` is now filler the resolver strips — so without this the widening would hand the
    /// document-conversion verb straight to the calculator.
    ///
    /// **One side rather than both**, because a conversion the calculator cannot do is still a
    /// conversion and deserves its own answer: `5 km to parsecs` reaches the evaluator and is told
    /// `parsecs is not a supported conversion unit`, where the planner would only be able to say the
    /// request is unsupported.
    private func looksLikeBareConversion(_ command: String) -> Bool {
        let parts = command
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
        guard parts.count == 4,
              Double(parts[0]) != nil,
              ["to", "in"].contains(parts[2].lowercased()) else {
            return false
        }
        return CalculatorService.namesConversionUnit(parts[1])
            || CalculatorService.namesConversionUnit(parts[3])
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
        RunRoutineCapabilityAdapter.plan(forRoutineNamed: routine.name)
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

    /// Asks for the body alone — `;trigger = expansion` — and not for the whole command, because the
    /// answer completes the command it is asked about (SONNY-281, `ClarifiedCommand.completions`):
    /// `snippet save` answered `;sig = hello` runs `snippet save ;sig = hello`. The question used to
    /// spell out the prefix too, which was right while the answer went to a planner and wrong once it
    /// joins onto the request — a user following that instruction to the letter produced a trigger
    /// of `snippet save ;sig`.
    private func snippetSaveClarificationPlan() -> AgentPlan {
        AgentPlan(
            summary: "Clarification needed.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify-snippet-save",
                    operation: .clarify,
                    description: "Ask for snippet trigger and expansion.",
                    question: "Use the format ;trigger = expansion."
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

    /// Mirrors `AgentActionExecutor.missingAutomationTargetQuestion`'s cross-kind wording, using
    /// the stored item's canonical name rather than the raw typed candidate.
    private func crossKindQuickDispatchClarificationPlan(
        missingKind: String,
        foundKind: String,
        foundName: String,
        verb: String
    ) -> AgentPlan {
        AgentPlan(
            summary: "Clarification needed.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify-cross-kind-quick-dispatch",
                    operation: .clarify,
                    description: "Ask whether the saved \(foundKind) was meant.",
                    question: "I don't have a \(missingKind) called \"\(foundName)\" saved, but you do have a \(foundKind) called \"\(foundName)\" — did you mean to \(verb) that?"
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

    /// The list this used to hold literally now lives in `SpokenName`, which
    /// `SpokenPath.normalized` reads too (SONNY-242). It was `["my ", "the "]` here and nowhere
    /// else, so a folder phrase the planner emitted — "my Desktop" — reached `PathWhitelist` with
    /// the possessive still on it and resolved to `~/my Desktop`. One list, two callers.
    private func strippedLaunchArticle(_ candidate: String) -> String {
        SpokenName.withoutLeadingArticle(candidate)
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
