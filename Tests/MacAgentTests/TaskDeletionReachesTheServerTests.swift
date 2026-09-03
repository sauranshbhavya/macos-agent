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
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().map(\.taskID) == ["task-a"])

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
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().map(\.taskID) == ["task-a"])
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
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().map(\.taskID) == ["task-a"])
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

/// A view model with real stores under one temp root and a stub gateway in front of it.
@MainActor
private struct TaskDeletionFixture {
    let root: URL
    let viewModel: AgentViewModel
    let seen = RecordedBackendRequests()
    private let host: String?
    private let network: NetworkState

    init(signedIn: Bool = true, queueInsideAFile: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonny-delete-reaches-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let encryption = LocalStorageEncryption(
            keyManager: FixedDeletionKeyManager(bytes: Data(repeating: 0x4D, count: 32))
        )
        let network = NetworkState()
        self.network = network
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
            localDataDeletionService: LocalDataDeletionService(fileURLs: []),
            backendClient: client,
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

    func goOffline() { network.set(.failure(URLError(.notConnectedToInternet))) }

    func comeBackOnline() { network.set(NetworkState.ok) }

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
        try? FileManager.default.removeItem(at: root)
    }
}

/// What the stub answers, flipped by the test between passes.
private final class NetworkState: @unchecked Sendable {
    static let ok = BackendStubURLProtocol.Outcome.reply(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(#"{"task_id":"t","deleted_at":"2026-08-30T00:00:00Z","requests_deleted":1}"#.utf8)
    )

    /// What a request answers when the gate was held and nobody opened it. Distinguishable from
    /// `ok`, so a test that mis-counts its `open()` calls fails on its own assertion instead of
    /// hanging — the backstop shape `CLAUDE.md` allows, reachable only by a real failure.
    static let gateNeverOpened = BackendStubURLProtocol.Outcome.failure(URLError(.timedOut))

    private let lock = NSLock()
    private var outcome = NetworkState.ok
    private var gate: DispatchSemaphore?

    var answer: BackendStubURLProtocol.Outcome {
        lock.lock()
        let held = gate
        let next = outcome
        lock.unlock()
        guard let held else { return next }
        return held.wait(timeout: .now() + 30) == .success ? next : Self.gateNeverOpened
    }

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
