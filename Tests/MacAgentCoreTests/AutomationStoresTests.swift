import Foundation
import Testing
@testable import MacAgentCore

struct AutomationStoresTests {
    @Test
    func storedRoutineIdentityMatchesItsName() {
        let routine = StoredRoutine(name: "Morning Setup", steps: [])
        #expect(routine.id == "Morning Setup")
    }

    @Test
    func deletingARoutineRemovesItsScheduleAndHistoryWithIt() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let schedule = RoutineSchedule.newlyCreated(
            cadence: .daily,
            hour: 9,
            minute: 0,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.save(StoredRoutine(name: "Morning", steps: [.fixture], schedule: schedule))
        try store.recordRun(routineNamed: "Morning", at: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(StoredRoutine(name: "Evening", steps: [.fixture]))

        try store.delete(routineNamed: "Morning")

        // Steps, schedule, and run history all live under the one deleted key — nothing survives
        // to dangle, and the other routine is untouched.
        let remaining = try store.loadAll()
        #expect(remaining.keys.sorted() == ["evening"])
        #expect(throws: AutomationStoreError.missingRoutine("Morning")) {
            try store.routine(named: "Morning")
        }
    }

    @Test
    func deletingAnUnknownRoutineThrowsRatherThanNoOping() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

        #expect(throws: AutomationStoreError.missingRoutine("Ghost")) {
            try store.delete(routineNamed: "Ghost")
        }
    }

    @Test
    func deletingAWorkspaceRemovesOnlyThatWorkspace() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try store.save(StoredWorkspace(name: "Client Work", apps: ["Mail"], urls: []))
        try store.save(StoredWorkspace(name: "Personal", apps: ["Safari"], urls: []))

        try store.delete(workspaceNamed: "Client Work")

        let remaining = try store.loadAll()
        #expect(remaining.keys.sorted() == ["personal"])
        #expect(throws: AutomationStoreError.missingWorkspace("Client Work")) {
            try store.workspace(named: "Client Work")
        }
    }

    @Test
    func deletingAnUnknownWorkspaceThrowsRatherThanNoOping() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))

        #expect(throws: AutomationStoreError.missingWorkspace("Ghost")) {
            try store.delete(workspaceNamed: "Ghost")
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomationStoresTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension AgentStep {
    static let fixture = AgentStep(
        id: "open",
        operation: .openApp,
        description: "Open Safari.",
        appName: "Safari"
    )
}
