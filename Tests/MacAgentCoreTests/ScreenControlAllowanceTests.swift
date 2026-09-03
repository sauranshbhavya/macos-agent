import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// Reading "screen-control runs left this month" off the gateway (SONNY-212).
///
/// **The client half of this ticket is a read and nothing else**, so this suite is about exactly
/// that: the request it sends, the body it accepts, and what it does with a body it cannot trust.
/// Where the number comes from is the server's, and `server/test/credit.test.ts` and
/// `credit.db.test.ts` own it; rendering it is SONNY-214's and refusing on it is SONNY-213's.
@Suite
struct ScreenControlAllowanceTests {
    static let now = SonnyISO8601.parse("2026-08-15T12:00:00Z")!

    static func body(
        plan: String = "test-plan-a",
        runsLeft: Int = 97,
        runsIncluded: Int = 100,
        creditsRemaining: Double = 970
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "plan": plan,
            // **The server's own form, milliseconds included.** `Date.toISOString()` writes `.000Z`
            // and contract §5.4's example shows it, so a fixture without them is a shape the gateway
            // never sends. `.iso8601` decodes both — measured, and `TaskHistoryStore.swift` records
            // the same measurement — but a fixture should be the real thing rather than a near miss
            // a later reader has to re-measure (PR #182's review, recorded residual).
            "period_start": "2026-08-01T00:00:00.000Z",
            "period_end": "2026-09-01T00:00:00.000Z",
            "screen_control_runs_left": runsLeft,
            "screen_control_runs_included": runsIncluded,
            // The derivation the gateway publishes beside the number. **`remaining` is read now**
            // (SONNY-213, PR #190's F1) — the step boundary asks whether the account has actually
            // run out, which `runsLeft` cannot answer for a session already spending its own run.
            // The other three stay unread. This comment said "this client must ignore it" until that
            // finding.
            "credits": [
                "allowance": 1000, "drawn": 30, "remaining": creditsRemaining, "per_run": 10,
                // SONNY-215's fifth figure. Unread here for the same reason three of its four
                // neighbours are: no decision in this client needs it.
                "topped_up": 0
            ]
        ] as [String: Any])
    }

    /// The same body with SONNY-215's setting block on it.
    ///
    /// **A separate builder rather than a defaulted parameter on the one above**, so every existing
    /// test in this suite still describes a body with no `auto_top_up` at all — which is the shape a
    /// gateway too old to send it produces, and the shape whose safe reading this ticket has to get
    /// right.
    static func bodyWithAutoTopUp(
        offered: Bool,
        optedIn: Bool,
        attemptsLeft: Int,
        runsLeft: Int = 97,
        creditsRemaining: Double = 970
    ) -> Data {
        var document = try! JSONSerialization.jsonObject(
            with: body(runsLeft: runsLeft, creditsRemaining: creditsRemaining)
        ) as! [String: Any]
        document["auto_top_up"] = [
            "offered": offered,
            "opted_in": optedIn,
            "attempts_left": attemptsLeft
        ]
        return try! JSONSerialization.data(withJSONObject: document)
    }

    static func reply(_ data: Data) -> BackendStubURLProtocol.Outcome {
        .reply(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
    }

    @Test
    @MainActor
    func theRunsLeftFigureIsReadFromTheGateway() async throws {
        let fixture = SignedInBackendFixture(now: { Self.now })
        defer { fixture.unregister() }
        let seen = RecordedBackendRequests()
        fixture.register { request in
            seen.append(request)
            return Self.reply(Self.body())
        }

        let allowance = try await ScreenControlAllowanceService(client: fixture.client).fetch()

        #expect(allowance.runsLeft == 97)
        #expect(allowance.runsIncluded == 100)
        // **Read from `credits.remaining`, and 970 rather than 97 is the whole assertion**: the two
        // figures are different numbers in the same body, so this fails if the remainder is ever
        // derived from the run count instead of decoded.
        #expect(allowance.creditsRemaining == 970)
        #expect(allowance.plan == "test-plan-a")
        #expect(allowance.periodStart == SonnyISO8601.parse("2026-08-01T00:00:00Z")!)
        #expect(allowance.periodEnd == SonnyISO8601.parse("2026-09-01T00:00:00Z")!)

        // One authenticated GET, at the contract's path, carrying no idempotency key — there is
        // nothing for one to be about on a request that changes nothing.
        let requests = seen.all
        try #require(requests.count == 1)
        let sent = requests[0]
        #expect(sent.path == "/v1/account/credits")
        #expect(sent.method == "GET")
        #expect(sent.authorization?.hasPrefix("Bearer ") == true)
        #expect(sent.idempotencyKey == nil)
    }

    /// **The state a session in flight is actually in: no whole run affordable, real credit left.**
    ///
    /// This is the reading SONNY-213's step boundary exists to tell apart from a genuine exhaustion,
    /// and it is unreachable from `runsLeft` alone — `floor(remaining / runCredits)` is 0 for every
    /// remainder below one run, so the run count says the same thing about "82% of a run left" and
    /// "nothing left". A client that derived the remainder from the run count would read both as
    /// zero and halt a session on the run the door had just granted it, which is exactly what PR
    /// #190's F1 was.
    ///
    /// Asserted here rather than only at the gate because the gate's own tests use a stub reader:
    /// nothing else in the suite decodes this field off a real body, and a mutant reading it off
    /// `screen_control_runs_left` survived the whole suite until this test existed.
    @Test
    @MainActor
    func theRemainderAndTheRunCountAreReadFromTheirOwnFields() async throws {
        let fixture = SignedInBackendFixture(now: { Self.now })
        defer { fixture.unregister() }
        fixture.register { _ in
            Self.reply(Self.body(runsLeft: 0, runsIncluded: 10, creditsRemaining: 8.2))
        }

        let allowance = try await ScreenControlAllowanceService(client: fixture.client).fetch()

        #expect(allowance.runsLeft == 0)
        #expect(allowance.creditsRemaining == 8.2)
    }

    @Test
    @MainActor
    func aFailureIsAFailureAndNeverANumber() async throws {
        // **There is no fallback figure, because every candidate is a lie**: zero locks a user out of
        // a feature they may have paid for, and any positive number promises runs the server never
        // granted. What the surface shows when this throws is SONNY-214's decision.
        let fixture = SignedInBackendFixture(now: { Self.now })
        defer { fixture.unregister() }
        fixture.register { _ in .failure(URLError(.notConnectedToInternet)) }

        await #expect(throws: (any Error).self) {
            try await ScreenControlAllowanceService(client: fixture.client).fetch()
        }
    }

    @Test
    @MainActor
    func aBodyMissingTheNumberIsRefusedRatherThanReadAsZero() async throws {
        // The direction that matters: a response this build cannot read must not become a run count.
        // A `Decodable` with an optional field defaulted to zero would turn a schema change into a
        // user who is silently out of runs.
        let fixture = SignedInBackendFixture(now: { Self.now })
        defer { fixture.unregister() }
        let partial = try! JSONSerialization.data(withJSONObject: [
            "plan": "test-plan-a",
            "period_start": "2026-08-01T00:00:00.000Z",
            "period_end": "2026-09-01T00:00:00.000Z",
            "screen_control_runs_included": 100
        ])
        fixture.register { _ in Self.reply(partial) }

        await #expect(throws: SonnyBackendError.self) {
            try await ScreenControlAllowanceService(client: fixture.client).fetch()
        }
    }

    @Test
    @MainActor
    func anUnknownFieldIsToleratedRatherThanRefused() async throws {
        // §2.1: the client tolerates response fields it does not know, so the gateway's body can grow
        // additively. This is the same tolerance that lets `credits` sit in every real response.
        let fixture = SignedInBackendFixture(now: { Self.now })
        defer { fixture.unregister() }
        var object = try! JSONSerialization.jsonObject(with: Self.body()) as! [String: Any]
        object["something_a_later_ticket_added"] = ["nested": true]
        let grown = try! JSONSerialization.data(withJSONObject: object)
        fixture.register { _ in Self.reply(grown) }

        let allowance = try await ScreenControlAllowanceService(client: fixture.client).fetch()
        #expect(allowance.runsLeft == 97)
    }

    @Test
    @MainActor
    func nothingIsCachedBetweenReads() async throws {
        // **The opposite call to `EntitlementService`'s**, and deliberately. A claim is honoured for
        // up to four days past its issue because an entitlement changes on the order of a
        // subscription; a run count changes on the order of a run, so a stored one is wrong most of
        // the time it is read — and wrong in the direction that shows runs to somebody who has none.
        let fixture = SignedInBackendFixture(now: { Self.now })
        defer { fixture.unregister() }
        let seen = RecordedBackendRequests()
        let answers = RunCounts([97, 42])
        fixture.register { request in
            seen.append(request)
            return Self.reply(Self.body(runsLeft: answers.next()))
        }
        let service = ScreenControlAllowanceService(client: fixture.client)

        #expect(try await service.fetch().runsLeft == 97)
        #expect(try await service.fetch().runsLeft == 42)
        #expect(seen.all.count == 2)
    }

    // MARK: - The auto-top-up setting and the purchase (SONNY-215)

    @Test
    @MainActor
    func aBodyWithNoSettingBlockReadsAsNothingOfferedAndNothingAgreed() async throws {
        // **The fail-closed direction on both axes, and the one that matters is the second.** A
        // gateway too old to send this block, or a field lost in a rewrite, must not be able to make
        // a user look opted in — because opted in is what the gate reads before it asks anybody to
        // charge a card. Every other test in this suite uses the same block-less body, so this is
        // asserting what all of them silently assume.
        let fixture = SignedInBackendFixture(now: { Self.now })
        defer { fixture.unregister() }
        fixture.register { _ in Self.reply(Self.body()) }

        let allowance = try await ScreenControlAllowanceService(client: fixture.client).fetch()

        #expect(allowance.autoTopUp == .none)
        #expect(allowance.autoTopUp.isOptedIn == false)
        #expect(allowance.autoTopUp.mayPurchase == false)
    }

    @Test
    @MainActor
    func theSettingIsReadFieldForFieldRatherThanInferredFromOneFlag() async throws {
        // Three distinct values in one body, and none of them derivable from another: a deployment
        // that offers top-ups to a user who has not asked for one, with two purchases left in the
        // period. A reading that collapsed any pair would answer this wrong.
        let fixture = SignedInBackendFixture(now: { Self.now })
        defer { fixture.unregister() }
        fixture.register { _ in
            Self.reply(Self.bodyWithAutoTopUp(offered: true, optedIn: false, attemptsLeft: 2))
        }

        let allowance = try await ScreenControlAllowanceService(client: fixture.client).fetch()

        #expect(allowance.autoTopUp.isOffered)
        #expect(allowance.autoTopUp.isOptedIn == false)
        #expect(allowance.autoTopUp.attemptsLeft == 2)
        // The composite the gate reads. Off because of the middle field alone, which is the whole
        // of this ticket's hard requirement seen from the client's side.
        #expect(allowance.autoTopUp.mayPurchase == false)
    }

    /// `mayPurchase` is all three, and each one alone is enough to stop a charge being asked for.
    ///
    /// **Parameterized over the population rather than over a representative**, on
    /// `anUnconfirmableClaimRefusesAtEveryMomentAndSaysWhichNo`'s reasoning: the case that matters is
    /// the one nobody thought to write, and here the three cases are three different reasons a user
    /// must not be charged.
    @Test(arguments: [
        (false, false, 0, false),
        (true, false, 3, false),
        (false, true, 3, false),
        (true, true, 0, false),
        (true, true, 1, true)
    ])
    func aPurchaseIsOnlyEverAskedForWhenAllThreeHold(
        offered: Bool,
        optedIn: Bool,
        attemptsLeft: Int,
        expected: Bool
    ) {
        let setting = ScreenControlAutoTopUp(
            isOffered: offered,
            isOptedIn: optedIn,
            attemptsLeft: attemptsLeft
        )
        #expect(setting.mayPurchase == expected)
    }

    @Test
    @MainActor
    func theSettingIsWrittenToTheGatewayAndTheServersAnswerIsWhatIsKept() async throws {
        // **The server's answer replaces the figure, rather than the request's own value.** A client
        // that showed what it asked for would be a switch that says a charge can happen before
        // anything agreed to it.
        let fixture = SignedInBackendFixture(now: { Self.now })
        defer { fixture.unregister() }
        let seen = RecordedBackendRequests()
        fixture.register { request in
            seen.append(request)
            return Self.reply(Self.bodyWithAutoTopUp(offered: true, optedIn: true, attemptsLeft: 3))
        }

        let allowance = try await ScreenControlAllowanceService(client: fixture.client)
            .setAutoTopUp(true)

        #expect(allowance.autoTopUp.isOptedIn)
        // The whole position comes back, not an acknowledgement — so the surface showing the switch
        // and the number beside it can never be one request apart.
        #expect(allowance.runsLeft == 97)

        let requests = seen.all
        try #require(requests.count == 1)
        let sent = requests[0]
        #expect(sent.path == "/v1/account/credits/auto-top-up")
        #expect(sent.method == "PUT")
        #expect(sent.authorization?.hasPrefix("Bearer ") == true)
        // **No idempotency key, and that is a property rather than an omission**: setting a switch
        // to a value twice reaches the same state, which is what §9.1 asks a key for on the requests
        // where it does not.
        #expect(sent.idempotencyKey == nil)
        let body = sent.body
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(decoded?["enabled"] as? Bool == true)
    }

    @Test
    @MainActor
    func turningTheSettingOffSendsFalseRatherThanOmittingTheField() async throws {
        // A body with no `enabled` is refused by the gateway rather than read as either value, so
        // this is the assertion that the off press is a real request and not a no-op.
        let fixture = SignedInBackendFixture(now: { Self.now })
        defer { fixture.unregister() }
        let seen = RecordedBackendRequests()
        fixture.register { request in
            seen.append(request)
            return Self.reply(Self.bodyWithAutoTopUp(offered: true, optedIn: false, attemptsLeft: 3))
        }

        let allowance = try await ScreenControlAllowanceService(client: fixture.client)
            .setAutoTopUp(false)

        #expect(allowance.autoTopUp.isOptedIn == false)
        let body = try #require(seen.all.first?.body)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(decoded?["enabled"] as? Bool == false)
    }

    @Test
    @MainActor
    func aPurchaseIsOnePostThatCarriesAKeyAndIsNotRetried() async throws {
        // **The one request this client makes that spends money**, and every property asserted here
        // is about that: a key so a repeat cannot buy a second pack, `isRetrySafe: false` so this
        // client never sends it twice on its own, and no body at all — there is nothing for a caller
        // to declare, because every guard is the gateway's.
        let fixture = SignedInBackendFixture(now: { Self.now })
        defer { fixture.unregister() }
        let seen = RecordedBackendRequests()
        fixture.register { request in
            seen.append(request)
            return Self.reply(
                Self.bodyWithAutoTopUp(
                    offered: true, optedIn: true, attemptsLeft: 2, runsLeft: 50, creditsRemaining: 500
                )
            )
        }

        let allowance = try await ScreenControlAllowanceService(client: fixture.client)
            .purchaseTopUp()

        // The answer is the allowance the purchase bought, which is what lets the gate re-ask its
        // own question without a second read.
        #expect(allowance.runsLeft == 50)
        #expect(allowance.creditsRemaining == 500)
        #expect(allowance.autoTopUp.attemptsLeft == 2)

        let requests = seen.all
        try #require(requests.count == 1)
        let sent = requests[0]
        #expect(sent.path == "/v1/account/credits/top-up")
        #expect(sent.method == "POST")
        #expect(sent.authorization?.hasPrefix("Bearer ") == true)
        #expect(sent.idempotencyKey != nil)
        // **Nothing declared, which is the property rather than an economy.** Every guard a top-up
        // passes is the gateway's — the consent, whether the account is actually out, how many
        // purchases the period has left and what a pack costs — so a body here would be a client
        // asserting something the server has to check anyway. Asserted as empty rather than as
        // `nil`, because `URLRequest` carries a bodyless POST as zero bytes.
        #expect(sent.body.isEmpty)
    }

    @Test
    @MainActor
    func twoPurchasesCarryTwoKeysRatherThanReusingOne() async throws {
        // **A key per attempt, not a key per client.** One reused key would make the second purchase
        // replay the first's stored response — which is right for a retry of one attempt and wrong
        // for a genuinely new one, and a user who had spent their second pack would be handed the
        // first one's answer.
        let fixture = SignedInBackendFixture(now: { Self.now })
        defer { fixture.unregister() }
        let seen = RecordedBackendRequests()
        fixture.register { request in
            seen.append(request)
            return Self.reply(Self.bodyWithAutoTopUp(offered: true, optedIn: true, attemptsLeft: 1))
        }
        let service = ScreenControlAllowanceService(client: fixture.client)

        _ = try await service.purchaseTopUp()
        _ = try await service.purchaseTopUp()

        let keys = seen.all.compactMap(\.idempotencyKey)
        try #require(keys.count == 2)
        #expect(keys[0] != keys[1])
    }

    @Test
    @MainActor
    func aPurchaseTheGatewayRefusesThrowsRatherThanAnsweringANumber() async throws {
        // Every way a purchase does not happen arrives at the gate as a throw, and the gate answers
        // all of them with the refusal it was about to give. `topup.not_permitted` is the code the
        // gateway sends an account that never opted in.
        let fixture = SignedInBackendFixture(now: { Self.now })
        defer { fixture.unregister() }
        fixture.register { _ in
            .reply(
                statusCode: 409,
                headers: ["Content-Type": "application/json"],
                body: try! JSONSerialization.data(withJSONObject: [
                    "error": [
                        "code": "topup.not_permitted",
                        "message": "No top-up was made for this account.",
                        "retryable": false
                    ]
                ])
            )
        }

        await #expect(throws: SonnyBackendError.self) {
            _ = try await ScreenControlAllowanceService(client: fixture.client).purchaseTopUp()
        }
    }

    @Test
    func theTopUpBudgetClearsBothOfTheGatewaysOwnCalls() {
        // **A relation between the two halves, pinned on this side** — `PORTAL_SESSION_TIMEOUT_MS`'s
        // precedent, and the reason it exists: a cross-half number living in prose on one side is a
        // number the next session moves without noticing the other. The gateway's own budget is
        // `TOPUP_CHARGE_TIMEOUT_MS`, 12 000 ms, spent twice in sequence — a draft order and a
        // finalize — and `server/test/topup.test.ts` asserts both literals from its side.
        let gatewayPerCallMilliseconds = 12_000.0
        #expect(SonnyBackendTimeouts.topUp == 40)
        #expect(SonnyBackendTimeouts.topUp * 1000 > gatewayPerCallMilliseconds * 2)
        // And longer than the ordinary auth budget, which is the whole reason it is its own number.
        #expect(SonnyBackendTimeouts.topUp > SonnyBackendTimeouts.auth)
    }

    /// The stub's answers, in order, in a form a `@Sendable` handler may read.
    final class RunCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int]

        init(_ values: [Int]) { self.values = values }

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return values.isEmpty ? 0 : values.removeFirst()
        }
    }
}
