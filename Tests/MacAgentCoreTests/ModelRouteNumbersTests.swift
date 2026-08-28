import Foundation
import Testing
@testable import MacAgentCore

/// §12's timeout table, the client half — **ten numbers and one ordering** (PR #139, F2; the vision
/// row is SONNY-131's).
///
/// **Nothing read these before this suite.** `SonnyBackendTimeouts`' five model-route constants reach
/// `SonnyModelRoute.timeout`, which reaches a `URLRequest.timeoutInterval`, and no test looked at
/// any of it: a mutant moving any one of them survived the whole suite, and so did one swapping two
/// routes' constants. Both shapes are held here.
///
/// **Why the server's numbers are literals in a Swift test.** §12's rule is a relation *between* the
/// two sides — "the client's timeout is always longer than the server's total deadline" — and
/// neither side can see the other's code. So each side writes the whole table down and asserts its
/// own half against it: `server/test/model.test.ts` holds `DEADLINE_MS` the same way, including the
/// vision row. Moving a number on one side without the other now fails on that side.
///
/// **The margin is not a constant, and two of SONNY-130's own doc comments said it was.** It is
/// fifteen seconds on the four long routes and five on `search` — §12's table, not one rule. The
/// first draft of the server's half asserted fifteen everywhere and went red on `search`, which is
/// what found the wrong claim. What holds on every row is the ordering.
struct ModelRouteNumbersTests {
    /// §12's table, transcribed. `serverTotal` is `DEADLINE_MS[route].total` in
    /// `server/src/model/limits.ts`, in seconds.
    private static let table: [(route: SonnyModelRoute, serverTotal: TimeInterval, client: TimeInterval)] = [
        (.plan, 75, 90),
        (.researchSynthesis, 105, 120),
        (.transcription, 75, 90),
        (.search, 25, 30),
        (.screenAnalyze, 105, 120),
    ]

    @Test
    func everyRouteCarriesTheClientTimeoutSection12GivesIt() {
        #expect(SonnyBackendTimeouts.plan == 90)
        #expect(SonnyBackendTimeouts.researchSynthesis == 120)
        #expect(SonnyBackendTimeouts.transcription == 90)
        #expect(SonnyBackendTimeouts.search == 30)
        #expect(SonnyBackendTimeouts.screenAnalyze == 120)
        // The row SONNY-128 declared, unchanged by either branch and asserted so it cannot drift
        // while the five beside it are held.
        #expect(SonnyBackendTimeouts.auth == 20)
    }

    @Test
    func eachRouteResolvesToItsOwnTimeoutAndNotANeighboursName() {
        // The mutant this kills is a swap: `case .plan: return SonnyBackendTimeouts.transcription`
        // type-checks, and until this test nothing looked. Two pairs of the five share a value —
        // `plan`/`transcription` at 90 and `researchSynthesis`/`screenAnalyze` at 120 — so the
        // assertion is per route against the table rather than against the set of values.
        for row in Self.table {
            #expect(row.route.timeout == row.client, "\(row.route.path) carries the wrong timeout")
        }
    }

    @Test
    func theClientAlwaysWaitsLongerThanTheServersTotalDeadline() {
        // §12's governing rule, and the reason it exists: a slow route has to surface as the
        // server's own typed `504 provider.timeout`, which the app can explain, rather than as this
        // client's transport timeout, which it cannot tell apart from a dead network.
        for row in Self.table {
            #expect(
                row.client > row.serverTotal,
                "\(row.route.path) would time out on the client before the server could answer"
            )
        }
    }

    @Test
    func theMarginIsFifteenSecondsOnTheLongRoutesAndFiveOnSearch() {
        // Written out rather than asserted as one number, because it is not one number — and
        // because a reader who has just seen the ordering rule will otherwise assume it is.
        #expect(SonnyBackendTimeouts.plan - 75 == 15)
        #expect(SonnyBackendTimeouts.researchSynthesis - 105 == 15)
        #expect(SonnyBackendTimeouts.transcription - 75 == 15)
        #expect(SonnyBackendTimeouts.screenAnalyze - 105 == 15)
        #expect(SonnyBackendTimeouts.search - 25 == 5)
        #expect(SonnyBackendTimeouts.auth - 15 == 5)
    }

    @Test
    func everyRoutePathIsTheOneTheContractNames() {
        // §4.1's table. A path typo is a 404 the client reads as `resource.not_found`, which it
        // does not retry and cannot explain — and no other test in the tree reads all five.
        #expect(SonnyModelRoute.plan.path == "/v1/plan")
        #expect(SonnyModelRoute.researchSynthesis.path == "/v1/research/synthesize")
        #expect(SonnyModelRoute.transcription.path == "/v1/transcriptions")
        #expect(SonnyModelRoute.search.path == "/v1/search")
        #expect(SonnyModelRoute.screenAnalyze.path == "/v1/screen/analyze")
    }

    @Test
    func everyRoutesUsageModelNameIsItsOwn() {
        // §4.2: `AIUsageRecord.model` holds the route's name rather than a model identifier the
        // client is no longer allowed to know. Distinctness is the property — two routes sharing a
        // name would make a usage summary unreadable, and it is one `return` away.
        let names = [
            SonnyModelRoute.plan.usageModelName,
            SonnyModelRoute.researchSynthesis.usageModelName,
            SonnyModelRoute.transcription.usageModelName,
            SonnyModelRoute.search.usageModelName,
            SonnyModelRoute.screenAnalyze.usageModelName,
        ]
        #expect(names == ["plan", "research.synthesize", "transcriptions", "search", "screen.analyze"])
        #expect(Set(names).count == names.count)
    }
}
