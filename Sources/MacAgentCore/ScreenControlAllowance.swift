import Foundation

/// **How many screen-control runs are left this month** — the one number the product asks a user to
/// track, read from the gateway (SONNY-212).
///
/// SONNY-17 fixed the user-facing unit and the founders re-affirmed it on 2026-08-31 against the one
/// case that had been written down as contradicting it: a standing watcher's repeated checks, which
/// SONNY-236 had recorded as drawing on the same allowance. That went the other way — **watchers are
/// free and capped instead** — so screen control stays the only line that draws and this stays a
/// single number rather than a pool two different things spend out of.
///
/// **This type reads and does nothing else.** Rendering it is SONNY-214's and refusing on it is
/// SONNY-213's; neither decision is taken here, and neither belongs in a type whose whole job is to
/// carry a figure the server derived.
public struct ScreenControlAllowance: Sendable, Equatable {
    /// The plan the server applied — its own, or the catalogue's default for an account with none.
    /// Opaque here: this build knows no plan keys and must not learn any.
    public let plan: String
    /// The number a user sees. Never negative; the server floors it.
    public let runsLeft: Int
    /// What a full period on this plan is worth, in runs — the denominator of "3 of 20 left".
    public let runsIncluded: Int
    /// **What is left in credits, which is not the same question as ``runsLeft`` and is never shown
    /// to anybody** (SONNY-213, PR #190's F1).
    ///
    /// `runsLeft` is `floor(remaining / runCredits)`: how many *whole further runs* the account can
    /// afford. That is the right question at a session's door and the wrong one at a step boundary,
    /// because a session in flight has already had its own iterations subtracted from `remaining` —
    /// so an account admitted on its last run reads `0` at the very next boundary and would be
    /// halted for spending the run it was just granted. The boundary's question is whether the
    /// account has actually *run out*, which is this figure.
    ///
    /// **Reading it is not a second number in the product**, which is what
    /// ``WireScreenControlAllowance``'s own note guards against: nothing renders this, SONNY-214's
    /// surface still shows one number, and the two cannot disagree — the gateway derives `runsLeft`
    /// from this very value, rounding before the floor precisely so that a reader recomputing the
    /// run count from the credits beside it gets the same answer (`balance.ts`'s `runsFrom`).
    public let creditsRemaining: Double
    /// The period this figure is about. `periodEnd` is exclusive.
    public let periodStart: Date
    public let periodEnd: Date
    /// Whether more runs can be bought when these run out, and whether the user asked for that
    /// (SONNY-215).
    public let autoTopUp: ScreenControlAutoTopUp

    public init(
        plan: String,
        runsLeft: Int,
        runsIncluded: Int,
        creditsRemaining: Double,
        periodStart: Date,
        periodEnd: Date,
        autoTopUp: ScreenControlAutoTopUp
    ) {
        self.plan = plan
        self.runsLeft = runsLeft
        self.runsIncluded = runsIncluded
        self.creditsRemaining = creditsRemaining
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.autoTopUp = autoTopUp
    }
}

/// The auto-top-up setting, as the gateway reports it (SONNY-215).
///
/// **Two booleans and not one, because they are different facts with different owners.**
/// ``isOffered`` is the deployment's — a pack is configured and this gateway can charge — and
/// ``isOptedIn`` is the user's. Collapsing them would make "nothing to sell" and "you said no" the
/// same state, and the product does opposite things with them: the first renders no control at all,
/// and the second renders one that is off.
public struct ScreenControlAutoTopUp: Sendable, Equatable {
    /// Whether this deployment sells more runs at all. `false` renders no control — a control that
    /// only fails when pressed is a broken control (founder direction, 2026-08-31).
    public let isOffered: Bool
    /// Whether this account asked for automatic purchases. **`false` is the default and the
    /// gateway's absence of a consent row is what produces it.**
    public let isOptedIn: Bool
    /// How many purchases this period may still make. `0` once the gateway's bound is spent.
    ///
    /// **Read by the gate and never rendered.** It is what lets a session skip a request the server
    /// would refuse anyway; putting it on a surface would be a second number beside the run count,
    /// which is what the one-paid-line decision exists to prevent.
    public let attemptsLeft: Int

    /// The state a build gets before it has read anything. **Nothing offered and nothing agreed** —
    /// fail-closed in both directions, so a decoding path that lost this field could not turn the
    /// feature on.
    public static let none = ScreenControlAutoTopUp(isOffered: false, isOptedIn: false, attemptsLeft: 0)

    public init(isOffered: Bool, isOptedIn: Bool, attemptsLeft: Int) {
        self.isOffered = isOffered
        self.isOptedIn = isOptedIn
        self.attemptsLeft = attemptsLeft
    }

    /// Whether a session that has just run out should ask the gateway to buy more.
    ///
    /// **All three, and the first one is the whole of this ticket's hard requirement.** The gateway
    /// refuses independently on every one of them — this is the client half, and it exists so a
    /// user who has not opted in never has a request made on their behalf at all, not because the
    /// refusal needs help.
    public var mayPurchase: Bool {
        isOffered && isOptedIn && attemptsLeft > 0
    }
}

/// Fetches the allowance. One request, no cache, no store.
///
/// ## Why there is no cache here, and why that is the opposite call to `EntitlementService`'s
///
/// That service caches deliberately and honours a claim for up to four days past its issue, because
/// an entitlement changes on the order of a subscription and the guarantee it carries — §16.3's — is
/// that a user with no network is not locked out. **A run count is the opposite kind of number.** It
/// changes on the order of a run, so a stored one is wrong most of the time it is read, and wrong in
/// the direction that matters: showing runs to somebody who has none. Nothing here writes to a local
/// store, which also keeps this type out of `LocalStore.allCases` and the six enrolments a new store
/// owes.
///
/// **A failure is a failure and never a number.** There is no fallback figure, because every
/// candidate is a lie: zero locks a user out of a feature they have paid for, and any positive
/// number promises runs the server never granted. The caller decides what to show when this throws,
/// and SONNY-214 built that surface: `AgentViewModel.refreshScreenControlAllowance()` is the one
/// caller in the app, it catches into `nil`, and both surfaces render no line at all on `nil` —
/// no placeholder, no zero, and no sentence about why. (This said the only caller was a test, which
/// SONNY-214 made false and PR #188's F8 caught.)
public actor ScreenControlAllowanceService {
    private let client: SonnyBackendClient

    /// No default, the same hazard `EntitlementService` and `SonnyBackendClient` both record: every
    /// packaged build on a Mac shares one Keychain, so a fixture that inherited a default client
    /// would read the founder's own session.
    public init(client: SonnyBackendClient) {
        self.client = client
    }

    /// Ask the gateway how many runs are left, or throw.
    public func fetch() async throws -> ScreenControlAllowance {
        let response = try await client.send(SonnyBackendRequest(
            method: "GET",
            path: Self.creditsPath,
            body: nil,
            authentication: .bearer,
            idempotencyKey: nil,
            // The auth budget rather than a route budget: this opens no provider call, so it is a
            // database read and a signature check, exactly like the entitlement claim beside it.
            timeout: SonnyBackendTimeouts.auth,
            // A `GET` that changes nothing, and it carries no idempotency key for the same reason —
            // there is nothing for one to be about. §9.3's own reading of what is safe to send again.
            isRetrySafe: true
        ))
        return try Self.decode(response.data)
    }

    /// Turn automatic top-ups on or off, and read back the position that follows (SONNY-215).
    ///
    /// **The setting lives on the gateway and not in a local default**, which is the decision this
    /// method is. The charge happens server-side, so the consent the charge is authorised by has to
    /// be a fact the gateway holds: a `UserDefaults` flag would be a consent the thing doing the
    /// charging could not read, and the negative requirement — no charge without the opt-in — would
    /// then rest on a client being honest about it.
    ///
    /// **A `PUT` and not a `POST`, so it carries no idempotency key and needs none**: sending it
    /// twice leaves the same setting, which is what idempotent means, and §9.1 asks for a key on a
    /// `POST` that changes something precisely because those are the ones a repeat can double.
    public func setAutoTopUp(_ enabled: Bool) async throws -> ScreenControlAllowance {
        let body = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
        let response = try await client.send(SonnyBackendRequest(
            method: "PUT",
            path: "/v1/account/credits/auto-top-up",
            body: body,
            authentication: .bearer,
            idempotencyKey: nil,
            timeout: SonnyBackendTimeouts.auth,
            // Setting a switch to a value is safe to send again: the second send reaches the same
            // state as the first.
            isRetrySafe: true
        ))
        return try Self.decode(response.data)
    }

    /// Ask the gateway to buy one more pack of runs, and read back the allowance it bought
    /// (SONNY-215).
    ///
    /// **Every guard that matters is the gateway's**, and this method takes no argument for that
    /// reason: there is nothing here for a caller to declare. Whether the account opted in, whether
    /// it is actually out, how many purchases the period has left and what a pack costs are all
    /// facts the server holds, and a request that carried any of them would be a client asserting
    /// something the server would have to check anyway.
    ///
    /// **An idempotency key per attempt, and not retry-safe.** §9.1 asks for a key on a `POST` that
    /// changes something, and this one moves money — so a key is what stops a repeat buying a second
    /// pack, and `isRetrySafe: false` is `verifyEmailCode`'s pairing for its reason: a call that
    /// spends something the user cannot get back is made once.
    public func purchaseTopUp() async throws -> ScreenControlAllowance {
        let response = try await client.send(SonnyBackendRequest(
            method: "POST",
            path: "/v1/account/credits/top-up",
            body: nil,
            authentication: .bearer,
            idempotencyKey: UUID(),
            // Its own budget, because this is the one call on this type that opens two outbound
            // provider requests behind it rather than reading a table.
            timeout: SonnyBackendTimeouts.topUp,
            isRetrySafe: false
        ))
        return try Self.decode(response.data)
    }

    /// The one route every method here reads, and the one body all three answer with.
    static let creditsPath = "/v1/account/credits"

    /// **One decode for three calls.** The `GET`, the setting and the purchase answer the same shape
    /// deliberately, so an answer is the account's whole position rather than a fragment a caller
    /// has to merge — and a second decoder here would be a second place for the three to disagree.
    private static func decode(_ data: Data) throws -> ScreenControlAllowance {
        guard let wire = try? decoder.decode(WireScreenControlAllowance.self, from: data) else {
            throw SonnyBackendError.undecodableResponse("screen-control allowance response")
        }
        return ScreenControlAllowance(
            plan: wire.plan,
            runsLeft: wire.screen_control_runs_left,
            runsIncluded: wire.screen_control_runs_included,
            creditsRemaining: wire.credits.remaining,
            periodStart: wire.period_start,
            periodEnd: wire.period_end,
            // **Absent decodes to nothing offered and nothing agreed**, which is the fail-closed
            // direction on both axes: a gateway too old to send this block cannot turn the feature
            // on, and cannot make a user look opted in.
            autoTopUp: ScreenControlAutoTopUp(
                isOffered: wire.auto_top_up?.offered ?? false,
                isOptedIn: wire.auto_top_up?.opted_in ?? false,
                attemptsLeft: wire.auto_top_up?.attempts_left ?? 0
            )
        )
    }

    /// §3.5: every instant on this wire is ISO-8601 and the server owns the clock.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// The wire body, field-for-field.
///
/// **`credits.remaining` is read, and only that one of the four.** This note used to say `credits`
/// was deliberately not read at all, on the ground that reading it "would be the first step toward a
/// second number in the product, which is exactly what the one-paid-line decision exists to
/// prevent". That reasoning was right about the *product* and wrong as a rule about this struct, and
/// the difference cost a user runs they had paid for (PR #190's F1): with only `runsLeft` in hand,
/// the gate had one figure for two different questions, and the question it got wrong was whether a
/// session already under way may continue.
///
/// The line that still holds is the one about the product surface: **nothing renders this**, and
/// SONNY-214 still shows exactly one number. `allowance`, `drawn` and `per_run` remain unread,
/// because no decision in this client needs them and §2.1 makes ignoring them free.
private struct WireScreenControlAllowance: Decodable {
    /// The derivation the gateway publishes beside the run count so a founder can sanity-check the
    /// weights against a measured cost. Only `remaining` is consumed; see the note above.
    ///
    /// `topped_up` is the fifth figure and is not read here for the reason the other three are not:
    /// no decision in this client needs it. It is on the wire so a founder can subtract what was
    /// bought from what the plan included.
    struct Credits: Decodable {
        let remaining: Double
    }

    /// The auto-top-up block (SONNY-215).
    ///
    /// **Optional, and its absence is read as nothing offered and nothing agreed.** §2.1 makes the
    /// client tolerant of fields it does not know; the mirror of that is that a field it *does* know
    /// and did not receive has to have a safe reading, and for a switch that authorises a charge the
    /// only safe reading is off.
    struct AutoTopUp: Decodable {
        let offered: Bool
        let opted_in: Bool
        let attempts_left: Int
    }

    let plan: String
    let screen_control_runs_left: Int
    let screen_control_runs_included: Int
    let credits: Credits
    let period_start: Date
    let period_end: Date
    let auto_top_up: AutoTopUp?
}
