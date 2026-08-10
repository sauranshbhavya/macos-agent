import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-64's core half: the exact plan a screen builds, and the origin stamped on the run that
/// carries it.
///
/// The two things under test are the two things that could quietly go wrong. A plan factory that
/// puts a value in the wrong field produces an edit nobody asked for while every downstream test
/// still passes, because downstream only sees the plan. And an origin that a planner could set
/// would be a trust signal worth nothing on exactly the day it starts being trusted — which is a
/// later ticket, so nothing would notice today.
@Suite
@MainActor
struct PrebuiltPlanDispatchTests {
    // MARK: - The plan a screen builds

    /// Each of the six (dimension, direction) pairs lands in its own field, and in **no other**.
    ///
    /// Asserted as "this field holds the value and the other five are nil" rather than just checking
    /// the one field, because the failure worth catching is not an empty field — it is a value
    /// arriving in a second one. `workspaceApps: ["X"], workspaceAppsToRemove: ["X"]` is a
    /// well-formed plan that the capability happily executes as a no-op, so a stray write would
    /// produce a green run, an honest-looking summary, and no edit at all.
    @Test(arguments: [
        (ScopedResourceKind.app, WorkspaceScopeEditRequest.Action.add),
        (.app, .remove),
        (.webDomain, .add),
        (.webDomain, .remove),
        (.fileLocation, .add),
        (.fileLocation, .remove)
    ])
    func eachEditKindAndDirectionLandsInItsOwnFieldAndNoOther(
        kind: ScopedResourceKind,
        action: WorkspaceScopeEditRequest.Action
    ) {
        let plan = EditWorkspaceCapabilityAdapter.plan(
            for: WorkspaceScopeEditRequest(
                workspaceName: "Client Alpha",
                kind: kind,
                value: "VALUE",
                action: action
            )
        )

        #expect(plan.steps.count == 1)
        let step = try! #require(plan.steps.first)
        #expect(step.operation == .editWorkspace)
        #expect(step.workspaceName == "Client Alpha")

        let fields: [(ScopedResourceKind, WorkspaceScopeEditRequest.Action, [String]?)] = [
            (.app, .add, step.workspaceApps),
            (.app, .remove, step.workspaceAppsToRemove),
            (.webDomain, .add, step.workspaceURLs),
            (.webDomain, .remove, step.workspaceURLsToRemove),
            (.fileLocation, .add, step.workspaceFileLocations),
            (.fileLocation, .remove, step.workspaceFileLocationsToRemove)
        ]
        for (fieldKind, fieldAction, value) in fields {
            if fieldKind == kind && fieldAction == action {
                #expect(value == ["VALUE"])
            } else {
                #expect(value == nil)
            }
        }
    }

    /// The summary is the sentence the log and the history label read back, and it says which
    /// direction the edit goes. An add and a remove reading the same would make the one line a user
    /// sees about a boundary change useless for telling the two apart.
    @Test
    func theSummaryStatesTheDirectionOfTheChange() {
        let add = EditWorkspaceCapabilityAdapter.plan(
            for: WorkspaceScopeEditRequest(
                workspaceName: "Client Alpha",
                kind: .app,
                value: "Slack",
                action: .add
            )
        )
        let remove = EditWorkspaceCapabilityAdapter.plan(
            for: WorkspaceScopeEditRequest(
                workspaceName: "Client Alpha",
                kind: .app,
                value: "Slack",
                action: .remove
            )
        )

        #expect(add.summary == "Add Slack to workspace Client Alpha.")
        #expect(remove.summary == "Remove Slack from workspace Client Alpha.")
        #expect(add.steps.first?.description == add.summary)
        #expect(remove.steps.first?.description == remove.summary)
    }

    /// A screen-built plan reaches the gate carrying **no** claim about how it should be judged.
    ///
    /// This is the property that makes a pre-built plan safe to allow at all: the tier, the
    /// escalation and its reason are computed downstream from the plan and the store, and there is
    /// no field on the plan through which a caller could pre-empt any of it. Pinned by running the
    /// real assessment over a screen-built removal and getting the capability's own tier-3 reason
    /// back, verbatim.
    @Test
    func aScreenBuiltRemovalIsAssessedByTheCapabilityExactlyAsATypedOneIs() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari", "Notes"], urls: [])
        )

        let plan = EditWorkspaceCapabilityAdapter.plan(
            for: WorkspaceScopeEditRequest(
                workspaceName: "Client Alpha",
                kind: .app,
                value: "Notes",
                action: .remove
            )
        )
        let runner = AgentRunner(planner: UnusedPlanner(), executor: fixture.executor)
        let prepared = try runner.prepare(plan: plan, source: .directUserAction)
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped)

        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.assessment.escalations.map(\.reason) == [
            "Removes Notes from workspace Client Alpha's apps. "
                + "What is removed stops counting as part of this workspace."
        ])
        // Nothing was written by assessing it.
        #expect(try fixture.store.workspace(named: "Client Alpha").apps == ["Safari", "Notes"])
    }

    /// The same edit, when it takes the last entry of a dimension, still raises the *other* consent.
    ///
    /// Both tier-3 reasons have to be reachable through the pre-built path, not just the one a
    /// single fixture happens to produce — the distinction between "you are losing this entry" and
    /// "this dimension stops restricting anything" is the whole reason SONNY-40 built two.
    @Test
    func aScreenBuiltRemovalThatEmptiesADimensionRaisesTheEmptyingConsent() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [fixture.insideWhitelist]
            )
        )

        let plan = EditWorkspaceCapabilityAdapter.plan(
            for: WorkspaceScopeEditRequest(
                workspaceName: "Client Alpha",
                kind: .fileLocation,
                value: fixture.insideWhitelist,
                action: .remove
            )
        )
        let runner = AgentRunner(planner: UnusedPlanner(), executor: fixture.executor)
        let prepared = try runner.prepare(plan: plan, source: .directUserAction)
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped)

        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.assessment.escalations.map(\.reason) == [
            "Workspace Client Alpha will no longer restrict file locations at all: "
                + "this removes the last entry from its file locations list."
        ])
    }

    /// An addition stays tier 2 through this path, exactly as it does when typed — the
    /// one-directional escalation rule is the capability's and the dispatch path does not touch it.
    @Test
    func aScreenBuiltAdditionStaysAtTheTierTwoConfirmation() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))

        let plan = EditWorkspaceCapabilityAdapter.plan(
            for: WorkspaceScopeEditRequest(
                workspaceName: "Client Alpha",
                kind: .app,
                value: "Slack",
                action: .add
            )
        )
        let runner = AgentRunner(planner: UnusedPlanner(), executor: fixture.executor)
        let request = try runner.approvalRequest(
            for: try runner.prepare(plan: plan, source: .directUserAction),
            scope: .unscoped
        )

        #expect(request.assessment.effectiveTier == .tier2)
        #expect(request.requirement == .lightweightConfirmation)
        #expect(request.assessment.escalations.isEmpty)
    }

    /// **The fourth consent shape: removing an entry that never restricted anything does not
    /// escalate at all.**
    ///
    /// Its three siblings above cover the tier-2 addition and both tier-3 removals; this one had
    /// coverage on the typed path only (`EditWorkspaceTests`), so the branch met its own
    /// one-test-per-shape bar for three of four. It is the shape most worth having here, because the
    /// inert entry is exactly what the sheet used to get wrong: an entry `WorkspaceScope` has
    /// already dropped costs the user nothing to remove, so asking for explicit approval on a
    /// sentence asserting a loss would be an over-claim — and the *disclosure* about which rows
    /// leave with it is what SONNY-41's R-1 was.
    ///
    /// A second, live location survives the edit, so the dimension is not emptied and the
    /// emptying consent is not what is being tested here. (PR #40 review, F6.)
    @Test
    func aScreenBuiltRemovalOfAnAlreadyInertEntryDoesNotEscalate() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.store.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                // The first is outside the whitelist, so the evaluator classifies it inert; the
                // second is inside it and keeps the dimension restricting.
                fileLocations: ["~/Downloads/Alpha", fixture.insideWhitelist]
            )
        )

        let plan = EditWorkspaceCapabilityAdapter.plan(
            for: WorkspaceScopeEditRequest(
                workspaceName: "Client Alpha",
                kind: .fileLocation,
                value: "~/Downloads/Alpha",
                action: .remove
            )
        )
        let runner = AgentRunner(planner: UnusedPlanner(), executor: fixture.executor)
        let prepared = try runner.prepare(plan: plan, source: .directUserAction)
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped)

        // Tier 2, not 3, and no escalation reason naming a loss that did not happen.
        #expect(request.assessment.effectiveTier == .tier2)
        #expect(request.requirement == .lightweightConfirmation)
        #expect(request.assessment.escalations.isEmpty)
    }

    // MARK: - The origin, and why a planner cannot claim it

    /// `prepare(plan:source:)` stamps what the caller says; `prepare(command:)` stamps `.planner`
    /// and takes no source at all.
    @Test
    func prepareStampsTheSourceAndTheTypedPathCanOnlyEverBePlanner() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let plan = openSafariPlan()

        let direct = try AgentRunner(planner: UnusedPlanner(), executor: fixture.executor)
            .prepare(plan: plan, source: .directUserAction)
        #expect(direct.source == .directUserAction)

        let resolver = try AgentRunner(planner: UnusedPlanner(), executor: fixture.executor)
            .prepare(plan: plan)
        #expect(resolver.source == .instantResolver)

        let typed = try await AgentRunner(planner: StubPlanner(plan: plan), executor: fixture.executor)
            .prepare(command: "Open Safari")
        #expect(typed.source == .planner)
    }

    /// **A planner cannot name its own origin, and the reason is that there is nothing to name it
    /// with.**
    ///
    /// The payload here is hostile on purpose: it carries `source` and `origin` keys at both the
    /// plan and the step level, spelling the privileged value exactly as the enum does. `AgentPlan`
    /// decodes without them because it has no such properties, and `prepare(command:)` then stamps
    /// `.planner` over the top regardless. Written as a decode-then-prepare round trip rather than
    /// as an assertion about the type's fields, because "this struct has no source property" is a
    /// fact a future field would silently invalidate while a shape test kept passing.
    @Test
    func aPlannerPayloadClaimingADirectUserActionOriginStillPreparesAsPlanner() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let payload = """
        {
          "summary": "Open Safari.",
          "requiresConfirmation": false,
          "source": "direct_user_action",
          "origin": "direct_user_action",
          "steps": [
            {
              "id": "s1",
              "operation": "open_app",
              "description": "Open Safari.",
              "appName": "Safari",
              "source": "direct_user_action"
            }
          ]
        }
        """
        let claimed = try JSONDecoder().decode(AgentPlan.self, from: Data(payload.utf8))
        let prepared = try await AgentRunner(
            planner: StubPlanner(plan: claimed),
            executor: fixture.executor
        ).prepare(command: "Open Safari")

        #expect(prepared.source == .planner)
    }

    /// A run built without saying anything about its origin is treated as the least-trusted kind.
    ///
    /// The default matters more than it looks: a construction site added later that forgets to pass
    /// a source inherits `.planner`, so the mistake costs a *missing* trust signal rather than a
    /// granted one. Mutating this default to `.directUserAction` is the change this pins.
    @Test
    func aPreparedRunDefaultsToTheLeastTrustedOrigin() {
        let run = PreparedAgentRun(plan: openSafariPlan(), previews: [])
        #expect(run.source == .planner)
    }

    // MARK: - Removal units, asked of the code that performs the removal

    /// Two URLs on one host are one removal unit; a different host is its own.
    @Test
    func urlRemovalUnitsGroupByHost() {
        let values = ["https://github.com/acme", "https://github.com/other", "https://example.org/x"]
        let units = EditWorkspaceCapabilityAdapter.removalUnits(kind: .webDomain, values: values)

        #expect(units[0] == ["https://github.com/other"])
        #expect(units[1] == ["https://github.com/acme"])
        #expect(units[2] == [])
    }

    /// An alias and its display name are one app, because that is what the catalog says.
    @Test
    func appRemovalUnitsGroupByCatalogKey() {
        let units = EditWorkspaceCapabilityAdapter.removalUnits(
            kind: .app,
            values: ["Chrome", "Google Chrome", "Safari"]
        )

        #expect(units[0] == ["Google Chrome"])
        #expect(units[1] == ["Chrome"])
        #expect(units[2] == [])
    }

    /// **SONNY-41's R-1, fixed: entries the evaluator considers inert are grouped too.**
    ///
    /// Both paths here are outside any whitelist, so `WorkspaceScope` drops them and a scope built
    /// from either one alone answers `.unconstrained` to everything — which is why the sheet's old
    /// symmetric-verdict probe could never group them, and why its Remove button promised to take
    /// one row and took two. They canonicalize to one path, so the capability removes them together.
    /// This is asked of the capability's own key function, so the two answers cannot drift again.
    @Test
    func inertFileLocationsThatCanonicalizeToOnePathAreOneRemovalUnit() {
        let units = EditWorkspaceCapabilityAdapter.removalUnits(
            kind: .fileLocation,
            values: ["~/Downloads/Alpha", "~/Downloads/Alpha/", "~/Downloads/Beta"]
        )

        #expect(units[0] == ["~/Downloads/Alpha/"])
        #expect(units[1] == ["~/Downloads/Alpha"])
        #expect(units[2] == [])
    }

    /// A parent folder and one inside it are **not** one unit — removal matching is equality of the
    /// canonical path, never the containment `verdict(for:)` uses. Grouping them would tell the user
    /// that removing `~/Documents` also removes `~/Documents/ClientAlpha`, which it does not.
    @Test
    func aParentFolderAndAFolderInsideItAreSeparateRemovalUnits() {
        let units = EditWorkspaceCapabilityAdapter.removalUnits(
            kind: .fileLocation,
            values: ["~/Documents", "~/Documents/ClientAlpha"]
        )

        #expect(units == [[], []])
    }

    /// An entry with no removal key takes nothing with it — a removal request can never name it, so
    /// reporting a shared removal would claim a deletion that cannot happen. A blank app name is the
    /// one entry that reaches that state.
    @Test
    func anEntryWithNoRemovalKeyIsGroupedWithNothing() {
        let units = EditWorkspaceCapabilityAdapter.removalUnits(kind: .app, values: ["", "", "Safari"])

        #expect(units == [[], [], []])
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let root: URL
        let store: WorkspaceStore
        let executor: AgentActionExecutor
        let insideWhitelist: String

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PrebuiltPlanDispatchTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let documents = root.appendingPathComponent("Documents", isDirectory: true)
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            insideWhitelist = documents.appendingPathComponent("ClientAlpha").path
            store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
            executor = AgentActionExecutor(
                whitelist: PathWhitelist(roots: [documents]),
                appOpener: UnusedAppOpener(),
                fileOpener: UnusedFileOpener(),
                routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
                workspaceStore: store,
                shortcutCatalog: UnusedShortcutCatalog(),
                shortcutRunHistoryStore: ShortcutRunHistoryStore(
                    fileURL: root.appendingPathComponent("shortcuts-history.json")
                )
            )
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func openSafariPlan() -> AgentPlan {
        AgentPlan(
            summary: "Open Safari.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "s1", operation: .openApp, description: "Open Safari.", appName: "Safari")
            ]
        )
    }
}

/// Never called: every test here either prepares a plan directly or hands `StubPlanner` the plan.
private struct UnusedPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        Issue.record("The planner must not be consulted for a pre-built plan.")
        throw AgentExecutionError.invalidPlan("planner should not be called")
    }
}

private struct StubPlanner: Planning {
    let plan: AgentPlan

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        plan
    }
}

/// Replaced rather than defaulted: nothing in this suite opens anything, and the executor's
/// production defaults are the real openers — one typo away from driving the developer's machine.
private struct UnusedAppOpener: AppOpening {
    func open(bundleIdentifier: String) async throws {
        Issue.record("No test here opens an app.")
    }
}

private struct UnusedFileOpener: FileOpening {
    func openFile(_ url: URL) async throws {
        Issue.record("No test here opens a file.")
    }
}

private struct UnusedShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}
