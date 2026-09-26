import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

@Suite
@MainActor
struct RunningAppAndRecentArtifactsTests {
    @Test
    func resolverBuildsRunningAppSwitchPlans() throws {
        let resolver = InstantCommandResolver(
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts()
        )

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


    // MARK: - Resolved-app pinning (SONNY-58)






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
    func resolverOpensRecentArtifactThroughExistingOpenGeneratedArtifactOperation() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecentArtifactStore(fileURL: root.appendingPathComponent("recent.json"))
        let artifact = try writeFile(named: "meeting-notes.md", in: root)
        try store.record(path: artifact.path)
        let resolver = InstantCommandResolver(
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: store
        )

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

