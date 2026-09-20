import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgent
@testable import MacAgentCore

// MARK: - SONNY-456: three runs at once, each in task history, and one key that stops them all

/// What has to hold of several runs before the product can start a second one: the cap, every run
/// landing in task history, and `⌃⌥⎋` stopping all of them. Each is driven through the real dispatch
/// path, with the second and later runs started in slots of their own the way the feature will
/// start them — `addRunSlotForTests()` is still the only way a second slot can exist.
@Suite(.serialized)
@MainActor
struct ConcurrentRunTests {
    /// Three runs parked on three approvals are three runs in flight, and a fourth command is
    /// refused where it was typed, with its words left in the composer.
    @Test
    func aFourthCommandIsRefusedWhileThreeRunsAreInFlightAndStartsOnceOneFinishes() async throws {
        let fixture = try makeDispatchFixture(planner: { NamedDraftPlanner(folder: $0) })
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        #expect(AgentViewModel.maximumConcurrentRuns == 3)

        // Each file exists, so each draft is an overwrite and each run parks at its approval.
        var runs = [viewModel.focusedRunID]
        for name in ["one", "two", "three"] {
            try "existing".write(
                to: fixture.projectFolder.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8
            )
            if runs.count < 3 {
                runs.append(viewModel.addRunSlotForTests())
            }
        }
        for (run, name) in zip(runs, ["one", "two", "three"]) {
            RunScope.$current.withValue(run) {
                viewModel.command = "Draft \(name)"
                viewModel.start()
            }
            try await HangBackstop.waitOrAbandon(for: "run \(name) to park its approval") {
                slot(run, in: viewModel).map { $0.approvalRequest != nil && !$0.isRunning } == true
            }
        }
        try #require(viewModel.runsInFlight == 3, "precondition: three runs are in flight")

        let fourth = viewModel.addRunSlotForTests()
        RunScope.$current.withValue(fourth) {
            viewModel.command = "Draft four"
            viewModel.start()
        }
        #expect(slot(fourth, in: viewModel)?.isRunning == false, "a fourth run started")
        #expect(slot(fourth, in: viewModel)?.errorMessage == AgentViewModel.tooManyRunsMessage)
        #expect(AgentViewModel.tooManyRunsMessage == "Sonny is already working on three tasks. Try again when one finishes.")
        #expect(slot(fourth, in: viewModel)?.retryToken == nil, "a refusal is not a failed task")
        #expect(slot(fourth, in: viewModel)?.lastCommand == "", "the refused command became the run's last command")
        #expect(viewModel.command == "Draft four", "the refused words were taken out of the composer")
        #expect(viewModel.runsInFlight == 3)

        // One finishes — denied, which is as finished as approved — and the same words start.
        RunScope.$current.withValue(runs[0]) { viewModel.cancelCurrentRun() }
        try #require(viewModel.runsInFlight == 2)
        RunScope.$current.withValue(fourth) { viewModel.start() }
        #expect(slot(fourth, in: viewModel)?.lastCommand == "Draft four")
        try await HangBackstop.waitOrAbandon(for: "the fourth run to finish") {
            slot(fourth, in: viewModel).map { !$0.isRunning && $0.lastCommand == "Draft four" } == true
        }
        #expect(FileManager.default.fileExists(atPath: fixture.projectFolder.appendingPathComponent("four.md").path))
        for run in runs.dropFirst() {
            RunScope.$current.withValue(run) { viewModel.cancelCurrentRun() }
        }
    }

    /// Two runs started one after the other, in flight together, each write their own row.
    @Test
    func twoRunsInFlightTogetherBothLandInTaskHistory() async throws {
        let fixture = try makeDispatchFixture(planner: { NamedDraftPlanner(folder: $0) })
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        let first = viewModel.focusedRunID
        let second = viewModel.addRunSlotForTests()

        viewModel.command = "Draft one"
        viewModel.start()
        RunScope.$current.withValue(second) {
            viewModel.command = "Draft two"
            viewModel.start()
        }
        try #require(viewModel.runsInFlight == 2, "precondition: the two runs overlap")
        try await HangBackstop.waitOrAbandon(for: "both runs to finish") {
            viewModel.runSlots.allSatisfy { !$0.isInFlight }
        }
        #expect(slot(first, in: viewModel)?.errorMessage == nil)
        #expect(slot(second, in: viewModel)?.errorMessage == nil)

        let history = try TaskHistoryStore(fileURL: fixture.root.appendingPathComponent("task-history.json")).loadAll()
        let commands = Set(history.map(\.command))
        #expect(commands == ["Draft one", "Draft two"], "each run owes task history its own row")
        #expect(history.count == 2)
        #expect(Set(history.map(\.id)).count == 2, "the two rows share an identity")
    }

    /// `⌃⌥⎋` is pressed outside any run, with the session on a run the widget is not showing. It
    /// stops that run, and the other one too.
    @Test
    func theEmergencyKeyStopsEveryRunWhicheverOneTheWidgetShows() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        var press: (@MainActor () -> Void)?
        viewModel.visionEmergencyStopHotKeyFactory = { onStop in
            press = onStop
            return try KeyThatOnlyRemembersItsHandler(onStop: onStop)
        }
        viewModel.registerEmergencyStopHotKey()
        let pressTheKey = try #require(press, "the key was registered with no handler")

        let onScreen = viewModel.focusedRunID
        let background = viewModel.addRunSlotForTests()
        let tasks = [onScreen, background].map { run in
            Task {
                try await RunScope.$current.withValue(run) {
                    try await viewModel.awaitVisionResume(
                        VisionSessionPause(appDisplayName: "Notes", reason: .userIdle, iteration: 1)
                    )
                }
            }
        }
        try await HangBackstop.waitOrAbandon(for: "both runs to park their pause") {
            viewModel.runSlots.allSatisfy { $0.visionResumeContinuation != nil }
        }
        try #require(viewModel.focusedRunID == onScreen)

        pressTheKey()

        #expect(slot(background, in: viewModel)?.visionSessionPause == nil, "the run in the background went on")
        #expect(slot(onScreen, in: viewModel)?.visionSessionPause == nil, "the run on screen went on")
        try #require(viewModel.runSlots.allSatisfy { $0.visionResumeContinuation == nil })
        for task in tasks {
            // `cancelCurrentRun` resumes the question with "do not resume"; with no `currentTask`
            // to cancel here, the question's own answer is what ends each run.
            #expect(try await task.value == false)
        }
    }
}

private final class KeyThatOnlyRemembersItsHandler: EmergencyStopHotKeyRegistering {
    init(onStop: @escaping @MainActor () -> Void) throws {}
}

/// Drafts `<name>.md` for a command that ends in a name, so each run writes — or parks on — its own file.
private struct NamedDraftPlanner: Planning {
    let folder: URL

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        let name = command.split(separator: " ").last.map(String.init) ?? "notes"
        return AgentPlan(
            summary: "Draft \(name).",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Draft \(name).",
                    outputPath: folder.appendingPathComponent("\(name).md").path,
                    draftTitle: "Notes",
                    draftContent: "Outline for \(name)."
                )
            ]
        )
    }
}

// MARK: - SONNY-456: what deletes, and what starts unattended, reads every run

/// A delete pressed while the widget shows an idle run, with a task running in another slot, is
/// refused exactly as it is when the task is the one on screen. Each of the five guards used to
/// read the run on screen alone.
@Suite(.serialized)
@MainActor
struct EveryRunGuardTests {
    enum Busy: String, CaseIterable, CustomTestStringConvertible {
        case running, awaitingApproval
        var testDescription: String { rawValue }
    }

    /// Puts a background slot into the named state and leaves the widget on the idle first run.
    private func makeBusyBackgroundRun(_ busy: Busy) async throws -> (fixture: DispatchFixture, onScreen: RunID) {
        let fixture = try makeDispatchFixture()
        let viewModel = fixture.viewModel
        let onScreen = viewModel.focusedRunID
        let background = viewModel.addRunSlotForTests()
        switch busy {
        case .running:
            RunScope.$current.withValue(background) { viewModel.isRunning = true }
        case .awaitingApproval:
            // A real parked approval: the draft's file exists, so the run stops at its question.
            try "existing".write(to: fixture.draftOutput, atomically: true, encoding: .utf8)
            RunScope.$current.withValue(background) {
                viewModel.command = "Draft notes"
                viewModel.start()
            }
            try await HangBackstop.waitOrAbandon(for: "the background run to park its approval") {
                slot(background, in: viewModel).map { $0.approvalRequest != nil && !$0.isRunning } == true
            }
        }
        try #require(viewModel.focusedRunID == onScreen)
        try #require(!viewModel.isRunning && !viewModel.isAwaitingApproval, "precondition: the run on screen is idle")
        return (fixture, onScreen)
    }

    @Test
    func theWholeWipeAndTheSetAsideFilesAreRefusedWhileAnotherRunIsRunning() async throws {
        let (fixture, _) = try await makeBusyBackgroundRun(.running)
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel

        viewModel.deleteLocalData()
        #expect(viewModel.errorMessage == "Stop the current run before deleting local data.")
        #expect(!viewModel.isDeletingLocalData, "the wipe began under a running task")

        viewModel.errorMessage = nil
        viewModel.deleteSetAsideFiles()
        #expect(viewModel.errorMessage == MemoryDeletionCopy.setAsideFilesRunGuard)
    }

    @Test(arguments: Busy.allCases)
    func aRoutineAWorkspaceAndAMemoryRowAreNotDeletedWhileAnotherRunIsBusy(_ busy: Busy) async throws {
        let (fixture, _) = try await makeBusyBackgroundRun(busy)
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        let workspace = StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [])
        try fixture.workspaceStore.save(workspace)

        viewModel.deleteWorkspace(workspace)
        #expect(viewModel.errorMessage == "Finish or stop the current task before deleting this workspace.")
        // By name over the values: the store keys its dictionary by a normalised name.
        #expect(
            try fixture.workspaceStore.loadAll().values.contains { $0.name == "Client Alpha" },
            "the workspace was deleted under a busy run"
        )

        viewModel.errorMessage = nil
        viewModel.deleteRoutine(StoredRoutine(name: "Morning", steps: []))
        #expect(viewModel.errorMessage == "Finish or stop the current task before deleting this routine.")

        viewModel.errorMessage = nil
        viewModel.deleteMemory(in: .taskHistory)
        #expect(viewModel.errorMessage == "Finish or stop the current task before deleting memory.")
    }
}
