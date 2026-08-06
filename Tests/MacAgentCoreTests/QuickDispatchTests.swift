import Foundation
import Testing
@testable import MacAgentCore

@Suite
@MainActor
struct QuickDispatchTests {
    @Test
    func resolverBuildsQuickRoutineAndWorkspacePlansForKnownSavedNames() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try routineStore.save(StoredRoutine(name: "Morning Setup", steps: [openSafariStep()]))
        try workspaceStore.save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"]))
        let resolver = InstantCommandResolver(routineStore: routineStore, workspaceStore: workspaceStore)

        guard case .plan(let routinePlan) = resolver.resolve(command: "run morning setup") else {
            Issue.record("Expected saved routine launch to resolve locally.")
            return
        }
        #expect(routinePlan.steps.map(\.operation) == [.runRoutine])
        #expect(routinePlan.steps[0].routineName == "Morning Setup")

        guard case .plan(let workspacePlan) = resolver.resolve(command: "open research workspace") else {
            Issue.record("Expected saved workspace launch to resolve locally.")
            return
        }
        #expect(workspacePlan.steps.map(\.operation) == [.openWorkspace])
        #expect(workspacePlan.steps[0].workspaceName == "Research")

        #expect(resolver.resolve(command: "run missing setup") == nil)
    }

    @Test
    func directLaunchCollisionsDeferToThePlanner() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Slack", apps: ["Notes"], urls: []))
        try routineStore.save(StoredRoutine(name: "Deep Work", steps: [openSafariStep()]))
        try workspaceStore.save(StoredWorkspace(name: "Deep Work", apps: ["Safari"], urls: []))
        let resolver = InstantCommandResolver(routineStore: routineStore, workspaceStore: workspaceStore)

        // A workspace named like an allowlisted app: "open Slack" is ambiguous and must reach
        // the planner, while the explicit kind-prefixed form stays instant.
        #expect(resolver.resolve(command: "open Slack") == nil)
        guard case .plan(let workspacePlan) = resolver.resolve(command: "open workspace Slack") else {
            Issue.record("Expected explicit workspace launch to resolve locally.")
            return
        }
        #expect(workspacePlan.steps[0].workspaceName == "Slack")

        // The same name saved as both a routine and a workspace: direct prefixes are ambiguous.
        #expect(resolver.resolve(command: "start Deep Work") == nil)
        guard case .plan(let routinePlan) = resolver.resolve(command: "run routine Deep Work") else {
            Issue.record("Expected explicit routine launch to resolve locally.")
            return
        }
        #expect(routinePlan.steps[0].routineName == "Deep Work")
    }

    /// The exact case from manual testing: a workspace saved as "slack" (lowercase) while
    /// "Slack" is an allowlisted app. `resolve()` must return nil so the real planner decides,
    /// rather than instant-running the workspace behind the user's back.
    @Test
    func lowercaseWorkspaceNamedLikeAnAllowlistedAppDefersToThePlanner() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(
            StoredWorkspace(name: "slack", apps: ["Notes"], urls: ["https://example.com"])
        )
        let resolver = InstantCommandResolver(
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: workspaceStore
        )

        #expect(resolver.resolve(command: "open Slack") == nil)
        #expect(resolver.resolve(command: "open slack") == nil)
        #expect(resolver.resolve(command: "launch Slack") == nil)

        // The explicit form is unambiguous and must still resolve instantly.
        guard case .plan(let plan) = resolver.resolve(command: "open workspace slack") else {
            Issue.record("Expected the explicit workspace form to resolve locally.")
            return
        }
        #expect(plan.steps.map(\.operation) == [.openWorkspace])
        #expect(plan.steps[0].workspaceName == "slack")
    }

    /// The seventh manual-pass case: "run hehe" where hehe is only a saved *workspace* used to
    /// fall through to the planner, which cannot name saved items and asked a generic question.
    /// The kind-locked verb must clarify with the item that actually exists — and never silently
    /// cross-resolve.
    @Test
    func runOfASavedWorkspaceNameClarifiesCrossKindInsteadOfReachingThePlanner() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Hehe", apps: ["Safari"], urls: []))
        let resolver = InstantCommandResolver(
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: workspaceStore
        )

        guard case .clarify(let plan) = resolver.resolve(command: "run hehe") else {
            Issue.record("Expected a cross-kind clarification, not planner fallthrough.")
            return
        }
        #expect(plan.steps.map(\.operation) == [.clarify])
        let question = try #require(plan.steps.first?.question)
        #expect(question.contains("I don't have a routine called \"Hehe\""))
        // Canonical stored name, not the raw lowercase typed candidate.
        #expect(question.contains("but you do have a workspace called \"Hehe\""))
        #expect(question.contains("did you mean to open that?"))
    }

    @Test
    func openOfASavedRoutineNameClarifiesCrossKind() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(StoredRoutine(name: "vibe", steps: [openSafariStep()]))
        let resolver = InstantCommandResolver(
            routineStore: routineStore,
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        )

        guard case .clarify(let plan) = resolver.resolve(command: "open vibe") else {
            Issue.record("Expected a cross-kind clarification, not planner fallthrough.")
            return
        }
        let question = try #require(plan.steps.first?.question)
        #expect(question.contains("I don't have a workspace called \"vibe\""))
        #expect(question.contains("but you do have a routine called \"vibe\""))
        #expect(question.contains("did you mean to run that?"))
    }

    /// The kind-prefixed form misses cross-kind the same way: "run routine hehe" where hehe is
    /// only a workspace gets the same clarification, via the explicit candidates.
    @Test
    func kindPrefixedRoutineFormWithAWorkspaceOnlyNameClarifies() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "hehe", apps: ["Safari"], urls: []))
        let resolver = InstantCommandResolver(
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: workspaceStore
        )

        guard case .clarify(let plan) = resolver.resolve(command: "run routine hehe") else {
            Issue.record("Expected the kind-prefixed cross-kind miss to clarify.")
            return
        }
        let question = try #require(plan.steps.first?.question)
        #expect(question.contains("but you do have a workspace called \"hehe\""))
        #expect(question.contains("did you mean to open that?"))
    }

    @Test
    func kindPrefixedWorkspaceFormWithARoutineOnlyNameClarifies() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(StoredRoutine(name: "vibe", steps: [openSafariStep()]))
        let resolver = InstantCommandResolver(
            routineStore: routineStore,
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        )

        guard case .clarify(let plan) = resolver.resolve(command: "open workspace vibe") else {
            Issue.record("Expected the kind-prefixed cross-kind miss to clarify.")
            return
        }
        let question = try #require(plan.steps.first?.question)
        #expect(question.contains("but you do have a routine called \"vibe\""))
        #expect(question.contains("did you mean to run that?"))
    }

    /// A name saved nowhere still reaches the planner — the cross-kind check must not overreach.
    @Test
    func runOfANameSavedNowhereStillReturnsNilToThePlanner() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "hehe", apps: ["Safari"], urls: []))
        let resolver = InstantCommandResolver(
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: workspaceStore
        )

        #expect(resolver.resolve(command: "run ghost") == nil)
    }

    /// "start" sits in both direct-prefix lists and already resolved cross-kind before this fix —
    /// guard that the both-verbs path still resolves straight to a plan, not a clarification.
    @Test
    func startOfASavedWorkspaceStillResolvesInstantly() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "hehe", apps: ["Safari"], urls: []))
        let resolver = InstantCommandResolver(
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: workspaceStore
        )

        guard case .plan(let plan) = resolver.resolve(command: "start hehe") else {
            Issue.record("Expected the both-verbs form to keep resolving instantly.")
            return
        }
        #expect(plan.steps.map(\.operation) == [.openWorkspace])
        #expect(plan.steps[0].workspaceName == "hehe")
    }

    /// Three-way ambiguity — the cross-kind name also names an allowlisted app — steps aside to
    /// the planner, consistent with the existing direct-form collision handling.
    @Test
    func crossKindNameThatAlsoNamesAnAllowlistedAppDefersToThePlanner() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Slack", apps: ["Notes"], urls: []))
        let resolver = InstantCommandResolver(
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: workspaceStore
        )

        #expect(resolver.resolve(command: "run Slack") == nil)
    }

    @Test
    func broadRunningAppPrefixesOnlyClaimPlausibleAppNames() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = InstantCommandResolver(
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        )

        #expect(resolver.resolve(command: "focus on writing my essay") == nil)
        #expect(resolver.resolve(command: "activate dark mode") == nil)

        guard case .plan(let plan) = resolver.resolve(command: "switch to Safari") else {
            Issue.record("Expected a plain app name to keep resolving locally.")
            return
        }
        #expect(plan.steps.map(\.operation) == [.switchRunningApp])
        #expect(plan.steps[0].appName == "Safari")
    }

    @Test
    func instantRoutineWithTierTwoNestedStepStillRequiresApproval() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("draft.md")
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(StoredRoutine(name: "Draft Routine", steps: [draftStep(output: output)]))
        let resolver = InstantCommandResolver(routineStore: routineStore)
        guard case .plan(let plan) = resolver.resolve(command: "run draft routine") else {
            Issue.record("Expected saved routine launch to resolve locally.")
            return
        }
        let runner = AgentRunner(
            planner: FailingPlanner(),
            executor: makeExecutor(root: root, routineStore: routineStore)
        )

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped)

        #expect(request.assessment.effectiveTier == .tier2)
        #expect(request.requirement == .lightweightConfirmation)
        #expect(request.requirement != .autoRun)

        do {
            _ = try await runner.execute(prepared, scope: .unscoped)
            Issue.record("Expected instant routine launch to pause for tier 2 approval.")
        } catch RiskApprovalError.approvalRequired(let approvalRequest) {
            #expect(approvalRequest.requirement == .lightweightConfirmation)
            #expect(approvalRequest.assessment.effectiveTier == .tier2)
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test
    func instantRoutineWithTierThreeNestedEscalationRequiresExplicitApproval() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("existing-draft.md")
        try Data("original".utf8).write(to: output)
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(StoredRoutine(name: "Overwrite Draft", steps: [draftStep(output: output)]))
        let resolver = InstantCommandResolver(routineStore: routineStore)
        guard case .plan(let plan) = resolver.resolve(command: "Overwrite Draft") else {
            Issue.record("Expected exact saved routine name to resolve locally.")
            return
        }
        let runner = AgentRunner(
            planner: FailingPlanner(),
            executor: makeExecutor(root: root, routineStore: routineStore)
        )

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped)

        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.requirement != .autoRun)

        do {
            _ = try await runner.execute(prepared, scope: .unscoped)
            Issue.record("Expected instant routine launch to pause for explicit tier 3 approval.")
        } catch RiskApprovalError.approvalRequired(let approvalRequest) {
            #expect(approvalRequest.requirement == .explicitApproval)
            #expect(approvalRequest.assessment.effectiveTier == .tier3)
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        #expect(try String(contentsOf: output, encoding: .utf8) == "original")
    }

    @Test
    func instantWorkspaceTierOneLaunchAutoRuns() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"]))
        let resolver = InstantCommandResolver(workspaceStore: workspaceStore)
        guard case .plan(let plan) = resolver.resolve(command: "open my research workspace") else {
            Issue.record("Expected saved workspace launch to resolve locally.")
            return
        }
        let appOpener = RecordingAppOpener()
        let browserOpener = RecordingBrowserOpener()
        let runner = AgentRunner(
            planner: FailingPlanner(),
            executor: makeExecutor(
                root: root,
                browserOpener: browserOpener,
                appOpener: appOpener,
                workspaceStore: workspaceStore
            )
        )

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped)
        let result = try await runner.execute(prepared, scope: .unscoped)

        #expect(request.assessment.effectiveTier == .tier1)
        #expect(request.requirement == .autoRun)
        #expect(appOpener.openedBundleIDs == ["com.apple.Safari"])
        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com"])
        // Browser targeting survives the planner-free instant-resolver path too.
        #expect(browserOpener.openedBrowsers.map { $0?.bundleIdentifier } == ["com.apple.Safari"])
        #expect(result.summary == "Opened workspace Research with 1 app(s) and 1 URL(s).")
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickDispatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutor(
        root: URL,
        browserOpener: BrowserOpening = NoopBrowserOpener(),
        appOpener: AppOpening = NoopAppOpener(),
        routineStore: RoutineStore? = nil,
        workspaceStore: WorkspaceStore? = nil
    ) -> AgentActionExecutor {
        AgentActionExecutor(
            whitelist: PathWhitelist(roots: [root]),
            browserOpener: browserOpener,
            appOpener: appOpener,
            routineStore: routineStore ?? RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: workspaceStore ?? WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        )
    }

    private func openSafariStep() -> AgentStep {
        AgentStep(
            id: "open-safari",
            operation: .openApp,
            description: "Open Safari.",
            appName: "Safari"
        )
    }

    private func draftStep(output: URL) -> AgentStep {
        AgentStep(
            id: "create-draft",
            operation: .createLocalDraft,
            description: "Create draft.",
            outputPath: output.path,
            draftTitle: "Draft",
            draftContent: "Draft body."
        )
    }
}

private struct FailingPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        Issue.record("Planner should not be called for quick routine/workspace dispatch.")
        throw PlannerError.missingAPIKey
    }
}

private struct NoopBrowserOpener: BrowserOpening {
    func open(_ url: URL, using browser: MacApp?) async throws {}
}

@MainActor
private final class RecordingBrowserOpener: BrowserOpening {
    private(set) var openedURLs: [URL] = []
    /// Parallel to `openedURLs`: the browser each open was targeted at, `nil` for the system default.
    private(set) var openedBrowsers: [MacApp?] = []

    func open(_ url: URL, using browser: MacApp?) async throws {
        openedURLs.append(url)
        openedBrowsers.append(browser)
    }
}

private struct NoopAppOpener: AppOpening {
    func open(bundleIdentifier: String) async throws {}
}

@MainActor
private final class RecordingAppOpener: AppOpening {
    private(set) var openedBundleIDs: [String] = []

    func open(bundleIdentifier: String) async throws {
        openedBundleIDs.append(bundleIdentifier)
    }
}
