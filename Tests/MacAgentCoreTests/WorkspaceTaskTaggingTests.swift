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
        // `.openWorkspace` is on `StoredRoutine.forbiddenStepOperations`, so `save` refuses this
        // routine (SONNY-52) — and refusing it is right: the routine could never be authored. What
        // is under test is the *resolver's* one-level descent into a routine that already contains
        // one, so the sanctioned bypass is the accurate way to set that state up.
        try routineStore.saveBypassingStepValidation(
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

    // MARK: - The clause as a subtractable phrase (SONNY-68)

    /// The second word order, which bound nothing before this ticket. "in my Switch workspace" is
    /// how the fourth recorded misroute was typed, and the tagger's regex only knew
    /// "in [the|my] workspace X" — so that command named a workspace Sonny could not see, and its
    /// scope silently did not exist.
    @Test
    func aNameBeforeTheNounBindsTheSameWorkspaceAsANameAfterIt() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))

        for command in [
            "zip the largest files in workspace Client Alpha",
            "zip the largest files in the workspace Client Alpha",
            "zip the largest files in my workspace Client Alpha",
            "zip the largest files in my Client Alpha workspace",
            "zip the largest files in the Client Alpha workspace",
            "zip the largest files in Client Alpha workspace"
        ] {
            #expect(
                WorkspaceTaskTagging.workspaceClause(in: command, workspaceStore: workspaceStore)?.workspaceName
                    == "Client Alpha",
                "\(command) should bind Client Alpha."
            )
        }
    }

    /// What the resolver subtracts: the clause, and nothing else. The canonical saved name comes
    /// back regardless of how it was typed, and the surviving text keeps the caller's own casing —
    /// an app query lowercased on the way through would put the wrong words in the summary the user
    /// reads.
    @Test
    func theClauseIsRemovedWithTheRestOfTheCommandLeftExactlyAsTyped() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Switch", apps: ["Chrome"], urls: []))

        let trailing = WorkspaceTaskTagging.workspaceClause(
            in: "Zoom in my SWITCH workspace",
            workspaceStore: workspaceStore
        )
        #expect(trailing?.workspaceName == "Switch")
        #expect(trailing?.remainingCommand == "Zoom")

        // Mid-sentence removal must not leave the double space that cutting a phrase out normally
        // produces.
        let embedded = WorkspaceTaskTagging.workspaceClause(
            in: "Zoom in the workspace Switch now",
            workspaceStore: workspaceStore
        )
        #expect(embedded?.remainingCommand == "Zoom now")

        // A name that is not saved is not a clause, so there is nothing to subtract.
        #expect(WorkspaceTaskTagging.workspaceClause(in: "Zoom in my Nowhere workspace", workspaceStore: workspaceStore) == nil)
    }

    /// **`FoldedText`'s whole reason for existing, which had no test until the review said so**
    /// (PR #39 review, cycle 1, F7). A character whose folded form is longer than itself breaks any
    /// scheme that assumes a folded offset is an original offset: "ß" folds to "ss", the "ﬁ"
    /// ligature to "fi", "İ" to "i". The clause must still be cut at the right place in the
    /// caller's own characters, and the text either side must come back untouched.
    @Test
    func aClauseIsCutCorrectlyAroundCharactersWhoseFoldedFormIsLonger() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Straße", apps: ["Safari"], urls: []))
        try workspaceStore.save(StoredWorkspace(name: "Oﬃce", apps: ["Safari"], urls: []))
        try workspaceStore.save(StoredWorkspace(name: "İstanbul", apps: ["Safari"], urls: []))

        let sharp = WorkspaceTaskTagging.workspaceClause(
            in: "please switch to code in the workspace Straße right now",
            workspaceStore: workspaceStore
        )
        #expect(sharp?.workspaceName == "Straße")
        #expect(sharp?.remainingCommand == "please switch to code right now")

        // Matched through the fold from the other side too: the typed form differs from the saved
        // one, and the canonical saved name is what comes back.
        let transliterated = WorkspaceTaskTagging.workspaceClause(
            in: "switch to code in the workspace Strasse",
            workspaceStore: workspaceStore
        )
        #expect(transliterated?.workspaceName == "Straße")
        #expect(transliterated?.remainingCommand == "switch to code")

        let ligature = WorkspaceTaskTagging.workspaceClause(
            in: "switch to code in my Office workspace now",
            workspaceStore: workspaceStore
        )
        #expect(ligature?.workspaceName == "Oﬃce")
        #expect(ligature?.remainingCommand == "switch to code now")

        let dottedCapital = WorkspaceTaskTagging.workspaceClause(
            in: "switch to code in the workspace Istanbul",
            workspaceStore: workspaceStore
        )
        #expect(dottedCapital?.workspaceName == "İstanbul")
        #expect(dottedCapital?.remainingCommand == "switch to code")
    }

    /// The leftmost/longest tie-break, under the *new* word order — both existing tie-break tests
    /// use only the old one (PR #39 review, cycle 1, F7).
    @Test
    func theTieBreakHoldsInTheNameBeforeNounOrderToo() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Client", apps: ["Safari"], urls: []))
        try workspaceStore.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))

        #expect(
            WorkspaceTaskTagging.workspaceClause(in: "zip the files in my Client Alpha workspace", workspaceStore: workspaceStore)?
                .workspaceName == "Client Alpha"
        )
        #expect(
            WorkspaceTaskTagging.workspaceClause(in: "zip the files in my Client workspace", workspaceStore: workspaceStore)?
                .workspaceName == "Client"
        )
    }

    /// A saved name that contains the phrase's own noun. Both orders have to survive it, and the
    /// subtraction has to take the whole clause rather than stopping at the first "workspace" it
    /// sees (PR #39 review, cycle 1, F7).
    @Test
    func aWorkspaceNamedAfterTheNounStillBindsAndIsStillSubtractedWhole() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Workspace Alpha", apps: ["Safari"], urls: []))
        try workspaceStore.save(StoredWorkspace(name: "Beta Workspace", apps: ["Safari"], urls: []))

        let leading = WorkspaceTaskTagging.workspaceClause(
            in: "switch to code in my Workspace Alpha workspace",
            workspaceStore: workspaceStore
        )
        #expect(leading?.workspaceName == "Workspace Alpha")
        #expect(leading?.remainingCommand == "switch to code")

        let trailing = WorkspaceTaskTagging.workspaceClause(
            in: "switch to code in the workspace Beta Workspace",
            workspaceStore: workspaceStore
        )
        #expect(trailing?.workspaceName == "Beta Workspace")
        #expect(trailing?.remainingCommand == "switch to code")
    }

    /// The boundary guard survives the second word order. "within workspace Client Alpha" contains
    /// a literal "in" from "with-IN", and neither alternative may match through it.
    @Test
    func theSecondWordOrderDoesNotWeakenThePhraseBoundaryGuard() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Client", apps: ["Safari"], urls: []))

        #expect(WorkspaceTaskTagging.workspaceClause(in: "search within workspace Client for the invoice", workspaceStore: workspaceStore) == nil)
        // A shorter name matching only as a prefix of a longer word is still rejected on the
        // trailing side, in the new order as well as the old.
        #expect(WorkspaceTaskTagging.workspaceClause(in: "look in my Clientele workspace", workspaceStore: workspaceStore) == nil)
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
