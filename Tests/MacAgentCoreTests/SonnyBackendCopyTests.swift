import Foundation
import Testing
@testable import MacAgentCore

/// What the user is told when a call to Sonny's backend fails, on the four model routes.
///
/// **The one property that runs through all of it: a sentence never tells the user to retry
/// something a retry cannot fix** (PR #139, F7). §9.3 splits every code into two lists, and the
/// non-retryable list is not advice — "retrying any of these produces the identical failure and
/// burns a round trip". Three of those codes were reaching the shared "Try again." sentence, and one
/// of the three, `request.invalid`, is what this branch's own server answers a missing `retention`
/// with, so it was not a corner.
///
/// The other half of §7.1 is asserted here too: none of these sentences is the server's. The server
/// authors a `message` for logs and the support lookup, and a sentence written on the server and
/// rendered in the app is a hole through Sonny's standing rule that the product does not explain
/// itself, editable by whoever edits the server with no review from anyone who knows that rule.
struct SonnyBackendCopyTests {
    private static func apiError(
        _ code: SonnyBackendErrorCode,
        status: Int = 502,
        message: String = "Server-authored sentence the client must never display."
    ) -> SonnyBackendError {
        .api(SonnyBackendAPIError(
            code: code,
            statusCode: status,
            message: message,
            requestID: "req_copy",
            retryAfter: nil,
            envelopeSaysRetryable: false
        ))
    }

    @Test
    func aNonRetryableFailureNeverTellsTheUserToTryAgain() {
        // The three §9.3 calls not retryable that these routes can actually produce.
        for code in [
            SonnyBackendErrorCode.providerRejected,
            .requestInvalid,
            .requestTooLarge,
        ] {
            let sentence = SonnyBackendCopy.sentence(for: Self.apiError(code))
            #expect(
                !sentence.lowercased().contains("try again"),
                "\(code.wire) invites a retry that cannot work: \(sentence)"
            )
            #expect(!sentence.isEmpty)
        }
    }

    @Test
    func eachNonRetryableCodeGetsItsOwnSentenceRatherThanASharedOne() {
        // Distinct, because collapsing them is what F7 was: three different things the user might
        // do next, answered with one sentence that fitted none of them.
        let sentences = [
            SonnyBackendCopy.sentence(for: Self.apiError(.providerRejected)),
            SonnyBackendCopy.sentence(for: Self.apiError(.requestInvalid, status: 400)),
            SonnyBackendCopy.sentence(for: Self.apiError(.requestTooLarge, status: 413)),
        ]
        #expect(sentences == [
            "Sonny couldn't do this one.",
            "Sonny couldn't send this one.",
            "That was too big for Sonny to send in one go.",
        ])
        #expect(Set(sentences).count == 3)
    }

    @Test
    func aRetryableFailureDoesInviteARetry() {
        // The other direction, so the fix above cannot be satisfied by removing "try again" from
        // everything. §9.3's retryable list is where the instruction is true.
        for code in [
            SonnyBackendErrorCode.providerUnavailable,
            .providerTimeout,
            .serverError,
            .serverUnavailable,
        ] {
            let sentence = SonnyBackendCopy.sentence(for: Self.apiError(code))
            #expect(
                sentence.lowercased().contains("try again"),
                "\(code.wire) is retryable but says: \(sentence)"
            )
        }
    }

    @Test
    func everySentenceIsTheAppsOwnAndCarriesNothingFromTheServer() {
        // §7.1: the client never displays `message`. Checked across every code the taxonomy has,
        // rather than on the handful a test happened to think of.
        let secret = "SERVER-AUTHORED-SENTENCE-9137"
        let codes: [SonnyBackendErrorCode] = [
            .authUnauthenticated, .authTokenExpired, .authTokenRevoked, .authCodeInvalid,
            .authCodeExpired, .authCodeUsed, .entitlementRequired, .entitlementExpired,
            .limitRate, .limitSpend, .requestInvalid, .requestTooLarge, .providerUnavailable,
            .providerTimeout, .providerRejected, .serverError, .serverUnavailable,
            .resourceNotFound, .idempotencyConflict, .versionUnsupported, .unknown("brand.new"),
        ]
        for code in codes {
            let sentence = SonnyBackendCopy.sentence(for: Self.apiError(code, message: secret))
            #expect(!sentence.contains(secret), "\(code.wire) leaked the server's message")
            // Nor the wire code, nor a status: neither is a thing to show a user.
            #expect(!sentence.contains(code.wire), "\(code.wire) leaked its own wire code")
            #expect(!sentence.contains("502"))
            #expect(!sentence.isEmpty)
        }
    }

    @Test
    func theTransportFailuresKeepTheirOwnDistinctSentences() {
        // `offline` and everything else are deliberately separate — §7.2 case 7 is the only entry
        // with no HTTP status, and the contract says why the distinction is load-bearing: the first
        // means everything local still works, the second means Sonny is up and this thing failed.
        #expect(
            SonnyBackendCopy.sentence(for: .offline)
                == "You're offline. Everything Sonny does on this Mac still works."
        )
        #expect(SonnyBackendCopy.sentence(for: .notSignedIn) == "Sign in to Sonny to run this.")
        #expect(
            SonnyBackendCopy.sentence(for: .backendNotConfigured)
                == "This build has no Sonny account service."
        )
        #expect(
            SonnyBackendCopy.sentence(for: .unreachable("DNS"))
                == "Sonny couldn't finish this one. Try again."
        )
        #expect(
            SonnyBackendCopy.sentence(for: .timedOut(after: 90))
                == "Sonny couldn't finish this one. Try again."
        )
        // And a timeout's own duration is not a thing to put in front of a user.
        #expect(!SonnyBackendCopy.sentence(for: .timedOut(after: 90)).contains("90"))
    }

    @Test
    func aRateLimitAndASpendCapSayDifferentThingsBecauseOnlyOneClearsByWaiting() {
        // §7.2 cases 3 and 3a. A spend cap carries no `Retry-After` precisely because waiting
        // seconds does not fix it, so "try again shortly" would be false for it.
        let rate = SonnyBackendCopy.sentence(for: Self.apiError(.limitRate, status: 429))
        let spend = SonnyBackendCopy.sentence(for: Self.apiError(.limitSpend, status: 429))
        #expect(rate == "Too many requests just now. Try again shortly.")
        #expect(spend == "You're out of allowance for this period.")
        #expect(!spend.lowercased().contains("try again"))
    }
}
