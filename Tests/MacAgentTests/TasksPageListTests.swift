import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// Which tasks the Tasks page lists as in progress.
@Suite
@MainActor
struct TasksPageListTests {
    private func snapshot(_ id: TaskID, _ phase: TaskPhase) -> TaskSnapshot {
        TaskSnapshot(id: id, goal: "Look", origin: .composer, isPrivate: false, phase: phase, progress: nil, actions: [])
    }

    @Test
    func aTaskAlreadyInHistoryIsNeverAlsoListedAsInProgress() {
        let finished = TaskID()
        let running = TaskID()
        let history = [FinishedTask(snapshot: snapshot(finished, .failed(TaskFailure(reason: nil, message: "Stopped."))), finishedAt: Date())]
        let listed = TasksPage.inProgress([snapshot(finished, .running), snapshot(running, .running)], history: history)
        #expect(listed.map(\.id) == [running])
    }

    @Test
    func aFinishedTaskIsNotInProgressAndTheNewestComesFirst() {
        let older = TaskID()
        let newer = TaskID()
        let done = TaskID()
        let listed = TasksPage.inProgress(
            [snapshot(older, .running), snapshot(done, .completed(summary: "Done.")), snapshot(newer, .queued)],
            history: []
        )
        #expect(listed.map(\.id) == [newer, older])
    }
}
