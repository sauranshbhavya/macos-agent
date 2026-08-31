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
        runsIncluded: Int = 100
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
            // The derivation the gateway publishes beside the number. This client must ignore it,
            // and a body carrying it is what the real server sends, so it is here.
            "credits": ["allowance": 1000, "drawn": 30, "remaining": 970, "per_run": 10]
        ])
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
