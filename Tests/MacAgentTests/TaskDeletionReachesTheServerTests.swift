import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

/// Pressing Delete on a task deletes the server's copy too (SONNY-333).
///
/// The founder decision of 2026-08-16 (SONNY-14) is that delete means deleted everywhere.
/// `DELETE /v1/tasks/{task_id}` has existed since SONNY-134 and nothing in the app pressed it, so
/// that rule was true of the endpoint and not of the button. These are the properties that make it
/// true of the button, and the founders' decision of 2026-08-30 about *how* — local at once, queue
/// the server delete, retry it.
@Suite
@MainActor
struct TaskDeletionReachesTheServerTests {
    // MARK: - The join

    /// **The id on the wire is the id the row carried**, which is contract §5.1 and the only thing
    /// that makes any of this possible: the local row is gone by the time the delete is sent, so
    /// the id it carried is the sole remaining name for the content on the server.
    @Test
    func deletingATaskSendsTheDeleteForTheIDThatRowWasFiledUnder() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        let record = try fixture.writeTaskRecord(id: "task-a")

        fixture.viewModel.deleteTask(record)
        await fixture.viewModel.pendingServerDeletionDeliveryForTests?.value

        #expect(try fixture.seen.only.path == "/v1/tasks/task-a")
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
        #expect(fixture.viewModel.taskHistoryRecords.isEmpty)
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.localStorageNotice == nil)
    }

    /// The button is never blocked on the network: the row is gone the moment `deleteTask` returns,
    /// before the delivery pass has been awaited at all.
    @Test
    func theRowDisappearsBeforeTheServerHasAnsweredAnything() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        fixture.holdTheGateway()
        let record = try fixture.writeTaskRecord(id: "task-a")

        fixture.viewModel.deleteTask(record)

        // Synchronously after the press, with the gateway still holding the request open.
        #expect(fixture.viewModel.taskHistoryRecords.isEmpty)
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().flatMap(\.taskIDs) == ["task-a"])

        fixture.viewModel.pendingServerDeletionDeliveryForTests?.cancel()
    }

    // MARK: - Offline and signed out

    /// The queue's whole reason for existing. Offline, the delete is remembered; at the next launch
    /// the sweep sends it.
    @Test
    func aDeletionMadeOfflineIsSentByTheNextLaunchsSweep() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        fixture.goOffline()
        let record = try fixture.writeTaskRecord(id: "task-a")

        fixture.viewModel.deleteTask(record)
        await fixture.viewModel.pendingServerDeletionDeliveryForTests?.value

        // The entry survives the failed pass. **Not asserted by counting requests**: the stub's
        // handler runs and *then* answers with a transport failure, so an attempt that never
        // reached a server still shows up here — and the client spends `.offline`'s own two-attempt
        // budget, so the count is two rather than zero or one either way.
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().flatMap(\.taskIDs) == ["task-a"])
        // A failed delivery is not the user's problem and must not read as one — the founders'
        // 2026-08-30 decision, and the reason this is not on `errorMessage`.
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.localStorageNotice == nil)
        let attemptsWhileOffline = fixture.seen.all.count

        fixture.comeBackOnline()
        fixture.viewModel.sweepPendingServerDeletions()
        await fixture.viewModel.pendingServerDeletionDeliveryForTests?.value

        // Exactly one more attempt, and the queue is settled by it.
        #expect(fixture.seen.all.count == attemptsWhileOffline + 1)
        #expect(fixture.seen.all.last?.path == "/v1/tasks/task-a")
        #expect(fixture.seen.all.last?.method == "DELETE")
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
    }

    /// Signed out, there is no session to send anything with — the case the ticket names, and the
    /// one where the retry is the entire mechanism keeping the 2026-08-16 promise.
    @Test
    func aDeletionMadeWhileSignedOutIsQueuedRatherThanLost() async throws {
        let fixture = try TaskDeletionFixture(signedIn: false)
        defer { fixture.tearDown() }
        let record = try fixture.writeTaskRecord(id: "task-a")

        fixture.viewModel.deleteTask(record)
        await fixture.viewModel.pendingServerDeletionDeliveryForTests?.value

        #expect(fixture.seen.all.isEmpty)
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().flatMap(\.taskIDs) == ["task-a"])
        #expect(fixture.viewModel.taskHistoryRecords.isEmpty)
        #expect(fixture.viewModel.errorMessage == nil)
    }

    // MARK: - Ordering, and the two half-failures

    /// **A local delete that throws withdraws the obligation** (PR #194 review, F1's symmetric half).
    ///
    /// The vision journal here holds bytes that will not decode, so the *first* local delete throws
    /// and `deleteTask` returns early with an error. The row is still standing — every delete in
    /// that block is atomic and the row's own is last — so an entry left queued for it would have
    /// the next launch remove the server's copy of a task the user can still see, after being told
    /// the delete had failed. Content taken on the strength of a press that visibly did not work.
    ///
    /// This was the shipped behaviour and the branch argued for it: *"the user presses again"*. They
    /// may reasonably decide not to, and the deletion went anyway with nothing to cancel it.
    @Test
    func aLocalDeleteThatFailsWithdrawsTheServerDeleteToo() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        let record = try fixture.writeTaskRecord(id: "task-a", visionSessionID: "session-a")
        try Data("not this store's bytes".utf8).write(
            to: fixture.root.appendingPathComponent("vision-sessions.json"),
            options: .atomic
        )

        fixture.viewModel.deleteTask(record)

        // The user is told the delete failed — it did, and nothing was taken on either side.
        #expect(fixture.viewModel.errorMessage != nil)
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
        // The row survives, so pressing again is a real way out — off the file, for the reason the
        // abort test above gives.
        #expect(try fixture.taskHistoryOnDisk() == ["task-a"])
    }

    /// **A failed queue write aborts the whole delete, and this is PR #194's F1.**
    ///
    /// The shipped code caught the enqueue throw, published a notice, and then fell through to the
    /// local deletes — producing byte-for-byte the outcome `deleteTask`'s own doc calls permanent,
    /// unrecoverable and silent: the id gone from the Mac, nothing queued, the server's copy
    /// orphaned with no remaining name. A test pinned that behaviour by name, so it was a choice
    /// arguing with its own justification rather than an oversight.
    ///
    /// **The row surviving is what makes the ordering real rather than decorative**, and it is what
    /// kills the mutant that moves the enqueue below the local block: down there, an enqueue failure
    /// arrives with the row already gone.
    ///
    /// `setError` rather than the storage-notice channel, because nothing was deleted — which is
    /// `errorMessage`'s own meaning, and the same sentence the local-failure path reports.
    ///
    /// The queue is made unwritable by putting a *file* where its directory would be, so
    /// `createDirectory` fails and the store cannot write.
    @Test
    func aQueueWriteThatFailsAbortsTheDeleteAndLeavesEverythingWhereItWas() async throws {
        let fixture = try TaskDeletionFixture(queueInsideAFile: true)
        defer { fixture.tearDown() }
        let record = try fixture.writeTaskRecord(id: "task-a")

        fixture.viewModel.deleteTask(record)

        #expect(fixture.viewModel.errorMessage != nil)
        #expect(fixture.viewModel.localStorageNotice == nil)
        // Nothing local was touched, so the user can press again and nothing is destroyed.
        //
        // **Read off the file, not off `taskHistoryRecords`.** This path returns before
        // `refreshTaskHistory()`, so the published list still holds what it held a moment ago — and
        // the mutant that moves the enqueue below the local deletes leaves that list looking exactly
        // like this while the row is gone from disk. It survived a whole battery on the published
        // assertion alone.
        #expect(try fixture.taskHistoryOnDisk() == ["task-a"])
        #expect(fixture.viewModel.taskHistoryRecords.map(\.id) == ["task-a"])
        #expect(fixture.seen.all.isEmpty)
    }

    /// **Two presses in a row send two deletes, not four** (PR #194 review, F3).
    ///
    /// The chain — each pass awaiting the previous one — was the branch's only concurrency control
    /// and nothing tested it: every existing test presses once, so removing the `await` passed the
    /// whole suite. This is the shape that sees it. The gateway is blocked, so both presses land
    /// before either pass can finish; with the chain, the first pass takes the queue as it then
    /// stands and the second finds it empty, which is two requests. Without it both passes load the
    /// same two entries and send each twice.
    ///
    /// Deterministic rather than a race: nothing between the two presses yields the main actor, so
    /// both entries are queued before either task runs.
    ///
    /// **It waits on the number of passes that have *finished*, not on the delivery handle, and that
    /// is the whole reason it is reliable** (found by this branch's own battery, which watched the
    /// chain mutant survive a run after two earlier runs killed it). The handle is the *last* pass;
    /// without the chain the last pass does not cover the first, so awaiting it can return while an
    /// earlier pass is still issuing requests and the count below measures whatever had landed by
    /// then. Two finished passes is a state both versions reach, so the wait succeeds either way and
    /// the mutant dies on the assertion rather than on a timeout — which is what keeps it a kill
    /// (`CLAUDE.md`'s note that a backstop timeout can never be counted as one).
    @Test
    func twoPressesInARowSendOneDeleteEach() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        let first = try fixture.writeTaskRecord(id: "task-a")
        let second = try fixture.writeTaskRecord(id: "task-b")
        fixture.blockTheGateway()

        fixture.viewModel.deleteTask(first)
        fixture.viewModel.deleteTask(second)
        fixture.releaseTheGateway(8)
        try await fixture.waitForDeliveryPasses(2)

        #expect(fixture.seen.all.count == 2)
        #expect(Set(fixture.seen.all.map(\.path)) == ["/v1/tasks/task-a", "/v1/tasks/task-b"])
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
        #expect(fixture.viewModel.taskHistoryRecords.isEmpty)
    }

    /// **A press landing while a pass is in flight keeps its own entry** (PR #194 review, F2).
    ///
    /// The other direction of the same hazard, and the damaging one. `enqueue` runs synchronously on
    /// the main actor; the delivery pass is a nonisolated `async` method, so it has released the main
    /// actor by the time it reaches `remove` — a press inside that window used to lose its entry
    /// outright, which is an obligation destroyed rather than a delivery repeated. The store's
    /// per-file lock is what closes it; `PendingServerDeletionStoreTests` drives the file directly,
    /// and this drives the real button through the real view model.
    @Test
    func aPressWhileAPassIsInFlightStillGetsItsOwnDeleteSent() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        let first = try fixture.writeTaskRecord(id: "task-a")
        let second = try fixture.writeTaskRecord(id: "task-b")
        fixture.blockTheGateway()

        fixture.viewModel.deleteTask(first)
        // Let the first pass start and reach its request before the second press lands.
        await Task.yield()
        fixture.viewModel.deleteTask(second)
        fixture.releaseTheGateway(8)
        try await fixture.waitForDeliveryPasses(2)

        #expect(Set(fixture.seen.all.map(\.path)) == ["/v1/tasks/task-a", "/v1/tasks/task-b"])
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
    }

    // MARK: - The store's place in the product

    /// The queue has no Memory row, is not suppressible by "Don't save this task", and is named in
    /// the sentence Settings uses for the wipe — three properties decided together on
    /// `PendingServerDeletionStore`, held here in one place so a change to any of them meets a test
    /// that says why.
    ///
    /// **That the wipe actually reaches its file is pinned in `LocalStorageSecurityTests`** rather
    /// than here, by `theWipeReachesEveryLocalStore` and `everyLocalStoreFileIsClassifiedExactlyOnce`
    /// — deliberately, because asserting it here would make this file name a store's real
    /// `~/Library` location, and `LocalStoreInjectionScanTests` keeps that population to the handful
    /// of files that are genuinely about production paths.
    @Test
    func theQueueShowsNowhereAndIsNotSuppressible() {
        #expect(LocalStore.pendingServerDeletions.memoryCategory == nil)
        #expect(LocalStore.pendingServerDeletions.kind == .notWrittenByTasks)
        #expect(TaskRecordingPolicy.suppressTraces.allowsWriting(to: .pendingServerDeletions))
        #expect(LocalDataDeletionCopy.everythingItTakes.contains("deletions Sonny hasn't finished"))
    }
}

/// The other three delete buttons reach the server too (SONNY-404).
///
/// SONNY-333 made one button keep the founder decision of 2026-08-16. Three deletions still stopped
/// at this Mac, and the founder settled all three on 2026-09-05: the whole local-data wipe stays a
/// promise about this Mac and says so; *Memory › Task history › Delete* queues every row's server
/// deletion as one bulk call; and *Delete what Sonny did on screen* gets a route that takes exactly
/// that task's screenshots.
@Suite
@MainActor
struct EveryDeleteReachesTheServerTests {
    // MARK: - Delete what Sonny did on screen

    /// **The narrower route, and the reason the whole ticket needed a contract change.**
    /// `DELETE /v1/tasks/{task_id}` would have taken the command text and the responses too, which
    /// is more than this button says.
    @Test
    func deletingAScreenRecordSendsTheScreenshotsRouteAndNotTheWholeTaskRoute() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        let record = try fixture.writeTaskWithAScreenRecord(id: "task-a", sessionID: "session-a")

        fixture.viewModel.deleteScreenRecord(for: record)
        try await fixture.waitForDeliveryPasses(1)

        #expect(try fixture.seen.only.path == "/v1/tasks/task-a/screenshots")
        #expect(try fixture.seen.only.method == "DELETE")
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
        #expect(fixture.viewModel.errorMessage == nil)
        // The local half is unchanged: the screen record goes and the task row stays.
        #expect(try fixture.visionSessionsOnDisk() == [])
        #expect(try fixture.taskHistoryOnDisk() == ["task-a"])
    }

    /// Offline, the obligation is remembered under its own scope — not as a whole-task delete, which
    /// would take content this button never named.
    @Test
    func aScreenRecordDeletedOfflineIsQueuedAsAScreenshotsObligationAndSentAtTheNextSweep() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        let record = try fixture.writeTaskWithAScreenRecord(id: "task-a", sessionID: "session-a")
        fixture.goOffline()

        fixture.viewModel.deleteScreenRecord(for: record)
        try await fixture.waitForDeliveryPasses(1)

        let queued = try fixture.viewModel.pendingServerDeletionsForTests()
        #expect(queued.count == 1)
        #expect(queued.first?.taskIDs == ["task-a"])
        #expect(queued.first?.scope == .screenshotsOnly)
        // Gone locally either way: the button is never blocked on the network.
        #expect(try fixture.visionSessionsOnDisk() == [])

        fixture.comeBackOnline()
        fixture.viewModel.sweepPendingServerDeletions()
        try await fixture.waitForDeliveryPasses(2)

        // A set rather than a list: the offline pass is a retry-safe request, so the shared client
        // spends its own attempt budget on it and the request *count* is that budget's, not this
        // test's. What this test is about is which route the queue delivers to, which is the set.
        #expect(Set(fixture.seen.all.map(\.path)) == ["/v1/tasks/task-a/screenshots"])
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
    }

    /// **The enqueue goes first, and a failed one aborts.** The button does not survive the local
    /// delete — it is offered only for a screen record that reads back — so a local delete that ran
    /// with nothing queued would leave the server's screenshots with no control able to ask again.
    @Test
    func aScreenRecordDeleteWhoseQueueWriteFailsDeletesNothingAndSaysSo() async throws {
        let fixture = try TaskDeletionFixture(queueInsideAFile: true)
        defer { fixture.tearDown() }
        let record = try fixture.writeTaskWithAScreenRecord(id: "task-a", sessionID: "session-a")

        fixture.viewModel.deleteScreenRecord(for: record)

        #expect(try fixture.visionSessionsOnDisk() == ["session-a"])
        #expect(fixture.viewModel.errorMessage != nil)
        #expect(fixture.seen.all.isEmpty)
    }

    // MARK: - Memory › Task history › Delete

    /// **One request naming every row, which is the founder decision of 2026-09-05.** One call per
    /// row would be up to ten thousand requests behind one press — and, in the queue, up to ten
    /// thousand entries against a cap of two hundred.
    @Test
    func deletingTheTaskHistoryRowSendsOneBulkCallNamingEveryRow() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        _ = try fixture.writeTaskRecord(id: "task-a")
        _ = try fixture.writeTaskRecord(id: "task-b")
        _ = try fixture.writeTaskRecord(id: "task-c")

        fixture.viewModel.deleteMemory(in: .taskHistory)
        try await fixture.waitForDeliveryPasses(1)

        let sent = try fixture.seen.only
        #expect(sent.path == "/v1/tasks")
        #expect(sent.method == "DELETE")
        let ids = try #require(sent.json["task_ids"] as? [String])
        #expect(Set(ids) == ["task-a", "task-b", "task-c"])
        #expect(try fixture.taskHistoryOnDisk() == [])
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
    }

    /// Offline, the whole press is **one** entry rather than one per row — which is what keeps the
    /// two-hundred cap from silently dropping the difference at the press that asks for the most.
    @Test
    func aTaskHistoryRowDeletedOfflineIsOneQueuedObligationNamingEveryRow() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        _ = try fixture.writeTaskRecord(id: "task-a")
        _ = try fixture.writeTaskRecord(id: "task-b")
        fixture.goOffline()

        fixture.viewModel.deleteMemory(in: .taskHistory)
        try await fixture.waitForDeliveryPasses(1)

        let queued = try fixture.viewModel.pendingServerDeletionsForTests()
        #expect(queued.count == 1)
        #expect(queued.first?.scope == .wholeTask)
        #expect(Set(try #require(queued.first?.taskIDs)) == ["task-a", "task-b"])
        #expect(try fixture.taskHistoryOnDisk() == [])

        fixture.comeBackOnline()
        fixture.viewModel.sweepPendingServerDeletions()
        try await fixture.waitForDeliveryPasses(2)

        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
        // A set, for the reason the screenshots test above gives: the offline attempt's retry budget
        // belongs to the shared client and not to this assertion.
        #expect(Set(fixture.seen.all.map(\.path)) == ["/v1/tasks"])
    }

    /// **A batch the gateway says holds another account's task stays queued**, exactly as §4.6's
    /// `404` keeps a single-task obligation: it means "not deliverable by this session", never "not
    /// deliverable", and a Mac two people have signed into raises it for the other one's tasks.
    @Test
    func aBulkDeleteThatReachedSomebodyElsesTaskKeepsTheObligation() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        fixture.answerBulkDeleteWith(tasksDeleted: 1, tasksNotFound: 1)
        _ = try fixture.writeTaskRecord(id: "task-a")
        _ = try fixture.writeTaskRecord(id: "task-b")

        fixture.viewModel.deleteMemory(in: .taskHistory)
        try await fixture.waitForDeliveryPasses(1)

        let queued = try fixture.viewModel.pendingServerDeletionsForTests()
        #expect(queued.count == 1)
        #expect(Set(try #require(queued.first?.taskIDs)) == ["task-a", "task-b"])
    }

    /// The enqueue goes first here too, for `deleteTask`'s reason: the ids are carried by the rows
    /// and by nothing else.
    @Test
    func aTaskHistoryRowDeleteWhoseQueueWriteFailsDeletesNothingAndSaysSo() async throws {
        let fixture = try TaskDeletionFixture(queueInsideAFile: true)
        defer { fixture.tearDown() }
        _ = try fixture.writeTaskRecord(id: "task-a")

        fixture.viewModel.deleteMemory(in: .taskHistory)

        #expect(try fixture.taskHistoryOnDisk() == ["task-a"])
        #expect(fixture.viewModel.errorMessage != nil)
        #expect(fixture.seen.all.isEmpty)
    }

    /// A press on an empty history owes nothing, so it queues nothing and sends nothing — an entry
    /// naming no tasks would be an obligation every future pass delivered as a request about
    /// nothing.
    @Test
    func deletingAnEmptyTaskHistoryQueuesNothingAndSendsNothing() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.deleteMemory(in: .taskHistory)

        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
        #expect(fixture.seen.all.isEmpty)
    }

    /// **A different Memory row queues nothing.** The founder's decision names Task history, and a
    /// row deleting routines or snippets has no server copy to reach — a press that enqueued
    /// anything here would be sending task ids for a control that never mentioned tasks.
    @Test
    func deletingAnotherMemoryRowReachesTheServerNotAtAll() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        _ = try fixture.writeTaskRecord(id: "task-a")

        fixture.viewModel.deleteMemory(in: .snippets)

        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
        #expect(fixture.seen.all.isEmpty)
        #expect(try fixture.taskHistoryOnDisk() == ["task-a"])
    }

    // MARK: - The two unfinished-task controls, which reach no server (SONNY-426, 2026-09-06)

    /// **The widget's cross deletes nothing, so it owes nothing** (SONNY-426).
    ///
    /// SONNY-426 was filed reading this as a fourth delete door of the kind SONNY-404 routed. It is
    /// not a delete door at all: the founders' decision of 2026-08-25 is that the cross stops the
    /// offer and keeps the record, taken so that no control in the widget can lose work
    /// irreversibly. The property is an absence — no queue entry, no request — and an absence is
    /// exactly what a later change removes without anyone noticing, which is why it is written down
    /// rather than left to be inferred from the code reading as if it does nothing.
    @Test
    func decliningAnUnfinishedTaskReachesTheServerNotAtAll() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        _ = try fixture.writeResumableTask(id: "unfinished-a")
        #expect(fixture.viewModel.resumeOffer?.id == "unfinished-a")

        fixture.viewModel.declineResumeOffer()

        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
        #expect(fixture.seen.all.isEmpty)
        // The record survives, declined — the half of the decision that makes the absence correct
        // rather than a gap. A cross that had deleted it would owe what a delete owes.
        #expect(try fixture.resumableTasksOnDisk() == ["unfinished-a"])
        #expect(try fixture.resumableTaskIsDeclinedOnDisk("unfinished-a"))
        #expect(fixture.viewModel.resumeOffer == nil)
    }

    /// **Memory › Unfinished tasks › Delete removes a checkpoint that names nothing on any server**
    /// (SONNY-426, from review-207's residual R7).
    ///
    /// The three doors SONNY-404 routed each hold §5.1's `task_id`. A `ResumableTask` holds no
    /// backend key at all, and the run's wire id — `currentTaskID`, re-minted at every dispatch —
    /// lives on the task-history row, which this press leaves standing. So the server's copy stays
    /// reachable through the doors that do name it, and queueing here would delete the server's copy
    /// of a task the user can still open on the Tasks page.
    ///
    /// **The row on disk is the load-bearing assertion**, for `taskHistoryOnDisk`'s reason: an
    /// enqueue added here would be invisible to a published-state check, and the point of this test
    /// is what the press did *not* reach.
    @Test
    func theUnfinishedTasksPerEntryDeleteReachesTheServerNotAtAll() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        _ = try fixture.writeTaskRecord(id: "task-a")
        let unfinished = try fixture.writeResumableTask(id: "unfinished-a")

        fixture.viewModel.deleteResumableTask(unfinished)

        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
        #expect(fixture.seen.all.isEmpty)
        #expect(try fixture.resumableTasksOnDisk() == [])
        #expect(try fixture.taskHistoryOnDisk() == ["task-a"])
        #expect(fixture.viewModel.errorMessage == nil)
    }

    // MARK: - The whole wipe is a promise about the account (SONNY-404 fix round, 2026-09-05)

    /// **The whole press, on the path where everything works.** The queue is drained, the account's
    /// server-side content is deleted, the local files go, and nothing at all is left owed.
    @Test
    func theWipeDrainsTheQueueThenDeletesTheAccountsContentAndLeavesNothingOwed() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        let record = try fixture.writeTaskRecord(id: "task-a")
        fixture.goOffline()
        fixture.viewModel.deleteTask(record)
        try await fixture.waitForDeliveryPasses(1)
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().count == 1)

        fixture.comeBackOnline()
        fixture.seen.removeAll()
        fixture.viewModel.deleteLocalData()
        await fixture.viewModel.localDataWipeForTests?.value

        // The drain went first — the owed per-task delete was sent before the file holding it could
        // be removed — and then the account-wide route. In that order, which is the founder's own
        // condition on this decision.
        #expect(fixture.seen.all.map(\.path) == ["/v1/tasks/task-a", "/v1/account/content"])
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.localDataDeletionStatusMessage?.contains("servers is deleted too") == true)
    }

    /// **The failing state, which is the one the founder's condition is about.** Offline, the press
    /// says once and plainly what is left and what happens to it, and leaves exactly one obligation
    /// behind — which names no task.
    @Test
    func aWipeThatCannotReachTheServerSaysSoAndLeavesOneObligationNamingNoTask() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        let record = try fixture.writeTaskRecord(id: "task-a")
        fixture.goOffline()
        // A per-task obligation already owed when the press lands — the case the whole rule is
        // about, because that entry names a task and the file it sits in is the file the wipe leaves
        // behind.
        fixture.viewModel.deleteTask(record)
        try await fixture.waitForDeliveryPasses(1)
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().count == 1)

        fixture.viewModel.deleteLocalData()
        await fixture.viewModel.localDataWipeForTests?.value

        let owed = try fixture.viewModel.pendingServerDeletionsForTests()
        // **Exactly one, and it is not the one that was there before.** The per-task obligation did
        // not survive the press; what stands in its place is wider than it was.
        #expect(owed.count == 1)
        #expect(owed.first?.scope == .everythingUnderTheAccount)
        // **The property the whole shape turns on.** A file a privacy wipe leaves behind may not
        // name anything the user did, and this one names nothing at all.
        #expect(owed.first?.taskIDs.isEmpty == true)

        let message = try #require(fixture.viewModel.localDataDeletionStatusMessage)
        #expect(message.contains("couldn't reach its servers"))
        #expect(message.contains("still there"))
        #expect(message.contains("the next time it can"))
        // Never silently: the sentence exists, and it is the same one the run summary carries.
        #expect(fixture.viewModel.finalSummary == message)
    }

    /// The obligation the wipe left is delivered by the ordinary sweep, and then nothing is owed.
    @Test
    func theObligationAWipeLeavesIsDeliveredAtTheNextSweep() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        fixture.goOffline()
        fixture.viewModel.deleteLocalData()
        await fixture.viewModel.localDataWipeForTests?.value
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().count == 1)

        fixture.comeBackOnline()
        fixture.seen.removeAll()
        fixture.viewModel.sweepPendingServerDeletions()
        try await fixture.waitForDeliveryPasses(1)

        #expect(Set(fixture.seen.all.map(\.path)) == ["/v1/account/content"])
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
    }

    /// A wipe that reached the gateway leaves **nothing** on disk to owe — not an entry that would
    /// be delivered again for no reason.
    @Test
    func aWipeThatReachedTheServerRecordsNoObligationAtAll() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.deleteLocalData()
        await fixture.viewModel.localDataWipeForTests?.value

        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
        #expect(fixture.seen.all.map(\.path) == ["/v1/account/content"])
    }

    // MARK: - An obligation belongs to the account that pressed it (PR #207's F1)

    /// **F1 shape A, the cross-account data-loss path.** A presses the wipe offline; B signs in on
    /// the same Mac; the sweep must not delete B's everything.
    @Test
    func anObligationLeftByOneAccountIsNeverDeliveredUnderAnother() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        fixture.goOffline()
        fixture.viewModel.deleteLocalData()
        await fixture.viewModel.localDataWipeForTests?.value
        let owed = try fixture.viewModel.pendingServerDeletionsForTests()
        #expect(owed.count == 1)
        #expect(owed.first?.accountID == "account-a")

        // A signs out, B signs in — and B's launch sweep runs.
        fixture.comeBackOnline()
        fixture.signIn(as: "account-b")
        fixture.seen.removeAll()
        fixture.viewModel.sweepPendingServerDeletions()
        try await fixture.waitForDeliveryPasses(1)

        // Nothing was sent at all. Before this round the sweep issued
        // `DELETE /v1/account/content` with B's token and deleted B's everything.
        #expect(fixture.seen.all.isEmpty)
        // And the obligation is kept rather than dropped: A may sign back in.
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().count == 1)
    }

    /// The same obligation, once the account that pressed it is back — it delivers.
    @Test
    func theAccountThatPressedTheWipeDeliversItsOwnObligation() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        fixture.goOffline()
        fixture.viewModel.deleteLocalData()
        await fixture.viewModel.localDataWipeForTests?.value

        fixture.comeBackOnline()
        fixture.signIn(as: "account-b")
        fixture.signIn(as: "account-a")
        fixture.seen.removeAll()
        fixture.viewModel.sweepPendingServerDeletions()
        try await fixture.waitForDeliveryPasses(1)

        #expect(fixture.seen.all.count == 1)
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
    }

    /// **F1 shape B, the cutoff.** The obligation carries the instant of the press, and the request
    /// carries it, so a delivery days later cannot reach content the press never covered.
    @Test
    func theWipesObligationCarriesTheInstantOfThePressAndTheRequestCarriesIt() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        fixture.goOffline()
        let before = Date()
        fixture.viewModel.deleteLocalData()
        await fixture.viewModel.localDataWipeForTests?.value
        let after = Date()

        let owed = try #require(try fixture.viewModel.pendingServerDeletionsForTests().first)
        #expect(owed.deletedAt >= before.addingTimeInterval(-1))
        #expect(owed.deletedAt <= after.addingTimeInterval(1))

        fixture.comeBackOnline()
        fixture.seen.removeAll()
        fixture.viewModel.sweepPendingServerDeletions()
        try await fixture.waitForDeliveryPasses(1)

        // **The bound on the wire is the press's own instant**, not merely a `before=` that is
        // present. A mutant sending `Date.distantFuture` satisfies "there is a bound" while deleting
        // exactly what an unbounded delete would, which is the whole defect — so the value is read.
        let sent = try fixture.seen.only
        #expect(sent.path == "/v1/account/content")
        let query = try #require(sent.query)
        let prefix = "before="
        let value = try #require(
            query
                .split(separator: "&")
                .first(where: { $0.hasPrefix(prefix) })
                .map { String($0.dropFirst(prefix.count)).removingPercentEncoding ?? "" }
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let sentInstant = try #require(formatter.date(from: value))
        // Within the second, because the wire format is whole seconds.
        #expect(abs(sentInstant.timeIntervalSince(owed.deletedAt)) < 1.5)
    }

    /// **F1's session-change door.** Signing in as somebody else discards what the previous account
    /// owed, and says so — rather than leaving it for a sweep to aim at the wrong account.
    @Test
    func signingInAsAnotherAccountDiscardsTheOldAccountsObligationsAndRecordsWhy() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        fixture.goOffline()
        fixture.viewModel.deleteLocalData()
        await fixture.viewModel.localDataWipeForTests?.value
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().count == 1)

        fixture.comeBackOnline()
        fixture.signIn(as: "account-b")
        fixture.viewModel.settlePendingServerDeletionsForSessionChange()
        await fixture.viewModel.pendingServerDeletionDeliveryForTests?.value

        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
        #expect(fixture.viewModel.logStore.events.contains {
            $0.message.contains("belonging to an account that is no longer signed in")
        })
    }

    /// Signing out keeps them: the account that owns them may sign back in, and the delivery gate is
    /// what holds them safe until it does.
    @Test
    func signingOutKeepsTheObligationsRatherThanDiscardingThem() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        fixture.goOffline()
        fixture.viewModel.deleteLocalData()
        await fixture.viewModel.localDataWipeForTests?.value

        fixture.signIn(as: nil)
        fixture.viewModel.settlePendingServerDeletionsForSessionChange()
        await fixture.viewModel.pendingServerDeletionDeliveryForTests?.value

        #expect(try fixture.viewModel.pendingServerDeletionsForTests().count == 1)
    }

    /// **A wipe pressed with nobody signed in records nothing at all, and says why.** An obligation
    /// that cannot name whose content it is about is the obligation that deletes the next account.
    @Test
    func aWipePressedSignedOutRecordsNoObligationAndTellsTheUserWhatToDo() async throws {
        let fixture = try TaskDeletionFixture(signedIn: false)
        defer { fixture.tearDown() }
        fixture.goOffline()

        fixture.viewModel.deleteLocalData()
        await fixture.viewModel.localDataWipeForTests?.value

        #expect(try fixture.viewModel.pendingServerDeletionsForTests().isEmpty)
        let message = try #require(fixture.viewModel.localDataDeletionStatusMessage)
        #expect(message.contains("You're signed out"))
        #expect(message.contains("Sign in and press Delete again."))
    }

    // MARK: - The failure branch owes what it could not do (PR #207's F2)

    /// **F2.** A local file that cannot be deleted throws *after* the queue file is already gone, so
    /// the obligation has to be recorded on that path too — or the server keeps everything with
    /// nothing owed and nothing said.
    @Test
    func aWipeWhoseLocalDeleteThrowsStillOwesTheServersCopyAndSaysSo() async throws {
        let fixture = try TaskDeletionFixture(oneLocalFileCannotBeDeleted: true)
        defer { fixture.tearDown() }
        fixture.goOffline()

        fixture.viewModel.deleteLocalData()
        await fixture.viewModel.localDataWipeForTests?.value

        let owed = try fixture.viewModel.pendingServerDeletionsForTests()
        #expect(owed.count == 1)
        #expect(owed.first?.scope == .everythingUnderTheAccount)
        let message = try #require(fixture.viewModel.localDataDeletionStatusMessage)
        #expect(message.contains("could not be deleted"))
        // The half that used to be missing entirely: the sentence names the servers.
        #expect(message.contains("their copy is still there"))
    }

    // MARK: - The cutoff comes from the server's clock (PR #207's cycle-3, G1)

    /// **The bound is compared against the gateway's own `occurred_at`, so it must be the gateway's
    /// clock.** A Mac running behind under-deletes while reporting the servers' copy gone; one
    /// running ahead puts the cutoff in the future, which is the over-deletion `?before=` exists to
    /// stop.
    @Test
    func theCutoffIsTheServersClockAndNotThisMacs() async throws {
        // **An hour *behind*, deliberately.** The offset is observed from a `Date` header, so a
        // request has to have gone out first — true of any Mac that has talked to the gateway at
        // all — and a server an hour *ahead* would push `serverNow()` past this fixture's own access
        // token expiry, so the client would refresh and the assertion would be reading the wrong
        // request. The direction does not matter to what is being tested: the bound follows the
        // gateway's clock rather than this Mac's, whichever way the two differ.
        let fixture = try TaskDeletionFixture(serverClockAhead: -3600)
        defer { fixture.tearDown() }
        let record = try fixture.writeTaskRecord(id: "task-a")
        fixture.viewModel.deleteTask(record)
        try await fixture.waitForDeliveryPasses(1)

        fixture.seen.removeAll()
        fixture.viewModel.deleteLocalData()
        await fixture.viewModel.localDataWipeForTests?.value

        let sent = try fixture.seen.only
        #expect(sent.path == "/v1/account/content")
        let bound = try #require(Self.boundOnTheWire(of: sent))
        // Nearer the gateway's hour-behind clock than this Mac's — with a second of slack for the
        // wire format, which carries no fractional seconds and truncates toward the past. On the
        // Mac's own clock this would be within a second of zero.
        #expect(bound.timeIntervalSince(Date()) < -3500)
        #expect(bound.timeIntervalSince(Date()) > -3700)
    }

    /// Parses the `before=` the request carried, or `nil` when it carried none.
    private static func boundOnTheWire(of request: RecordedBackendRequest) -> Date? {
        let prefix = "before="
        guard let value = request.query?
            .split(separator: "&")
            .first(where: { $0.hasPrefix(prefix) })
            .map({ String($0.dropFirst(prefix.count)).removingPercentEncoding ?? "" })
        else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    // MARK: - The wipe holds its claim (PR #207's F3)

    /// **F3's second half: the claim is held until the *last* wipe finishes, not the first.**
    ///
    /// Each wipe used to clear the flag when its own body ended, so a second press chained behind
    /// the first had the first's completion drop the claim while the second was still draining,
    /// still calling the gateway and still about to delete every store — the window the claim exists
    /// to close, re-opened by pressing twice.
    ///
    /// **The signal is each wipe's own handle, and there is no wall clock in it at all.** Awaiting
    /// the first press's task returns exactly when that wipe has finished and decremented the count,
    /// which is the instant this test is about; the second is still blocked on the gateway, so the
    /// claim must still be held whichever of the two continuations the main actor runs next.
    ///
    /// **It was written as a poll for the second wipe's request and that was wrong** — the poll's
    /// backstop is a deadline, so a loaded full-suite run failed it while the same test passed under
    /// a filter, which is the shape `CLAUDE.md` calls a test that only finds a defect on an idle
    /// machine. The handles remove the dependency rather than widening the number.
    @Test
    func aSecondPressInsideTheWindowDoesNotReleaseTheFirstWipesClaim() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        fixture.blockTheGateway()

        fixture.viewModel.deleteLocalData()
        let firstWipe = fixture.viewModel.localDataWipeForTests
        fixture.viewModel.deleteLocalData()
        let secondWipe = fixture.viewModel.localDataWipeForTests
        #expect(fixture.viewModel.isDeletingLocalData)

        // Let exactly one request through: the first wipe finishes, the second is still blocked.
        fixture.releaseTheGateway(1)
        await firstWipe?.value

        // Before this round the first wipe's completion had already set the flag false, and the run
        // doors — and Settings' Delete — were open again while the second wipe was still draining,
        // still calling the gateway and still about to delete every store.
        #expect(fixture.viewModel.isDeletingLocalData)
        #expect(!fixture.viewModel.isRunning)

        fixture.releaseTheGateway(1)
        await secondWipe?.value
        // And it is released once the last one finishes, or the control never comes back.
        #expect(!fixture.viewModel.isDeletingLocalData)
    }

    /// The control the user actually presses is disabled for the whole window, which is why two
    /// presses are unreachable through the product.
    @Test
    func settingsDeleteControlIsDisabledWhileAWipeIsRunning() throws {
        let page = try MacAgentSource.read("CommandCenterView.swift")
        let block = try MacAgentSource.braceBlock(of: page, openedBy: "private struct SettingsDataPage: View {")
        #expect(block.contains(".disabled(viewModel.isRunning || viewModel.isDeletingLocalData)"))
    }


    /// **F3.** The press now spans a server round trip, and a run started inside that window would
    /// have every store deleted underneath it. The doors refuse instead.
    @Test
    func aRunCannotStartWhileTheWipeIsRunning() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        fixture.holdTheGateway()

        fixture.viewModel.deleteLocalData()
        // Synchronously after the press, with the gateway still holding the request open.
        #expect(fixture.viewModel.isDeletingLocalData)
        fixture.viewModel.command = "do the thing"
        fixture.viewModel.start()
        // Refused, and it says why rather than doing nothing: the run door reads the wipe's claim.
        #expect(!fixture.viewModel.isRunning)
        #expect(fixture.viewModel.logStore.events.contains {
            $0.message == "Not started: Sonny is deleting your data."
        })

        fixture.viewModel.localDataWipeForTests?.cancel()
    }

    /// **The words, at both surfaces that state them, in each state.** Neither sentence is reachable
    /// from a test except through the source, because this repository renders no views in the suite
    /// — and the founder's decision is precisely that the words say which promise this press is.
    @Test
    func bothSurfacesSayTheWipeReachesTheServersAndNothingAboutWhy() throws {
        let page = try MacAgentSource.read("CommandCenterView.swift")
        let dialog = try MacAgentSource.read("ContentView.swift")

        #expect(page.contains(
            "Deletes \\(LocalDataDeletionCopy.everythingItTakes) from this Mac and from Sonny's servers."
        ))
        #expect(dialog.contains(
            "This deletes \\(LocalDataDeletionCopy.everythingItTakes) from this Mac and from Sonny's servers."
        ))
        // **And the how-it-works sentence is gone** (PR #207's R5). A confirmation names what the
        // press does; what happens when the servers cannot be reached is said afterwards, by
        // `LocalDataDeletionCopy.outcome`, in the state it actually happened in.
        #expect(!dialog.contains("it deletes their copy the next time it can"))
        // And what it leaves alone — the account among them, because "delete my data" and "delete my
        // account" are two promises and only one of them has a control in the app.
        #expect(dialog.contains("Generated files, API keys and your account are not deleted."))
        // The superseded reading is gone from both surfaces rather than merely added to.
        #expect(!page.contains("from this Mac.\""))
        #expect(!dialog.contains("what Sonny's servers keep are not deleted"))
    }

    /// Both outcomes of the one sentence, at the type that owns it.
    @Test
    func theWipesOwnSentenceNamesBothOutcomesAndNeverGoesQuiet() {
        let reached = LocalDataDeletionCopy.outcome(deletedFileCount: 13, serverCopy: .deleted)
        #expect(reached == "Deleted 13 local data files. The copy on Sonny's servers is deleted too.")

        let owed = LocalDataDeletionCopy.outcome(deletedFileCount: 1, serverCopy: .owed)
        #expect(owed == "Deleted 1 local data file. Sonny couldn't reach its servers, so their copy is still there. Sonny deletes it the next time it can.")

        // **The third state, and it is the one that must not promise a retry** (PR #207's F1):
        // nothing was recorded, because an obligation that cannot name whose content it is about is
        // the obligation that deletes the next account to sign in.
        let stranded = LocalDataDeletionCopy.outcome(deletedFileCount: 2, serverCopy: .strandedWithNoSession)
        #expect(stranded == "Deleted 2 local data files. You're signed out, so the copy on Sonny's servers is still there. Sign in and press Delete again.")

        // **A local failure names the servers too** (PR #207's F2): the sentence used to talk only
        // about a file while the servers' copy sat there.
        let partial = LocalDataDeletionCopy.outcome(
            deletedFileCount: 2,
            localFailure: "vision-sessions.json",
            serverCopy: .owed
        )
        #expect(partial.contains("but some could not be deleted: vision-sessions.json"))
        #expect(partial.contains("their copy is still there"))
    }

    /// The narrow button's confirmation names both halves of what it reaches.
    @Test
    func theScreenRecordConfirmationSaysItReachesTheServerAndKeepsTheTask() {
        let message = TaskDeletePresentation.screenRecordConfirmationMessage
        #expect(message.contains("from this Mac and from Sonny's servers"))
        #expect(message.contains("The task stays in your history."))
    }
}

/// A view model with real stores under one temp root and a stub gateway in front of it.
@MainActor
private struct TaskDeletionFixture {
    let root: URL
    let viewModel: AgentViewModel
    let seen = RecordedBackendRequests()
    private let host: String?
    private let network: NetworkState
    /// Who is signed in, as the view model reads it — settable, because the defect F1 names is what
    /// happens when it *changes* between a press and its delivery.
    private let account: AccountBox

    init(
        signedIn: Bool = true,
        queueInsideAFile: Bool = false,
        /// How far ahead of this Mac the gateway's own clock reads. The stub puts it on a `Date`
        /// header, which is what `SonnyBackendClient` observes §3.5's offset from, so a request has
        /// to have gone out before the offset exists — which is what SONNY-404's G1 test arranges.
        serverClockAhead: TimeInterval = 0,
        /// One file in this fixture's own wipe list that cannot be unlinked, so
        /// `deleteAllLocalData()` throws **after** deleting everything else — the queue among them.
        /// That is the shape PR #207's F2 is about, and it is the shape the wipe's own list produces
        /// rather than one invented here.
        oneLocalFileCannotBeDeleted: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonny-delete-reaches-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let encryption = LocalStorageEncryption(
            keyManager: FixedDeletionKeyManager(bytes: Data(repeating: 0x4D, count: 32))
        )
        let network = NetworkState(serverClockAhead: serverClockAhead)
        self.network = network
        let account = AccountBox(signedIn ? "account-a" : nil)
        self.account = account
        let seen = self.seen

        let client: SonnyBackendClient
        if signedIn {
            let backend = SignedInBackendFixture()
            host = backend.host
            backend.register { request in
                seen.append(request)
                return network.answer
            }
            client = backend.client
        } else {
            // Configured, so nothing is refused for want of a base URL, and with an empty Keychain
            // so the only thing missing is the session.
            let stub = BackendStubURLProtocol.makeSession()
            host = stub.host
            BackendStubURLProtocol.register(host: stub.host) { request in
                seen.append(request)
                return network.answer
            }
            client = makeHermeticBackendClient(
                environment: SonnyBackendEnvironment(baseURL: stub.baseURL, source: .debugOverride),
                session: stub.session
            )
        }

        // A *file* where the queue's directory would be, so the store's `createDirectory` fails and
        // its write cannot land. The nearest thing to an unwritable location that does not depend on
        // permissions the test process may or may not have.
        let queueURL: URL
        if queueInsideAFile {
            let blocker = root.appendingPathComponent("blocked")
            try Data("not a directory".utf8).write(to: blocker, options: .atomic)
            queueURL = blocker.appendingPathComponent("pending-server-deletions.json")
        } else {
            queueURL = root.appendingPathComponent("pending-server-deletions.json")
        }

        // **The wipe's own list, with the undeletable file *last but one*** so the queue really is
        // deleted before the throw — which is the ordering PR #207's F2 turns on:
        // `deleteAllLocalData` collects failures and throws only after it has deleted everything it
        // could, so the queue file is always gone by the time the caller sees the error.
        var wipeFileURLs: [URL] = [
            queueURL,
            root.appendingPathComponent("task-history.json"),
            root.appendingPathComponent("vision-sessions.json"),
            root.appendingPathComponent("task-plan-details.json")
        ]
        if oneLocalFileCannotBeDeleted {
            // A *directory* where the wipe expects a file: `removeItem` on a non-empty directory
            // whose parent is not writable fails, and the simplest reliable refusal here is a
            // directory containing a file, which `removeItem` will not unlink as a plain file.
            let blocked = root.appendingPathComponent("blocked-store", isDirectory: true)
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
            try Data("held".utf8).write(to: blocked.appendingPathComponent("child"), options: .atomic)
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: blocked.path)
            wipeFileURLs.append(blocked)
        }

        let suiteName = "TaskDeletionReachesTheServerTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)

        viewModel = AgentViewModel(
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json"), encryption: encryption),
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"), encryption: encryption),
            snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json"), encryption: encryption),
            recentArtifactStore: RecentArtifactStore(
                fileURL: root.appendingPathComponent("recent-artifacts.json"),
                encryption: encryption
            ),
            shortcutCatalog: NoShortcuts(),
            browserOpener: HermeticBrowserOpener(),
            appOpener: HermeticAppOpener(),
            fileOpener: HermeticFileOpener(),
            finderRevealer: { _ in },
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
                fileURL: root.appendingPathComponent("task-history.json"),
                encryption: encryption
            ),
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
            pendingServerDeletionStore: PendingServerDeletionStore(
                fileURL: queueURL,
                encryption: encryption
            ),
            standingWatcherObserver: UnreachableStandingWatcherObserver(),
            clipboardHistoryMonitor: ClipboardHistoryMonitor(
                reader: SilentPasteboard(),
                store: ClipboardHistoryStore(
                    fileURL: root.appendingPathComponent("clipboard-history.json"),
                    encryption: encryption
                ),
                settingsStore: ClipboardHistorySettingsStore(
                    fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
                    encryption: encryption
                )
            ),
            // **Over this fixture's own files, not an empty list** (SONNY-404's fix round). The wipe
            // has to genuinely remove the queue for a test to be able to say that a per-task
            // obligation does not survive the press — with an empty list the wipe deleted nothing
            // and the assertion would have been about a file nobody touched. The real list is
            // `LocalDataDeletionService.defaultStoreFileURLs()`, which points under `~/Library` and
            // is never what a fixture passes.
            localDataDeletionService: LocalDataDeletionService(fileURLs: wipeFileURLs),
            backendClient: client,
            // Movable, because F1's shape A is precisely what happens when this changes between a
            // press and its delivery.
            accountIdentity: { account.current },
            userDefaults: userDefaults,
            whitelist: PathWhitelist(roots: [root])
        )
    }

    /// Writes one finished task and hands back the record as the Tasks page would.
    func writeTaskRecord(id: String, visionSessionID: String? = nil) throws -> CompletedTaskRecord {
        let store = TaskHistoryStore(
            fileURL: root.appendingPathComponent("task-history.json"),
            encryption: LocalStorageEncryption(
                keyManager: FixedDeletionKeyManager(bytes: Data(repeating: 0x4D, count: 32))
            )
        )
        // Timestamps derived from the id, so two records in one test are an hour apart rather than
        // sharing an instant — these files persist whole-second dates and `refreshTaskHistory`'s
        // sort is not stable, so same-second twins come back in no defined order.
        //
        // **A byte sum rather than `hashValue`** (PR #194 cycle-3's residuals). Swift seeds String
        // hashing per process, so the offset differed between runs and two ids collided about one
        // run in twenty-four — benign here, since nothing asserts on order, and exactly the kind of
        // per-process-random value that later makes one run look different for no reason a reader
        // can see.
        let offset = Double((id.utf8.reduce(0) { ($0 + Int($1)) % 24 }) * 3600)
        let record = CompletedTaskRecord(
            id: id,
            command: "do the thing",
            startedAt: Date(timeIntervalSince1970: 1_772_000_000 + offset),
            completedAt: Date(timeIntervalSince1970: 1_772_000_060 + offset),
            outcomeStatus: .completed,
            visionSessionID: visionSessionID
        )
        _ = try store.record(record)
        viewModel.refreshTaskHistory()
        // **By id, never `first`.** The Tasks page hands `deleteTask` the row the user clicked;
        // taking the head of the list gives a test with two rows whichever one the sort happened to
        // put on top, which is how this helper silently handed the same record back twice.
        return try #require(viewModel.taskHistoryRecords.first { $0.id == id })
    }

    /// Writes one unfinished task the widget will offer to carry on with, and hands it back as
    /// Memory's Unfinished tasks row would (SONNY-426).
    ///
    /// One `.openURL` step, because `mayBeOfferedForResume` requires every remaining step to be
    /// `.safeToRepeat` and a record the offer withholds cannot exercise the cross at all.
    ///
    /// **Dated from now rather than from the fixed instant `writeTaskRecord` uses**, because this
    /// store has an idle expiry and that one does not: `ResumableTaskStore.loadAll` drops a record
    /// nobody came back to, so a fixture timestamp months in the past is written and then never
    /// read back — which reads as the view model failing to publish rather than as the store doing
    /// its job.
    func writeResumableTask(id: String) throws -> ResumableTask {
        let now = Date()
        let task = ResumableTask(
            id: id,
            command: "open the page",
            plan: AgentPlan(
                summary: "Open the page.",
                requiresConfirmation: false,
                steps: [
                    AgentStep(
                        id: "url",
                        operation: .openURL,
                        description: "Open the page.",
                        targetURL: "https://example.com/page"
                    )
                ]
            ),
            startedAt: now.addingTimeInterval(-60),
            updatedAt: now
        )
        try resumableTaskStore().save(task)
        viewModel.refreshResumableTasks()
        return try #require(viewModel.resumableTasks.first { $0.id == id })
    }

    /// The unfinished tasks as the *file* holds them, for `taskHistoryOnDisk`'s reason: a path that
    /// returns early leaves the published list saying whatever it said before.
    func resumableTasksOnDisk() throws -> [String] {
        try resumableTaskStore().loadAll().map(\.id)
    }

    /// Whether the file records this task as declined — the cross's whole effect, and the thing that
    /// has to survive a press that deletes nothing.
    func resumableTaskIsDeclinedOnDisk(_ id: String) throws -> Bool {
        try resumableTaskStore().loadAll().first { $0.id == id }?.isDeclined ?? false
    }

    private func resumableTaskStore() -> ResumableTaskStore {
        ResumableTaskStore(
            fileURL: root.appendingPathComponent("resumable-tasks.json"),
            encryption: LocalStorageEncryption(
                keyManager: FixedDeletionKeyManager(bytes: Data(repeating: 0x4D, count: 32))
            )
        )
    }

    /// Writes one finished task that ran a screen-control session, and the session beside it.
    func writeTaskWithAScreenRecord(id: String, sessionID: String) throws -> CompletedTaskRecord {
        let journal = VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: LocalStorageEncryption(
                keyManager: FixedDeletionKeyManager(bytes: Data(repeating: 0x4D, count: 32))
            )
        )
        try journal.save(VisionSessionRecord(
            id: sessionID,
            goal: "do the thing on screen",
            appDisplayName: "Notes",
            startedAt: Date(timeIntervalSince1970: 1_772_000_000),
            endedAt: Date(timeIntervalSince1970: 1_772_000_060),
            endReasonCode: "completed"
        ))
        return try writeTaskRecord(id: id, visionSessionID: sessionID)
    }

    /// The vision journal as the *file* holds it, for the same reason `taskHistoryOnDisk` exists:
    /// a path that returns early leaves the published state saying whatever it said before.
    func visionSessionsOnDisk() throws -> [String] {
        try VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: LocalStorageEncryption(
                keyManager: FixedDeletionKeyManager(bytes: Data(repeating: 0x4D, count: 32))
            )
        ).loadAll().map(\.id)
    }

    /// Answers the bulk route with a body of the test's choosing — the one response field the client
    /// actually reads.
    func answerBulkDeleteWith(tasksDeleted: Int, tasksNotFound: Int) {
        network.set(.reply(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("""
            {"deleted_at":"2026-09-05T00:00:00Z","tasks_deleted":\(tasksDeleted),\
            "tasks_not_found":\(tasksNotFound),"requests_deleted":1}
            """.utf8)
        ))
    }

    /// Task history as the *file* holds it, not as the view model last published it.
    ///
    /// **The distinction is what let a mutant through** (this branch's own battery). A path that
    /// returns before `refreshTaskHistory()` leaves `taskHistoryRecords` holding whatever it held
    /// before, so an assertion on the published list is satisfied by a row that has just been
    /// deleted from disk — which is exactly the mutant that moves the enqueue below the local
    /// deletes.
    func taskHistoryOnDisk() throws -> [String] {
        try TaskHistoryStore(
            fileURL: root.appendingPathComponent("task-history.json"),
            encryption: LocalStorageEncryption(
                keyManager: FixedDeletionKeyManager(bytes: Data(repeating: 0x4D, count: 32))
            )
        ).loadAll().compactMap(\.id)
    }

    /// Waits until this many delivery passes have finished.
    ///
    /// **The handle first, and the poll only if that was not enough** — which is what keeps the
    /// passing path free of any wall clock at all. In the shipped code the passes chain, so awaiting
    /// the last handle transitively covers every earlier one and the count is already there: the
    /// loop below never runs a single iteration. It runs only under a mutant that breaks the chain,
    /// where the last handle covers nothing, and there a timeout is a red on a broken tree rather
    /// than a flake on a healthy one.
    ///
    /// **Written this way after the poll-only version failed a loaded full-suite run** and passed in
    /// 0.049 s on its own: a neighbouring test held the main actor for 43 seconds, so a 30-second
    /// deadline for a main-actor hop was reachable without anything being wrong. That is the third
    /// time on this branch a test has depended on the machine being idle, which is why the fix is to
    /// remove the dependency rather than to widen the number.
    func waitForDeliveryPasses(_ count: Int, timeout: TimeInterval = 60) async throws {
        await viewModel.pendingServerDeletionDeliveryForTests?.value
        let deadline = Date(timeIntervalSinceNow: timeout)
        while viewModel.completedServerDeletionPasses < count {
            if Date() > deadline {
                Issue.record("only \(viewModel.completedServerDeletionPasses) of \(count) delivery passes finished — treat as genuinely stuck.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The account the view model reads right now.
    var currentAccount: String? { account.current }

    /// Somebody else signs in on this Mac — the second half of F1's shape A.
    func signIn(as accountID: String?) { account.current = accountID }

    func goOffline() { network.set(.failure(URLError(.notConnectedToInternet))) }

    func comeBackOnline() { network.comeBackOnline() }

    /// A gateway that never answers, so the delivery pass is provably still in flight while the
    /// assertions about the button run.
    func holdTheGateway() { network.set(.hang) }

    /// A gateway that answers, but only once the test says so. Unlike `holdTheGateway()` this lets
    /// the pass finish, which is what a test about *two* passes needs.
    func blockTheGateway() { network.hold() }

    func releaseTheGateway(_ requests: Int) { network.open(requests) }


    func tearDown() {
        if let host {
            BackendStubURLProtocol.unregister(host: host)
        }
        // The immutable flag has to come off or the whole temp root survives the run.
        let blocked = root.appendingPathComponent("blocked-store", isDirectory: true)
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blocked.path)
        try? FileManager.default.removeItem(at: root)
    }
}

/// The signed-in account, mutable from a test and readable from the view model's synchronous seam.
private final class AccountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String?) { self.value = value }

    var current: String? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// What the stub answers, flipped by the test between passes.
private final class NetworkState: @unchecked Sendable {
    static let ok = reply(serverClockAhead: 0)

    /// The ordinary success, optionally carrying a `Date` header the client reads §3.5's clock
    /// offset from (SONNY-404, PR #207's cycle-3, G1).
    static func reply(serverClockAhead: TimeInterval) -> BackendStubURLProtocol.Outcome {
        var headers = ["Content-Type": "application/json"]
        if serverClockAhead != 0 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            headers["Date"] = formatter.string(from: Date().addingTimeInterval(serverClockAhead))
        }
        return BackendStubURLProtocol.Outcome.reply(
            statusCode: 200,
            headers: headers,
            body: Data(#"{"task_id":"t","deleted_at":"2026-08-30T00:00:00Z","requests_deleted":1}"#.utf8)
        )
    }

    /// What a request answers when the gate was held and nobody opened it. Distinguishable from
    /// `ok`, so a test that mis-counts its `open()` calls fails on its own assertion instead of
    /// hanging — the backstop shape `CLAUDE.md` allows, reachable only by a real failure.
    static let gateNeverOpened = BackendStubURLProtocol.Outcome.failure(URLError(.timedOut))

    private let lock = NSLock()
    private var outcome = NetworkState.ok
    private var gate: DispatchSemaphore?

    init(serverClockAhead: TimeInterval = 0) {
        outcome = NetworkState.reply(serverClockAhead: serverClockAhead)
        self.serverClockAhead = serverClockAhead
    }

    private let serverClockAhead: TimeInterval

    var answer: BackendStubURLProtocol.Outcome {
        lock.lock()
        let held = gate
        let next = outcome
        lock.unlock()
        guard let held else { return next }
        return held.wait(timeout: .now() + 30) == .success ? next : Self.gateNeverOpened
    }

    /// Back to the ordinary success, carrying whatever clock header this fixture was built with.
    func comeBackOnline() { set(Self.reply(serverClockAhead: serverClockAhead)) }

    func set(_ next: BackendStubURLProtocol.Outcome) {
        lock.lock()
        outcome = next
        lock.unlock()
    }

    /// Every request from here on blocks until `open(_:)` lets it through.
    func hold() {
        lock.lock()
        gate = DispatchSemaphore(value: 0)
        lock.unlock()
    }

    func open(_ count: Int) {
        lock.lock()
        let held = gate
        lock.unlock()
        for _ in 0..<count { held?.signal() }
    }
}

private struct FixedDeletionKeyManager: LocalStorageKeyManaging {
    let bytes: Data

    func keyData() throws -> Data {
        bytes
    }
}

private struct NoShortcuts: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}

@MainActor
private final class SilentPasteboard: PasteboardReading {
    var changeCount = 0

    func typeIdentifiers() -> [String] {
        []
    }

    func stringValue() -> String? {
        nil
    }
}
