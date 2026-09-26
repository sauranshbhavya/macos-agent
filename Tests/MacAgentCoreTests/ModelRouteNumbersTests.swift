import Foundation
import Testing
@testable import MacAgentCore

/// §12's timeout table, the client half. Since V2 the Mac calls one model route, transcription, and
/// the account routes.
///
/// **Why the server's numbers are literals in a Swift test.** §12's rule is a relation *between* the
/// two sides — "the client's timeout is always longer than the server's total deadline" — and
/// neither side can see the other's code. So each side writes the table down and asserts its own
/// half against it: `server/test/model.test.ts` holds `DEADLINE_MS` the same way. Moving a number on
/// one side without the other fails on that side.
struct ModelRouteNumbersTests {
    /// §12's table, transcribed. `serverTotal` is `DEADLINE_MS[route].total` in
    /// `server/src/model/limits.ts`, in seconds.
    private static let table: [(route: SonnyModelRoute, serverTotal: TimeInterval, client: TimeInterval)] = [
        (.transcription, 75, 90),
    ]

    @Test
    func everyRouteCarriesTheClientTimeoutSection12GivesIt() {
        #expect(SonnyBackendTimeouts.transcription == 90)
        #expect(SonnyBackendTimeouts.auth == 20)
    }

    @Test
    func eachRouteResolvesToItsOwnTimeout() {
        for row in Self.table {
            #expect(row.route.timeout == row.client, "\(row.route.path) carries the wrong timeout")
        }
    }

    @Test
    func theClientAlwaysWaitsLongerThanTheServersTotalDeadline() {
        // §12's governing rule: a slow route has to surface as the server's own typed
        // `504 provider.timeout`, which the app can explain, rather than as this client's transport
        // timeout, which it cannot tell apart from a dead network.
        for row in Self.table {
            #expect(
                row.client > row.serverTotal,
                "\(row.route.path) would time out on the client before the server could answer"
            )
        }
    }

    @Test
    func theMarginIsFifteenSecondsOnTranscriptionAndFiveOnTheAccountRoutes() {
        #expect(SonnyBackendTimeouts.transcription - 75 == 15)
        #expect(SonnyBackendTimeouts.auth - 15 == 5)
    }

    @Test
    func theTranscriptionRouteIsTheOneTheContractNames() {
        // A path typo is a 404 the client reads as `resource.not_found`, which it does not retry.
        #expect(SonnyModelRoute.transcription.path == "/v1/transcriptions")
        #expect(SonnyModelRoute.transcription.usageModelName == "transcriptions")
    }
}
