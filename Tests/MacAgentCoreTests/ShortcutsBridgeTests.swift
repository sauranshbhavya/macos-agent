import Foundation
import Testing
@testable import MacAgentCore

@Suite
@MainActor
struct ShortcutsBridgeTests {
    @Test
    func instantResolverBuildsShortcutPlanAndClarifiesUnknownNames() throws {
        let resolver = InstantCommandResolver(shortcutCatalog: FakeShortcutCatalog(names: ["Morning Routine"]))

        guard case .plan(let plan) = resolver.resolve(command: "run my Morning Routine shortcut") else {
            Issue.record("Expected known Shortcut command to resolve locally.")
            return
        }
        #expect(plan.steps.map(\.operation) == [.invokeShortcut])
        #expect(plan.steps[0].shortcutName == "Morning Routine")

        guard case .clarify(let clarifyPlan) = resolver.resolve(command: "run Missing shortcut") else {
            Issue.record("Expected unknown Shortcut command to ask a clarification.")
            return
        }
        #expect(clarifyPlan.steps.map(\.operation) == [.clarify])
        #expect(clarifyPlan.steps[0].question?.contains("Missing") == true)
    }

    @Test
    func plannerShortcutWithUnknownNameBecomesClarifyPlan() throws {
        let runner = AgentRunner(
            planner: FailingPlanner(),
            executor: makeExecutor(catalog: FakeShortcutCatalog(names: ["Morning Routine"]))
        )

        let prepared = try runner.prepare(
            plan: shortcutPlan(name: "Mornign Routine"),
            source: .planner
        )

        #expect(prepared.plan.steps.map(\.operation) == [.clarify])
        #expect(prepared.clarificationQuestion?.contains("Mornign Routine") == true)
        #expect(prepared.previews.first?.title == "Clarification needed")
    }

    @Test
    func shortcutWithoutHistoryIsTierTwoAndSuccessDemotesFutureRuns() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = ShortcutRunHistoryStore(fileURL: root.appendingPathComponent("shortcuts-history.json"))
        let invoker = FakeShortcutInvoker(results: [
            ProcessResult(terminationStatus: 0, output: "done\n")
        ])
        let runner = AgentRunner(
            planner: FailingPlanner(),
            executor: makeExecutor(
                catalog: FakeShortcutCatalog(names: ["Morning Routine"]),
                invoker: invoker,
                history: history
            )
        )
        let plan = shortcutPlan(name: "Morning Routine")

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        let firstRequest = try runner.approvalRequest(for: prepared, scope: .unscoped)
        #expect(firstRequest.assessment.effectiveTier == .tier2)
        #expect(firstRequest.requirement == .lightweightConfirmation)

        let result = try await runner.execute(prepared, approvalDecision: .approved(.tier2), scope: .unscoped)
        #expect(result.summary == "Ran Shortcut Morning Routine.")
        #expect(invoker.invocations.map(\.name) == ["Morning Routine"])
        #expect(try history.hasCleanObservedSuccess(for: "morning routine"))

        let demotedRequest = try runner.approvalRequest(for: prepared, scope: .unscoped)
        #expect(demotedRequest.assessment.effectiveTier == .tier1)
        #expect(demotedRequest.requirement == .autoRun)
    }

    @Test
    func shortcutFailureClearsHistoryDemotion() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = ShortcutRunHistoryStore(fileURL: root.appendingPathComponent("shortcuts-history.json"))
        try history.recordSuccess(shortcutName: "Morning Routine", at: Date(timeIntervalSince1970: 100))
        let invoker = FakeShortcutInvoker(results: [
            ProcessResult(terminationStatus: 1, output: "boom")
        ])
        let runner = AgentRunner(
            planner: FailingPlanner(),
            executor: makeExecutor(
                catalog: FakeShortcutCatalog(names: ["Morning Routine"]),
                invoker: invoker,
                history: history
            )
        )
        let plan = shortcutPlan(name: "Morning Routine")

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        let demotedRequest = try runner.approvalRequest(for: prepared, scope: .unscoped)
        #expect(demotedRequest.assessment.effectiveTier == .tier1)
        #expect(demotedRequest.requirement == .autoRun)

        do {
            _ = try await runner.execute(prepared, scope: .unscoped)
            Issue.record("Expected failed Shortcut process to throw.")
        } catch ShortcutsBridgeError.invocationFailed(let name, let code, let output) {
            #expect(name == "Morning Routine")
            #expect(code == 1)
            #expect(output == "boom")
        } catch {
            Issue.record("Expected invocationFailed, got \(error).")
        }

        #expect(try !history.hasCleanObservedSuccess(for: "Morning Routine"))
        let resetRequest = try runner.approvalRequest(for: prepared, scope: .unscoped)
        #expect(resetRequest.assessment.effectiveTier == .tier2)
        #expect(resetRequest.requirement == .lightweightConfirmation)
    }

    @Test
    func processInvokerUsesFixedShortcutsCommandAndTemporaryInputPath() async throws {
        let runner = CapturingShortcutProcessRunner()
        let invoker = ProcessShortcutInvoker(processRunner: runner)

        _ = try await invoker.invokeShortcut(name: "Resize Image", input: "hello world")

        #expect(runner.executablePaths == ["/usr/bin/shortcuts"])
        let arguments = try #require(runner.arguments.first)
        #expect(arguments.prefix(2) == ["run", "Resize Image"])
        #expect(arguments.contains("--input-path"))
        #expect(runner.capturedInput == "hello world")
    }

    @Test
    func agentPlanDecoderAcceptsShortcutFields() throws {
        let json = """
        {
          "summary": "Run Shortcut.",
          "requiresConfirmation": true,
          "steps": [
            {
              "id": "shortcut",
              "operation": "invoke_shortcut",
              "description": "Run Morning Routine.",
              "inputPath": null,
              "outputPath": null,
              "count": null,
              "targetURL": null,
              "appName": null,
              "question": null,
              "mediaProvider": null,
              "mediaTitle": null,
              "mediaArtist": null,
              "contextSource": null,
              "routineName": null,
              "routineSteps": null,
              "workspaceName": null,
              "workspaceApps": null,
              "workspaceURLs": null,
              "sourceURLs": null,
              "searchQuery": null,
              "draftTitle": null,
              "draftContent": null,
              "shortcutName": "Morning Routine",
              "shortcutInput": "hello"
            }
          ]
        }
        """

        let plan = try AgentPlanDecoder.decodeStrict(from: json)

        #expect(plan.steps[0].operation == .invokeShortcut)
        #expect(plan.steps[0].shortcutName == "Morning Routine")
        #expect(plan.steps[0].shortcutInput == "hello")
    }

    /// `execute` used to resolve the shortcut spec twice on its own (once directly, once via the
    /// preview it builds), on top of the plan-validation pass in `resolveDefaultOutputs` — three
    /// `shortcuts list` spawns for one invocation. The adapter's own duplicate is gone; the
    /// remaining read is the separate validation pass, deliberately left in place.
    @Test
    func invokingAShortcutDoesNotResolveTheCatalogTwiceInsideExecute() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = CountingShortcutCatalog(names: ["Focus Mode"])
        let executor = makeExecutor(
            catalog: catalog,
            invoker: FakeShortcutInvoker(results: [ProcessResult(terminationStatus: 0, output: "")]),
            history: ShortcutRunHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        )

        _ = try await executor.execute(plan: shortcutPlan(name: "Focus Mode")) { _, _ in }

        #expect(catalog.readCount == 2)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShortcutsBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutor(
        catalog: any ShortcutCatalogProviding,
        invoker: any ShortcutInvoking = FakeShortcutInvoker(results: []),
        history: ShortcutRunHistoryStore = ShortcutRunHistoryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-shortcuts-history-\(UUID().uuidString).json"))
    ) -> AgentActionExecutor {
        AgentActionExecutor(
            shortcutCatalog: catalog,
            shortcutInvoker: invoker,
            shortcutRunHistoryStore: history
        )
    }

    private func shortcutPlan(name: String, input: String? = nil) -> AgentPlan {
        AgentPlan(
            summary: "Run Shortcut \(name).",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "shortcut",
                    operation: .invokeShortcut,
                    description: "Run Shortcut \(name).",
                    shortcutName: name,
                    shortcutInput: input
                )
            ]
        )
    }
}

/// Internal rather than file-private: `AgentActionExecutorTests` needs the same fake to assess a
/// chain of Shortcut steps, and the real catalog shells out to `shortcuts list` on every call, so
/// a second copy of this would be a second thing to keep honest.
struct FakeShortcutCatalog: ShortcutCatalogProviding {
    var names: [String]

    func shortcutNames() throws -> [String] {
        names
    }
}

/// Counts catalog reads. The real catalog shells out to `shortcuts list` on every call, so a
/// duplicate resolution inside one execute is a real, avoidable subprocess spawn.
private final class CountingShortcutCatalog: ShortcutCatalogProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let names: [String]
    private var reads = 0

    init(names: [String]) {
        self.names = names
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func shortcutNames() throws -> [String] {
        lock.lock()
        reads += 1
        lock.unlock()
        return names
    }
}

private struct ShortcutInvocation: Equatable {
    var name: String
    var input: String?
}

private final class FakeShortcutInvoker: ShortcutInvoking, @unchecked Sendable {
    private var results: [ProcessResult]
    private(set) var invocations: [ShortcutInvocation] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func invokeShortcut(name: String, input: String?) async throws -> ProcessResult {
        invocations.append(ShortcutInvocation(name: name, input: input))
        if results.isEmpty {
            return ProcessResult(terminationStatus: 0, output: "")
        }
        return results.removeFirst()
    }
}

private final class CapturingShortcutProcessRunner: ShortcutProcessRunning, @unchecked Sendable {
    private(set) var executablePaths: [String] = []
    private(set) var arguments: [[String]] = []
    private(set) var capturedInput: String?

    func run(executablePath: String, arguments: [String]) async throws -> ProcessResult {
        executablePaths.append(executablePath)
        self.arguments.append(arguments)
        if let inputPathIndex = arguments.firstIndex(of: "--input-path"),
           inputPathIndex + 1 < arguments.count {
            capturedInput = try String(contentsOfFile: arguments[inputPathIndex + 1], encoding: .utf8)
        }
        return ProcessResult(terminationStatus: 0, output: "ok")
    }
}

private struct FailingPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        Issue.record("Planner should not be called for injected Shortcut tests.")
        throw PlannerError.missingAPIKey
    }
}
