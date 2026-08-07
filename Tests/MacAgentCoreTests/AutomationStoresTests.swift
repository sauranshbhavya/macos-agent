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

    // MARK: - Step safety at the store (SONNY-52)

    /// The list itself, pinned literally rather than through the code that reads it.
    ///
    /// Every rejection test below drives off `StoredRoutine.forbiddenStepOperations`, so a test
    /// that only looped the list would pass just as happily with an entry deleted from it — it
    /// would simply stop testing that entry. This is the assertion that makes a deletion or a
    /// silent addition fail, and the reason the per-operation tests below can be written as a loop
    /// without being self-fulfilling.
    @Test
    func theForbiddenStepListIsExactlyTheSixOperationsRoutinesMayNotContain() {
        #expect(
            StoredRoutine.forbiddenStepOperations == [
                .saveRoutine,
                .runRoutine,
                .createWorkspace,
                .openWorkspace,
                .clarify,
                .unsupported
            ]
        )
        // The complement matters as much as the membership: a rule that crept wider would refuse
        // routines users legitimately author. These four are the everyday routine operations.
        for operation in [AgentOperation.openApp, .openURL, .writeMarkdown, .createLocalDraft] {
            #expect(StoredRoutine.forbiddenStepOperations.contains(operation) == false)
        }
    }

    /// Each forbidden operation, rejected at the store rather than only at the save capability.
    /// Before SONNY-52 every one of these writes succeeded: `RoutineStore.save` validated the
    /// schedule and nothing else, so a routine the save capability refuses could be written
    /// straight to disk and then executed.
    @Test
    func savingRejectsEveryForbiddenStepOperationWithTheOperationNamed() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

        for operation in StoredRoutine.forbiddenStepOperations {
            let step = AgentStep(id: "bad", operation: operation, description: "Nope.")
            #expect(throws: AutomationStoreError.unsafeRoutineStep(operation.rawValue)) {
                try store.save(StoredRoutine(name: "Morning", steps: [step]))
            }
        }

        // Nothing was written by any of them — a rejection that still left a partial file on disk
        // would be a worse outcome than no check at all.
        #expect(try store.loadAll().isEmpty)
    }

    /// A forbidden step buried behind legal ones is still rejected. Checking only `steps.first`
    /// would pass every test above and miss the shape a real routine actually takes.
    @Test
    func savingRejectsAForbiddenStepThatIsNotTheFirstStep() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

        #expect(throws: AutomationStoreError.unsafeRoutineStep("run_routine")) {
            try store.save(
                StoredRoutine(
                    name: "Morning",
                    steps: [
                        .fixture,
                        AgentStep(id: "nested-run", operation: .runRoutine, description: "Run another routine.")
                    ]
                )
            )
        }
    }

    /// The save capability refuses nested `routineSteps` alongside the operation list, and both
    /// halves of that rule now live in `StoredRoutine.validateStepSafety` — so the store refuses
    /// them too. A routine holding routines is recursion the executor never agreed to walk.
    @Test
    func savingRejectsAStepCarryingNestedRoutineSteps() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

        #expect(throws: AutomationStoreError.unsafeRoutineStep("nested routineSteps")) {
            try store.save(
                StoredRoutine(
                    name: "Morning",
                    steps: [AgentStep(id: "wrap", operation: .openApp, description: "Wrap.", routineSteps: [.fixture])]
                )
            )
        }
        // An empty nested array is not a nested routine — refusing it would reject a shape the
        // planner emits harmlessly, and the adapter has never refused it either.
        try store.save(
            StoredRoutine(
                name: "Evening",
                steps: [AgentStep(id: "wrap", operation: .openApp, description: "Wrap.", routineSteps: [])]
            )
        )
        #expect(try store.routine(named: "Evening").steps.count == 1)
    }

    /// Steps are checked before the schedule, so a routine that is wrong in both ways is told
    /// about the problem that makes it unsafe to *run* rather than the one that makes it unsafe to
    /// *fire*. Pinned because the ordering is a decision, not an accident of line order.
    @Test
    func stepSafetyIsReportedAheadOfScheduleValidation() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

        #expect(throws: AutomationStoreError.unsafeRoutineStep("clarify")) {
            try store.save(
                StoredRoutine(
                    name: "Morning",
                    steps: [AgentStep(id: "ask", operation: .clarify, description: "Ask.")],
                    // Invalid on its own: weekly with no weekday.
                    schedule: RoutineSchedule(cadence: .weekly, hour: 9, minute: 0)
                )
            )
        }
    }

    /// The sanctioned bypass writes what `save` refuses, and stays a *step*-safety bypass only —
    /// an invalid schedule still throws, and the merge-on-nil behavior is still `save`'s. A bypass
    /// that quietly skipped the rest of `save` would be a second write path, which is the thing
    /// this ticket exists to remove.
    @Test
    func theSanctionedBypassWritesForbiddenStepsButStillValidatesTheSchedule() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let forbidden = AgentStep(
            id: "open-workspace",
            operation: .openWorkspace,
            description: "Open workspace",
            workspaceName: "Research"
        )

        try store.saveBypassingStepValidation(StoredRoutine(name: "Morning", steps: [forbidden]))

        #expect(try store.routine(named: "Morning").steps.map(\.operation) == [.openWorkspace])
        #expect(throws: AutomationStoreError.invalidSchedule("A weekly routine needs a weekday.")) {
            try store.saveBypassingStepValidation(
                StoredRoutine(
                    name: "Evening",
                    steps: [forbidden],
                    schedule: RoutineSchedule(cadence: .weekly, hour: 9, minute: 0)
                )
            )
        }
        // ...and it still merges rather than replacing: redefining the steps of a routine written
        // this way keeps the schedule the earlier write gave it, exactly as `save` would.
        try store.setSchedule(
            routineNamed: "Morning",
            to: RoutineSchedule(cadence: .daily, hour: 7, minute: 15)
        )
        try store.saveBypassingStepValidation(StoredRoutine(name: "Morning", steps: [forbidden, forbidden]))
        #expect(try store.routine(named: "Morning").schedule?.hour == 7)
    }

    /// A legal routine is untouched by any of this — the check refuses a named set, it does not
    /// narrow what a routine may do.
    @Test
    func savingAnOrdinaryRoutineIsUnaffectedByStepValidation() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

        try store.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    .fixture,
                    AgentStep(id: "open-url", operation: .openURL, description: "Open GitHub.", targetURL: "https://github.com"),
                    AgentStep(id: "draft", operation: .createLocalDraft, description: "Draft notes.")
                ]
            )
        )

        #expect(try store.routine(named: "Morning").steps.count == 3)
    }

    /// A `workspaces.json` written before file locations existed, hand-written rather than encoded
    /// from the current struct — a fixture built by encoding `StoredWorkspace` today would already
    /// carry the key and could never catch a missing-key regression on a real pre-existing file.
    @Test
    func aWorkspacesFileWrittenBeforeFileLocationsExistedStillDecodes() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspaces.json")
        let legacyJSON = """
        {
            "research": {
                "name": "Research",
                "apps": ["Safari"],
                "urls": ["https://example.com/reference"],
                "teamType": "solo"
            }
        }
        """
        try Data(legacyJSON.utf8).write(to: url, options: .atomic)
        let store = WorkspaceStore(fileURL: url, encryption: fixedKeyEncryption())

        let workspace = try store.workspace(named: "Research")

        #expect(workspace.fileLocations == nil)
        #expect(workspace.effectiveFileLocations == [])
        #expect(workspace.apps == ["Safari"])
    }

    /// `CreateWorkspaceCapabilityAdapter` builds a fresh `StoredWorkspace(name:apps:urls:)` on every
    /// save, so without merge-preserve, re-creating a workspace by natural language would silently
    /// delete its restriction scope — a boundary the user never consented to dropping.
    @Test
    func savingAWorkspaceWithNilFileLocationsPreservesTheStoredOnes() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try store.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: ["~/Documents/ClientAlpha"]
            )
        )

        try store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari", "Notes"], urls: []))

        let stored = try store.workspace(named: "Client Alpha")
        #expect(stored.fileLocations == ["~/Documents/ClientAlpha"])
        #expect(stored.apps == ["Safari", "Notes"])
    }

    /// SONNY-43, folded into SONNY-40. `CreateWorkspaceCapabilityAdapter` builds a fresh
    /// `StoredWorkspace(name:apps:urls:)` with no team type at all, so before the merge a user who
    /// said "create a workspace called Client Alpha with Safari" — a phrase about apps — silently
    /// demoted a workspace they had marked as their team's back to solo.
    @Test
    func savingAWorkspaceWithNilTeamTypePreservesTheStoredOne() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], teamType: .team)
        )

        // Exactly what the natural-language re-create path constructs.
        try store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari", "Notes"], urls: []))

        let stored = try store.workspace(named: "Client Alpha")
        #expect(stored.teamType == .team)
        #expect(stored.effectiveTeamType == .team)
        #expect(stored.apps == ["Safari", "Notes"])
    }

    /// The other half of `teamType`'s merge rule, and the reason it is a merge rather than an
    /// unconditional carry-forward: a caller that *states* a team type still wins. Nothing demotes a
    /// team workspace today, but a rule that could not express a demotion would be a one-way door.
    @Test
    func savingAWorkspaceWithAnExplicitTeamTypeReplacesTheStoredOne() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], teamType: .team)
        )

        try store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], teamType: .solo)
        )

        #expect(try store.workspace(named: "Client Alpha").teamType == .solo)
    }

    /// The other half of the same contract: nil means "not talking about file locations", `[]` means
    /// "clear them", so an edit path that empties the list is never silently ignored.
    @Test
    func savingAWorkspaceWithAnEmptyFileLocationsListClearsThem() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], fileLocations: ["~/Documents/ClientAlpha"])
        )

        try store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], fileLocations: []))

        let stored = try store.workspace(named: "Client Alpha")
        #expect(stored.fileLocations == [])
        #expect(stored.effectiveFileLocations == [])
    }

    @Test
    func savingAWorkspaceWithNewFileLocationsReplacesTheStoredOnes() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], fileLocations: ["~/Documents/Old"])
        )

        try store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], fileLocations: ["~/Documents/New"])
        )

        #expect(try store.workspace(named: "Client Alpha").fileLocations == ["~/Documents/New"])
    }

    /// The merge only applies to a workspace that already exists — a brand-new one keeps whatever it
    /// was created with, including nothing.
    @Test
    func savingANewWorkspaceWithNilFileLocationsLeavesThemUnset() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))

        try store.save(StoredWorkspace(name: "Fresh", apps: ["Safari"], urls: []))

        #expect(try store.workspace(named: "Fresh").fileLocations == nil)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomationStoresTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixedKeyEncryption() -> LocalStorageEncryption {
        LocalStorageEncryption(keyManager: FixedAutomationStoreKeyManager())
    }
}

private struct FixedAutomationStoreKeyManager: LocalStorageKeyManaging {
    func keyData() throws -> Data {
        Data(repeating: 0x24, count: 32)
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
