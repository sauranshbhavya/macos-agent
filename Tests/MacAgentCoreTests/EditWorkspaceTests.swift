import Foundation
import Testing
@testable import MacAgentCore

/// `edit_workspace` — the capability that makes workspace restriction scope configurable at all.
///
/// Every assertion about an escalation reason is on the **literal string**. The reasons are the
/// product here: they are the only thing standing between "I am removing one folder" and "I am
/// switching file scoping off for this workspace", and a test that compared them to the code's own
/// builder would agree with any wording, including a wrong one.
@Suite
@MainActor
struct EditWorkspaceTests {
    // MARK: - The reason strings, and the two consents they are asking for

    /// The exact copy for a removal that leaves the kind configured. Names what is lost.
    private static let removedOneOfSeveralAppsReason =
        "Removes Notes from workspace Client Alpha's apps. "
        + "What is removed stops opening with the workspace and stops counting as part of it."

    /// The exact copy for a removal that empties the kind. States the dimension, and deliberately
    /// does **not** name the entry — naming it would describe the smaller consent the user is not
    /// being asked for.
    private static let fileLocationsNoLongerRestrictedReason =
        "Workspace Client Alpha will no longer restrict file locations at all: "
        + "this removes the last entry from its file locations list."

    private static let removedOneOfSeveralFileLocationsReasonPrefix =
        "Removes "

    // MARK: - Adding

    /// The end-to-end half of the B1 merge-preserve contract, and the first ticket where a user can
    /// actually lose a boundary: a file location added by voice has to survive the user re-creating
    /// the same workspace by voice.
    @Test
    func addingAFileLocationPersistsAndSurvivesANaturalLanguageRecreate() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))
        let folder = try fixture.makeFolder("ClientAlpha")

        _ = try await fixture.executor.execute(plan: Fixture.editPlan(addFileLocations: [folder.path])) { _, _ in }

        #expect(try fixture.store.workspace(named: "Client Alpha").fileLocations == [folder.path])

        // The natural-language re-create: `CreateWorkspaceCapabilityAdapter` builds a fresh
        // `StoredWorkspace(name:apps:urls:)` with no file locations at all.
        _ = try await fixture.executor.execute(plan: Fixture.createPlan(apps: ["Safari", "Notes"])) { _, _ in }

        let recreated = try fixture.store.workspace(named: "Client Alpha")
        #expect(recreated.fileLocations == [folder.path])
        #expect(recreated.apps == ["Safari", "Notes"])
    }

    /// Widening the boundary is the action the whole feature depends on, so it is not taxed with an
    /// approval prompt. Recorded as a decision, with a forward flag for row C, rather than an
    /// omission — which is why it is pinned rather than merely unasserted.
    @Test
    func addingNeverEscalatesAboveTierTwo() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))
        let folder = try fixture.makeFolder("ClientAlpha")

        let assessment = try fixture.executor.assessRisk(
            plan: Fixture.editPlan(
                addApps: ["Notes"],
                addURLs: ["https://github.com"],
                addFileLocations: [folder.path]
            ),
            scope: .unscoped
        )

        #expect(assessment.defaultTier == .tier2)
        #expect(assessment.effectiveTier == .tier2)
        #expect(assessment.escalations.isEmpty)
    }

    @Test
    func addingAnEntryTheWorkspaceAlreadyHoldsDoesNotDuplicateIt() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Google Chrome"], urls: ["https://github.com/a"])
        )

        // "Chrome" and "Google Chrome" are one app to `WorkspaceScope`, so they have to be one app
        // here too — a second entry would be a list the user never asked for. A second URL on a host
        // already listed is *not* a duplicate: it is another page the workspace opens.
        _ = try await fixture.executor.execute(
            plan: Fixture.editPlan(addApps: ["Chrome"], addURLs: ["https://github.com/b"])
        ) { _, _ in }

        let stored = try fixture.store.workspace(named: "Client Alpha")
        #expect(stored.apps == ["Google Chrome"])
        #expect(stored.urls == ["https://github.com/a", "https://github.com/b"])
    }

    /// A well-formed request with nothing left to do is a no-op with an honest summary, not a
    /// malformed plan. Pins that "did this step name anything?" is asked of the *request* — asking it
    /// of the outcome would turn "add Safari" to a workspace that already lists Safari into an
    /// accusation about the planner.
    @Test
    func anAdditionTheWorkspaceAlreadyHoldsIsANoOpRatherThanAnInvalidPlan() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))

        let result = try await fixture.executor.execute(
            plan: Fixture.editPlan(addApps: ["Safari"])
        ) { _, _ in }

        #expect(result.summary == "Updated workspace Client Alpha. Nothing changed — the workspace already matched this edit.")
        #expect(try fixture.store.workspace(named: "Client Alpha").apps == ["Safari"])
    }

    // MARK: - Removing one of several

    /// Removing one of several entries escalates and names what is lost, and the kind stays
    /// configured afterwards — a non-matching resource still resolves `.outOfScope` and still
    /// prompts.
    @Test
    func removingOneOfSeveralAppsEscalatesNamingWhatIsLostAndLeavesTheKindConfigured() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari", "Notes"], urls: []))

        let assessment = try fixture.executor.assessRisk(
            plan: Fixture.editPlan(removeApps: ["Notes"]),
            scope: .unscoped
        )

        #expect(assessment.defaultTier == .tier2)
        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations.map(\.reason) == [Self.removedOneOfSeveralAppsReason])
        #expect(assessment.escalations.map(\.toTier) == [.tier3])

        _ = try await fixture.executor.execute(plan: Fixture.editPlan(removeApps: ["Notes"])) { _, _ in }

        let scope = try fixture.scope()
        #expect(scope.verdict(for: .app("Notes")) == .outOfScope)
        #expect(scope.verdict(for: .app("Safari")) == .inScope)
    }

    /// A removal named in a spelling the catalog resolves to the same app still removes it. The
    /// failure this pins is a silent one: under a raw-string compare the workspace would report
    /// success and keep Chrome in scope.
    @Test
    func removingAnAppByADifferentSpellingStillRemovesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Google Chrome", "Safari"], urls: [])
        )

        _ = try await fixture.executor.execute(plan: Fixture.editPlan(removeApps: ["Chrome"])) { _, _ in }

        #expect(try fixture.store.workspace(named: "Client Alpha").apps == ["Safari"])
    }

    /// URLs are matched by host, so naming a site removes every stored URL on it. Under exact-string
    /// matching the workspace would keep `github.com` in scope while the tier-3 prompt claimed the
    /// site had been removed.
    @Test
    func removingAURLByHostRemovesEveryStoredURLOnThatHost() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: ["https://github.com/a", "https://github.com/b", "https://example.com"]
            )
        )

        _ = try await fixture.executor.execute(plan: Fixture.editPlan(removeURLs: ["github.com"])) { _, _ in }

        let stored = try fixture.store.workspace(named: "Client Alpha")
        #expect(stored.urls == ["https://example.com"])
        #expect(try fixture.scope().verdict(for: .webDomain("github.com")) == .outOfScope)
    }

    // MARK: - Removing the last entry of a kind

    /// The case a one-of-two removal test satisfies the generic rule without ever touching.
    ///
    /// Emptying a kind turns it `.unconstrained`, which means the dimension stops escalating on
    /// *anything* for every future task in this workspace. The reason has to say that, and it has to
    /// be a different sentence from the one that merely names an entry — the two are different
    /// consents and only one of them is being given.
    @Test
    func removingTheLastFileLocationSaysTheDimensionIsNoLongerRestricted() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let folder = try fixture.makeFolder("ClientAlpha")
        try fixture.store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], fileLocations: [folder.path])
        )

        let assessment = try fixture.executor.assessRisk(
            plan: Fixture.editPlan(removeFileLocations: [folder.path]),
            scope: .unscoped
        )

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations.map(\.reason) == [Self.fileLocationsNoLongerRestrictedReason])
        // The consent being asked for is about the dimension, so the entry is deliberately absent.
        #expect(!Self.fileLocationsNoLongerRestrictedReason.contains(folder.path))
        #expect(Self.fileLocationsNoLongerRestrictedReason != Self.removedOneOfSeveralAppsReason)

        _ = try await fixture.executor.execute(
            plan: Fixture.editPlan(removeFileLocations: [folder.path])
        ) { _, _ in }

        // `.unconstrained`, not `.outOfScope`: the workspace has stopped saying anything about
        // folders, which is exactly what the prompt was warning about.
        let scope = try fixture.scope()
        #expect(scope.verdict(for: .fileLocation(folder.path)) == .unconstrained)
        #expect(scope.verdict(for: .fileLocation(fixture.root.appendingPathComponent("Elsewhere").path)) == .unconstrained)
        #expect(try fixture.store.workspace(named: "Client Alpha").fileLocations == [])
    }

    /// The same distinction on a different kind, so the wording is not accidentally file-specific,
    /// and the two reasons are pinned as different sentences on the *same* kind — which is the
    /// comparison that matters, since a caller only ever sees one kind's pair at a time.
    @Test
    func removingOneOfTwoFileLocationsAndRemovingTheLastOneGiveDifferentReasons() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let kept = try fixture.makeFolder("Kept")
        let dropped = try fixture.makeFolder("Dropped")
        try fixture.store.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [kept.path, dropped.path]
            )
        )

        let oneOfTwo = try fixture.executor.assessRisk(
            plan: Fixture.editPlan(removeFileLocations: [dropped.path]),
            scope: .unscoped
        )
        let bothAtOnce = try fixture.executor.assessRisk(
            plan: Fixture.editPlan(removeFileLocations: [kept.path, dropped.path]),
            scope: .unscoped
        )

        let expectedOneOfTwo = "Removes \(dropped.path) from workspace Client Alpha's file locations. "
            + "What is removed stops counting as part of it."
        #expect(oneOfTwo.escalations.map(\.reason) == [expectedOneOfTwo])
        #expect(bothAtOnce.escalations.map(\.reason) == [Self.fileLocationsNoLongerRestrictedReason])
        #expect(expectedOneOfTwo != Self.fileLocationsNoLongerRestrictedReason)
        #expect(expectedOneOfTwo.hasPrefix(Self.removedOneOfSeveralFileLocationsReasonPrefix))
    }

    /// A removal that empties one kind while another kind only loses one of several produces both
    /// sentences, correctly paired. One merged reason would have to pick a single wording and be
    /// wrong about the other half.
    @Test
    func anEditThatEmptiesOneKindAndTrimsAnotherReportsBothConsentsSeparately() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let folder = try fixture.makeFolder("ClientAlpha")
        try fixture.store.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari", "Notes"],
                urls: [],
                fileLocations: [folder.path]
            )
        )

        let assessment = try fixture.executor.assessRisk(
            plan: Fixture.editPlan(removeApps: ["Notes"], removeFileLocations: [folder.path]),
            scope: .unscoped
        )

        #expect(assessment.escalations.map(\.reason) == [
            Self.removedOneOfSeveralAppsReason,
            Self.fileLocationsNoLongerRestrictedReason
        ])
    }

    /// Removing the last entry while adding another in the same breath is **not** an emptying: the
    /// dimension stays configured, so the heavier consent is the wrong one to ask for.
    @Test
    func replacingTheLastFileLocationInOneEditIsNotAnEmptying() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let old = try fixture.makeFolder("Old")
        let new = try fixture.makeFolder("New")
        try fixture.store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], fileLocations: [old.path])
        )

        let assessment = try fixture.executor.assessRisk(
            plan: Fixture.editPlan(addFileLocations: [new.path], removeFileLocations: [old.path]),
            scope: .unscoped
        )

        let expected = "Removes \(old.path) from workspace Client Alpha's file locations. "
            + "What is removed stops counting as part of it."
        #expect(assessment.escalations.map(\.reason) == [expected])
        #expect(assessment.effectiveTier == .tier3)
    }

    /// Removing something and adding it back in the same edit loses nothing, so it must not ask for
    /// a tier-3 consent to a loss that does not happen. Pins that removals are derived from the
    /// outcome rather than from the request.
    @Test
    func removingAndReAddingTheSameEntryLosesNothingAndDoesNotEscalate() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari", "Notes"], urls: []))

        let assessment = try fixture.executor.assessRisk(
            plan: Fixture.editPlan(addApps: ["Notes"], removeApps: ["Notes"]),
            scope: .unscoped
        )

        #expect(assessment.escalations.isEmpty)
        #expect(assessment.effectiveTier == .tier2)
    }

    /// A removal that names nothing the workspace holds is reported rather than silently swallowed,
    /// and it does not escalate — nothing is lost. The add in the same step still lands, which is
    /// why this is not an error.
    @Test
    func aRemovalThatMatchesNothingIsReportedAndStillLetsTheAdditionThrough() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))

        let plan = Fixture.editPlan(addApps: ["Notes"], removeApps: ["Mail"])
        let assessment = try fixture.executor.assessRisk(plan: plan, scope: .unscoped)
        let result = try await fixture.executor.execute(plan: plan) { _, _ in }

        #expect(assessment.escalations.isEmpty)
        #expect(result.summary.contains("Not in this workspace's apps, so nothing was removed: Mail"))
        #expect(try fixture.store.workspace(named: "Client Alpha").apps == ["Safari", "Notes"])
    }

    // MARK: - Validation

    /// A folder outside the whitelist can never match at scope-check time, because `PathWhitelist`
    /// rejects the path first — so accepting one would hand the user a boundary that quietly does
    /// nothing. Asserted on both halves: the error is specific, and the store is untouched.
    @Test
    func aFileLocationOutsideTheWhitelistIsRejectedWithASpecificErrorAndNothingIsSaved() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditWorkspaceTests-Outside-\(UUID().uuidString)", isDirectory: true)

        var thrown: Error?
        do {
            _ = try await fixture.executor.execute(
                plan: Fixture.editPlan(addFileLocations: [outside.path])
            ) { _, _ in }
        } catch {
            thrown = error
        }

        let validation = try #require(thrown as? PathValidationError)
        guard case .outsideWhitelist(let path, let roots) = validation else {
            Issue.record("Expected .outsideWhitelist, got \(validation)")
            return
        }
        #expect(path.hasSuffix(outside.lastPathComponent))
        #expect(roots == [fixture.root.resolvingSymlinksInPath().path])
        #expect(validation.errorDescription?.contains("is outside the writable whitelist") == true)

        let stored = try fixture.store.workspace(named: "Client Alpha")
        #expect(stored.fileLocations == nil)
        #expect(stored.apps == ["Safari"])
    }

    /// A removal request is deliberately not whitelist-validated: a stored location outside the
    /// whitelist is inert and useless, so removing it has to be possible. Refusing would make it the
    /// one edit the user could never make.
    @Test
    func anInertFileLocationOutsideTheWhitelistCanStillBeRemoved() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let outside = "/tmp/EditWorkspaceTests-Legacy"
        let kept = try fixture.makeFolder("Kept")
        try fixture.store.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [kept.path, outside]
            )
        )

        _ = try await fixture.executor.execute(
            plan: Fixture.editPlan(removeFileLocations: [outside])
        ) { _, _ in }

        #expect(try fixture.store.workspace(named: "Client Alpha").fileLocations == [kept.path])
    }

    @Test
    func editingAWorkspaceThatDoesNotExistFailsNamingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        await #expect(throws: AutomationStoreError.missingWorkspace("Client Alpha")) {
            _ = try await fixture.executor.execute(
                plan: Fixture.editPlan(addApps: ["Notes"])
            ) { _, _ in }
        }
        #expect(AutomationStoreError.missingWorkspace("Client Alpha").errorDescription
            == "No workspace named Client Alpha is saved.")
        #expect(try fixture.store.loadAll().isEmpty)
    }

    /// The SONNY-30 anti-pattern, pinned so it cannot be reintroduced here. The sibling
    /// `CreateWorkspaceCapabilityAdapter` wraps its store load in `try?`, which turns a decrypt
    /// failure into "no workspace by that name" — and in `assessRisk` that silently suppresses a
    /// correct tier-3 escalation. A broken store has to read as broken.
    @Test
    func aStoreLoadFailureSurfacesAsAFailureRatherThanAsAMissingWorkspace() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        // A file that claims to be encrypted and is not: the header is real, the ciphertext is not.
        var corrupt = LocalStorageEncryption.fileHeader
        corrupt.append(Data(repeating: 0x00, count: 64))
        try corrupt.write(to: fixture.storeURL, options: .atomic)

        var thrownFromExecute: Error?
        do {
            _ = try await fixture.executor.execute(
                plan: Fixture.editPlan(addApps: ["Notes"])
            ) { _, _ in }
        } catch {
            thrownFromExecute = error
        }
        var thrownFromAssess: Error?
        do {
            _ = try fixture.executor.assessRisk(plan: Fixture.editPlan(addApps: ["Notes"]), scope: .unscoped)
        } catch {
            thrownFromAssess = error
        }

        #expect(thrownFromExecute != nil)
        #expect(thrownFromAssess != nil)
        #expect(!(thrownFromExecute is AutomationStoreError))
        #expect(!(thrownFromAssess is AutomationStoreError))
    }

    /// The rule creation already enforces, applied to the *outcome*: a workspace with neither apps
    /// nor URLs can never be opened again. Refused before anything is written.
    @Test
    func anEditThatWouldLeaveNoAppsAndNoURLsIsRefusedAndNothingIsSaved() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))

        await #expect(throws: AutomationStoreError.emptyWorkspace) {
            _ = try await fixture.executor.execute(
                plan: Fixture.editPlan(removeApps: ["Safari"])
            ) { _, _ in }
        }
        #expect(try fixture.store.workspace(named: "Client Alpha").apps == ["Safari"])
    }

    @Test
    func anEditStepNamingNoChangeAtAllIsAnInvalidPlan() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))

        await #expect(
            throws: AgentExecutionError.invalidPlan(
                "edit_workspace step names no apps, URLs, or file locations to add or remove."
            )
        ) {
            _ = try await fixture.executor.execute(plan: Fixture.editPlan()) { _, _ in }
        }
    }

    @Test
    func anEditWithNoWorkspaceNameFailsBeforeTouchingTheStore() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        await #expect(throws: AutomationStoreError.missingName("Workspace")) {
            _ = try await fixture.executor.execute(
                plan: Fixture.editPlan(workspaceName: "   ", addApps: ["Notes"])
            ) { _, _ in }
        }
    }

    @Test
    func addingAURLThatIsNotSafeIsRejectedAndNothingIsSaved() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))

        await #expect(throws: SafeURLError.unsupportedScheme("ftp")) {
            _ = try await fixture.executor.execute(
                plan: Fixture.editPlan(addURLs: ["ftp://example.com"])
            ) { _, _ in }
        }
        #expect(try fixture.store.workspace(named: "Client Alpha").urls.isEmpty)
    }

    // MARK: - What an edit must not disturb

    /// An edit states the workspace's whole outcome, so everything it does not mention has to come
    /// back unchanged — including the display name's own casing, since renaming is an explicit
    /// non-goal and the store keys on a folded name.
    @Test
    func anEditPreservesTeamTypeAndTheStoredDisplayNameCasing() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], teamType: .team)
        )

        _ = try await fixture.executor.execute(
            plan: Fixture.editPlan(workspaceName: "client alpha", addApps: ["Notes"])
        ) { _, _ in }

        let stored = try fixture.store.workspace(named: "Client Alpha")
        #expect(stored.name == "Client Alpha")
        #expect(stored.teamType == .team)
        #expect(stored.effectiveTeamType == .team)
        #expect(stored.apps == ["Safari", "Notes"])
        #expect(try fixture.store.loadAll().count == 1)
    }

    /// The preview is what the approval panel renders, so it has to describe the same edit the
    /// escalation is asking about — and it must not have any side effect of its own.
    @Test
    func previewDescribesTheEditWithoutWritingAnything() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let folder = try fixture.makeFolder("ClientAlpha")
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari", "Notes"], urls: []))

        let previews = try fixture.executor.preview(
            plan: Fixture.editPlan(addFileLocations: [folder.path], removeApps: ["Notes"])
        )

        let preview = try #require(previews.first)
        #expect(preview.title == "Edit workspace Client Alpha")
        #expect(preview.details.contains("Add file locations: \(folder.path)"))
        #expect(preview.details.contains("Remove apps: Notes"))
        #expect(preview.writes == [fixture.storeURL.path])
        // Untouched: preview is a dry run.
        let stored = try fixture.store.workspace(named: "Client Alpha")
        #expect(stored.apps == ["Safari", "Notes"])
        #expect(stored.fileLocations == nil)
    }

    /// The emptying sentence is repeated in the run result, not only in the approval prompt. The
    /// prompt is read once under time pressure; this is the line that explains why a later task in
    /// this workspace stops prompting.
    @Test
    func theRunSummaryRepeatsThatTheDimensionIsNoLongerRestricted() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let folder = try fixture.makeFolder("ClientAlpha")
        try fixture.store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], fileLocations: [folder.path])
        )

        let result = try await fixture.executor.execute(
            plan: Fixture.editPlan(removeFileLocations: [folder.path])
        ) { _, _ in }

        #expect(result.summary.contains("Client Alpha no longer restricts file locations at all."))
        #expect(result.summary.contains("Removed 1 file locations: \(folder.path)."))
    }

    /// Configuring a boundary is not touching one. `edit_workspace` carries real paths in its plan
    /// fields — the only operation in the enum that does so while touching nothing — so a workspace
    /// cannot escalate on the folder being added to it.
    @Test
    func editWorkspaceContributesNoScopedResourcesEvenWhenItNamesFolders() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let inside = try fixture.makeFolder("Inside")
        let scope = WorkspaceScope(
            workspace: StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: ["https://example.com"],
                fileLocations: [inside.path]
            ),
            whitelist: fixture.whitelist
        )
        let step = AgentStep(
            id: "edit",
            operation: .editWorkspace,
            description: "Edit workspace.",
            workspaceName: "Client Alpha",
            workspaceApps: ["Slack"],
            workspaceURLs: ["https://elsewhere.example"],
            workspaceFileLocations: ["/etc"],
            workspaceAppsToRemove: ["Safari"],
            workspaceURLsToRemove: ["example.com"],
            workspaceFileLocationsToRemove: [inside.path]
        )

        let classification = PlanScopedResources.classification(of: step)
        #expect(classification.resources.isEmpty)
        #expect(classification.isOpaque == false)

        let evaluation = WorkspaceScopeEvaluator.evaluate(
            plan: AgentPlan(summary: "Edit.", requiresConfirmation: true, steps: [step]),
            scope: scope
        )
        #expect(evaluation.findings.isEmpty)
        #expect(evaluation.planVerdict == .unconstrained)
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let root: URL
        let storeURL: URL
        let whitelist: PathWhitelist
        let store: WorkspaceStore
        let executor: AgentActionExecutor

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("EditWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            storeURL = root.appendingPathComponent("workspaces.json")
            whitelist = PathWhitelist(roots: [root])
            store = WorkspaceStore(fileURL: storeURL)
            // Nothing this capability does opens an app, a file or a Shortcut — but the executor's
            // production defaults are the real openers and the real `shortcuts list`, so they are
            // replaced rather than left to be one typo away from driving the developer's machine.
            executor = AgentActionExecutor(
                whitelist: whitelist,
                appOpener: NoopAppOpener(),
                fileOpener: NoopFileOpener(),
                routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
                workspaceStore: store,
                shortcutCatalog: FakeShortcutCatalog(names: []),
                shortcutRunHistoryStore: ShortcutRunHistoryStore(
                    fileURL: root.appendingPathComponent("shortcuts-history.json")
                )
            )
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }

        /// A real directory inside the test whitelist. Real because `PathWhitelist` resolves symlinks
        /// on both sides, and on macOS the temporary directory is one.
        func makeFolder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.resolvingSymlinksInPath()
        }

        func scope() throws -> WorkspaceScope {
            WorkspaceScope(workspace: try store.workspace(named: "Client Alpha"), whitelist: whitelist)
        }

        static func editPlan(
            workspaceName: String = "Client Alpha",
            addApps: [String]? = nil,
            addURLs: [String]? = nil,
            addFileLocations: [String]? = nil,
            removeApps: [String]? = nil,
            removeURLs: [String]? = nil,
            removeFileLocations: [String]? = nil
        ) -> AgentPlan {
            AgentPlan(
                summary: "Edit workspace.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(
                        id: "edit-workspace",
                        operation: .editWorkspace,
                        description: "Edit workspace.",
                        workspaceName: workspaceName,
                        workspaceApps: addApps,
                        workspaceURLs: addURLs,
                        workspaceFileLocations: addFileLocations,
                        workspaceAppsToRemove: removeApps,
                        workspaceURLsToRemove: removeURLs,
                        workspaceFileLocationsToRemove: removeFileLocations
                    )
                ]
            )
        }

        static func createPlan(apps: [String], urls: [String] = []) -> AgentPlan {
            AgentPlan(
                summary: "Create workspace.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(
                        id: "create-workspace",
                        operation: .createWorkspace,
                        description: "Create workspace.",
                        workspaceName: "Client Alpha",
                        workspaceApps: apps,
                        workspaceURLs: urls
                    )
                ]
            )
        }
    }
}

private struct NoopAppOpener: AppOpening {
    func open(bundleIdentifier: String) async throws {}
}

private struct NoopFileOpener: FileOpening {
    func openFile(_ url: URL) async throws {}
}
