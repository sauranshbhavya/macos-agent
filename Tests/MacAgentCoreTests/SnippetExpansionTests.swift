import Foundation
import Testing
@testable import MacAgentCore

@Suite
@MainActor
struct SnippetExpansionTests {
    @Test
    func storeSavesAndFindsExactTriggersOnly() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
        let snippet = StoredSnippet(
            trigger: " ;sig ",
            expansion: " Best,\nSonny ",
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        try store.save(snippet)

        #expect(try store.snippet(matchingTrigger: ";sig").expansion == "Best,\nSonny")
        #expect(try store.findExactTrigger(";sig")?.trigger == ";sig")
        #expect(try store.findExactTrigger(" ;sig ")?.trigger == ";sig")
        #expect(try store.findExactTrigger(";SIG") == nil)
    }

    @Test
    func storeValidatesTriggerAndExpansion() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))

        #expect(throws: SnippetStoreError.missingTrigger) {
            try store.save(StoredSnippet(trigger: " ", expansion: "Hello"))
        }
        #expect(throws: SnippetStoreError.missingExpansion) {
            try store.save(StoredSnippet(trigger: ";hello", expansion: " "))
        }
    }

    @Test
    func resolverBuildsSnippetPlanForExactSavedTrigger() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
        try store.save(StoredSnippet(trigger: ";sig", expansion: "Best,\nSonny"))
        let resolver = InstantCommandResolver(snippetStore: store)

        guard case .plan(let plan) = resolver.resolve(command: ";sig") else {
            Issue.record("Expected saved snippet trigger to resolve locally.")
            return
        }

        #expect(plan.steps.map(\.operation) == [.expandSnippet])
        #expect(plan.steps[0].searchQuery == ";sig")
        #expect(resolver.resolve(command: ";missing") == nil)
    }

    @Test
    func snippetSaveCommandUsesTierTwoRunnerPathThenEnablesExactExpansion() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
        let resolver = InstantCommandResolver(snippetStore: store)

        guard case .plan(let savePlan) = resolver.resolve(command: "snippet save ;sig = Best, Sonny") else {
            Issue.record("Expected snippet save command to resolve locally.")
            return
        }

        #expect(savePlan.steps.map(\.operation) == [.saveSnippet])
        #expect(savePlan.steps[0].searchQuery == ";sig")
        #expect(savePlan.steps[0].draftContent == "Best, Sonny")

        let executor = AgentActionExecutor(
            snippetStore: store,
            now: { Date(timeIntervalSince1970: 123) }
        )
        let runner = AgentRunner(planner: FailingPlanner(), executor: executor)
        let prepared = try runner.prepare(plan: savePlan, source: .instantResolver)
        #expect(prepared.previews.first?.title == "Save snippet")

        let request = try runner.approvalRequest(for: prepared)
        #expect(request.assessment.effectiveTier == .tier2)
        #expect(request.requirement == .lightweightConfirmation)
        #expect(request.requirement != .autoRun)

        do {
            _ = try await runner.execute(prepared)
            Issue.record("Expected snippet save to pause for tier 2 approval.")
        } catch RiskApprovalError.approvalRequired(let approvalRequest) {
            #expect(approvalRequest.requirement == .lightweightConfirmation)
            #expect(approvalRequest.assessment.effectiveTier == .tier2)
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        #expect(try store.findExactTrigger(";sig") == nil)

        let result = try await runner.execute(
            prepared,
            approvalDecision: .approved(.tier2),
            confirmationMessage: "Test approved snippet save"
        )
        #expect(result.summary == "Saved snippet ;sig.")
        #expect(try store.snippet(matchingTrigger: ";sig").expansion == "Best, Sonny")

        guard case .plan(let expansionPlan) = resolver.resolve(command: ";sig") else {
            Issue.record("Expected saved snippet trigger to resolve after save.")
            return
        }
        #expect(expansionPlan.steps.map(\.operation) == [.expandSnippet])
    }

    @Test
    func resavingExistingSnippetTriggerEscalatesToTierThree() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
        try store.save(StoredSnippet(trigger: ";sig", expansion: "Old text"))
        let executor = AgentActionExecutor(
            snippetStore: store,
            now: { Date(timeIntervalSince1970: 123) }
        )
        let runner = AgentRunner(planner: FailingPlanner(), executor: executor)
        let resolver = InstantCommandResolver(snippetStore: store)

        guard case .plan(let savePlan) = resolver.resolve(command: "snippet save ;sig = New text") else {
            Issue.record("Expected snippet save command to resolve locally.")
            return
        }

        let prepared = try runner.prepare(plan: savePlan, source: .instantResolver)
        let request = try runner.approvalRequest(for: prepared)

        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.assessment.escalations.contains { $0.reason.contains(";sig") })
        #expect(try store.findExactTrigger(";sig")?.expansion == "Old text")

        // The approval prompt reads "Allow access to <involvedResource>". Snippet save stores
        // its trigger in `searchQuery`, which used to make that read "Search: ;sig".
        #expect(request.approvalCopy.involvedResource == "Snippet: ;sig")
        #expect(!request.approvalCopy.involvedResource.contains("Search:"))
    }

    @Test
    func snippetSaveCommandClarifiesWhenTriggerOrExpansionIsMissing() {
        let resolver = InstantCommandResolver()

        guard case .clarify(let clarifyPlan) = resolver.resolve(command: "snippet save ;sig") else {
            Issue.record("Expected malformed snippet save command to ask for clarification.")
            return
        }

        #expect(clarifyPlan.steps.map(\.operation) == [.clarify])
        #expect(clarifyPlan.steps[0].question == "Use the format snippet save ;trigger = expansion.")
    }

    @Test
    func snippetExpansionUsesTierZeroRunnerPath() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
        try store.save(StoredSnippet(trigger: ";sig", expansion: "Best,\nSonny"))
        let executor = AgentActionExecutor(snippetStore: store)
        let runner = AgentRunner(planner: FailingPlanner(), executor: executor)
        let plan = AgentPlan(
            summary: "Expand snippet ;sig.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "snippet",
                    operation: .expandSnippet,
                    description: "Expand snippet ;sig.",
                    searchQuery: ";sig"
                )
            ]
        )

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        #expect(prepared.previews.first?.title == "Expand snippet")
        #expect(prepared.previews.first?.details.contains("Expansion: Best,\nSonny") == true)

        let request = try runner.approvalRequest(for: prepared)
        #expect(request.assessment.effectiveTier == .tier0)
        #expect(request.requirement == .autoRun)

        let result = try await runner.execute(prepared)
        #expect(result.summary == "Best,\nSonny")
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetExpansionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct FailingPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        Issue.record("Planner should not be called for snippet instant commands.")
        throw PlannerError.missingAPIKey
    }
}
