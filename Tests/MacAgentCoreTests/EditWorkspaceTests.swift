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
    ///
    /// It deliberately says nothing about the app no longer *opening*: an app `MacAppCatalog` cannot
    /// resolve is saved for scope only and never opened with the workspace at all, so that clause
    /// would assert a behaviour change that cannot occur for exactly the apps SONNY-44 made listable.
    private static let removedOneOfSeveralAppsReason =
        "Removes Notes from workspace Client Alpha's apps. "
        + "What is removed stops counting as part of this workspace."

    /// The exact copy for a removal that empties the kind. States the dimension, and deliberately
    /// does **not** name the entry — naming it would describe the smaller consent the user is not
    /// being asked for.
    private static let fileLocationsNoLongerRestrictedReason =
        "Workspace Client Alpha will no longer restrict file locations at all: "
        + "this removes the last entry from its file locations list."

    private static let removedOneOfSeveralFileLocationsReasonPrefix =
        "Removes "

    /// The URL kind's pair, the third dimension. Held here rather than inline so the two can be
    /// asserted different from each other, the same way the file-location pair is.
    private static let urlsNoLongerRestrictedReason =
        "Workspace Client Alpha will no longer restrict URLs at all: "
        + "this removes the last entry from its URLs list."

    private static let removedOneOfSeveralURLsReason =
        "Removes https://github.com/a from workspace Client Alpha's URLs. "
        + "What is removed stops counting as part of this workspace."

    // MARK: - Adding

    /// The end-to-end half of the B1 merge-preserve contract, and the first ticket where a user can
    /// actually lose a boundary: a file location added by voice has to survive the user re-creating
    /// the same workspace by voice.
    ///
    /// **`teamType` rides here too, and that is the point.** SONNY-43's own criterion is survival
    /// across a *natural-language re-create*; the store-level regression asserts it against two
    /// direct `store.save` calls and couples to the create path only by a comment saying that is what
    /// the adapter builds. True today — but a change to `CreateWorkspaceCapabilityAdapter` that
    /// started stating a team type would break preservation with that test still green. This drives
    /// the real create adapter through the executor, so both merge-preserved fields are pinned at the
    /// level the criterion actually states.
    @Test
    func addingAFileLocationPersistsAndSurvivesANaturalLanguageRecreate() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], teamType: .team)
        )
        let folder = try fixture.makeFolder("ClientAlpha")

        _ = try await fixture.executor.execute(plan: Fixture.editPlan(addFileLocations: [folder.path])) { _, _ in }

        #expect(try fixture.store.workspace(named: "Client Alpha").fileLocations == [folder.path])

        // The natural-language re-create: `CreateWorkspaceCapabilityAdapter` builds a fresh
        // `StoredWorkspace(name:apps:urls:)` with neither file locations nor a team type.
        _ = try await fixture.executor.execute(plan: Fixture.createPlan(apps: ["Safari", "Notes"])) { _, _ in }

        let recreated = try fixture.store.workspace(named: "Client Alpha")
        #expect(recreated.fileLocations == [folder.path])
        #expect(recreated.teamType == .team)
        #expect(recreated.effectiveTeamType == .team)
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
            + "What is removed stops counting as part of this workspace."
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
            + "What is removed stops counting as part of this workspace."
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
        #expect(result.summary.contains("Removed file locations: \(folder.path)."))
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

    // MARK: - The third kind's dimension pin

    /// **The last-entry criterion, on URLs — the kind that had no pin at all.**
    ///
    /// Apps and file locations each had one, so mutating their arm of `restricts(_:in:)` died; the
    /// `.webDomain` arm survived the whole suite, and what that mutant models is this branch's
    /// headline failure: a workspace with apps *and* one URL, the user removes the URL, both
    /// restriction flags read `appKeys` — non-empty either side — so the dimension goes
    /// `.unconstrained` while the approver is handed the milder entry-naming consent.
    ///
    /// Both URL consents are pinned here on their literal strings and asserted different from each
    /// other, which is the shape the file-location pair already had.
    @Test
    func removingTheLastURLSaysTheDimensionIsNoLongerRestricted() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        // Kept openable by its apps, so the empty-workspace guard is not what is under test.
        try fixture.store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: ["https://github.com/a"])
        )
        // Premise guard, so this cannot pass vacuously: the workspace really does restrict exactly
        // one host before the edit.
        #expect(try fixture.scope().webDomains == ["github.com"])

        let assessment = try fixture.executor.assessRisk(
            plan: Fixture.editPlan(removeURLs: ["github.com"]),
            scope: .unscoped
        )

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations.map(\.reason) == [Self.urlsNoLongerRestrictedReason])
        // States the dimension, never the entry — the smaller consent the user is not being asked for.
        #expect(!Self.urlsNoLongerRestrictedReason.contains("github.com"))
        #expect(Self.urlsNoLongerRestrictedReason != Self.removedOneOfSeveralURLsReason)

        _ = try await fixture.executor.execute(plan: Fixture.editPlan(removeURLs: ["github.com"])) { _, _ in }

        let scope = try fixture.scope()
        #expect(scope.verdict(for: .webDomain("github.com")) == .unconstrained)
        #expect(scope.verdict(for: .webDomain("example.com")) == .unconstrained)
        #expect(try fixture.store.workspace(named: "Client Alpha").urls.isEmpty)
    }

    // MARK: - Consent for an entry that never restricted anything

    /// Removing an entry `WorkspaceScope` had already classified inert costs the user nothing, so it
    /// must not ask for explicit approval on a sentence asserting a loss.
    ///
    /// The emptiness question was made evaluator-aware first; the escalation *trigger* was not, and
    /// still diffed raw stored strings. Same single source of truth now: the evaluator decides what
    /// counted, and a removal of something that never counted stays at the default tier.
    @Test
    func removingOnlyAnInertEntryDoesNotEscalateAndStillRemovesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let working = try fixture.makeFolder("Working")
        let inert = "/tmp/EditWorkspaceTests-Inert-NeverRestricted"
        try fixture.store.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [working.path, inert]
            )
        )
        #expect(try fixture.scope().inertEntries.map(\.value) == [inert])

        let assessment = try fixture.executor.assessRisk(
            plan: Fixture.editPlan(removeFileLocations: [inert]),
            scope: .unscoped
        )

        #expect(assessment.effectiveTier == .tier2)
        #expect(assessment.escalations.isEmpty)

        // Enforcement is unchanged: the entry still leaves the stored list, and the dimension the
        // working entry restricts is untouched.
        _ = try await fixture.executor.execute(plan: Fixture.editPlan(removeFileLocations: [inert])) { _, _ in }
        #expect(try fixture.store.workspace(named: "Client Alpha").fileLocations == [working.path])
        #expect(try fixture.scope().verdict(for: .fileLocation(fixture.root.appendingPathComponent("Other").path))
            == .outOfScope)
    }

    /// A removal that drops one working entry *and* one inert one names only the working entry —
    /// the reason says what was lost, and nothing else.
    @Test
    func aMixedRemovalNamesOnlyTheEntryThatActuallyRestrictedSomething() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let dropped = try fixture.makeFolder("Dropped")
        let kept = try fixture.makeFolder("Kept")
        let inert = "/tmp/EditWorkspaceTests-Inert-Mixed"
        try fixture.store.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [dropped.path, kept.path, inert]
            )
        )

        let assessment = try fixture.executor.assessRisk(
            plan: Fixture.editPlan(removeFileLocations: [dropped.path, inert]),
            scope: .unscoped
        )

        // `kept` survives, so this is a one-of-several removal, and the inert entry is absent from
        // the reason even though it is absent from the stored list afterwards too.
        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations.map(\.reason) == [
            "Removes \(dropped.path) from workspace Client Alpha's file locations. "
                + "What is removed stops counting as part of this workspace."
        ])
    }

    // MARK: - Gaps closed after the adversarial review

    /// The <code>.webDomain</code> escalation branch, asserted through <code>assessRisk</code> on the
    /// literal string. Without this the URL kind could have been dropped from the escalation list
    /// entirely and every other test would still have passed, letting a URL removal run at tier 2
    /// with no approval prompt at all.
    @Test
    func removingOneOfSeveralURLsEscalatesWithTheURLFlavouredReason() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: ["https://github.com/a", "https://example.com"]
            )
        )

        let assessment = try fixture.executor.assessRisk(
            plan: Fixture.editPlan(removeURLs: ["github.com"]),
            scope: .unscoped
        )

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations.map(\.reason) == [Self.removedOneOfSeveralURLsReason])
        // The kind stays configured, so a non-matching host is still refused rather than blessed.
        #expect(try fixture.scope().verdict(for: .webDomain("github.com")) == .inScope)
    }

    /// The apps flavour of the dimension-emptied reason, and the empty-workspace guard's *other*
    /// operand — the direction where removing every app is legitimate because URLs keep the
    /// workspace openable. Every other test in this file leaves `urls` empty, so a regression that
    /// required apps to survive unconditionally would have gone unnoticed.
    @Test
    func removingTheLastAppFromAWorkspaceWithURLsSucceedsAndUnrestrictsApps() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: ["https://github.com"])
        )

        let assessment = try fixture.executor.assessRisk(
            plan: Fixture.editPlan(removeApps: ["Safari"]),
            scope: .unscoped
        )
        #expect(assessment.escalations.map(\.reason) == [
            "Workspace Client Alpha will no longer restrict apps at all: "
                + "this removes the last entry from its apps list."
        ])

        _ = try await fixture.executor.execute(plan: Fixture.editPlan(removeApps: ["Safari"])) { _, _ in }

        let stored = try fixture.store.workspace(named: "Client Alpha")
        #expect(stored.apps.isEmpty)
        #expect(stored.urls == ["https://github.com"])
        #expect(try fixture.scope().verdict(for: .app("Safari")) == .unconstrained)
    }

    /// **The emptiness question is the evaluator's, not a string count.**
    ///
    /// `WorkspaceScope` drops an entry it cannot match into `inertEntries` and leaves it out of the
    /// canonical lists `verdict(for:)` checks, so a kind whose surviving entries are all inert is
    /// `.unconstrained` however many strings remain on disk. Removing the last *working* file
    /// location while an inert one survives therefore empties the dimension in every way the user
    /// experiences it — and a raw `after.isEmpty` check, which is what this shipped with first, says
    /// it did not and hands the approver the milder consent.
    @Test
    func removingTheLastWorkingFileLocationEmptiesTheKindEvenWhenAnInertOneSurvives() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let working = try fixture.makeFolder("Working")
        // Outside the test whitelist root, so `WorkspaceScope` records it inert and it never reaches
        // `fileRoots`. Written straight to the store: the adapter itself refuses to *add* one.
        let inert = "/tmp/EditWorkspaceTests-Inert"
        try fixture.store.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [working.path, inert]
            )
        )
        // Premise guard, so this cannot pass vacuously: the stored workspace really does restrict
        // exactly one folder before the edit.
        #expect(try fixture.scope().fileRoots.count == 1)

        let assessment = try fixture.executor.assessRisk(
            plan: Fixture.editPlan(removeFileLocations: [working.path]),
            scope: .unscoped
        )

        #expect(assessment.escalations.map(\.reason) == [Self.fileLocationsNoLongerRestrictedReason])

        _ = try await fixture.executor.execute(
            plan: Fixture.editPlan(removeFileLocations: [working.path])
        ) { _, _ in }

        // The inert entry is still on disk — it was never named — and the dimension is nonetheless
        // unconstrained, which is exactly what the prompt said.
        let stored = try fixture.store.workspace(named: "Client Alpha")
        #expect(stored.fileLocations == [inert])
        #expect(try fixture.scope().verdict(for: .fileLocation(working.path)) == .unconstrained)
    }

    /// Scheme and host are case-insensitive and a bare trailing slash is not a different page, so
    /// none of these is a second entry. `absoluteString` alone says all three are.
    @Test
    func addingACaseOrTrailingSlashVariantOfAStoredURLDoesNotDuplicateIt() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: ["https://github.com/a"])
        )

        _ = try await fixture.executor.execute(
            plan: Fixture.editPlan(addURLs: ["HTTPS://GitHub.com/a", "https://github.com/a"])
        ) { _, _ in }
        _ = try await fixture.executor.execute(
            plan: Fixture.editPlan(addURLs: ["https://example.com", "https://example.com/"])
        ) { _, _ in }

        #expect(try fixture.store.workspace(named: "Client Alpha").urls
            == ["https://github.com/a", "https://example.com"])
    }

    /// The same dedup path as apps and URLs, on the kind whose identity goes through
    /// `PathWhitelist.canonicalURL` — so a trailing slash is not a second folder either.
    @Test
    func addingAFileLocationTheWorkspaceAlreadyHoldsDoesNotDuplicateIt() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let folder = try fixture.makeFolder("ClientAlpha")
        try fixture.store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], fileLocations: [folder.path])
        )

        _ = try await fixture.executor.execute(
            plan: Fixture.editPlan(addFileLocations: [folder.path, folder.path + "/"])
        ) { _, _ in }

        #expect(try fixture.store.workspace(named: "Client Alpha").fileLocations == [folder.path])
    }

    /// A blank entry is inert to `WorkspaceScope` — a boundary that quietly does nothing — so both
    /// kinds that can carry one reject it rather than storing it.
    @Test
    func blankAppNamesAndBlankPathsAreRejectedAndNothingIsSaved() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))

        await #expect(throws: MacAppCatalogError.missingAppName) {
            _ = try await fixture.executor.execute(
                plan: Fixture.editPlan(addApps: ["Notes", "   "])
            ) { _, _ in }
        }
        await #expect(throws: PathValidationError.pathIsEmpty) {
            _ = try await fixture.executor.execute(
                plan: Fixture.editPlan(addFileLocations: ["   "])
            ) { _, _ in }
        }

        let stored = try fixture.store.workspace(named: "Client Alpha")
        #expect(stored.apps == ["Safari"])
        #expect(stored.fileLocations == nil)
    }

    /// Two edits of one workspace are each assessed against the same pre-execution store while
    /// executing against each other's writes, so two "one of several" consents can between them
    /// empty a dimension with neither saying so. `AgentRunner` gates once by design and
    /// `executeChain` never re-gates, so the plan shape is refused rather than the gate rebuilt.
    ///
    /// Three shapes, because the first version of this guard passed the first and failed the other
    /// two. `workflow(in:)` is an order-independent `Set`, so any second distinct operation anywhere
    /// sends the plan down `.chain` and every edit step arrives in a segment of its own —
    /// **adjacency is irrelevant**, and a per-segment count can never see what it needs to reject.
    @Test(arguments: [
        ("pure pair", false, false),
        ("pair plus a third operation, edits adjacent", true, false),
        ("pair with the third operation between them", true, true)
    ])
    func everyPlanShapeEditingOneWorkspaceTwiceIsRefused(
        shape: (name: String, includesThirdOperation: Bool, thirdOperationBetween: Bool)
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let first = try fixture.makeFolder("First")
        let second = try fixture.makeFolder("Second")
        try fixture.store.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [first.path, second.path]
            )
        )
        let openApp = AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")
        var steps = [Fixture.editPlan(removeFileLocations: [first.path]).steps[0]]
        if shape.includesThirdOperation, shape.thirdOperationBetween {
            steps.append(openApp)
        }
        steps.append(Fixture.editStep(id: "edit-workspace-2", removeFileLocations: [second.path]))
        if shape.includesThirdOperation, !shape.thirdOperationBetween {
            steps.append(openApp)
        }
        let plan = AgentPlan(summary: "Edit workspace twice.", requiresConfirmation: true, steps: steps)
        let expected = AgentExecutionError.invalidPlan(
            "A plan may edit workspace Client Alpha only once. "
                + "Put every change to one workspace in a single edit_workspace step."
        )

        #expect(throws: expected, "\(shape.name)") {
            _ = try fixture.executor.assessRisk(plan: plan, scope: .unscoped)
        }
        await #expect(throws: expected, "\(shape.name)") {
            _ = try await fixture.executor.execute(plan: plan) { _, _ in }
        }
        #expect(try fixture.store.workspace(named: "Client Alpha").fileLocations == [first.path, second.path])
    }

    /// The same guard must **not** fire across two workspaces, and refusing them was its own defect:
    /// `AgentStep.workspaceName` is a single `String?`, so "add Notes to Work and remove Slack from
    /// Research" cannot be put in one step, and the old message told the user to do the impossible.
    ///
    /// The hazard the guard exists for is entirely between two edits of *one* workspace — two
    /// workspaces share no stored record, so each assessment is correct in isolation, which is what
    /// the per-step escalations here assert.
    @Test
    func aPlanEditingTwoDifferentWorkspacesProceedsAndAssessesEachCorrectly() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))
        try fixture.store.save(StoredWorkspace(name: "Research", apps: ["Safari", "Slack"], urls: []))
        let plan = AgentPlan(
            summary: "Edit two workspaces.",
            requiresConfirmation: true,
            steps: [
                Fixture.editStep(id: "edit-1", workspaceName: "Client Alpha", addApps: ["Notes"]),
                Fixture.editStep(id: "edit-2", workspaceName: "Research", removeApps: ["Slack"])
            ]
        )

        // One escalation, from the removal half only — the addition half is correctly silent, which
        // is what "each assessment is correct in isolation" means here.
        let assessment = try fixture.executor.assessRisk(plan: plan, scope: .unscoped)
        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations.map(\.reason) == [
            "Removes Slack from workspace Research's apps. "
                + "What is removed stops counting as part of this workspace."
        ])

        _ = try await fixture.executor.execute(plan: plan) { _, _ in }

        #expect(try fixture.store.workspace(named: "Client Alpha").apps == ["Safari", "Notes"])
        #expect(try fixture.store.workspace(named: "Research").apps == ["Safari"])
    }

    /// Case- and diacritic-folded, because that is what `WorkspaceStore` keys on: two steps naming
    /// one workspace in two spellings are two edits of the same record on disk.
    @Test
    func twoEditStepsNamingTheSameWorkspaceInDifferentCasingAreStillRefused() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari", "Notes"], urls: []))
        let plan = AgentPlan(
            summary: "Edit workspace twice.",
            requiresConfirmation: true,
            steps: [
                Fixture.editStep(id: "edit-1", workspaceName: "Client Alpha", removeApps: ["Notes"]),
                Fixture.editStep(id: "edit-2", workspaceName: "client alpha", addApps: ["Mail"])
            ]
        )

        // Named with the spelling of the step that collided, not the stored display name: this rule
        // runs before any store load, and a resolve hook that read the store to prettify an error
        // would be doing I/O for copy.
        #expect(throws: AgentExecutionError.invalidPlan(
            "A plan may edit workspace client alpha only once. "
                + "Put every change to one workspace in a single edit_workspace step."
        )) {
            _ = try fixture.executor.assessRisk(plan: plan, scope: .unscoped)
        }
    }

    /// The approval panel's "Undo:" line. A tier-2 edit is the *common* case — adding never
    /// escalates — and it fell through to "Delete generated local files manually if needed.", which
    /// is wrong for an action that generates no files.
    @Test
    func aTierTwoEditShowsTheWorkspaceUndoCopyRatherThanTheGeneratedFilesDefault() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))

        let assessment = try fixture.executor.assessRisk(
            plan: Fixture.editPlan(addApps: ["Notes"]),
            scope: .unscoped
        )

        #expect(assessment.effectiveTier == .tier2)
        #expect(assessment.approvalCopy?.undoDescription == "Edit or replace the saved routine/workspace manually.")
        #expect(assessment.approvalCopy?.involvedResource == "Workspace: Client Alpha")
        // An edit writes one file inside Sonny's own store and opens none of what it declares.
        #expect(assessment.approvalCopy?.dataLeavesDevice == false)
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

        static func editStep(
            id: String,
            workspaceName: String = "Client Alpha",
            addApps: [String]? = nil,
            addURLs: [String]? = nil,
            addFileLocations: [String]? = nil,
            removeApps: [String]? = nil,
            removeURLs: [String]? = nil,
            removeFileLocations: [String]? = nil
        ) -> AgentStep {
            AgentStep(
                id: id,
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

/// SONNY-44's decoupling decision is "normalize on save plus a soft warning at creation/**edit**
/// time", and its written note to SONNY-40 asked the edit path to read the behaviours from
/// `WorkspaceScopeOnlyApps` rather than re-derive them. Create and open both disclosed; edit shipped
/// without it, so the same addition told the user two different things depending on which door it
/// came through.
@Suite
@MainActor
struct EditWorkspaceScopeOnlyDisclosureTests {
    @Test
    func addingAnAppSonnyCannotLaunchCarriesTheScopeOnlyNoteInBothPreviewAndSummary() async throws {
        let fixture = try ScopeOnlyFixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))
        let plan = ScopeOnlyFixture.addAppsPlan(["Microsoft Word"])

        let previews = try fixture.executor.preview(plan: plan)
        let result = try await fixture.executor.execute(plan: plan) { _, _ in }

        // The exact wording the create path emits, from the one shared builder — asserted against
        // that builder's own output so the two doors cannot drift to different sentences.
        let expected = try #require(WorkspaceScopeOnlyApps.scopeOnlyNote(for: ["Microsoft Word"]))
        #expect(expected == "Microsoft Word isn't an app Sonny can launch — counted for workspace scope only.")
        #expect(previews.first?.details.contains(expected) == true)
        #expect(result.summary.contains(expected))
        // The app is still a real scope member — this is disclosure, never refusal.
        #expect(try fixture.store.workspace(named: "Client Alpha").apps == ["Safari", "Microsoft Word"])
    }

    @Test
    func addingAnAppSonnyCanLaunchCarriesNoNote() async throws {
        let fixture = try ScopeOnlyFixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))
        let plan = ScopeOnlyFixture.addAppsPlan(["Notes"])

        let previews = try fixture.executor.preview(plan: plan)
        let result = try await fixture.executor.execute(plan: plan) { _, _ in }

        #expect(previews.first?.details.allSatisfy { !$0.contains("scope only") } == true)
        #expect(!result.summary.contains("scope only"))
    }

    /// An add that changes nothing discloses nothing: the note is computed over what the edit
    /// actually added, not over what the step asked for.
    @Test
    func reAddingAnAppTheWorkspaceAlreadyListsCarriesNoNote() async throws {
        let fixture = try ScopeOnlyFixture()
        defer { fixture.tearDown() }
        try fixture.store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari", "Microsoft Word"], urls: [])
        )

        let result = try await fixture.executor.execute(
            plan: ScopeOnlyFixture.addAppsPlan(["Microsoft Word"])
        ) { _, _ in }

        #expect(!result.summary.contains("scope only"))
    }

    @MainActor
    private struct ScopeOnlyFixture {
        let root: URL
        let store: WorkspaceStore
        let executor: AgentActionExecutor

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("EditScopeOnlyTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
            executor = AgentActionExecutor(
                whitelist: PathWhitelist(roots: [root]),
                appOpener: ScopeOnlyNoopAppOpener(),
                fileOpener: ScopeOnlyNoopFileOpener(),
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

        static func addAppsPlan(_ apps: [String]) -> AgentPlan {
            AgentPlan(
                summary: "Edit workspace.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(
                        id: "edit-workspace",
                        operation: .editWorkspace,
                        description: "Edit workspace.",
                        workspaceName: "Client Alpha",
                        workspaceApps: apps
                    )
                ]
            )
        }
    }
}

private struct ScopeOnlyNoopAppOpener: AppOpening {
    func open(bundleIdentifier: String) async throws {}
}

private struct ScopeOnlyNoopFileOpener: FileOpening {
    func openFile(_ url: URL) async throws {}
}
