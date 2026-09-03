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

    /// **The queue write goes before the local deletes, and this is what pins it.**
    ///
    /// The vision journal here holds bytes that will not decode, so the *first* local delete throws
    /// and `deleteTask` returns early with an error. The id is queued anyway — which is only true if
    /// the enqueue ran first. Move it below the local block and this test fails, because nothing
    /// after the `catch`'s `return` runs.
    ///
    /// The ordering matters because the two half-failures are not symmetric. This one leaves a task
    /// the user can still see and delete again. The other — local records gone, nothing queued —
    /// destroys the only remaining name for the server's copy, permanently and silently.
    @Test
    func aLocalDeleteThatFailsStillLeavesTheServerDeleteOwed() async throws {
        let fixture = try TaskDeletionFixture()
        defer { fixture.tearDown() }
        let record = try fixture.writeTaskRecord(id: "task-a", visionSessionID: "session-a")
        try Data("not this store's bytes".utf8).write(
            to: fixture.root.appendingPathComponent("vision-sessions.json"),
            options: .atomic
        )

        fixture.viewModel.deleteTask(record)

        // The user is told the delete failed — it did, locally, which is the half they can act on.
        #expect(fixture.viewModel.errorMessage != nil)
        // And the server's copy is still owed rather than orphaned.
        #expect(try fixture.viewModel.pendingServerDeletionsForTests().map(\.taskID) == ["task-a"])
    }

    /// **A failed queue write is a notice, never `errorMessage`.**
    ///
    /// `errorMessage` means "the thing you asked for did not happen", and the widget renders
    /// `.failure` ahead of `.result` — so routing a bookkeeping failure there replaces the result of
    /// a task that ran and succeeded. That is CLAUDE.md's channel rule, and the defect it names
    /// arrived twice by other doors (PR #89's F4 and SONNY-201). It would also be untrue here: by
    /// the time anything is on screen the row and its dependents are gone, which is what the user
    /// pressed for.
    ///
    /// The queue is made unwritable by putting a *file* where its directory would be, so
    /// `createDirectory` fails and the store cannot write.
    @Test
    func aQueueWriteThatFailsIsANoticeAndTheLocalDeleteStillHappens() async throws {
        let fixture = try TaskDeletionFixture(queueInsideAFile: true)
        defer { fixture.tearDown() }
        let record = try fixture.writeTaskRecord(id: "task-a")

        fixture.viewModel.deleteTask(record)

        #expect(fixture.viewModel.errorMessage == nil)
        let notice = try #require(fixture.viewModel.localStorageNotice)
        #expect(notice.contains("deleted from your account"))
        // The local half still happened: this failure must not stop the button working.
        #expect(fixture.viewModel.taskHistoryRecords.isEmpty)
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
        let record = CompletedTaskRecord(
            id: id,
            command: "do the thing",
            startedAt: Date(timeIntervalSince1970: 1_772_000_000),
            completedAt: Date(timeIntervalSince1970: 1_772_000_060),
            outcomeStatus: .completed,
            visionSessionID: visionSessionID
        )
        _ = try store.record(record)
        viewModel.refreshTaskHistory()
        return try #require(viewModel.taskHistoryRecords.first)
    }

    func goOffline() { network.set(.failure(URLError(.notConnectedToInternet))) }

    func comeBackOnline() { network.set(NetworkState.ok) }

    /// A gateway that never answers, so the delivery pass is provably still in flight while the
    /// assertions about the button run.
    func holdTheGateway() { network.set(.hang) }

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

    private let lock = NSLock()
    private var outcome = NetworkState.ok

    var answer: BackendStubURLProtocol.Outcome {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    func set(_ next: BackendStubURLProtocol.Outcome) {
        lock.lock()
        outcome = next
        lock.unlock()
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
