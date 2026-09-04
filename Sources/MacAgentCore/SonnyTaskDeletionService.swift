import Foundation

/// What one pass over the queue did (SONNY-333).
///
/// Counts rather than the ids themselves: nothing renders this, and a type that carried the ids
/// would be a second place a deleted task's key could be read from.
public struct PendingServerDeletionDelivery: Equatable, Sendable {
    /// The server confirmed the delete — including the `requests_deleted: 0` it answers for a task
    /// it never stored, which is a success and is contract §4.6's most deliberate rule.
    public var delivered: Int
    /// Still owed after this pass: the network, the session or the gateway was not there.
    public var stillOwed: Int
    /// Dropped because no future attempt could ever succeed. See `deliverPendingDeletions()`.
    public var undeliverable: Int
    /// Whether the pass stopped before reaching every entry. True whenever a failure was about the
    /// session or the transport rather than about one task.
    public var stoppedEarly: Bool

    public init(delivered: Int, stillOwed: Int, undeliverable: Int, stoppedEarly: Bool) {
        self.delivered = delivered
        self.stillOwed = stillOwed
        self.undeliverable = undeliverable
        self.stoppedEarly = stoppedEarly
    }

    public static let nothingOwed = PendingServerDeletionDelivery(
        delivered: 0,
        stillOwed: 0,
        undeliverable: 0,
        stoppedEarly: false
    )
}

/// The other half of "delete means deleted everywhere" (SONNY-333, contract §4.6).
///
/// `DELETE /v1/tasks/{task_id}` has existed since SONNY-134 and removes the account's retained
/// content for a task and every training-snapshot member copied from it. Nothing in the Mac app
/// called it, so the founder decision of 2026-08-16 was true of the endpoint and not of the button.
/// This is the thing that presses it.
///
/// **A service of its own rather than a method on `SonnyAccountService`.** That type's own comment
/// justifies carrying the billing-portal call because "there is nothing else to it" — one
/// authenticated `POST` returning a URL. This is not that: it owns a durable queue, a delivery pass
/// with four outcomes, and the rule for which failures are permanent. It is also not account-shaped
/// at all; it is task-shaped, and putting it beside the three auth calls would make "the auth
/// service" a name that had stopped being true.
///
/// **A struct over the shared `SonnyBackendClient`, never a second client.** Two clients in one
/// process is two token caches and two single-flight refresh guards, and the gateway reads a second
/// rotation inside its ten-second overlap as a stolen token and revokes the family (contract §3.3).
/// The same rule `main.swift` states for the account model and the view model.
public struct SonnyTaskDeletionService: Sendable {
    private let client: SonnyBackendClient
    private let store: PendingServerDeletionStore

    public init(client: SonnyBackendClient, store: PendingServerDeletionStore) {
        self.client = client
        self.store = store
    }

    /// Records that this task's server copy is owed, synchronously, before the local records go.
    ///
    /// A thin pass-through to the store, and it is here rather than at the call site so that the
    /// view model holds one collaborator for this feature instead of a store and a service that
    /// have to be kept pointing at the same file.
    public func recordDeletedTask(id: String, deletedAt: Date = Date()) throws {
        try store.enqueue(taskID: id, deletedAt: deletedAt)
    }

    /// Withdraws an obligation recorded a moment ago, because the local delete it was recorded for
    /// did not happen (PR #194 review, F1's symmetric half).
    ///
    /// **The pair to `recordDeletedTask`, and the reason `deleteTask` can now move the obligation
    /// and the local records together or not at all.** (Not "all-or-nothing" flatly: the three local
    /// deletes are three files in sequence with no transaction, and `deleteTask`'s own comment says
    /// what that leaves — PR #194 cycle-3, R3.)
    /// The enqueue runs first so that a crash between the two steps errs towards deleting; a local
    /// delete that *throws* is different from a crash, because there is somewhere to put the
    /// correction. Without this, an entry written for a delete that then failed would have the next
    /// launch's sweep remove the server's copy of a task still sitting in the user's history, after
    /// they were told the delete had not happened — content taken on the strength of a press that
    /// visibly did not work.
    public func withdrawDeletedTask(id: String) throws {
        try store.remove(taskID: id)
    }

    /// What is still owed, oldest first. Read by tests and by nothing in the product — the queue has
    /// no surface, deliberately, and `PendingServerDeletionStore` says why.
    public func pendingDeletions() throws -> [PendingServerDeletion] {
        try store.loadAll()
    }

    /// One pass over the queue: send each owed delete, forget the ones that are settled.
    ///
    /// **Never throws.** Every caller is a background pass the user did not ask for — the launch
    /// sweep, and the attempt fired after a delete lands — so there is nobody to report to and
    /// nothing to report that they could act on. That is the founders' decision of 2026-08-30 in
    /// this method's shape: the failure is recorded for a later sweep rather than surfaced, because
    /// a failed backend delete is not something a person can do anything about, and the 2026-08-16
    /// rule is satisfied by the retry succeeding rather than by the first attempt succeeding.
    ///
    /// ## Which failures are permanent, and which are only now
    ///
    /// The queue's whole hazard is an entry that can never be delivered and is retried forever, so
    /// each answer is classified rather than lumped:
    ///
    /// - **`200`** — delivered. The entry goes. This covers the case §4.6 is most deliberate about:
    ///   a task the gateway never stored, from an incognito run or from before the user signed in,
    ///   answers `200` with `requests_deleted: 0` and not a `404`. The body is not decoded, because
    ///   nothing on this Mac consumes `requests_deleted` and decoding a field no caller reads
    ///   invites a later one to cache on it (`SonnyAccountService`'s own reasoning for the portal
    ///   response's `expires_at`).
    /// - **`404 resource.not_found`** — kept, and this is the one that could reasonably go the other
    ///   way. §4.6 reserves that code for a `task_id` belonging to a *different* account, so it says
    ///   "not deliverable by this session", never "not deliverable". A Mac that two people have
    ///   signed into can raise it for an entry the other one owes, and dropping it there would lose
    ///   an obligation for good. The cost of keeping it is one request per launch until the right
    ///   account signs in, bounded by `PendingServerDeletionStore.maxItems`.
    /// - **`400 request.invalid`** — dropped. The gateway will not accept this id in any session, so
    ///   every future attempt is the same request getting the same answer. This is the one place an
    ///   entry is abandoned on purpose, and it is unreachable in practice: `task_id`s are minted by
    ///   `AgentViewModel.beginNewTaskIdentity()` as `UUID().uuidString`, which is inside §4.6's
    ///   parameter shape by construction.
    /// - **anything else** — kept. Offline, a transport timeout, no session, a gateway that is not
    ///   configured, a 5xx, a rate limit: all of them are "not now", and the next launch tries
    ///   again.
    ///
    /// ## Why a session or transport failure stops the pass
    ///
    /// Those failures are about the client rather than about one task, so every remaining entry is
    /// going to meet the same one. Carrying on would spend the route's whole timeout per entry — up
    /// to two hundred of them — on a machine that has just been shown to have no network. A failure
    /// that *is* about one task (`404`, `400`) does not stop the pass, because the entry behind it
    /// may be perfectly deliverable.
    @discardableResult
    public func deliverPendingDeletions() async -> PendingServerDeletionDelivery {
        let owed: [PendingServerDeletion]
        do {
            owed = try store.loadAll()
        } catch {
            // An unreadable queue file. Nothing here can be delivered and nothing here can be
            // repaired by trying, so this reports the honest nothing rather than a failure the
            // caller has no channel for. The file is still reachable by Settings' wipe, and
            // `AgentViewModel.refreshStoreReadability()` still sees it as unreadable.
            return .nothingOwed
        }
        guard !owed.isEmpty else {
            return .nothingOwed
        }

        var delivered = 0
        var undeliverable = 0
        var stoppedEarly = false

        // Labelled, because `break` inside a `switch` leaves the `switch` and not the loop — and
        // this is precisely the shape where that mistake reads as working code that quietly keeps
        // going after it was told to stop.
        pass: for entry in owed {
            switch await attemptDelete(taskID: entry.taskID) {
            case .settled:
                delivered += 1
                try? store.remove(taskID: entry.taskID)
            case .neverDeliverable:
                undeliverable += 1
                try? store.remove(taskID: entry.taskID)
            case .notThisSession:
                // Kept, and the pass carries on: this is about the account rather than the network.
                continue
            case .notNow:
                stoppedEarly = true
                break pass
            }
        }

        return PendingServerDeletionDelivery(
            delivered: delivered,
            stillOwed: owed.count - delivered - undeliverable,
            undeliverable: undeliverable,
            stoppedEarly: stoppedEarly
        )
    }

    private enum AttemptOutcome {
        /// The server has answered about this task. Nothing more is owed.
        case settled
        /// No session will ever get a different answer for this entry.
        case neverDeliverable
        /// This account cannot deliver it; another one may.
        case notThisSession
        /// The network, the session or the gateway. Every remaining entry meets the same thing.
        case notNow
    }

    private func attemptDelete(taskID: String) async -> AttemptOutcome {
        do {
            _ = try await client.send(SonnyBackendRequest(
                method: "DELETE",
                path: Self.path(forTaskID: taskID),
                body: nil,
                authentication: .bearer,
                // §9.3: "yes" — naturally idempotent, and the only row in that table that says yes
                // without "with the same key". A second delete succeeds with `requests_deleted: 0`,
                // so there is no lost first response for a key to stand in for.
                idempotencyKey: nil,
                // §12's `auth, account, meta, health, delete` row, which this client's timeout table
                // already carries and which named this route before anything sent it.
                timeout: SonnyBackendTimeouts.auth,
                isRetrySafe: true
            ))
            return .settled
        } catch let error as SonnyBackendError {
            switch error {
            case .api(let api) where api.code == .resourceNotFound:
                return .notThisSession
            case .api(let api) where api.code == .requestInvalid:
                return .neverDeliverable
            default:
                return .notNow
            }
        } catch {
            // `send` throws `SonnyBackendError` and nothing else, so this arm is unreachable. It
            // answers "not now" rather than dropping the entry, because an unrecognised failure is
            // the one case where abandoning an obligation would be least defensible.
            return .notNow
        }
    }

    /// `/v1/tasks/{task_id}` with the id percent-encoded.
    ///
    /// Encoded even though every id this app mints is a `UUID().uuidString`, which needs no
    /// encoding: the queue is a file, a file survives across versions, and a path assembled by
    /// interpolation is how a value that is not what it used to be becomes a different request.
    static func path(forTaskID taskID: String) -> String {
        let encoded = taskID.addingPercentEncoding(withAllowedCharacters: .sonnyPathSegment) ?? taskID
        return "/v1/tasks/\(encoded)"
    }
}

private extension CharacterSet {
    /// RFC 3986's `pchar` minus the sub-delimiters that would read as structure in a path segment.
    /// `urlPathAllowed` cannot be used directly: it permits `/`, which is exactly the character a
    /// task id must not be able to contribute to a path.
    static let sonnyPathSegment = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
