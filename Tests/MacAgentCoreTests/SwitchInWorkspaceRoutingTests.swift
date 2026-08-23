import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-68 — the four misroutes recorded on the ticket, pinned as regressions.
///
/// Every one of them was typed at the real app during SONNY-58's manual pass, and every one became
/// something other than an app switch: two became `edit_workspace` (one a removal the user approved
/// believing it was setup), one became an `edit_workspace` *add* of the literal query string, one
/// became a failing `open_app`. The single cause was that the workspace clause pushed the candidate
/// app name past `looksLikeRunningAppName`'s three-word ceiling, so the resolver declined and the
/// planner — which had no `switch_running_app` in its schema — spent the intent on whichever
/// operation the sentence vaguely fit.
///
/// These assert the concrete routing, not that something resolved: the operation, the exact query
/// carried into the plan, the workspace the task still binds to, and — the negative that names the
/// class — that no switch phrasing produces a workspace edit.
@Suite
struct SwitchInWorkspaceRoutingTests {
    /// Observation 1: *"switch to code in the workspace Switch"* → planned as "Update the Switch
    /// workspace to use VS Code instead of Chrome", a tier-3 removal the user approved.
    @Test
    func theRemovalMisrouteResolvesToASwitchCarryingOnlyTheAppName() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        try fixture.assertSwitchPlan(for: "switch to code in the workspace Switch", appName: "code")
    }

    /// Observation 2: *"switch to the code app in the workspace Switch"* → `open_app`, which failed
    /// on the twelve-app launch catalog ("cannot open code app"). The article and the trailing
    /// "app" are part of how people name an app out loud, so the candidate is narrowed to the name
    /// itself rather than handed to the planner.
    @Test
    func theCatalogMisrouteResolvesToASwitchOnceTheArticleAndAppSuffixAreDropped() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        try fixture.assertSwitchPlan(for: "switch to the code app in the workspace Switch", appName: "code")
    }

    /// SONNY-242 merged this file's article list into the shared `SpokenName.leadingArticles` and
    /// widened it from `["my", "the"]` to four words, which this site could not afford: a plan
    /// carries one `appName`, so it discards the original candidate and every strippable word is a
    /// word an app can no longer be called. "our standup app" became `standup`, so an app really
    /// called *Our Standup* was unreachable — and would have silently activated a running *Standup*
    /// instead. The strippable set is now the intersection with `runningAppLeadingStopWords`, which
    /// is the only reason this site strips at all, so the pair below both hold: `the` still comes
    /// off because the guard rejects it, and `our` stays on because the guard never did.
    /// (PR #106 review, F3.)
    @Test
    func onlyTheArticlesTheGuardRejectsComeOffAnAppName() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        try fixture.assertSwitchPlan(for: "switch to our standup app in the workspace Switch", appName: "our standup")
        try fixture.assertSwitchPlan(for: "switch to your standup app in the workspace Switch", appName: "your standup")
        try fixture.assertSwitchPlan(for: "switch to the standup app in the workspace Switch", appName: "standup")
        try fixture.assertSwitchPlan(for: "switch to my standup app in the workspace Switch", appName: "standup")
    }

    /// Observation 3: *"switch to xcod in the workspace Switch"* → an `edit_workspace` **add** of
    /// the literal string "xcod" to the workspace. A clean prefix of a running app, turned into a
    /// stored boundary entry.
    @Test
    func thePrefixQueryMisrouteResolvesToASwitchRatherThanAWorkspaceAddition() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        try fixture.assertSwitchPlan(for: "switch to xcod in the workspace Switch", appName: "xcod")
    }

    /// Observation 4: *"Switch to zoom in my Switch workspace"* → another workspace edit. This
    /// phrasing puts the name ahead of the noun, the order the scope binder did not recognise
    /// either, so it was the one command of the four whose named workspace Sonny could not see at
    /// all. Both halves are fixed together — see `theClauseThatIsSubtractedIsTheClauseThatBinds`.
    @Test
    func theNameBeforeNounClauseResolvesToASwitchAndKeepsOriginalCasing() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        // The command as recorded, lower-case.
        try fixture.assertSwitchPlan(for: "Switch to zoom in my Switch workspace", appName: "zoom")
        // A re-cased variant, because a lower-case input cannot tell preserved casing apart from
        // lower-casing — the folded text the clause is matched in is lower-case throughout, so the
        // query surviving with a capital is what proves the index map hands back the caller's own
        // characters.
        try fixture.assertSwitchPlan(for: "Switch to Zoom in my Switch workspace", appName: "Zoom")
    }

    /// **The invariant the subtraction rests on.** The resolver is allowed to drop the workspace
    /// clause from the app query only because that same clause is what binds the task's workspace —
    /// so nothing the user typed is discarded, it is consumed somewhere else. Asserted for all four
    /// commands at once, because a fix that made the query right and the scope vanish would be a
    /// quieter version of the same bug.
    @Test
    func theClauseThatIsSubtractedIsTheClauseThatBinds() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        for command in Fixture.recordedMisroutes {
            let resolution = fixture.resolver.resolve(command: command)
            guard case .plan(let plan) = resolution else {
                Issue.record("Expected \(command) to resolve to a plan.")
                continue
            }
            #expect(
                WorkspaceTaskTagging.resolvedWorkspaceName(
                    command: command,
                    plan: plan,
                    routineStore: fixture.routineStore,
                    workspaceStore: fixture.workspaceStore
                ) == "Switch",
                "\(command) must still bind the workspace it names."
            )
        }
    }

    /// The class, stated as a negative: no switch phrasing carrying a workspace clause produces a
    /// workspace mutation of any kind. Written against the operation set rather than one operation
    /// so a future misroute into `create_workspace` or `open_workspace` fails here too.
    @Test
    func noSwitchPhrasingCarryingAWorkspaceClauseProducesAWorkspaceMutation() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let mutations: Set<AgentOperation> = [.editWorkspace, .createWorkspace, .openWorkspace]
        for command in Fixture.recordedMisroutes {
            guard case .plan(let plan)? = fixture.resolver.resolve(command: command) else {
                Issue.record("Expected \(command) to resolve locally rather than reaching the planner.")
                continue
            }
            #expect(plan.steps.allSatisfy { !mutations.contains($0.operation) }, "\(command) mutated a workspace.")
        }
    }

    /// A clause naming a workspace that is not saved is left alone. The recogniser matches real
    /// saved names only, so there is no clause to subtract and no scope to bind — the command falls
    /// to the planner exactly as it does today, and an `edit_workspace` on a name that matches
    /// nothing becomes a clarification rather than a boundary change.
    @Test
    func aClauseNamingAnUnsavedWorkspaceIsNotSubtracted() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        #expect(fixture.resolver.resolve(command: "switch to code in the workspace Nowhere") == nil)
    }

    /// **The base-parity table: every rejection the guard makes, measured at `48d0150` and required
    /// to be identical here.**
    ///
    /// This exists because the first version of the fix broke exactly this and nothing caught it.
    /// An unconditional article trim ran ahead of the guard and disabled two of its eight leading
    /// stop words — `the` and `my` — so nine measured phrasings that fell through to the planner at
    /// base were captured as doomed app queries instead. The worst of them are workspace-opening
    /// asks, which is this ticket's own subject matter: "switch to my Research workspace" reached
    /// the planner's `open_workspace` rule before SONNY-68 and must still reach it.
    ///
    /// Every command below returned `nil` at `48d0150` (measured with a temporary probe against the
    /// real resolver in a detached worktree at that SHA), with the single stated exception. The
    /// contract that makes this hold structurally rather than by luck: with no workspace clause
    /// recognised, `runningAppCandidate` returns the remainder untouched apart from edge
    /// punctuation, so the guard sees what it always saw.
    @Test
    func everyGuardRejectionBehavesExactlyAsItDidAtTheBaseCommit() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        // All eight leading stop words, one command each. Base: nil, every one.
        for command in [
            "focus on writing my essay",   // on
            "switch to to do list",        // to
            "switch to in tray",           // in
            "switch to at work",           // at
            "switch to the Notes app",     // the
            "switch to a browser",         // a
            "switch to an editor",         // an
            "focus my essay"               // my
        ] {
            #expect(fixture.resolver.resolve(command: command) == nil, "\(command) must still fall to the planner.")
        }

        // The other two guard rules, unchanged. Base: nil, both.
        #expect(fixture.resolver.resolve(command: "activate dark mode") == nil)
        #expect(fixture.resolver.resolve(command: "switch to one two three four") == nil)

        // The nine workspace-opening phrasings the review measured. Base: nil for the first eight;
        // the ninth was claimed at base and is deliberately left alone, since changing it would be
        // a divergence of its own rather than a restoration.
        for command in [
            "switch to the workspace Switch",
            "switch to my Research workspace",
            "switch to the Research workspace",
            "switch to my Switch workspace",
            "focus the Research workspace",
            "activate my Research workspace",
            "switch to the workspace",
            "switch to my workspace",
            "switch to my mail"
        ] {
            #expect(fixture.resolver.resolve(command: command) == nil, "\(command) must still fall to the planner.")
        }
        // Base: switch_running_app("Research workspace") — pre-existing, and pre-existing is what it
        // stays. Asserted so a later widening cannot quietly claim this was always the intent.
        try fixture.assertSwitchPlan(for: "switch to Research workspace", appName: "Research workspace")

        // A clause-carrying residue gets no special licence either: the clause comes off, and what
        // is left is judged by the same guard, leading stop word and all.
        #expect(fixture.resolver.resolve(command: "switch to my essay in the workspace Switch") == nil)
        #expect(fixture.resolver.resolve(command: "focus on code in my Switch workspace") == nil)
        #expect(fixture.resolver.resolve(command: "switch to in the workspace Switch") == nil)
    }

    /// New behaviour, named as new (PR #39 review, cycle 1, F2). Each of these returned `nil` at
    /// `48d0150`; none of them is a preserved case, and asserting them inside a test named for
    /// unchanged behaviour is what the review caught.
    ///
    /// The naming form, not an article rule: a clause-carrying residue shaped `[the|my] NAME app`
    /// resolves to NAME, because the trailing noun is what declares the phrase names an app.
    /// Without the clause the same words are refused — which is the base-parity row above for
    /// "switch to the Notes app", and the reason this normalisation cannot leak into the guard.
    @Test
    func theAppNamingFormIsRecognisedOnlyInsideAClauseCarryingCommand() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        try fixture.assertSwitchPlan(for: "switch to the code app in the workspace Switch", appName: "code")
        try fixture.assertSwitchPlan(for: "switch to the Notes app in my Switch workspace", appName: "Notes")
        try fixture.assertSwitchPlan(for: "switch to code app in the workspace Switch", appName: "code")

        // Base: nil. Head: still nil — the clause-free form of the same words.
        #expect(fixture.resolver.resolve(command: "switch to the code app") == nil)
    }

    /// New behaviour (PR #39 review, cycle 1, F3): edge punctuation comes off the candidate, so a
    /// typed full stop no longer strands itself in the query.
    ///
    /// The clause-carrying shapes are newly reachable — they could not reach the resolver at all
    /// before this ticket — but **the bare form was already broken at `48d0150`**, where
    /// "switch to chrome." resolved to `appName "chrome."` and then failed by name because
    /// `RunningAppMatcher.normalize` folds spaces and not punctuation. That older kind is fixed
    /// here too; it is the one place this branch deliberately diverges from base on a clause-free
    /// command.
    @Test
    func edgePunctuationIsStrippedFromTheQueryOnBothTheBareAndClauseCarryingShapes() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        // Base: switch_running_app("chrome.") — claimed, then doomed at the matcher.
        try fixture.assertSwitchPlan(for: "switch to chrome.", appName: "chrome")

        // Base: nil for all four; the headline command is the one the manual checklist asks the
        // user to type, so a typed full stop is a realistic way to fail it.
        try fixture.assertSwitchPlan(for: "switch to code in the workspace Switch.", appName: "code")
        try fixture.assertSwitchPlan(for: "switch to code in the workspace Switch!", appName: "code")
        try fixture.assertSwitchPlan(for: "switch to code, in the workspace Switch", appName: "code")
        try fixture.assertSwitchPlan(for: "switch to code (in the workspace Switch)", appName: "code")

        // Interior punctuation is left alone — it is part of real names.
        try fixture.assertSwitchPlan(for: "switch to zoom.us", appName: "zoom.us")
    }

    /// The phrasings that already resolved keep resolving, and the quick-dispatch precedence ahead
    /// of the running-app prefixes is unchanged. Base: each of these resolved identically at
    /// `48d0150`.
    @Test
    func thePhrasingsThatAlreadyResolvedAreUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        try fixture.assertSwitchPlan(for: "switch to chrom", appName: "chrom")
        try fixture.assertSwitchPlan(for: "switch to fin", appName: "fin")
        try fixture.assertSwitchPlan(for: "switch to Safari", appName: "Safari")

        // Quick dispatch still wins ahead of the running-app prefixes, and this fixture is the
        // sharpest case of it: the workspace really is named "Switch", so the bare word is an exact
        // saved-name match and opens the workspace. Untouched by this ticket — the clause-carrying
        // form above is what changed, not the whole-command form. (The bare verb's clarification,
        // which needs a store with no such collision, stays pinned in
        // `RunningAppAndRecentArtifactsTests.resolverBuildsRunningAppSwitchPlans`.)
        guard case .plan(let bareVerbPlan)? = fixture.resolver.resolve(command: "switch") else {
            Issue.record("A bare command matching a saved workspace name must still open it.")
            return
        }
        #expect(bareVerbPlan.steps.map(\.operation) == [.openWorkspace])
        #expect(bareVerbPlan.steps[0].workspaceName == "Switch")
    }

    /// The scoped switch this makes reachable, through the executor rather than the resolver alone:
    /// the resolver's own plan, run under the workspace the command named, earns SONNY-58's verdict
    /// from the app that will actually be activated. In scope it stays tier 1; out of scope it is a
    /// tier-3 approval naming the resolved app — never quieter than the same action is today.
    @Test
    @MainActor
    func theResolvedPlanEarnsItsScopeVerdictFromTheAppThatWillBeActivated() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        guard case .plan(let plan)? = fixture.resolver.resolve(command: "switch to xcod in the workspace Switch") else {
            Issue.record("Expected the clause-carrying command to resolve locally.")
            return
        }

        let switcher = StubRunningAppSwitcher(apps: [
            RunningApp(displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", processIdentifier: 100)
        ])
        let runner = AgentRunner(
            planner: UncalledPlanner(),
            executor: AgentActionExecutor(runningAppSwitcher: switcher)
        )
        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        #expect(prepared.plan.steps[0].resolvedAppName == "Xcode")

        let outOfScope = try runner.approvalRequest(
            for: prepared,
            scope: .scoped(WorkspaceScope(workspace: StoredWorkspace(name: "Switch", apps: ["Chrome"], urls: []))),
            context: ApprovalContext(mode: .normal, appControl: .notApplicable)
        )
        #expect(outOfScope.assessment.effectiveTier == .tier3)
        #expect(outOfScope.assessment.scopeVerdict == .outOfScope)
        #expect(outOfScope.assessment.escalations.contains {
            $0.reason == "Xcode is not part of the Switch workspace."
        })

        let inScope = try runner.approvalRequest(
            for: prepared,
            scope: .scoped(WorkspaceScope(workspace: StoredWorkspace(name: "Switch", apps: ["Xcode"], urls: []))),
            context: ApprovalContext(mode: .normal, appControl: .notApplicable)
        )
        #expect(inScope.assessment.effectiveTier == .tier1)
        #expect(inScope.assessment.scopeVerdict == .inScope)
    }

    /// The fail-closed direction, which the ticket's own final pass recorded as the correct
    /// outcome: a claimed switch query that matches no running app fails by name on the switch
    /// path. It does not become a plan of some other kind, and it does not silently do nothing.
    @Test
    @MainActor
    func anUnmatchedQueryFailsOnTheSwitchPathRatherThanBecomingAnotherOperation() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        guard case .plan(let plan)? = fixture.resolver.resolve(command: "switch to xcod in the workspace Switch") else {
            Issue.record("Expected the clause-carrying command to resolve locally.")
            return
        }

        let runner = AgentRunner(
            planner: UncalledPlanner(),
            executor: AgentActionExecutor(runningAppSwitcher: StubRunningAppSwitcher(apps: []))
        )
        #expect(throws: RunningAppSwitchError.noMatchingRunningApp("xcod")) {
            _ = try runner.prepare(plan: plan, source: .instantResolver)
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        /// Verbatim, as recovered from the task-history record on SONNY-68 — the fourth entry is
        /// lower-case "zoom" because that is what was typed, and the comment recovering it exists
        /// precisely to correct an earlier recollection error (PR #39 review, cycle 1, F6). A
        /// re-cased variant is asserted separately, where casing is the thing under test.
        static let recordedMisroutes = [
            "switch to code in the workspace Switch",
            "switch to the code app in the workspace Switch",
            "switch to xcod in the workspace Switch",
            "Switch to zoom in my Switch workspace"
        ]

        let root: URL
        let routineStore: RoutineStore
        let workspaceStore: WorkspaceStore
        let resolver: InstantCommandResolver

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SwitchInWorkspaceRoutingTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
            workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
            try workspaceStore.save(StoredWorkspace(name: "Switch", apps: ["Chrome"], urls: []))
            resolver = InstantCommandResolver(
                snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
                routineStore: routineStore,
                workspaceStore: workspaceStore
            )
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }

        func assertSwitchPlan(
            for command: String,
            appName: String,
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws {
            guard case .plan(let plan)? = resolver.resolve(command: command) else {
                Issue.record("Expected \(command) to resolve to a plan.", sourceLocation: sourceLocation)
                return
            }
            #expect(plan.steps.map(\.operation) == [.switchRunningApp], sourceLocation: sourceLocation)
            #expect(plan.steps[0].appName == appName, sourceLocation: sourceLocation)
            #expect(plan.summary == "Switch to \(appName).", sourceLocation: sourceLocation)
        }
    }
}

@MainActor
private final class StubRunningAppSwitcher: RunningAppSwitching {
    var apps: [RunningApp]
    var activatedBundleIdentifiers: [String] = []

    init(apps: [RunningApp]) {
        self.apps = apps
    }

    func runningApps() -> [RunningApp] {
        apps
    }

    func activate(bundleIdentifier: String) async throws {
        guard apps.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw RunningAppSwitchError.noMatchingRunningApp(bundleIdentifier)
        }
        activatedBundleIdentifiers.append(bundleIdentifier)
    }
}

private struct UncalledPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        Issue.record("The planner must not be reached for an instant-resolved switch command.")
        throw PlannerError.missingAPIKey
    }
}
