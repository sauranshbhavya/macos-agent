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

    public init(
        plan: String,
        runsLeft: Int,
        runsIncluded: Int,
        creditsRemaining: Double,
        periodStart: Date,
        periodEnd: Date
    ) {
        self.plan = plan
        self.runsLeft = runsLeft
        self.runsIncluded = runsIncluded
        self.creditsRemaining = creditsRemaining
        self.periodStart = periodStart
        self.periodEnd = periodEnd
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
            path: "/v1/account/credits",
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
        guard let wire = try? Self.decoder.decode(WireScreenControlAllowance.self, from: response.data) else {
            throw SonnyBackendError.undecodableResponse("screen-control allowance response")
        }
        return ScreenControlAllowance(
            plan: wire.plan,
            runsLeft: wire.screen_control_runs_left,
            runsIncluded: wire.screen_control_runs_included,
            creditsRemaining: wire.credits.remaining,
            periodStart: wire.period_start,
            periodEnd: wire.period_end
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
    struct Credits: Decodable {
        let remaining: Double
    }

    let plan: String
    let screen_control_runs_left: Int
    let screen_control_runs_included: Int
    let credits: Credits
    let period_start: Date
    let period_end: Date
}
