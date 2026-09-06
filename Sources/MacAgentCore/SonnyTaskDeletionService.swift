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
    private let accountIdentity: @Sendable () -> String?

    /// **`accountIdentity` is a synchronous seam, and it has to be** (SONNY-404, PR #207's F1).
    ///
    /// Every obligation now carries the account it was pressed under, and the enqueue that records
    /// one runs *before* the local deletes — synchronously, which is the ordering the whole feature
    /// turns on. `SonnyBackendClient` is an `actor`, so `restoredIdentity()` is reachable only
    /// through an `await`, and awaiting it here would make the enqueue asynchronous. SONNY-333
    /// looked at exactly this and dropped the account stamp for that reason; the answer is a
    /// closure the app wires to a synchronous read of the token store rather than to the actor.
    ///
    /// **Required, not defaulted.** A default here would be a fixture silently reading the
    /// developer's own Keychain, which is the hazard `SonnyBackendClient.init`'s own doc calls one
    /// step worse than a defaulted local store.
    public init(
        client: SonnyBackendClient,
        store: PendingServerDeletionStore,
        accountIdentity: @escaping @Sendable () -> String?
    ) {
        self.client = client
        self.store = store
        self.accountIdentity = accountIdentity
    }

    /// The account a press is being made under, right now. `nil` when nobody is signed in.
    public var currentAccountID: String? { accountIdentity() }

    /// Records that this task's server copy is owed, synchronously, before the local records go.
    ///
    /// A thin pass-through to the store, and it is here rather than at the call site so that the
    /// view model holds one collaborator for this feature instead of a store and a service that
    /// have to be kept pointing at the same file.
    public func recordDeletedTask(id: String, deletedAt: Date = Date()) throws {
        try store.enqueue(taskID: id, accountID: accountIdentity(), deletedAt: deletedAt)
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
        try store.remove(taskID: id, accountID: accountIdentity())
    }

    /// Records that several tasks' server copies are owed as **one** obligation (SONNY-404).
    ///
    /// *Command Center › Memory › Task history › Delete* removes every history row at once, and the
    /// founder decided on 2026-09-05 that it queues one bulk call rather than one call per row. One
    /// entry is the same decision at the store: the queue keeps two hundred entries and a history
    /// keeps ten thousand rows, so one entry per row would have the cap drop the difference in
    /// silence — from the single press that asks for the most.
    ///
    /// An empty list records nothing; `PendingServerDeletionStore.enqueue` says why.
    public func recordDeletedTasks(ids: [String], deletedAt: Date = Date()) throws {
        try store.enqueue(
            taskIDs: ids,
            scope: .wholeTask,
            accountID: accountIdentity(),
            deletedAt: deletedAt
        )
    }

    /// Withdraws the obligation `recordDeletedTasks` wrote, because the local delete it was recorded
    /// for did not happen. The pair to it, exactly as `withdrawDeletedTask` is to
    /// `recordDeletedTask`, and for the reason on that method.
    public func withdrawDeletedTasks(ids: [String]) throws {
        try store.remove(PendingServerDeletion(
            // **Trimmed-empty, matching `enqueue`** (PR #207's R3). Filtering on `isEmpty` here while
            // the enqueue filtered on trimmed-empty gave the two different id sets for a
            // whitespace-only id, so the digest differed and the withdrawal missed the entry it was
            // written to remove. Unreachable today — every id is a `UUID().uuidString` — and the two
            // sides of a keyed pair disagreeing about their key is not a thing to leave standing.
            taskIDs: Array(Set(ids.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })),
            scope: .wholeTask,
            accountID: accountIdentity(),
            deletedAt: Date()
        ))
    }

    /// Records that this task's **screenshots** are owed — not the task (SONNY-404).
    ///
    /// *Delete what Sonny did on screen* removes the task's vision-session record and leaves the
    /// task, its command and its result standing. `DELETE /v1/tasks/{task_id}` would take all three
    /// on the server, which is more than the button says, so the founder decided on 2026-09-05 for a
    /// narrower route and this is the obligation that reaches it.
    public func recordDeletedScreenRecord(taskID: String, deletedAt: Date = Date()) throws {
        try store.enqueue(
            taskIDs: [taskID],
            scope: .screenshotsOnly,
            accountID: accountIdentity(),
            deletedAt: deletedAt
        )
    }

    /// The withdrawal pair to `recordDeletedScreenRecord`.
    public func withdrawDeletedScreenRecord(taskID: String) throws {
        try store.remove(PendingServerDeletion(
            taskIDs: [taskID],
            scope: .screenshotsOnly,
            accountID: accountIdentity(),
            deletedAt: Date()
        ))
    }

    // MARK: - Settings' whole wipe (SONNY-404)

    /// Delivers whatever the queue still owes, and says whether it emptied it.
    ///
    /// **This is the drain the founder's decision of 2026-09-04 names**, and its place in the wipe
    /// is *before the queue file is removed*. Everything it fails to deliver is either subsumed by
    /// the account-wide delete that follows it or, in the one case that is neither, abandoned — see
    /// `AgentViewModel.deleteLocalData`, which is where that cost is written down.
    @discardableResult
    public func drainBeforeAWipe() async -> PendingServerDeletionDelivery {
        await deliverPendingDeletions()
    }

    /// The instant a press should be bounded at — **the server's clock, not this Mac's**
    /// (SONNY-404, PR #207's cycle-3, G1).
    ///
    /// The cutoff is compared against `occurred_at` on the gateway's own rows, so a Mac whose clock
    /// is wrong bounds the deletion at the wrong instant. Running behind, the immediate wipe
    /// under-deletes while reporting that the servers' copy is gone; running ahead, the queued
    /// obligation's cutoff sits in the future, which is the over-deletion `?before=` was added to
    /// prevent. `SonnyBackendClient.serverNow()` exists for exactly this (§3.5's offset) and is what
    /// `EntitlementService` and `SonnyAccountService` already read.
    ///
    /// **It is the Mac's clock plus a correction, so it is never unavailable**: with no observation
    /// yet the offset is zero and this is `Date()`, which is what the press used before.
    ///
    /// **The wire truncates it toward the past by up to a second**, deliberately and harmlessly:
    /// §2.1's format carries no fractional seconds, so a bound of `…00.750` goes out as `…00Z`. The
    /// error is always in the under-deleting direction, which is the safe one for a bound whose job
    /// is to stop a delayed delete reaching too far.
    public func instantToBoundAPressAt() async -> Date {
        await client.serverNow()
    }

    /// Deletes everything the gateway retains for this account, leaving the account open.
    ///
    /// **Not queued first and then delivered**, unlike every other delete in this file, because the
    /// wipe has to *know* whether it worked: the words it shows the user differ, and a press that
    /// could not reach the gateway has to say so rather than report a silent success. So this is the
    /// attempt, and the caller records the obligation only when it fails.
    public func deleteEverythingUnderTheAccount(before cutoff: Date) async -> Bool {
        do {
            try await client.deleteAccountContent(before: cutoff)
            return true
        } catch {
            return false
        }
    }

    /// Records that the account's server-side content is still owed, after a wipe could not reach
    /// the gateway. **Names no task**, which is what makes the queue file safe to leave behind.
    ///
    /// **It refuses when nobody is signed in, and that refusal is the fix for a data-loss path**
    /// (PR #207's F1). An obligation that cannot name whose content it is about is an obligation
    /// that deletes whoever's content happens to be there when it is finally delivered — user A
    /// presses the wipe signed out, user B signs in on the same Mac, and B's everything goes.
    /// Nothing is recorded instead, and `deleteLocalData` says so in words the user can act on.
    ///
    /// **`deletedAt` is the press, and the delivery carries it as a cutoff** (`before` on §4.6.3),
    /// so an obligation delivered days later cannot reach content the press never covered.
    ///
    /// Returns whether an obligation was recorded, so the caller's sentence can be true.
    @discardableResult
    public func recordOwedAccountContentDeletion(deletedAt: Date = Date()) throws -> Bool {
        guard let accountID = accountIdentity() else {
            return false
        }
        try store.enqueue(
            taskIDs: [],
            scope: .everythingUnderTheAccount,
            accountID: accountID,
            deletedAt: deletedAt
        )
        return true
    }

    /// Discards every queued obligation that is not this account's, and says how many went
    /// (SONNY-404, PR #207's F1). See `PendingServerDeletionStore.discardObligationsNotBelongingTo`.
    @discardableResult
    public func discardObligationsForOtherAccounts() throws -> Int {
        guard let accountID = accountIdentity() else {
            // Nobody is signed in, so there is no "other account" to be a wrong one: the obligations
            // stay, and the account that owns them delivers them when it signs back in.
            return 0
        }
        return try store.discardObligationsNotBelongingTo(accountID: accountID)
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
            switch await attempt(entry) {
            case .settled:
                delivered += 1
                try? store.remove(entry)
            case .neverDeliverable:
                undeliverable += 1
                try? store.remove(entry)
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

    /// Sends whichever request settles this obligation, and reads its answer under the same four
    /// outcomes (SONNY-404).
    ///
    /// The three shapes and why each takes the route it does:
    ///
    /// - **one task, whole** — `DELETE /v1/tasks/{task_id}`, untouched from SONNY-333. The bulk
    ///   route would serve it, and using it here would rewrite the one delete path this repository
    ///   has already reviewed four times over for a saving of nothing.
    /// - **many tasks, whole** — `DELETE /v1/tasks`, one call. The founder's decision of 2026-09-05.
    /// - **one task, screenshots only** — `DELETE /v1/tasks/{task_id}/screenshots`.
    /// - **the whole account** — `DELETE /v1/account/content`, which names no task and takes
    ///   everything the other two could have named. Settings' wipe leaves this one behind when it
    ///   could not reach the gateway.
    private func attempt(_ entry: PendingServerDeletion) async -> AttemptOutcome {
        guard deliverable(entry) else {
            // Kept, not dropped, and the pass carries on — the same answer §4.6's `404` earns, in
            // the same words: not deliverable by *this* session, never not deliverable.
            return .notThisSession
        }
        switch entry.scope {
        case .wholeTask:
            guard entry.taskIDs.count > 1 else {
                guard let only = entry.taskIDs.first else {
                    // An entry naming nothing. `enqueue` refuses to write one and `loadKeyed` drops
                    // one it reads, so this is unreachable; it settles rather than sticking, because
                    // an obligation about no tasks is one no request could ever discharge.
                    return .settled
                }
                return await attemptDelete(taskID: only)
            }
            return await attemptBulkDelete(taskIDs: entry.taskIDs)
        case .screenshotsOnly:
            guard let only = entry.taskIDs.first else {
                return .settled
            }
            return await attemptScreenshotsDelete(taskID: only)
        case .everythingUnderTheAccount:
            // The press's own instant, carried as the cutoff — see `recordOwedAccountContentDeletion`.
            return await attemptAccountContentDelete(before: entry.deletedAt)
        }
    }

    /// **Whether this session may deliver this obligation at all** (SONNY-404, PR #207's F1).
    ///
    /// Two rules, and the difference between them is which protection each scope already had:
    ///
    /// - **`.everythingUnderTheAccount` requires an exact match.** It carries no task id, so §4.6's
    ///   `404` — the thing that refuses a per-task delete aimed at somebody else's task — has
    ///   nothing to fire on, and the route takes its account from the bearer token. The account
    ///   recorded at the press is the only bound there is, so it is enforced here.
    /// - **A per-task obligation with no account is delivered as before.** That is a file written
    ///   before this field existed, and §4.6's `404` is exactly the protection SONNY-333 designed
    ///   for it and it still works. One with an account is held to it, which is strictly tighter.
    private func deliverable(_ entry: PendingServerDeletion) -> Bool {
        let current = accountIdentity()
        guard let stamped = entry.accountID else {
            return PendingServerDeletion.namesTasks(entry.scope)
        }
        return stamped == current
    }

    /// `DELETE /v1/account/content` — everything this account has stored, account left open.
    ///
    /// **The one obligation whose four outcomes read differently, and only in the `404` arm.** There
    /// is no id on this path, so `resource.not_found` cannot mean "belongs to another account"; if
    /// the gateway ever answered it, it would mean the route is not there, which no future session
    /// changes either. It goes through the shared classifier anyway rather than being special-cased
    /// — `.notThisSession` keeps the entry, which is the safe direction for an obligation about a
    /// user's whole account, and a special case here would be a fourth reading of a taxonomy whose
    /// value is that there are three places it is written and one place it is decided.
    private func attemptAccountContentDelete(before cutoff: Date) async -> AttemptOutcome {
        do {
            try await client.deleteAccountContent(before: cutoff)
            return .settled
        } catch let error as SonnyBackendError {
            return Self.outcome(for: error)
        } catch {
            return .notNow
        }
    }

    /// **`tasks_not_found` is read as the batch's `404`, and the entry is kept whole.**
    ///
    /// §4.6's `404` means "belongs to a different account", which SONNY-333 keeps rather than drops
    /// because a Mac two people have signed into raises it for an entry the other one owes. The
    /// batch says the same thing with a count, so the same rule applies: any foreign id and the
    /// obligation stays.
    ///
    /// **Kept whole rather than narrowed to the ids that were refused**, which the gateway could
    /// have reported and deliberately does not. Narrowing would need a fourth store door that
    /// rewrites an entry mid-pass, and what it would buy is a smaller request on a Mac that is
    /// already re-sending ids the gateway will delete a second time for free. The cost of not
    /// narrowing is one bulk request per launch until the other account signs in — which is exactly
    /// the cost SONNY-333 accepted for the single-task case, in the same words.
    private func attemptBulkDelete(taskIDs: [String]) async -> AttemptOutcome {
        do {
            let outcome = try await client.deleteTasks(ids: taskIDs)
            return outcome.tasksNotFound > 0 ? .notThisSession : .settled
        } catch let error as SonnyBackendError {
            return Self.outcome(for: error)
        } catch {
            return .notNow
        }
    }

    private func attemptScreenshotsDelete(taskID: String) async -> AttemptOutcome {
        do {
            try await client.deleteTaskScreenshots(id: taskID)
            return .settled
        } catch let error as SonnyBackendError {
            return Self.outcome(for: error)
        } catch {
            return .notNow
        }
    }

    /// The four-outcome classification, in one place so the three routes cannot drift apart
    /// (SONNY-404). Every sentence justifying it is on `deliverPendingDeletions()`.
    private static func outcome(for error: SonnyBackendError) -> AttemptOutcome {
        switch error {
        case .api(let api) where api.code == .resourceNotFound:
            return .notThisSession
        case .api(let api) where api.code == .requestInvalid:
            return .neverDeliverable
        default:
            return .notNow
        }
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
            return Self.outcome(for: error)
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
