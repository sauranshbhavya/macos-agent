import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// The delivery pass that makes "delete means deleted everywhere" true of the button (SONNY-333).
///
/// The four outcomes are the whole of this type's design, so each has a test of its own: what is
/// delivered, what is kept because *this* session cannot deliver it, what is dropped because no
/// session ever could, and what stops the pass instead of being retried two hundred times against a
/// machine that has just been shown to have no network.
@Suite
@MainActor
struct SonnyTaskDeletionServiceTests {
    /// One signed-in account for the whole suite. Every obligation carries the account it was
    /// pressed under since SONNY-404's second fix round; these tests are about the delivery pass's
    /// four outcomes rather than about who pressed, so they all run under one.
    private nonisolated static let account = "account-a"

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonny-deletion-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeStore(at root: URL) -> PendingServerDeletionStore {
        PendingServerDeletionStore(fileURL: root.appendingPathComponent("pending-server-deletions.json"))
    }

    private static let epoch = Date(timeIntervalSince1970: 1_772_000_000)


    // MARK: - The wire

    /// §4.6's request, exactly: the verb, the path, the session, and no idempotency key.
    ///
    /// **No key is the assertion worth having here.** §9.3's table gives every other mutating route
    /// "yes, with the same key" and gives this one a bare "yes" — the delete is naturally
    /// idempotent, a second one succeeds with `requests_deleted: 0`, so there is no lost first
    /// response for a stored one to stand in for. A key would also make a retry replay the *first*
    /// answer, which is the one behaviour a delete must not have.
    @Test
    func aQueuedDeletionIsSentAsAnAuthenticatedDeleteOnTheTasksPath() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = SignedInBackendFixture()
        defer { backend.unregister() }
        let seen = RecordedBackendRequests()
        backend.register { request in
            seen.append(request)
            return DeletionStubReplies.deleted
        }
        let store = makeStore(at: root)
        let service = SonnyTaskDeletionService(client: backend.client, store: store, accountIdentity: { Self.account })
        try service.recordDeletedTask(id: "task-a", deletedAt: Self.epoch)

        let outcome = await service.deliverPendingDeletions()

        let request = try seen.only
        #expect(request.method == "DELETE")
        #expect(request.path == "/v1/tasks/task-a")
        #expect(request.authorization == "Bearer test-access-token")
        #expect(request.idempotencyKey == nil)
        #expect(outcome == PendingServerDeletionDelivery(
            delivered: 1,
            stillOwed: 0,
            undeliverable: 0,
            stoppedEarly: false
        ))
        #expect(try store.loadAll().isEmpty)
    }

    /// An id that is not a bare `UUID` cannot contribute structure to the path.
    ///
    /// Unreachable through the product today — `beginNewTaskIdentity()` mints
    /// `UUID().uuidString` — and asserted anyway, because the queue is a *file*: it outlives the
    /// version that wrote it, and a path assembled by interpolation is how a value that stopped
    /// being what it used to be becomes a different request.
    @Test
    func aTaskIDIsPercentEncodedIntoThePathRatherThanInterpolated() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = SignedInBackendFixture()
        defer { backend.unregister() }
        let seen = RecordedBackendRequests()
        backend.register { request in
            seen.append(request)
            return DeletionStubReplies.deleted
        }
        let service = SonnyTaskDeletionService(client: backend.client, store: makeStore(at: root), accountIdentity: { Self.account })
        try service.recordDeletedTask(id: "a/../v1/account", deletedAt: Self.epoch)

        _ = await service.deliverPendingDeletions()

        // `URLRequest.url?.path` decodes, so the escaping is asserted on the function that builds
        // the string rather than on what the stub sees decoded back.
        #expect(SonnyTaskDeletionService.path(forTaskID: "a/../v1/account") == "/v1/tasks/a%2F..%2Fv1%2Faccount")
        #expect(try seen.only.path.hasPrefix("/v1/tasks/"))
    }

    @Test
    func anEmptyQueueMakesNoRequestAtAll() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = SignedInBackendFixture()
        defer { backend.unregister() }
        let seen = RecordedBackendRequests()
        backend.register { request in
            seen.append(request)
            return DeletionStubReplies.deleted
        }
        let service = SonnyTaskDeletionService(client: backend.client, store: makeStore(at: root), accountIdentity: { Self.account })

        let outcome = await service.deliverPendingDeletions()

        #expect(seen.all.isEmpty)
        #expect(outcome == .nothingOwed)
    }

    // MARK: - The four outcomes

    /// **§4.6's most deliberate rule, from this side.** A task the gateway never stored — an
    /// incognito run, or one that ran before the user signed in — answers `200` with
    /// `requests_deleted: 0` rather than a `404`, because a delete that is already true must not
    /// surface as something the user has to interpret. So the entry goes, exactly as it does for a
    /// task that really had content.
    @Test
    func aTaskTheServerNeverStoredIsDeliveredRatherThanRetried() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = SignedInBackendFixture()
        defer { backend.unregister() }
        backend.register { _ in
            DeletionStubReplies.reply(200, #"{"task_id":"t","deleted_at":"2026-08-30T00:00:00Z","requests_deleted":0}"#)
        }
        let store = makeStore(at: root)
        let service = SonnyTaskDeletionService(client: backend.client, store: store, accountIdentity: { Self.account })
        try service.recordDeletedTask(id: "never-stored", deletedAt: Self.epoch)

        let outcome = await service.deliverPendingDeletions()

        #expect(outcome.delivered == 1)
        #expect(try store.loadAll().isEmpty)
    }

    /// **A `404` keeps the entry, and the pass carries on.**
    ///
    /// §4.6 reserves `resource.not_found` for a `task_id` belonging to a *different* account, so it
    /// says "not deliverable by this session" and never "not deliverable". A Mac two people have
    /// signed into can raise it for an entry the other one owes, and dropping it there would lose an
    /// obligation permanently. Carrying on to the next entry is the other half: this failure is
    /// about the account, not about the network, so the entry behind it may be perfectly
    /// deliverable — which is what the second id here checks.
    @Test
    func aTaskBelongingToAnotherAccountIsKeptAndTheRestOfTheQueueStillGoes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = SignedInBackendFixture()
        defer { backend.unregister() }
        backend.register { request in
            if request.url?.path == "/v1/tasks/someone-elses" {
                return DeletionStubReplies.reply(404, #"{"error":{"code":"resource.not_found","message":"No such task for this account.","request_id":"r"}}"#)
            }
            return DeletionStubReplies.deleted
        }
        let store = makeStore(at: root)
        let service = SonnyTaskDeletionService(client: backend.client, store: store, accountIdentity: { Self.account })
        try service.recordDeletedTask(id: "someone-elses", deletedAt: Self.epoch)
        try service.recordDeletedTask(id: "mine", deletedAt: Self.epoch.addingTimeInterval(60))

        let outcome = await service.deliverPendingDeletions()

        #expect(outcome == PendingServerDeletionDelivery(
            delivered: 1,
            stillOwed: 1,
            undeliverable: 0,
            stoppedEarly: false
        ))
        #expect(try store.loadAll().flatMap(\.taskIDs) == ["someone-elses"])
    }

    /// **A `400 request.invalid` is the one answer that abandons an entry, and it is the only one.**
    ///
    /// The gateway will not accept this id in any session, so every future attempt is the same
    /// request getting the same answer — which is the unbounded retry the queue's cap exists to
    /// bound and this branch exists not to need.
    @Test
    func anIDTheGatewayWillNeverAcceptIsDroppedRatherThanRetriedForever() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = SignedInBackendFixture()
        defer { backend.unregister() }
        backend.register { _ in
            DeletionStubReplies.reply(400, #"{"error":{"code":"request.invalid","message":"A task identifier is required.","request_id":"r"}}"#)
        }
        let store = makeStore(at: root)
        let service = SonnyTaskDeletionService(client: backend.client, store: store, accountIdentity: { Self.account })
        try service.recordDeletedTask(id: "malformed", deletedAt: Self.epoch)

        let outcome = await service.deliverPendingDeletions()

        #expect(outcome == PendingServerDeletionDelivery(
            delivered: 0,
            stillOwed: 0,
            undeliverable: 1,
            stoppedEarly: false
        ))
        #expect(try store.loadAll().isEmpty)
    }

    /// **A gateway failure keeps the entry and stops the pass.**
    ///
    /// Stopping is the assertion worth having: three entries, one request. Carrying on would spend
    /// the route's whole twenty-second budget per entry — up to two hundred of them — against a
    /// gateway that has just said it cannot serve one.
    @Test
    func aServerFailureKeepsEverythingAndStopsAfterTheFirstAttempt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = SignedInBackendFixture()
        defer { backend.unregister() }
        let seen = RecordedBackendRequests()
        backend.register { request in
            seen.append(request)
            return DeletionStubReplies.reply(503, #"{"error":{"code":"server.unavailable","message":"Try later.","request_id":"r"}}"#)
        }
        let store = makeStore(at: root)
        let service = SonnyTaskDeletionService(client: backend.client, store: store, accountIdentity: { Self.account })
        for index in 0..<3 {
            try service.recordDeletedTask(id: "task-\(index)", deletedAt: Self.epoch.addingTimeInterval(Double(index)))
        }

        let outcome = await service.deliverPendingDeletions()

        #expect(outcome.delivered == 0)
        #expect(outcome.stillOwed == 3)
        #expect(outcome.stoppedEarly)
        #expect(try store.loadAll().count == 3)
        // One entry attempted, not three. `server.unavailable` is retryable, so the client spends
        // that entry's own attempt budget on it — what this pins is that the *queue* does not then
        // walk the other two.
        #expect(Set(seen.all.map(\.path)) == ["/v1/tasks/task-0"])
    }

    /// Signed out. Nothing is sent and nothing is lost — the founders' 2026-08-30 decision in its
    /// most literal case, since a task deleted while signed out has no way to reach the server at
    /// all and the retry is the entire mechanism that keeps the 2026-08-16 promise.
    @Test
    func aSignedOutMacQueuesTheDeletionAndSendsNothing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = BackendStubURLProtocol.makeSession()
        let seen = RecordedBackendRequests()
        BackendStubURLProtocol.register(host: stub.host) { request in
            seen.append(request)
            return DeletionStubReplies.deleted
        }
        defer { BackendStubURLProtocol.unregister(host: stub.host) }
        // Configured, so nothing is refused for want of a base URL — and with an empty Keychain, so
        // the only thing missing is the session.
        let client = makeHermeticBackendClient(
            environment: SonnyBackendEnvironment(baseURL: stub.baseURL, source: .debugOverride),
            session: stub.session
        )
        let store = makeStore(at: root)
        let service = SonnyTaskDeletionService(client: client, store: store, accountIdentity: { Self.account })
        try service.recordDeletedTask(id: "task-a", deletedAt: Self.epoch)

        let outcome = await service.deliverPendingDeletions()

        #expect(seen.all.isEmpty)
        #expect(outcome.stillOwed == 1)
        #expect(outcome.stoppedEarly)
        #expect(try store.loadAll().flatMap(\.taskIDs) == ["task-a"])
    }

    /// Offline, then online. The whole point of the queue, end to end.
    @Test
    func aDeletionQueuedWhileOfflineIsDeliveredByTheNextPass() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = SignedInBackendFixture()
        defer { backend.unregister() }
        let offline = OneShotSwitch()
        backend.register { _ in
            offline.isOn ? .failure(URLError(.notConnectedToInternet)) : DeletionStubReplies.deleted
        }
        let store = makeStore(at: root)
        let service = SonnyTaskDeletionService(client: backend.client, store: store, accountIdentity: { Self.account })
        try service.recordDeletedTask(id: "task-a", deletedAt: Self.epoch)

        offline.turnOn()
        let whileOffline = await service.deliverPendingDeletions()
        #expect(whileOffline.stillOwed == 1)
        #expect(try store.loadAll().flatMap(\.taskIDs) == ["task-a"])

        offline.turnOff()
        let whenBack = await service.deliverPendingDeletions()
        #expect(whenBack.delivered == 1)
        #expect(try store.loadAll().isEmpty)
    }

    /// An unreadable queue file reports nothing owed rather than throwing at a caller that has no
    /// channel to report through. The store itself still throws —
    /// `PendingServerDeletionStoreTests.anUnreadableFileThrowsRatherThanReadingAsEmpty` — which is
    /// what `AgentViewModel.refreshStoreReadability()` reads.
    @Test
    func anUnreadableQueueDeliversNothingAndDoesNotThrow() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(at: root)
        try Data("not this store's bytes".utf8).write(to: store.fileURL, options: .atomic)
        let backend = SignedInBackendFixture()
        defer { backend.unregister() }
        let seen = RecordedBackendRequests()
        backend.register { request in
            seen.append(request)
            return DeletionStubReplies.deleted
        }

        let outcome = await SonnyTaskDeletionService(client: backend.client, store: store, accountIdentity: { Self.account })
            .deliverPendingDeletions()

        #expect(outcome == .nothingOwed)
        #expect(seen.all.isEmpty)
    }
}

/// A flag a `@Sendable` stub handler can read while the test flips it.
private final class OneShotSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isOn: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func turnOn() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func turnOff() {
        lock.lock()
        value = false
        lock.unlock()
    }
}

/// Replies the stub handlers hand back.
///
/// Outside the suite because the suite is `@MainActor` and a `URLProtocol` handler is a
/// `@Sendable` closure running on URLSession's own threads — statics on a main-actor type cannot be
/// read from one, which is the compiler telling the truth about where these are used.
private enum DeletionStubReplies {
    static func reply(_ statusCode: Int, _ body: String) -> BackendStubURLProtocol.Outcome {
        .reply(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8)
        )
    }

    static let deleted = reply(
        200,
        #"{"task_id":"t","deleted_at":"2026-08-30T00:00:00Z","requests_deleted":3}"#
    )
}
