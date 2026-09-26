import Foundation
import MacAgentTestSupport
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
        let resolver = InstantCommandResolver(
            snippetStore: store,
            recentArtifactStore: UnreachableLocalStores.recentArtifacts()
        )

        guard case .plan(let plan) = resolver.resolve(command: ";sig") else {
            Issue.record("Expected saved snippet trigger to resolve locally.")
            return
        }

        #expect(plan.steps.map(\.operation) == [.expandSnippet])
        #expect(plan.steps[0].searchQuery == ";sig")
        #expect(resolver.resolve(command: ";missing") == nil)
    }





    @Test
    func snippetSaveCommandClarifiesWhenTriggerOrExpansionIsMissing() {
        let resolver = InstantCommandResolver(
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts()
        )

        guard case .clarify(let clarifyPlan) = resolver.resolve(command: "snippet save ;sig") else {
            Issue.record("Expected malformed snippet save command to ask for clarification.")
            return
        }

        #expect(clarifyPlan.steps.map(\.operation) == [.clarify])
        // The body alone, not the whole command: the answer joins onto the request (SONNY-281).
        #expect(clarifyPlan.steps[0].question == "Use the format ;trigger = expansion.")
    }


    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetExpansionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

}

