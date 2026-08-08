import Foundation
import Testing
@testable import MacAgentCore

@Suite
@MainActor
struct RunningAppAndRecentArtifactsTests {
    @Test
    func resolverBuildsRunningAppSwitchPlans() throws {
        let resolver = InstantCommandResolver()

        guard case .plan(let plan) = resolver.resolve(command: "switch to Notion") else {
            Issue.record("Expected running app switch command to resolve locally.")
            return
        }
        #expect(plan.steps.map(\.operation) == [.switchRunningApp])
        #expect(plan.steps[0].appName == "Notion")

        guard case .clarify(let clarifyPlan) = resolver.resolve(command: "switch") else {
            Issue.record("Expected empty switch command to ask a clarification.")
            return
        }
        #expect(clarifyPlan.steps.map(\.operation) == [.clarify])
        #expect(clarifyPlan.steps[0].question == "Which running app should I switch to?")
    }

    @Test
    func runningAppSwitchUsesTierOneRunnerPathWithoutCatalogAllowlist() async throws {
        let switcher = FakeRunningAppSwitcher(apps: [
            RunningApp(displayName: "Notion", bundleIdentifier: "notion.id", processIdentifier: 100),
            RunningApp(displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", processIdentifier: 101)
        ])
        let executor = AgentActionExecutor(runningAppSwitcher: switcher)
        let runner = AgentRunner(planner: FailingPlanner(), executor: executor)
        let plan = AgentPlan(
            summary: "Switch to Notion.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "switch",
                    operation: .switchRunningApp,
                    description: "Switch to Notion.",
                    appName: "Not"
                )
            ]
        )

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        #expect(prepared.previews.first?.title == "Switch running app")
        #expect(prepared.previews.first?.details.contains("App: Notion") == true)

        let request = try runner.approvalRequest(for: prepared, scope: .unscoped)
        #expect(request.assessment.effectiveTier == .tier1)
        #expect(request.requirement == .autoRun)

        let result = try await runner.execute(prepared, scope: .unscoped)
        #expect(result.summary == "Switched to Notion.")
        #expect(switcher.activatedBundleIdentifiers == ["notion.id"])
    }

    // MARK: - Resolved-app pinning (SONNY-58)

    /// The ticket's headline divergence, end to end. The query "code" catalog-resolves to VS Code —
    /// which is what the old classifier scored, calling the plan in scope — while the only running
    /// match is Xcode, which is what execution would activate. The verdict now binds to the
    /// resolved app: pinned at prepare, out of scope at assessment, tier 3, and the escalation and
    /// approval copy both name Xcode rather than the query.
    @Test
    func theScopeVerdictBindsToTheResolvedAppNotTheQueryString() throws {
        let switcher = FakeRunningAppSwitcher(apps: [
            RunningApp(displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", processIdentifier: 100)
        ])
        let executor = AgentActionExecutor(runningAppSwitcher: switcher)
        let runner = AgentRunner(planner: FailingPlanner(), executor: executor)
        let scope = TaskWorkspaceScope.scoped(
            WorkspaceScope(workspace: StoredWorkspace(name: "Writing", apps: ["VS Code"], urls: []))
        )
        let plan = AgentPlan(
            summary: "Switch to code.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "switch", operation: .switchRunningApp, description: "Switch to code.", appName: "code")
            ]
        )

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        #expect(prepared.plan.steps[0].resolvedAppName == "Xcode")
        #expect(prepared.plan.steps[0].resolvedBundleIdentifier == "com.apple.dt.Xcode")

        let request = try runner.approvalRequest(for: prepared, scope: scope)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.assessment.scopeVerdict == .outOfScope)
        #expect(request.assessment.escalations.contains {
            $0.reason == "Xcode is not part of the Writing workspace."
        })
        // The query string earns nothing and names nothing: no escalation mentions it, and the
        // approval's involved-resource line carries the resolved app.
        #expect(!request.assessment.escalations.contains { $0.reason.hasPrefix("code ") })
        #expect(request.approvalCopy.involvedResource.contains("Xcode"))
    }

    /// The truthful other direction: a partial query whose *resolved* app is the listed one no
    /// longer earns a false out-of-scope prompt. "chrom" resolves nothing in the catalog — the old
    /// classifier scored `name:chrom`, out of scope, tier 3 — but the running app it actually
    /// matches is the Chrome the workspace lists, by bundle id.
    @Test
    func aPartialQueryResolvingToAListedAppIsInScope() async throws {
        let switcher = FakeRunningAppSwitcher(apps: [
            RunningApp(displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 100)
        ])
        let executor = AgentActionExecutor(runningAppSwitcher: switcher)
        let runner = AgentRunner(planner: FailingPlanner(), executor: executor)
        let scope = TaskWorkspaceScope.scoped(
            WorkspaceScope(workspace: StoredWorkspace(name: "Work", apps: ["Chrome"], urls: []))
        )
        let plan = AgentPlan(
            summary: "Switch to chrom.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "switch", operation: .switchRunningApp, description: "Switch to chrom.", appName: "chrom")
            ]
        )

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        let request = try runner.approvalRequest(for: prepared, scope: scope)
        #expect(request.assessment.effectiveTier == .tier1)
        #expect(request.requirement == .autoRun)
        #expect(request.assessment.escalations.isEmpty)
        #expect(request.assessment.scopeVerdict == .inScope)

        let result = try await runner.execute(prepared, scope: scope)
        #expect(result.summary == "Switched to Google Chrome.")
        #expect(switcher.activatedBundleIdentifiers == ["com.google.Chrome"])
    }

    /// One resolution, made at prepare, immutable after. When the pinned app quits — and another
    /// app that would now best-match the query is running — execution fails naming the pinned app;
    /// it never re-matches the query onto something the assessment never scored.
    @Test
    func executionActivatesThePinOrFailsClosedWhenThePinnedAppQuit() async throws {
        let switcher = FakeRunningAppSwitcher(apps: [
            RunningApp(displayName: "Notion", bundleIdentifier: "notion.id", processIdentifier: 100)
        ])
        let executor = AgentActionExecutor(runningAppSwitcher: switcher)
        let runner = AgentRunner(planner: FailingPlanner(), executor: executor)
        let plan = AgentPlan(
            summary: "Switch to Not.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "switch", operation: .switchRunningApp, description: "Switch to Not.", appName: "Not")
            ]
        )

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        #expect(prepared.plan.steps[0].resolvedBundleIdentifier == "notion.id")

        // Notion quits; Notes — a fresh best-match for the query "Not" — is now running.
        switcher.apps = [
            RunningApp(displayName: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 200)
        ]

        await #expect(throws: RunningAppSwitchError.noMatchingRunningApp("Notion")) {
            try await runner.execute(prepared, scope: .unscoped)
        }
        #expect(switcher.activatedBundleIdentifiers.isEmpty)
    }

    /// Pin once, first resolver wins: re-running the resolve phase on an already-pinned plan
    /// changes nothing, even when the list now holds an exact match for the raw query — the pin,
    /// not the query, is the step's identity from prepare onward.
    @Test
    func theResolvePhaseNeverReResolvesAPinnedStep() throws {
        let switcher = FakeRunningAppSwitcher(apps: [
            RunningApp(displayName: "Notion", bundleIdentifier: "notion.id", processIdentifier: 100)
        ])
        let executor = AgentActionExecutor(runningAppSwitcher: switcher)
        let runner = AgentRunner(planner: FailingPlanner(), executor: executor)
        let plan = AgentPlan(
            summary: "Switch to Not.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "switch", operation: .switchRunningApp, description: "Switch to Not.", appName: "Not")
            ]
        )
        let prepared = try runner.prepare(plan: plan, source: .instantResolver)

        switcher.apps = [
            RunningApp(displayName: "Not", bundleIdentifier: "exact.not", processIdentifier: 300),
            RunningApp(displayName: "Notion", bundleIdentifier: "notion.id", processIdentifier: 100)
        ]
        let reprepared = try runner.prepare(plan: prepared.plan, source: .instantResolver)

        #expect(reprepared.plan.steps[0].resolvedAppName == "Notion")
        #expect(reprepared.plan.steps[0].resolvedBundleIdentifier == "notion.id")
    }

    /// An unresolvable query fails at the resolve phase — the earliest gate, before anything is
    /// classified or previewed — with the same error the preview used to throw, and earns no pin.
    @Test
    func anUnresolvableQueryFailsAtPrepareWithoutAPin() {
        let switcher = FakeRunningAppSwitcher(apps: [
            RunningApp(displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", processIdentifier: 100)
        ])
        let executor = AgentActionExecutor(runningAppSwitcher: switcher)
        let runner = AgentRunner(planner: FailingPlanner(), executor: executor)
        let plan = AgentPlan(
            summary: "Switch to notion.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "switch", operation: .switchRunningApp, description: "Switch to notion.", appName: "notion")
            ]
        )

        #expect(throws: RunningAppSwitchError.noMatchingRunningApp("notion")) {
            try runner.prepare(plan: plan, source: .instantResolver)
        }
    }

    @Test
    func recentArtifactStoreRecordsRegularFilesAndAppliesCaps() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecentArtifactStore(fileURL: root.appendingPathComponent("recent.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldFile = try writeFile(named: "old.md", in: root)
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(try store.record(path: folder.path, recordedAt: now) == nil)
        try store.record(path: oldFile.path, recordedAt: now.addingTimeInterval(-RecentArtifactStore.maxAge - 1))
        for index in 0..<105 {
            let file = try writeFile(named: "artifact-\(index).md", in: root)
            try store.record(path: file.path, recordedAt: now.addingTimeInterval(-TimeInterval(index)))
        }

        let artifacts = try store.loadAll(now: now)
        #expect(artifacts.count == RecentArtifactStore.maxItems)
        #expect(artifacts.first?.title == "artifact-0.md")
        #expect(artifacts.last?.title == "artifact-99.md")
        #expect(!artifacts.contains { $0.path == oldFile.path })

        let duplicate = try #require(try store.record(path: artifacts[1].path, recordedAt: now.addingTimeInterval(1)))
        #expect(duplicate.path == artifacts[1].path)
        #expect(try store.loadAll(now: now.addingTimeInterval(1)).first?.path == artifacts[1].path)
    }

    @Test
    func recentArtifactStoreRecordsGeneratedFilesButNotAutomationStores() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecentArtifactStore(fileURL: root.appendingPathComponent("recent.json"))
        let artifact = try writeFile(named: "largest-files.zip", in: root)
        let folder = root.appendingPathComponent("pdfs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let routineFile = try writeFile(named: "routines.json", in: root)

        let generated = AgentRunResult(
            plan: AgentPlan(
                summary: "Create zip.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(id: "zip", operation: .createZip, description: "Create zip.")
                ]
            ),
            previews: [
                ActionPreview(title: "Zip", writes: [artifact.path, folder.path])
            ],
            summary: "Created zip.",
            suggestions: [
                RunSuggestion(title: "Reveal zip", kind: .revealInFinder, value: artifact.path),
                RunSuggestion(title: "Reveal PDFs", kind: .revealInFinder, value: folder.path)
            ]
        )
        #expect(try store.recordGeneratedArtifacts(from: generated) == 1)
        #expect(try store.loadAll().map(\.path) == [artifact.path])

        let automationStoreWrite = AgentRunResult(
            plan: AgentPlan(
                summary: "Save routine.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(id: "routine", operation: .saveRoutine, description: "Save routine.")
                ]
            ),
            previews: [
                ActionPreview(title: "Routine", writes: [routineFile.path])
            ],
            summary: "Saved routine."
        )
        #expect(try store.recordGeneratedArtifacts(from: automationStoreWrite) == 0)
        #expect(try store.loadAll().map(\.path) == [artifact.path])
    }

    @Test
    func recentArtifactLookupUsesTierZeroRunnerPath() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecentArtifactStore(fileURL: root.appendingPathComponent("recent.json"))
        let artifact = try writeFile(named: "research-note.md", in: root)
        try store.record(path: artifact.path)

        let executor = AgentActionExecutor(recentArtifactStore: store)
        let runner = AgentRunner(planner: FailingPlanner(), executor: executor)
        let plan = AgentPlan(
            summary: "Search recent artifacts.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "recent",
                    operation: .lookupRecentArtifacts,
                    description: "Search recent artifacts.",
                    count: 10,
                    searchQuery: "research"
                )
            ]
        )

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        #expect(prepared.previews.first?.title == "Recent artifacts")
        #expect(prepared.previews.first?.details.contains { $0.contains("research-note.md") } == true)

        let request = try runner.approvalRequest(for: prepared, scope: .unscoped)
        #expect(request.assessment.effectiveTier == .tier0)
        #expect(request.requirement == .autoRun)

        let result = try await runner.execute(prepared, scope: .unscoped)
        #expect(result.summary == "Found 1 recent artifact.")
    }

    @Test
    func resolverOpensRecentArtifactThroughExistingOpenGeneratedArtifactOperation() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecentArtifactStore(fileURL: root.appendingPathComponent("recent.json"))
        let artifact = try writeFile(named: "meeting-notes.md", in: root)
        try store.record(path: artifact.path)
        let resolver = InstantCommandResolver(recentArtifactStore: store)

        guard case .plan(let openPlan) = resolver.resolve(command: "open recent artifact meeting") else {
            Issue.record("Expected recent artifact open command to resolve locally.")
            return
        }
        #expect(openPlan.steps.map(\.operation) == [.openGeneratedArtifact])
        #expect(openPlan.steps[0].outputPath == artifact.path)

        guard case .clarify(let clarifyPlan) = resolver.resolve(command: "open recent artifact missing") else {
            Issue.record("Expected missing recent artifact open command to ask a clarification.")
            return
        }
        #expect(clarifyPlan.steps.map(\.operation) == [.clarify])
        #expect(clarifyPlan.steps[0].question?.contains("missing") == true)
    }

    @Test
    func agentRunnerRecordsArtifactsAfterSuccessfulExecutionOnly() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecentArtifactStore(fileURL: root.appendingPathComponent("recent.json"))
        let output = root.appendingPathComponent("draft.md")
        let executor = AgentActionExecutor(
            whitelist: PathWhitelist(roots: [root]),
            recentArtifactStore: store
        )
        let logStore = AgentLogStore()
        let runner = AgentRunner(
            planner: FailingPlanner(),
            executor: executor,
            logStore: logStore,
            recentArtifactStore: store
        )
        let plan = AgentPlan(
            summary: "Create draft.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Create draft.",
                    outputPath: output.path,
                    draftTitle: "Draft",
                    draftContent: "Hello"
                )
            ]
        )

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        #expect(try store.loadAll().isEmpty)

        let result = try await runner.execute(prepared, approvalDecision: .approved(.tier2), scope: .unscoped)
        #expect(result.summary == "Created local draft at \(output.path).")
        #expect(try store.loadAll().map(\.path) == [output.path])
        #expect(logStore.events.contains { $0.phase == .observe && $0.message == "Recorded 1 recent artifact" })
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunningAppAndRecentArtifactsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("artifact".utf8).write(to: url, options: .atomic)
        return url
    }
}

@MainActor
private final class FakeRunningAppSwitcher: RunningAppSwitching {
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

private struct FailingPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        Issue.record("Planner should not be called for running app or recent artifact instant commands.")
        throw PlannerError.missingAPIKey
    }
}
