import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore
import MacAgentTestSupport

/// A real `SonnyAppModel` over V2 stores in a temporary folder, with a scripted gateway, for the
/// Insights and Memory tests.
@MainActor
struct PagesFixture {
    let gateway = ScriptedGateway()
    let folder: URL
    let stores: KernelStores
    let app: SonnyAppModel

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pages-\(UUID().uuidString)")
        stores = KernelStores(folder: folder)
        let controller = TaskController(
            url: URL(string: "ws://gateway.test/v2/session")!,
            transport: gateway,
            credentials: FixedGatewayCredentials(),
            identity: .init(deviceID: DeviceID(), appVersion: "2.0.0", osVersion: "26.0"),
            ledgers: MemoryTaskLedgerStore(),
            capabilities: KernelCapabilities([]),
            permissions: { .init(accessibility: .granted, screenRecording: .granted, automation: []) },
            backoff: GatewayBackoff(base: 0.01, cap: 0.05, jitter: { 0 }),
            connectTimeout: 60
        )
        let desk = TaskDesk(
            controller: controller,
            history: stores.history,
            routines: stores.routines,
            watchers: stores.watchers,
            instant: { _ in nil },
            mode: { .normal }
        )
        let defaults = try #require(UserDefaults(suiteName: "PagesFixture-\(UUID().uuidString)"))
        app = SonnyAppModel(desk: desk, stores: stores, client: makeHermeticBackendClient(), defaults: defaults)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The next task the app sends to the gateway.
    func started() async throws -> (TaskID, TaskStartBody) {
        let message = try await gateway.next("task.start")
        guard case .taskStart(let body) = message.payload, let task = message.address?.task else {
            throw PagesFixtureFailure()
        }
        return (task, body)
    }

    /// Asks through the desk, the door every entry point uses, lets the gateway finish the task,
    /// and waits until it has ended.
    func runToCompletion(_ goal: String, isPrivate: Bool = false) async throws -> TaskID {
        _ = await app.desk.ask(goal, isPrivate: isPrivate)
        let (task, body) = try await started()
        #expect(body.isPrivate == isPrivate)
        await gateway.send(task, .finish(FinishBody(status: .completed, summary: "Done: \(goal)")))
        #expect(await eventually { app.controller.snapshot(task)?.phase.isTerminal == true })
        return task
    }

    /// One of everything the Memory page shows, written straight to the V2 stores.
    func seedOneOfEach(now: Date = Date()) async throws {
        try await stores.routines.save(RoutineGoal(name: "Morning", goal: "Open my calendar", schedule: nil, savedAt: now))
        try await stores.history.record(finishedSnapshot("Book a table"), finishedAt: now)
        try stores.snippets.save(StoredSnippet(trigger: ";sig", expansion: "Best, Sam", updatedAt: now))
        try stores.clipboard.record("copied text", copiedAt: now)
        _ = try stores.approvedApps.approve(bundleIdentifier: "com.apple.Notes", displayName: "Notes", approvedAt: now)
        let file = folder.appendingPathComponent("report.txt")
        try "report".write(to: file, atomically: true, encoding: .utf8)
        try stores.recentFiles.record(path: file.path, recordedAt: now)
        await app.desk.load()
    }

    /// How many entries each store holds: routines and history as the desk reads them back from
    /// their stores, and the rest read from disk.
    func storedCount(_ category: MemoryCategory) async throws -> Int {
        await app.desk.load()
        switch category {
        case .routines: return app.desk.routines.count
        case .taskHistory: return app.desk.history.count
        case .recentArtifacts: return try stores.recentFiles.loadAll().count
        case .clipboardHistory: return try stores.clipboard.loadAll().count
        case .snippets: return try stores.snippets.loadAll().count
        case .approvedApps: return try stores.approvedApps.loadAll().count
        }
    }

    func finishedSnapshot(_ goal: String, outcome: TaskPhase = .completed(summary: "Done.")) -> TaskSnapshot {
        TaskSnapshot(id: TaskID(), goal: goal, origin: .composer, isPrivate: false, phase: outcome, progress: nil, actions: [])
    }
}

struct PagesFixtureFailure: Error {}
