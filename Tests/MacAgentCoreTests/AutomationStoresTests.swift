import Foundation
import Testing
@testable import MacAgentCore

struct AutomationStoresTests {
    // MARK: - SONNY-67: the routine store's read door

    /// **The defect, end to end.** A `routines.json` written by something that is not Sonny can carry
    /// `resolvedAppName`/`resolvedBundleIdentifier` pre-set on a step. Nothing downstream questions a
    /// pin that arrives already set — `RunningAppSwitchCapabilityAdapter`'s pin-once guard honours it
    /// at every gate, correctly and by design — so the store's read door is where it has to be
    /// removed. Written here as an encrypted store, through the store's own writer, so the test
    /// exercises the real decode path rather than a hand-rolled plaintext file.
    @Test
    func aTamperedRoutineLosesItsPreSetResolverPinsOnLoad() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

        var tampered = AgentStep(id: "switch", operation: .openApp, description: "Open Safari.", appName: "Safari")
        tampered.resolvedAppName = "Safari"
        tampered.resolvedBundleIdentifier = "com.attacker.lookalike"
        // `saveBypassingStepValidation` is the module-internal test-only write door; it is what a
        // hand-written file is being stood in for here.
        try store.saveBypassingStepValidation(StoredRoutine(name: "Tampered", steps: [tampered]))

        let loaded = try store.routine(named: "Tampered")

        #expect(loaded.steps.count == 1)
        #expect(loaded.steps[0].resolvedAppName == nil)
        #expect(loaded.steps[0].resolvedBundleIdentifier == nil)
        // Everything else the step said survives — this strips a pin, it does not sanitise a step.
        #expect(loaded.steps[0].appName == "Safari")
        #expect(loaded.steps[0].operation == .openApp)
    }

    /// Nested `routineSteps` are refused at the write door and so can only exist in a file Sonny did
    /// not write — which is the same file this is defending against. The strip recurses for that
    /// reason, and this is the pin.
    @Test
    func preSetPinsAreStrippedInsideNestedRoutineStepsToo() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

        var nested = AgentStep(id: "nested", operation: .openApp, description: "Open Safari.", appName: "Safari")
        nested.resolvedAppName = "Safari"
        nested.resolvedBundleIdentifier = "com.attacker.lookalike"
        var outer = AgentStep(id: "outer", operation: .openApp, description: "Open Safari.", appName: "Safari")
        outer.routineSteps = [nested]
        try store.saveBypassingStepValidation(StoredRoutine(name: "Nested", steps: [outer]))

        let loaded = try store.routine(named: "Nested")

        let innerStep = try #require(loaded.steps.first?.routineSteps?.first)
        #expect(innerStep.resolvedAppName == nil)
        #expect(innerStep.resolvedBundleIdentifier == nil)
    }

    /// **The third pin, through the real read door** (PR #94 review, F1).
    ///
    /// `resolvedFromFinderSelection` was added by SONNY-185 and registered in
    /// `everyAgentStepFieldIsClassifiedAgainstTheResolverOnlyStrip`'s `resolverOnly` set, whose own
    /// comment says the strip "must clear it too" — and the strip did not, because that test asserts
    /// `Mirror` membership rather than behaviour and so passed vacuously. This is the assertion that
    /// could not: it drives a forged value through `saveBypassingStepValidation` and reads it back.
    ///
    /// Both nesting levels, because the Finder pin differs from the two identity pins in exactly the
    /// place that matters here: its operations are *not* in `forbiddenStepOperations`, so a nested
    /// `scan_select_largest_files` is a step a routine may legitimately contain, and a hand-written
    /// file can therefore put a forged pin somewhere the identity pins could never reach.
    @Test
    func aForgedFinderSelectionPinIsStrippedAtBothNestingLevels() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

        var nested = AgentStep(
            id: "scan",
            operation: .scanSelectLargestFiles,
            description: "Scan the selected folder.",
            inputPath: "~/Documents/Client",
            count: 3,
            contextSource: .finderSelection
        )
        nested.resolvedFromFinderSelection = true
        var outer = AgentStep(
            id: "zip",
            operation: .createZip,
            description: "Zip it.",
            inputPath: "~/Documents/Client",
            contextSource: .finderSelection
        )
        outer.resolvedFromFinderSelection = true
        outer.routineSteps = [nested]
        try store.saveBypassingStepValidation(StoredRoutine(name: "Forged", steps: [outer]))

        let loaded = try store.routine(named: "Forged")

        #expect(loaded.steps[0].resolvedFromFinderSelection == nil)
        let innerStep = try #require(loaded.steps.first?.routineSteps?.first)
        #expect(innerStep.resolvedFromFinderSelection == nil)
        // A pin is stripped; a step is not sanitised. The planner's own declaration survives, which
        // is what the classifier reads together with the pin.
        #expect(loaded.steps[0].contextSource == .finderSelection)
        #expect(innerStep.contextSource == .finderSelection)
        #expect(innerStep.inputPath == "~/Documents/Client")
    }

    /// The other direction, and the one that makes the strip safe to apply unconditionally: a routine
    /// saved the way the product saves them round-trips byte-identically. If this ever fails, the
    /// strip has started removing something a legitimate store had.
    @Test
    func aLegitimatelySavedRoutineRoundTripsUnchanged() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let routine = StoredRoutine(
            name: "Morning",
            steps: [
                AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari"),
                AgentStep(id: "url", operation: .openURL, description: "Open the board.", targetURL: "https://example.com", browserName: "Arc")
            ]
        )
        try store.save(routine)

        #expect(try store.routine(named: "Morning") == routine)
    }

    /// The decision behind SONNY-67's log line, held as a value (founder decision 2026-08-21, F6).
    /// The warning itself is an `os.Logger` call, which no test in this repository observes — the two
    /// existing `LocalStorageMigrationLog` warnings have none either, and reading them back needs
    /// `OSLogStore`. What *is* cheap to hold is the condition that decides whether it is emitted, so
    /// that lives in its own function and this pins it.
    @Test
    func onlyStepsCarryingAPinAreCountedForTheStripWarning() {
        var pinnedName = AgentStep(id: "a", operation: .openApp, description: "a", appName: "Safari")
        pinnedName.resolvedAppName = "Safari"
        var pinnedIdentifier = AgentStep(id: "b", operation: .openApp, description: "b", appName: "Notes")
        pinnedIdentifier.resolvedBundleIdentifier = "com.apple.Notes"
        var pinnedBoth = AgentStep(id: "c", operation: .openApp, description: "c", appName: "Mail")
        pinnedBoth.resolvedAppName = "Mail"
        pinnedBoth.resolvedBundleIdentifier = "com.apple.mail"
        // The third pin counts on its own too (PR #94 review, F1) — a step carrying only this one
        // was invisible to the warning while the strip's own comment claimed it was cleared.
        var pinnedFinder = AgentStep(id: "e", operation: .createZip, description: "e")
        pinnedFinder.resolvedFromFinderSelection = true
        var pinnedAllThree = AgentStep(id: "f", operation: .openApp, description: "f", appName: "Notes")
        pinnedAllThree.resolvedAppName = "Notes"
        pinnedAllThree.resolvedBundleIdentifier = "com.apple.Notes"
        pinnedAllThree.resolvedFromFinderSelection = true
        let clean = AgentStep(id: "d", operation: .openApp, description: "d", appName: "Music")

        #expect(StoredRoutine.resolverPinnedStepCount([clean]) == 0)
        #expect(StoredRoutine.resolverPinnedStepCount([pinnedFinder]) == 1)
        // Any pin counts the step, and a step carrying all three counts once — the unit is the step,
        // matching what the strip clears.
        #expect(
            StoredRoutine.resolverPinnedStepCount(
                [pinnedName, pinnedIdentifier, pinnedBoth, pinnedFinder, pinnedAllThree, clean]
            ) == 5
        )

        // Recursive, like the strip: a nested step's pin is a pin.
        var outer = AgentStep(id: "outer", operation: .openApp, description: "outer", appName: "Safari")
        outer.routineSteps = [pinnedBoth, clean]
        #expect(StoredRoutine.resolverPinnedStepCount([outer]) == 1)
    }

    /// **The forcing function.** The strip clears three named fields, and a hand-maintained list of
    /// resolver-only fields is exactly the thing that goes stale — the defect this ticket closes
    /// exists because one door knew a rule and another did not.
    ///
    /// `Mirror` enumerates `AgentStep`'s stored properties whether or not they are set, so a field
    /// added to that type lands in `actual` and fails this test until someone classifies it. The two
    /// questions to answer then are: can the planner write it (is it in `AgentPlanDecoder.stepKeys`
    /// and the schema?), and if not, must `StoredRoutine.strippingResolverPins` clear it?
    ///
    /// **What this cannot tell you, and PR #94's review is why the sentence is here:** membership in
    /// `resolverOnly` is a claim *about* the strip, not a check *of* it. SONNY-185 added
    /// `resolvedFromFinderSelection` to the set below with a comment saying the strip must clear it,
    /// the strip did not, and this test stayed green — it only ever asked whether the field had been
    /// classified. The behavioural counterpart is
    /// `aForgedFinderSelectionPinIsStrippedAtBothNestingLevels`, and every field listed as
    /// resolver-only needs one of those or it is classified and unguarded.
    @Test
    func everyAgentStepFieldIsClassifiedAgainstTheResolverOnlyStrip() {
        let probe = AgentStep(id: "probe", operation: .clarify, description: "Probe.")
        let actual = Set(Mirror(reflecting: probe).children.compactMap(\.label))

        /// Planner-writable: present in `AgentPlanDecoder.stepKeys` and in the planner schema.
        let plannerWritable: Set<String> = [
            "id", "operation", "description", "inputPath", "outputPath", "count", "targetURL",
            "appName", "question", "mediaProvider", "mediaTitle", "mediaArtist", "contextSource",
            "routineName", "routineSteps", "workspaceName", "workspaceApps", "workspaceURLs",
            "workspaceFileLocations", "workspaceAppsToRemove", "workspaceURLsToRemove",
            "workspaceFileLocationsToRemove", "sourceURLs", "searchQuery", "draftTitle",
            "draftContent", "shortcutName", "shortcutInput", "visionGoal", "browserName"
        ]
        /// Resolver-only: written by the executor, never decodable from a planner response, and
        /// therefore stripped by the routine store's read door — each one held by a behavioural test
        /// of the strip as well as by membership here.
        let resolverOnly: Set<String> = [
            "resolvedAppName",
            "resolvedBundleIdentifier",
            // SONNY-185. Not an identity like the two above it — one boolean recording whether the
            // resolve phase actually drove Finder to find this step's folder — but resolver-written
            // and decode-excluded on exactly the same terms, so the strip must clear it too.
            "resolvedFromFinderSelection"
        ]

        #expect(
            actual == plannerWritable.union(resolverOnly),
            "an AgentStep field is unclassified: decide whether the routine store must strip it"
        )
        #expect(plannerWritable.intersection(resolverOnly).isEmpty)
    }

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
    func theForbiddenStepListIsExactlyTheNineOperationsRoutinesMayNotContain() {
        #expect(
            StoredRoutine.forbiddenStepOperations == [
                .saveRoutine,
                .runRoutine,
                .createWorkspace,
                .editWorkspace,
                .openWorkspace,
                .switchRunningApp,
                // Row I's third layer of "unattended vision: never". A stored routine structurally
                // cannot carry a vision step, so the scheduled path can never see one through this
                // door — independent of the scheduled path's own refusal and of the
                // `.approved(.tier2)` ceiling a tier-3 vision assessment cannot pass.
                .visionSession,
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
