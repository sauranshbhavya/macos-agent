import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

@Suite
@MainActor
struct AgentViewModelLocalStorageTests {
    @Test
    func missingLocalStoreFilesRemainSilentFirstRunState() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x42))

        viewModel.refreshSavedItems()
        viewModel.refreshTaskHistory()
        viewModel.refreshClipboardHistoryNotice()

        #expect(viewModel.savedRoutines.isEmpty)
        #expect(viewModel.savedWorkspaces.isEmpty)
        #expect(viewModel.taskHistoryRecords.isEmpty)
        #expect(viewModel.clipboardHistoryEnabled)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.localStorageNotice == nil)
    }

    @Test
    func savedItemsDecryptFailureSurfacesVisibleErrorInsteadOfSilentEmptyState() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineURL = root.appendingPathComponent("routines.json")
        let workspaceURL = root.appendingPathComponent("workspaces.json")
        try RoutineStore(fileURL: routineURL, encryption: testEncryption(byte: 0x42)).save(
            StoredRoutine(
                name: "Encrypted Morning",
                steps: [
                    AgentStep(
                        id: "open",
                        operation: .openApp,
                        description: "Open Safari.",
                        appName: "Safari"
                    )
                ]
            )
        )
        try WorkspaceStore(fileURL: workspaceURL, encryption: testEncryption(byte: 0x42)).save(
            StoredWorkspace(name: "Encrypted Research", apps: ["Safari"], urls: ["https://example.com"])
        )
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        viewModel.refreshSavedItems()

        let message = try #require(viewModel.localStorageNotice)
        #expect(message.contains("Sonny could not load encrypted local data"))
        #expect(message.contains("A local data file exists but could not be decrypted or decoded"))
        #expect(message.contains("saved routines"))
        #expect(message.contains("saved workspaces"))
        #expect(viewModel.savedRoutines.isEmpty)
        #expect(viewModel.savedWorkspaces.isEmpty)
    }

    @Test
    func clipboardSettingsDecryptFailureSurfacesVisibleError() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent("clipboard-history-settings.json")
        try ClipboardHistorySettingsStore(fileURL: settingsURL, encryption: testEncryption(byte: 0x42))
            .save(ClipboardHistorySettings(noticeDismissed: true, isEnabled: true))
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        viewModel.refreshClipboardHistoryNotice()

        let message = try #require(viewModel.localStorageNotice)
        #expect(message.contains("Sonny could not load encrypted local data"))
        #expect(message.contains("clipboard history settings"))
    }

    @Test
    func taskHistoryDecryptFailureSurfacesVisibleErrorInsteadOfSilentEmptyState() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskHistoryURL = root.appendingPathComponent("task-history.json")
        try TaskHistoryStore(fileURL: taskHistoryURL, encryption: testEncryption(byte: 0x42))
            .record(
                CompletedTaskRecord(
                    command: "Encrypted task",
                    startedAt: .fixture,
                    completedAt: Date(timeInterval: 5, since: .fixture),
                    outcomeStatus: .completed
                )
            )
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        viewModel.refreshTaskHistory()

        let message = try #require(viewModel.localStorageNotice)
        #expect(message.contains("Sonny could not load encrypted local data"))
        #expect(message.contains("task history"))
        #expect(viewModel.taskHistoryRecords.isEmpty)
    }

    /// The shipped bug this branch fixes: `refreshSavedItems()` runs after every successful task,
    /// so a corrupt store unrelated to that task used to overwrite `errorMessage` and make the
    /// widget render `.failure` instead of the real result.
    @Test
    func corruptStoreDoesNotMakeASuccessfulTaskLookLikeAFailure() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try RoutineStore(
            fileURL: root.appendingPathComponent("routines.json"),
            encryption: testEncryption(byte: 0x42)
        ).save(StoredRoutine(name: "Unreadable", steps: [
            AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")
        ]))
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        viewModel.command = "= 1 + 1"
        viewModel.start()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // The task itself succeeded and its result is intact...
        #expect(viewModel.finalSummary.contains("2"))
        #expect(viewModel.errorMessage == nil)
        // ...while the unrelated storage problem is reported on its own channel.
        let notice = try #require(viewModel.localStorageNotice)
        #expect(notice.contains("saved routines"))
    }

    @Test
    func silentlyReadStoresReportCorruptionThatWouldOtherwiseBeInvisible() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try SnippetStore(
            fileURL: root.appendingPathComponent("snippets.json"),
            encryption: testEncryption(byte: 0x42)
        ).save(StoredSnippet(trigger: ";sig", expansion: "Best,\nSonny"))
        // `record` no-ops unless the artifact really exists on disk, so create it first —
        // otherwise nothing is written and there is no corrupt store to detect.
        let artifactURL = root.appendingPathComponent("note.md")
        try Data("note".utf8).write(to: artifactURL)
        try RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json"),
            encryption: testEncryption(byte: 0x42)
        ).record(path: artifactURL.path, recordedAt: .fixture)
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        viewModel.refreshSavedItems()

        // Snippets and recent artifacts are otherwise only read through `try?` paths, so without
        // this probe a corrupt file just silently stops those features working.
        let notice = try #require(viewModel.localStorageNotice)
        #expect(notice.contains("snippets"))
        #expect(notice.contains("recent artifacts"))
    }

    /// **Row J's grants are the sharpest case of the same problem** (SONNY-140). The store has no
    /// list of its own until the revocation surface lands, and nothing in the product reads it
    /// through a path that can complain — so an unreadable file would present as Sonny asking about
    /// apps the user already allowed, which reads as the feature working badly rather than as a
    /// file that will not open. The probe is the only place it can say so.
    ///
    /// Asserted on the literal wording, because the distinction the banner has to keep is a wording
    /// distinction: this is the *load* sentence, and a save failure must never borrow it.
    @Test
    func anUnreadableApprovedAppsStoreSaysSoInsteadOfSilentlyLosingEveryGrant() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try ApprovedAppStore(
            fileURL: root.appendingPathComponent("approved-apps.json"),
            encryption: testEncryption(byte: 0x42)
        ).approve(bundleIdentifier: "com.apple.Notes", displayName: "Notes")
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        viewModel.refreshSavedItems()

        let notice = try #require(viewModel.localStorageNotice)
        #expect(notice.hasPrefix("Sonny could not load encrypted local data."))
        #expect(notice.contains("allowed apps: A local data file exists but could not be decrypted or decoded."))
        // A load failure is a storage notice, never the task error — `errorMessage` means "the task
        // you just ran failed".
        #expect(viewModel.errorMessage == nil)
    }

    /// The other half of the pair: a readable store is silent. Without this, the test above would
    /// pass against a view model that shouted about the grants store unconditionally.
    @Test
    func aReadableApprovedAppsStoreProducesNoNotice() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption(byte: 0x42)
        try ApprovedAppStore(
            fileURL: root.appendingPathComponent("approved-apps.json"),
            encryption: encryption
        ).approve(bundleIdentifier: "com.apple.Notes", displayName: "Notes")
        let viewModel = try makeViewModel(root: root, encryption: encryption)

        viewModel.refreshSavedItems()

        #expect(viewModel.localStorageNotice == nil)
    }

    /// The pin that was missing when the banner started repeating itself (PR #41 cycle-3, R4).
    ///
    /// Every other assertion on this banner uses `contains`, which passes whether the explanation
    /// appears once or twice — so when SONNY-30 gave store load errors the same sentence the headline
    /// hardcoded, nothing went red and the per-source detail quietly degraded into a repeat of the
    /// line above it. Counting the occurrence is what `contains` cannot do.
    ///
    /// Asserted alongside the distinguishing content rather than instead of it: a banner that dropped
    /// the explanation entirely would also count one, and that would be a worse notice, not a better
    /// one.
    ///
    /// **One** corrupt store, deliberately. The duplication was headline-against-detail, so it is
    /// only visible at one affected store — with two, the explanation legitimately appears twice,
    /// once per store, and a count assertion would be pinning the store count instead of the defect.
    @Test
    func theLoadFailureBannerExplainsItselfOnceAndStillNamesTheAffectedStore() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try RoutineStore(
            fileURL: root.appendingPathComponent("routines.json"),
            encryption: testEncryption(byte: 0x42)
        ).save(StoredRoutine(name: "Unreadable", steps: [
            AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")
        ]))
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        viewModel.refreshSavedItems()

        let notice = try #require(viewModel.localStorageNotice)
        let explanation = "A local data file exists but could not be decrypted or decoded."
        #expect(notice.components(separatedBy: explanation).count - 1 == 1)
        // The trailing sentence is SONNY-239's: the banner names the control that repairs this,
        // rather than stopping at an accurate description the reader can do nothing with. It is
        // appended only when an unreadable store has a Memory row to act from — saved routines has
        // one — and it carries no second copy of the explanation, which is what this test counts.
        #expect(
            notice == "Sonny could not load encrypted local data. saved routines: \(explanation)"
                + " Open Memory in Command Center to clear it."
        )
    }

    // MARK: - SONNY-78: a corrupt workspace store is not an unbound task

    /// **The defect.** `resolveTaskScope` read the bound workspace with `try? workspaceStore.workspace(named:)`,
    /// which throws for absence *and* rethrows a decrypt or decode failure — so an unreadable
    /// `workspaces.json` was handled identically to a workspace the user had deleted, and the task
    /// silently ran unscoped. `.unscoped` is not a smaller boundary: `assessRisk` computes scope
    /// findings only when a workspace scope is present, so every out-of-scope advisory for that run
    /// disappears, and with it the sentence the ran-without-asking trace would have carried.
    ///
    /// **The plan is a bare `clarify` step, and that is what makes this test measure the fix.** A
    /// completed run ends in `refreshSavedItems()`, which reads the workspace store itself and
    /// records the *same* `.savedWorkspaces` source — so a test that runs a task to completion sees
    /// the notice whether or not `resolveTaskScope` reported anything, and passes with the fix
    /// removed. A mutation battery caught exactly that: the first version of this test survived a
    /// mutant deleting the `recordLocalStorageLoadFailure` call it was written to pin. A
    /// clarification returns from `performStart` *before* that refresh, and `resolveTaskScope` runs
    /// before the clarification is read, so the notice here has exactly one possible author.
    ///
    /// The binding comes through `start(workspaceBinding:)` — the workspace-card dispatch path — so
    /// the name is known without a store read, which is exactly the case where the scope can fail
    /// while the user has already been told the task belongs somewhere.
    @Test
    func aCorruptWorkspaceStoreReportsItselfInsteadOfSilentlyUnbindingTheTask() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceStore(
            fileURL: root.appendingPathComponent("workspaces.json"),
            encryption: testEncryption(byte: 0x42)
        ).save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://example.com"]))
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        // `canSubmit` requires a non-empty command even for a prebuilt plan; the text is never read
        // by this path beyond history's label for it.
        viewModel.command = "zip the selected folder"
        viewModel.start(workspaceBinding: "Research", prebuiltPlan: clarifyingPlan())
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // The storage problem is named on its own channel rather than swallowed, and this is the
        // only path that could have named it.
        let notice = try #require(viewModel.localStorageNotice)
        #expect(notice.contains("saved workspaces"))
        // Nothing was refused: a corrupt store is not this task failing, and blocking the dispatch to
        // report a storage problem would invert escalate-never-block for no safety gain.
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.clarificationQuestion != nil)
        // The scope genuinely did not bind, which is what makes the notice the only thing standing
        // between the user and a silent unbinding. `lastAssessedScope` rather than `activeTaskScope`
        // because it is the post-terminal record and reads the same on every path — *not* because
        // `activeTaskScope` was reset here, which it was not: `performStart`'s `defer` clears it only
        // when `approvalRequest == nil && clarificationQuestion == nil`, and this path pauses on a
        // clarification. That reset reasoning is true of the completed-run test below and was wrongly
        // stated here (PR #83, F7).
        #expect(viewModel.lastAssessedScope == .unscoped)
    }

    /// The other side of the distinction, and the behaviour that had to survive the fix: a workspace
    /// that is simply *gone* still binds to nothing, silently. That fallback is legitimate — a
    /// workspace deleted between dispatch and assessment is not a storage fault — and reporting it
    /// as one would put a decryption banner in front of a user whose store is perfectly healthy.
    ///
    /// Same clarification shape as above, and for the same reason in reverse: a completed run's
    /// `refreshSavedItems()` would *clear* the source against this healthy store, so a run-to-
    /// completion test asserts nil no matter what `resolveTaskScope` did.
    @Test
    func aWorkspaceThatNoLongerExistsStillUnbindsWithoutReportingAStoreFailure() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption(byte: 0x42)
        // A healthy, readable store — it just does not contain the bound name.
        try WorkspaceStore(
            fileURL: root.appendingPathComponent("workspaces.json"),
            encryption: encryption
        ).save(StoredWorkspace(name: "Writing", apps: ["Notes"], urls: []))
        let viewModel = try makeViewModel(root: root, encryption: encryption)

        // `canSubmit` requires a non-empty command even for a prebuilt plan; the text is never read
        // by this path beyond history's label for it.
        viewModel.command = "zip the selected folder"
        viewModel.start(workspaceBinding: "Research", prebuiltPlan: clarifyingPlan())
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.localStorageNotice == nil)
        #expect(viewModel.clarificationQuestion != nil)
        #expect(viewModel.lastAssessedScope == .unscoped)
    }

    /// **A blank workspace name is not a storage fault** (PR #83, F1). `findWorkspace` validates
    /// before it loads — `normalizedName` throws `.missingName` for a blank or whitespace-only
    /// string without touching the file — so a catch-all around that call reported "could not load
    /// encrypted local data" for a store that is perfectly healthy and was never even opened.
    ///
    /// Reachable with no tampering: the planner schema requires a `workspaceName` slot on every step
    /// and `""` is a valid value, nothing normalises blank to `nil`, and `directWorkspaceName` reads
    /// the field off any operation rather than only the workspace ones.
    @Test
    func aBlankWorkspaceNameBindsNothingWithoutClaimingTheStoreIsUnreadable() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption(byte: 0x42)
        try WorkspaceStore(
            fileURL: root.appendingPathComponent("workspaces.json"),
            encryption: encryption
        ).save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: []))
        let viewModel = try makeViewModel(root: root, encryption: encryption)

        viewModel.command = "zip the selected folder"
        // A whitespace-only name, carried on the step the way the planner can emit it.
        viewModel.start(prebuiltPlan: clarifyingPlan(workspaceName: "   "))
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.localStorageNotice == nil)
        #expect(viewModel.lastAssessedScope == .unscoped)
    }

    /// **A store that will not load leaves the history row untagged rather than tagging a boundary
    /// the run never had** (SONNY-191, the unreadable-store case).
    ///
    /// The third of the four ways a plan-carried name can fail to bind, and the one this file is the
    /// right home for — the two above it cover deleted and blank, and `ProductShellTests` covers
    /// those plus the bound case against a real task-history file. This needs a workspace store
    /// written under one key and read under another, which is the fixture shape this suite already
    /// has.
    ///
    /// `directWorkspaceName` reads `AgentStep.workspaceName` straight off the plan with no store
    /// access at all, so the old second derivation resolved "Research" here regardless of the store
    /// being unreadable, and the row claimed a workspace that had bounded nothing. Reported *and*
    /// untagged is the honest pair: the storage problem is named on its own channel, and the row
    /// says what actually happened.
    ///
    /// Unlike this suite's clarification-shaped tests, this one has to run to completion — a
    /// non-terminal status writes no row, and the row is the whole subject. That costs the notice
    /// assertion its isolation, since `refreshSavedItems()` records the same `.savedWorkspaces`
    /// source on the way out; the row's tag is what this test pins, and the notice is asserted only
    /// as the accompanying behaviour SONNY-78 already owns.
    @Test
    func aWorkspaceStoreThatWillNotLoadLeavesTheRowUntaggedInsteadOfClaimingABoundaryItNeverHad() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceStore(
            fileURL: root.appendingPathComponent("workspaces.json"),
            encryption: testEncryption(byte: 0x42)
        ).save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: []))
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        viewModel.command = "tally the sprint numbers"
        viewModel.start(prebuiltPlan: calculatingPlan(workspaceName: "Research"))
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Nothing bound, and the storage problem said so rather than being swallowed (SONNY-78).
        #expect(viewModel.lastAssessedScope == .unscoped)
        #expect(try #require(viewModel.localStorageNotice).contains("saved workspaces"))
        #expect(viewModel.errorMessage == nil, "an unreadable store is not this task failing")

        // The row exists, succeeded, and claims no workspace.
        let record = try #require(viewModel.taskHistoryRecords.last)
        #expect(record.outcomeStatus == .completed)
        #expect(record.workspaceName == nil)
    }

    /// The persisted form of the same thing, and the worse one: `validateStepSafety` checks a step's
    /// *operation* and not its fields, so a routine can be saved carrying a stray blank
    /// `workspaceName`, and `nestedRoutineWorkspaceName` then reproduces it on every single run of
    /// that routine rather than once.
    ///
    /// **Why this run pauses on an approval instead of completing** (PR #83 cycle 3). The first
    /// version of this test dispatched a routine that ran to completion, and was vacuous for the
    /// same reason the branch's other two were: `performStart` ends in `refreshSavedItems()`, which
    /// *clears* `.savedWorkspaces` against a healthy store, so the notice assertion passed with the
    /// guard reverted — and `lastAssessedScope` is `.unscoped` either way, because the pre-fix
    /// `catch` returned that too. Both assertions held on the pre-fix tree.
    ///
    /// A `[run_routine, clarify]` plan cannot isolate it — `clarificationQuestion(in:)` asks
    /// `workflow(in:)` first, which throws "Clarification must be the only planned step" for a mixed
    /// plan, so `prepare` fails before `resolveTaskScope` ever runs. The approval pause is the other
    /// early return that sits after the scope resolution and before the refresh: the routine's
    /// snippet step collides with an existing trigger, which escalates `.destructive`, which asks.
    /// So the notice here has exactly one possible author, the same isolation the other three tests
    /// use by a different door.
    @Test
    func aRoutineCarryingABlankWorkspaceNameDoesNotReportAStoreFailureOnEveryRun() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption(byte: 0x42)
        try WorkspaceStore(
            fileURL: root.appendingPathComponent("workspaces.json"),
            encryption: encryption
        ).save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: []))
        // The collision that makes the run stop and ask: same trigger, different expansion.
        try SnippetStore(
            fileURL: root.appendingPathComponent("snippets.json"),
            encryption: encryption
        ).save(StoredSnippet(trigger: ";sig", expansion: "the old signature", updatedAt: .fixture))
        try RoutineStore(
            fileURL: root.appendingPathComponent("routines.json"),
            encryption: encryption
        ).save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(
                        id: "snippet",
                        operation: .saveSnippet,
                        description: "Save the signature snippet.",
                        // The stray blank the store accepts because step safety checks operations,
                        // not fields — and the only thing `nestedRoutineWorkspaceName` will find.
                        workspaceName: "",
                        searchQuery: ";sig",
                        draftContent: "the new signature"
                    )
                ]
            )
        )
        let viewModel = try makeViewModel(root: root, encryption: encryption)

        viewModel.command = "run my morning routine"
        viewModel.start(prebuiltPlan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Morning"))
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Paused before `refreshSavedItems()` could clear anything...
        #expect(viewModel.isAwaitingApproval)
        // ...and nothing was recorded, because a blank name never reached the store.
        #expect(viewModel.localStorageNotice == nil)
        #expect(viewModel.lastAssessedScope == .unscoped)
    }

    /// **The success path clears the failure it recorded** (PR #83, F3). Deleting the
    /// `clearLocalStorageLoadFailure` call left the whole suite green, because nothing exercised a
    /// successful scope read against a view model that already had the failure recorded.
    ///
    /// The failure is seeded through `refreshSavedItems()` rather than through a first dispatch, and
    /// that is what makes the assertion belong to `resolveTaskScope`. Only one dispatch follows the
    /// repair, it takes the clarification path, and `performStart` returns from that path *before* it
    /// reaches its own `refreshSavedItems()` — so the clear at the end has exactly one possible
    /// author, the same isolation the corrupt-store test above relies on in the other direction.
    @Test
    func aRepairedWorkspaceStoreClearsTheFailureItReported() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspacesURL = root.appendingPathComponent("workspaces.json")
        let readable = testEncryption(byte: 0x42)
        // Written with a key the view model cannot read.
        try WorkspaceStore(fileURL: workspacesURL, encryption: testEncryption(byte: 0x99))
            .save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: []))
        let viewModel = try makeViewModel(root: root, encryption: readable)

        viewModel.refreshSavedItems()
        let recorded = try #require(viewModel.localStorageNotice)
        #expect(recorded.contains("saved workspaces"))

        // Repair it. Removed first rather than saved over: `save` merges, so it loads before it
        // writes and would fail on the very bytes being replaced.
        try FileManager.default.removeItem(at: workspacesURL)
        try WorkspaceStore(fileURL: workspacesURL, encryption: readable)
            .save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: []))

        viewModel.command = "zip the selected folder"
        viewModel.start(workspaceBinding: "Research", prebuiltPlan: clarifyingPlan())
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.localStorageNotice == nil)
        #expect(viewModel.clarificationQuestion != nil)
    }

    /// And a healthy store that *does* contain the workspace binds it, so the fix did not turn every
    /// scope resolution into a failure path. Asserted through `lastAssessedScope`, the post-terminal
    /// record of what the assessment actually used — `activeTaskScope` and therefore
    /// `boundWorkspaceName` are reset when a run ends, so neither can answer this afterwards.
    @Test
    func aReadableWorkspaceStoreStillBindsTheScope() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption(byte: 0x42)
        try WorkspaceStore(
            fileURL: root.appendingPathComponent("workspaces.json"),
            encryption: encryption
        ).save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://example.com"]))
        let viewModel = try makeViewModel(root: root, encryption: encryption)

        viewModel.command = "= 1 + 1"
        viewModel.start(workspaceBinding: "Research")
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // A completed run is fine here: this asserts that the scope *bound*, which no other path can
        // produce — unlike the notice, which `refreshSavedItems()` also writes.
        #expect(viewModel.localStorageNotice == nil)
        guard case .scoped(let scope) = viewModel.lastAssessedScope else {
            Issue.record("A readable store holding the bound workspace must produce a scoped assessment.")
            return
        }
        #expect(scope.workspaceName == "Research")
    }

    // MARK: - Per-task deletion (SONNY-116)

    @Test
    func deletingATaskRemovesItsHistoryRowAndItsScreenRecordTogether() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption(byte: 0x42)
        let fixture = try seedLinkedTask(root: root, encryption: encryption)
        let viewModel = try makeViewModel(root: root, encryption: encryption)
        viewModel.refreshTaskHistory()
        let doomed = try #require(viewModel.taskHistoryRecords.first { $0.command == "reply in Discord" })

        viewModel.deleteTask(doomed)

        #expect(viewModel.errorMessage == nil)
        // Published state agrees with the file: the row is gone from both.
        #expect(!viewModel.taskHistoryRecords.contains { $0.id == doomed.id })
        #expect(try fixture.history.loadAll().map(\.command) == ["unrelated"])
        // And the screen record went with it.
        #expect(try fixture.journal.record(withID: "session-1") == nil)
        // The unrelated task's own session is untouched — the delete is per-task, not a wipe.
        #expect(try fixture.journal.record(withID: "session-2") != nil)
        // Row E's plan detail is the third dependent, and it goes too (SONNY-147). A stored plan
        // surviving its row would be unreachable bytes: this store is keyed on the row's id and has
        // no other index, so nothing in the product could ever find or delete it again.
        #expect(try fixture.planDetails.detail(forTaskID: try #require(doomed.id)) == nil)
        // The unrelated task keeps its own.
        #expect(try fixture.planDetails.loadAll().map(\.taskID) == ["survivor-task"])
    }

    /// **The ordering test the ticket asks for, and the reason it exists.** Dependents are deleted
    /// before the row because the row is the only thing that makes them reachable through the
    /// product. Forcing the row's delete to fail proves the order rather than commenting it: the
    /// screen record is already gone, and the row survives carrying a link that now resolves to
    /// nothing — the designed dangling state, and a state the user can retry out of.
    ///
    /// If a later refactor swaps the two writes, this test fails: the journal would still hold the
    /// session while the row had gone, which is the orphan the founder named as the real defect.
    @Test(.requiresUnprivilegedProcess)
    func whenTheRowDeleteFailsTheScreenRecordIsAlreadyGoneAndTheRowSurvives() throws {
        let root = try makeDirectory()
        let historyRoot = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: historyRoot.path)
            try? FileManager.default.removeItem(at: root)
        }
        let encryption = testEncryption(byte: 0x42)
        let fixture = try seedLinkedTask(root: root, encryption: encryption, historyRoot: historyRoot)
        let viewModel = try makeViewModel(root: root, encryption: encryption, taskHistoryRoot: historyRoot)
        viewModel.refreshTaskHistory()
        let doomed = try #require(viewModel.taskHistoryRecords.first { $0.command == "reply in Discord" })
        // Read-only directory: task history still reads, but its rewrite cannot land. The journal
        // sits elsewhere and stays writable.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: historyRoot.path)

        viewModel.deleteTask(doomed)

        // The dependents went first and are gone — both of them, so a third one added later
        // inherits the invariant rather than restating it.
        #expect(try fixture.journal.record(withID: "session-1") == nil)
        #expect(try fixture.planDetails.detail(forTaskID: try #require(doomed.id)) == nil)
        // The row survived, still carrying its now-unresolvable link.
        let survivingRow = try #require(try fixture.history.loadAll().first { $0.id == doomed.id })
        #expect(survivingRow.visionSessionID == "session-1")
        #expect(survivingRow.command == "reply in Discord")
        // A delete is a write, so the failure gets write wording and never the load-failure banner.
        let message = try #require(viewModel.errorMessage)
        #expect(message.hasPrefix("Could not delete this task: "))
        #expect(!message.contains("decrypted or decoded"))
        #expect(viewModel.localStorageNotice == nil)
    }

    @Test
    func deletingOnlyTheScreenRecordLeavesTheRowAndItsLinkInPlace() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption(byte: 0x42)
        let fixture = try seedLinkedTask(root: root, encryption: encryption)
        let viewModel = try makeViewModel(root: root, encryption: encryption)
        viewModel.refreshTaskHistory()
        let target = try #require(viewModel.taskHistoryRecords.first { $0.command == "reply in Discord" })

        viewModel.deleteScreenRecord(for: target)

        #expect(viewModel.errorMessage == nil)
        #expect(try fixture.journal.record(withID: "session-1") == nil)
        // The row is still there, and it keeps its link — deliberately, so a deleted screen record
        // and one that aged out look the same.
        let row = try #require(try fixture.history.loadAll().first { $0.id == target.id })
        #expect(row.visionSessionID == "session-1")
        #expect(try fixture.history.loadAll().count == 2)
    }

    @Test
    func deletingATaskThatRanNoScreenSessionRemovesJustTheRow() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption(byte: 0x42)
        let fixture = try seedLinkedTask(root: root, encryption: encryption)
        let viewModel = try makeViewModel(root: root, encryption: encryption)
        viewModel.refreshTaskHistory()
        let plainTask = try #require(viewModel.taskHistoryRecords.first { $0.command == "unrelated" })
        #expect(plainTask.visionSessionID == nil)

        viewModel.deleteTask(plainTask)

        #expect(viewModel.errorMessage == nil)
        #expect(try fixture.history.loadAll().map(\.command) == ["reply in Discord"])
        // Nothing reached the journal, so the other task's session is still there.
        #expect(try fixture.journal.record(withID: "session-1") != nil)
    }

    @Test
    func deletingATaskThatIsAlreadyGoneIsSilent() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption(byte: 0x42)
        let fixture = try seedLinkedTask(root: root, encryption: encryption)
        let viewModel = try makeViewModel(root: root, encryption: encryption)
        viewModel.refreshTaskHistory()
        let target = try #require(viewModel.taskHistoryRecords.first { $0.command == "unrelated" })

        viewModel.deleteTask(target)
        viewModel.deleteTask(target)

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.localStorageNotice == nil)
        #expect(try fixture.history.loadAll().map(\.command) == ["reply in Discord"])
    }

    private struct LinkedTaskFixture {
        var history: TaskHistoryStore
        var journal: VisionSessionJournalStore
        var planDetails: TaskPlanDetailStore
    }

    /// Two tasks: one that ran a screen-control session and one that did not, plus a second session
    /// belonging to nothing under test, so a delete that reached too far is visible.
    private func seedLinkedTask(
        root: URL,
        encryption: LocalStorageEncryption,
        historyRoot: URL? = nil
    ) throws -> LinkedTaskFixture {
        let history = TaskHistoryStore(
            fileURL: (historyRoot ?? root).appendingPathComponent("task-history.json"),
            encryption: encryption
        )
        let journal = VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: encryption
        )
        let planDetails = TaskPlanDetailStore(
            fileURL: root.appendingPathComponent("task-plan-details.json"),
            encryption: encryption
        )
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for id in ["session-1", "session-2"] {
            try journal.save(
                VisionSessionRecord(
                    id: id,
                    goal: "goal \(id)",
                    appDisplayName: "Discord",
                    startedAt: base
                )
            )
        }
        let doomedRecord = CompletedTaskRecord(
            command: "reply in Discord",
            startedAt: base,
            completedAt: base.addingTimeInterval(30),
            outcomeStatus: .completed,
            visionSessionID: "session-1",
            result: .modelAuthored("The reply is sent.")
        )
        try history.record(doomedRecord)
        try history.record(
            CompletedTaskRecord(
                command: "unrelated",
                startedAt: base.addingTimeInterval(100),
                completedAt: base.addingTimeInterval(130),
                outcomeStatus: .completed
            )
        )
        // A plan for the doomed task and one for a task this fixture never deletes, so a delete that
        // wiped the store rather than one entry fails as loudly as one that deleted nothing.
        try planDetails.save(
            StoredTaskPlanDetail(
                taskID: try #require(doomedRecord.id),
                completedAt: doomedRecord.completedAt,
                planSummary: "Reply in Discord.",
                steps: []
            )
        )
        try planDetails.save(
            StoredTaskPlanDetail(
                taskID: "survivor-task",
                completedAt: base.addingTimeInterval(130),
                planSummary: "Something else.",
                steps: []
            )
        )
        return LinkedTaskFixture(history: history, journal: journal, planDetails: planDetails)
    }

    // MARK: - SONNY-187: what the storage notice's own notification offers

    /// **The storage notice no longer posts through the failure category, and no longer carries a
    /// Retry** (SONNY-187, founder decision 2026-08-21).
    ///
    /// It did, and that button is wired to `retryLastCommand()` — so a banner reading "your snippets
    /// file could not be decrypted" offered to re-dispatch whatever the user had last typed, a task
    /// with no relationship to the file. Reachable from a bookkeeping write failing during a run
    /// that otherwise succeeded, which makes it an offer to re-run a task that had just worked.
    ///
    /// **Worse on this channel than on the scheduled one SONNY-113 fixed.** `localStorageNotice`
    /// exists precisely so a storage problem is not confused with a task outcome — its own
    /// declaration says a corrupt store must never make a successful task read as failed — so moving
    /// it off `errorMessage` and then posting it in the failure notification category undid the move
    /// at the last hop.
    ///
    /// Asserted by reading the wiring because it cannot be asserted by running it:
    /// `SonnyNotificationService.init?` returns nil without bundle identity, and
    /// `UNUserNotificationCenter.current()` aborts the process rather than throwing when there is
    /// none — so the subscription this pins does not exist in a test run at all. Same shape and same
    /// reasoning as `ScheduledRoutineRunTests.theScheduledNoticePostsThroughItsOwnActionlessCategory`.
    ///
    /// **This is one half of SONNY-187 and the ticket stays open for the other**: both notice strips
    /// are still invisible while the widget is compact, which the founder left for its own decision.
    /// `FloatingWidgetView.isCollapsible` carries that pointer.
    @Test
    func theStorageNoticePostsThroughItsOwnActionlessCategoryRatherThanTheFailureOne() throws {
        let delegate = try MacAgentSource.read("AppDelegate.swift")
        let subscription = try MacAgentSource.region(
            of: delegate,
            from: "viewModel.$localStorageNotice",
            to: ".store(in: &cancellables)"
        )
        #expect(subscription.contains("postStorageNoticeNotification"))
        #expect(!subscription.contains("postErrorNotification"))

        // And the category it posts into offers nothing to press. The two neighbours that do carry
        // actions are named here too, so this fails if the empty array is ever filled in by copying
        // one of them.
        let service = try MacAgentSource.read("SonnyNotificationService.swift")
        let storageCategory = try MacAgentSource.region(
            of: service,
            from: "identifier: SonnyNotificationCategory.storage,",
            to: ")"
        )
        #expect(storageCategory.contains("actions: [],"))
        #expect(!storageCategory.contains("retryAction"))
        #expect(!storageCategory.contains("allowAction"))

        // The click opens Command Center: the notice renders there as a row on four pages, and
        // Settings' local-data controls are the nearest thing to somewhere to act on it. Without its
        // own case the default arm would front the widget, which offers nothing but Dismiss.
        #expect(service.contains("case SonnyNotificationCategory.storage:"))
        #expect(service.contains("self?.onOpenStorageNotice()"))
        let wiring = try MacAgentSource.region(
            of: delegate,
            from: "onOpenStorageNotice: { [weak self] in",
            to: "}"
        )
        #expect(wiring.contains("showCommandCenter()"))
    }
}

/// A one-step plan that completes hermetically, carrying a `workspaceName` on the step.
///
/// `clarifyingPlan` below is the right shape for the scope-only tests, which need an early return
/// before `refreshSavedItems()`. A test that reads a task-history *row* back cannot use it: a
/// `.clarificationNeeded` status is not terminal, so `recordTaskHistoryIfTerminal` writes nothing.
private func calculatingPlan(workspaceName: String?) -> AgentPlan {
    AgentPlan(
        summary: "Calculate 1 + 1.",
        requiresConfirmation: false,
        steps: [
            AgentStep(
                id: "calculate",
                operation: .calculateUtility,
                description: "Calculate 1 + 1.",
                workspaceName: workspaceName,
                searchQuery: "1 + 1"
            )
        ]
    )
}

/// A plan that prepares straight into a clarification, so `performStart` returns before
/// `refreshSavedItems()` runs. That early return is what isolates `resolveTaskScope`'s own
/// load-failure reporting from the identical reporting the post-run refresh does (SONNY-78).
private func clarifyingPlan(workspaceName: String? = nil) -> AgentPlan {
    AgentPlan(
        summary: "Ask first.",
        requiresConfirmation: false,
        steps: [
            AgentStep(
                id: "clarify",
                operation: .clarify,
                description: "Ask which folder.",
                question: "Which folder should Sonny use?",
                workspaceName: workspaceName
            )
        ]
    )
}

@MainActor
/// `taskHistoryRoot` exists for the delete-ordering test, which needs task history in a directory
/// it can make read-only while the journal stays writable. Everything else defaults to `root`.
///
/// The vision journal is injected rather than defaulted for the reason the hermetic-seams comment
/// below already gives: an un-injected `VisionSessionJournalStore()` resolves to the real
/// `~/Library/Application Support/Sonny/vision-sessions.json`. No test in this file read it before
/// SONNY-116, so nothing was wrong yet — which is exactly the shape of the bug that comment
/// describes, a fixture that is hermetic by accident rather than by construction.
private func makeViewModel(
    root: URL,
    encryption: LocalStorageEncryption,
    taskHistoryRoot: URL? = nil
) throws -> AgentViewModel {
    let suiteName = "AgentViewModelLocalStorageTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    return AgentViewModel(
        routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json"), encryption: encryption),
        workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"), encryption: encryption),
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json"), encryption: encryption),
        recentArtifactStore: RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json"),
            encryption: encryption
        ),
        shortcutCatalog: EmptyShortcutCatalog(),
        // Hermetic seams (fakes in ProductShellTests.swift, same test target). These tests execute
        // real plans; their commands touch no side-effect seam *today*, but that is a property of
        // the commands rather than of the fixture — this bug arrived exactly that way, when a
        // routine fixture gained a URL step. Injected so hermeticity is structural.
        browserOpener: HermeticBrowserOpener(),
        appOpener: HermeticAppOpener(),
        fileOpener: HermeticFileOpener(),
        finderRevealer: hermeticFinderRevealer,
        mediaOpener: HermeticMediaOpener(),
        runningAppSwitcher: HermeticRunningAppSwitcher(),
        shortcutInvoker: HermeticShortcutInvoker(),
        finderContextReader: HermeticFinderContextReader(),
        documentConverter: HermeticDocumentConverter(),
        zipArchiver: HermeticZipArchiver(),
        shortcutRunHistoryStore: ShortcutRunHistoryStore(
            fileURL: root.appendingPathComponent("shortcuts-run-history.json"),
            encryption: encryption
        ),
        taskHistoryStore: TaskHistoryStore(
            fileURL: (taskHistoryRoot ?? root).appendingPathComponent("task-history.json"),
            encryption: encryption
        ),
        // Row E's plan details (SONNY-147). Under `root`, not `taskHistoryRoot`: the ordering test
        // makes the history directory read-only and needs every dependent to stay writable, exactly
        // as the vision journal already does.
        taskPlanDetailStore: TaskPlanDetailStore(
            fileURL: root.appendingPathComponent("task-plan-details.json"),
            encryption: encryption
        ),
        visionSessionJournalStore: VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: encryption
        ),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
            encryption: encryption
        ),
        approvedAppStore: ApprovedAppStore(
            fileURL: root.appendingPathComponent("approved-apps.json"),
            encryption: encryption
        ),
        outputLocationStore: OutputLocationStore(
            fileURL: root.appendingPathComponent("output-locations.json"),
            encryption: encryption
        ),
        resumableTaskStore: ResumableTaskStore(
            fileURL: root.appendingPathComponent("resumable-tasks.json"),
            encryption: encryption
        ),
        standingWatcherObserver: UnreachableStandingWatcherObserver(),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: FakePasteboardReader(),
            store: ClipboardHistoryStore(
                fileURL: root.appendingPathComponent("clipboard-history.json"),
                encryption: encryption
            ),
            settingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
                encryption: encryption
            )
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        // SONNY-130: undefaulted like the stores, and for a worse reason — this client holds the
        // Keychain session every packaged build on this Mac shares. Hermetic: no environment, so
        // every request fails before a URL is built, and an in-memory Keychain of its own.
        backendClient: makeHermeticBackendClient(),
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        userDefaults: userDefaults
    )
}

private func testEncryption(byte: UInt8) -> LocalStorageEncryption {
    LocalStorageEncryption(
        keyManager: FixedLocalStorageKeyManager(bytes: Data(repeating: byte, count: 32))
    )
}

private struct FixedLocalStorageKeyManager: LocalStorageKeyManaging {
    let bytes: Data

    func keyData() throws -> Data {
        bytes
    }
}

private struct EmptyShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}

@MainActor
private final class FakePasteboardReader: PasteboardReading {
    var changeCount = 0

    func typeIdentifiers() -> [String] {
        []
    }

    func stringValue() -> String? {
        nil
    }
}

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacAgentTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private extension Date {
    static let fixture = Date(timeIntervalSince1970: 1_700_000_000)
}
