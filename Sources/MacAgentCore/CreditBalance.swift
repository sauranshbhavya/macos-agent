import Foundation

/// An account's credits this month, read from the gateway (V2 plan decision 8): what the plan and
/// any top-ups give, and what is left after the model calls its tasks made. Tasks spend credits by
/// tokens; the gateway stops a task before its next model call when they run out.
public struct CreditBalance: Sendable, Equatable {
    /// The plan the server applied — its own, or the catalogue's default for an account with none.
    public let plan: String
    /// What this period is worth: the plan's monthly credits plus what was topped up.
    public let creditsAllowance: Double
    /// What is left. Never negative.
    public let creditsRemaining: Double
    /// The period these figures are about. `periodEnd` is exclusive.
    public let periodStart: Date
    public let periodEnd: Date
    /// Whether more credits can be bought when these run out, and whether the user asked for that.
    public let autoTopUp: CreditAutoTopUp
    /// What this account was last charged for a top-up, and when; `nil` when it never has been.
    public let lastTopUp: CreditTopUpCharge?

    public init(
        plan: String,
        creditsAllowance: Double,
        creditsRemaining: Double,
        periodStart: Date,
        periodEnd: Date,
        autoTopUp: CreditAutoTopUp,
        lastTopUp: CreditTopUpCharge?
    ) {
        self.plan = plan
        self.creditsAllowance = creditsAllowance
        self.creditsRemaining = creditsRemaining
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.autoTopUp = autoTopUp
        self.lastTopUp = lastTopUp
    }
}

/// A sum of money, as a payment provider counts one (SONNY-215's F6).
///
/// **Minor units and a currency code, never a formatted string.** §7.1's rule is that the words are
/// this repository's rather than the server's, and a price is words the moment it is written down —
/// a currency symbol, a separator and a decimal place are all locale decisions. The gateway sends
/// the number and the code; `CreditPresentation` is where they become something to read.
public struct CreditMoney: Sendable, Equatable {
    /// In the currency's smallest unit — 500 for $5.00. Never fractional.
    public let amount: Int
    /// ISO 4217, as the provider writes it. Case is not normalised here; the formatter uppercases.
    public let currency: String

    public init(amount: Int, currency: String) {
        self.amount = amount
        self.currency = currency
    }
}

/// One charge that happened: what it cost, and when the session that triggered it asked.
public struct CreditTopUpCharge: Sendable, Equatable {
    public let price: CreditMoney
    public let at: Date

    public init(price: CreditMoney, at: Date) {
        self.price = price
        self.at = at
    }
}

/// The auto-top-up setting, as the gateway reports it (SONNY-215).
///
/// **Two booleans and not one, because they are different facts with different owners.**
/// ``isOffered`` is the deployment's — a pack is configured and this gateway can charge — and
/// ``isOptedIn`` is the user's. Collapsing them would make "nothing to sell" and "you said no" the
/// same state, and the product does opposite things with them: the first renders no control at all,
/// and the second renders one that is off.
public struct CreditAutoTopUp: Sendable, Equatable {
    /// Whether this deployment sells more credits at all. `false` renders no control — a control that
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
    /// **What one pack costs, so the switch that authorises the charge can say it** (SONNY-215's F6,
    /// founder decision option B). `nil` when this deployment sells none.
    ///
    /// This is the *configured* price, which is the only one available before a purchase has
    /// happened. The record of a charge that did happen is ``CreditBalance/lastTopUp``, and
    /// that one carries the provider's own figure.
    public let price: CreditMoney?

    /// The state a build gets before it has read anything. **Nothing offered, nothing agreed and no
    /// price** — fail-closed in every direction, so a decoding path that lost these fields could not
    /// turn the feature on or put a number on a control.
    public static let none = CreditAutoTopUp(
        isOffered: false,
        isOptedIn: false,
        attemptsLeft: 0,
        price: nil
    )

    public init(isOffered: Bool, isOptedIn: Bool, attemptsLeft: Int, price: CreditMoney?) {
        self.isOffered = isOffered
        self.isOptedIn = isOptedIn
        self.attemptsLeft = attemptsLeft
        self.price = price
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

/// Fetches the balance. One request, no cache, no store: a balance changes with every model call,
/// so a stored one would be wrong most of the time it is read. A failure is a failure and never a
/// number; the app shows no line at all rather than a figure the server never gave.
public actor CreditBalanceService {
    private let client: SonnyBackendClient

    /// No default, the same hazard `EntitlementService` and `SonnyBackendClient` both record: every
    /// packaged build on a Mac shares one Keychain, so a fixture that inherited a default client
    /// would read the founder's own session.
    public init(client: SonnyBackendClient) {
        self.client = client
    }

    /// Ask the gateway how many credits are left, or throw.
    public func fetch() async throws -> CreditBalance {
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
    public func setAutoTopUp(_ enabled: Bool) async throws -> CreditBalance {
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

    /// Ask the gateway to buy one more pack of credits, and read back the balance it bought
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
    public func purchaseTopUp() async throws -> CreditBalance {
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
    private static func decode(_ data: Data) throws -> CreditBalance {
        guard let wire = try? decoder.decode(WireCreditBalance.self, from: data) else {
            throw SonnyBackendError.undecodableResponse("credit balance response")
        }
        return CreditBalance(
            plan: wire.plan,
            creditsAllowance: wire.credits.allowance,
            creditsRemaining: wire.credits.remaining,
            periodStart: wire.period_start,
            periodEnd: wire.period_end,
            // **Absent decodes to nothing offered and nothing agreed**, which is the fail-closed
            // direction on both axes: a gateway too old to send this block cannot turn the feature
            // on, and cannot make a user look opted in.
            autoTopUp: CreditAutoTopUp(
                isOffered: wire.auto_top_up?.offered ?? false,
                isOptedIn: wire.auto_top_up?.opted_in ?? false,
                attemptsLeft: wire.auto_top_up?.attempts_left ?? 0,
                price: wire.auto_top_up?.price.map {
                    CreditMoney(amount: $0.amount, currency: $0.currency)
                }
            ),
            lastTopUp: wire.last_top_up.map {
                CreditTopUpCharge(
                    price: CreditMoney(amount: $0.amount, currency: $0.currency),
                    at: $0.at
                )
            }
        )
    }

    /// §3.5: every instant on this wire is ISO-8601 and the server owns the clock.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// The wire body, field-for-field. `drawn` and `topped_up` are on the wire for a founder checking the
/// arithmetic; nothing in this client reads them.
private struct WireCreditBalance: Decodable {
    struct Credits: Decodable {
        let allowance: Double
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
        /// `null` on a deployment that sells no pack, and absent on a gateway too old to send it.
        /// Both decode to `nil`, which renders no price rather than a wrong one.
        let price: Money?
    }

    /// A sum of money on the wire — minor units and a code, never a formatted string.
    struct Money: Decodable {
        let amount: Int
        let currency: String
    }

    /// One charge that happened (SONNY-215's F6).
    struct LastTopUp: Decodable {
        let amount: Int
        let currency: String
        let at: Date
    }

    let plan: String
    let credits: Credits
    let period_start: Date
    let period_end: Date
    let auto_top_up: AutoTopUp?
    let last_top_up: LastTopUp?
}
