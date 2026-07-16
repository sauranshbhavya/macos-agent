import Foundation
import Testing
@testable import MacAgentCore

struct WorkspaceTaskTaggingTests {
    @Test
    func directDispatchResolvesWorkspaceNameFromPlanSteps() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let plan = AgentPlan(
            summary: "Open workspace.",
            requiresConfirmation: false,
            steps: [openWorkspaceStep(named: "Research")]
        )

        let resolved = WorkspaceTaskTagging.resolvedWorkspaceName(
            command: "open my research workspace",
            plan: plan,
            routineStore: routineStore,
            workspaceStore: workspaceStore
        )

        #expect(resolved == "Research")
    }

    @Test
    func routineNestedResolutionTagsAWorkspaceTheCommandNeverMentions() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try routineStore.save(
            StoredRoutine(name: "Morning Setup", steps: [openWorkspaceStep(named: "Research")])
        )
        let plan = AgentPlan(
            summary: "Run routine Morning Setup.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "run-routine",
                    operation: .runRoutine,
                    description: "Run saved routine",
                    routineName: "Morning Setup"
                )
            ]
        )

        let resolved = WorkspaceTaskTagging.resolvedWorkspaceName(
            command: "run my morning setup routine",
            plan: plan,
            routineStore: routineStore,
            workspaceStore: workspaceStore
        )

        #expect(resolved == "Research")
    }

    @Test
    func freeTextMatchPrefersTheLongerNameOnASamePositionCollision() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Client", apps: [], urls: []))
        try workspaceStore.save(StoredWorkspace(name: "Client Alpha", apps: [], urls: []))

        let resolved = WorkspaceTaskTagging.resolvedWorkspaceName(
            command: "zip my largest files in workspace Client Alpha please",
            plan: nil,
            routineStore: routineStore,
            workspaceStore: workspaceStore
        )

        #expect(resolved == "Client Alpha")
    }

    @Test
    func freeTextMatchResolvesTwoDistinctWorkspacesToTheLeftmostOne() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Zeta", apps: [], urls: []))
        try workspaceStore.save(StoredWorkspace(name: "Alpha Prime", apps: [], urls: []))

        let resolved = WorkspaceTaskTagging.resolvedWorkspaceName(
            command: "summarize the notes in workspace Zeta and email them to workspace Alpha Prime",
            plan: nil,
            routineStore: routineStore,
            workspaceStore: workspaceStore
        )

        #expect(resolved == "Zeta")
    }

    @Test
    func freeTextMatchHandlesParenthesesAndAmpersandWithoutCrashing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "R&D (2024)", apps: [], urls: []))

        let resolved = WorkspaceTaskTagging.resolvedWorkspaceName(
            command: "share the report in workspace R&D (2024) today",
            plan: nil,
            routineStore: routineStore,
            workspaceStore: workspaceStore
        )

        #expect(resolved == "R&D (2024)")
    }

    @Test
    func freeTextMatchHandlesPlusSignsWithoutCrashing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "C++ Lab", apps: [], urls: []))

        let resolved = WorkspaceTaskTagging.resolvedWorkspaceName(
            command: "compile the project in workspace C++ Lab",
            plan: nil,
            routineStore: routineStore,
            workspaceStore: workspaceStore
        )

        #expect(resolved == "C++ Lab")
    }

    @Test
    func noMatchAnywhereStaysNilRatherThanFalsePositive() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Research", apps: [], urls: []))

        let resolved = WorkspaceTaskTagging.resolvedWorkspaceName(
            command: "just zip my largest files, nothing workspace-related here",
            plan: nil,
            routineStore: routineStore,
            workspaceStore: workspaceStore
        )

        #expect(resolved == nil)
    }

    @Test
    func aWordEndingInInDoesNotSpuriouslyMatchTheLeadingPhraseBoundary() throws {
        // "within" ends in a literal "in" immediately followed by whitespace — without a leading
        // boundary check, the regex would match starting at that embedded "in", spuriously
        // resolving as if the user had actually written "in workspace Client Alpha".
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Client Alpha", apps: [], urls: []))

        let resolved = WorkspaceTaskTagging.resolvedWorkspaceName(
            command: "search within workspace Client Alpha for the invoice",
            plan: nil,
            routineStore: routineStore,
            workspaceStore: workspaceStore
        )

        #expect(resolved == nil)
    }

    @Test
    func aNilPlanFallsStraightToTheFreeTextTier() throws {
        // Exercises the exact behavior the plan-less `recordPriorTaskContext` overload depends on
        // (cancel/fail-before-a-plan-existed path in AgentViewModel): with no plan at all, direct
        // dispatch and routine-nested resolution are skipped entirely and only the command text
        // itself can produce a tag.
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Research", apps: [], urls: []))

        let resolved = WorkspaceTaskTagging.resolvedWorkspaceName(
            command: "summarize the latest updates in workspace Research please",
            plan: nil,
            routineStore: routineStore,
            workspaceStore: workspaceStore
        )

        #expect(resolved == "Research")
    }

    private func openWorkspaceStep(named workspaceName: String) -> AgentStep {
        AgentStep(
            id: "open-workspace",
            operation: .openWorkspace,
            description: "Open workspace",
            workspaceName: workspaceName
        )
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceTaskTaggingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
