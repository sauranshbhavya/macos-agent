import Foundation
import Testing
@testable import MacAgentCore

/// What the user is actually told, as concrete strings (SONNY-135).
///
/// **The ticket asks for the strings themselves**, not for a mapping that exists: "each refusal
/// reason produces its own human message. Assert the concrete strings." A test that only checked
/// that a message was non-empty would pass against a copy layer that answered "Error" seven times.
@Suite
struct EntitlementCopyTests {
    @Test
    func everyRefusalHasItsOwnSentence() {
        #expect(EntitlementCopy.message(for: .notSignedIn) == "Sign in to Sonny to use this.")
        #expect(EntitlementCopy.message(for: .noClaim) == "Connect once so Sonny can check your plan.")
        #expect(EntitlementCopy.message(for: .unreadableClaim)
            == "Sonny couldn't check your plan. Try again in a moment.")
        // **Its own sentence since PR #152's review, F2.** It shared the one above and told a user
        // who had just signed in to sign in again, which could not have helped — the state is the
        // second person on a Mac meeting the first one's claim, and it is now cleared and refetched
        // rather than merely refused.
        #expect(EntitlementCopy.message(for: .claimIsForAnotherSession)
            == "Sonny is catching up with your plan. Try again in a moment.")
        #expect(EntitlementCopy.message(for: .clockUnusable)
            == "Your Mac's date and time are too far off. Set them automatically and try again.")
        #expect(EntitlementCopy.message(for: .lapsed)
            == "Sonny couldn't check your plan recently enough. Reconnect and try again.")
        #expect(EntitlementCopy.message(for: .notEntitled) == "This isn't part of your plan.")
    }

    @Test
    func theStatesAUserCouldConfuseAreToldApart() {
        // The ticket names three that must not read alike — not signed in, not entitled, backend
        // down — and the limits are two more. All five, and their sentences are pairwise distinct.
        let sentences = [
            EntitlementCopy.message(for: .notSignedIn),
            EntitlementCopy.message(for: .notEntitled),
            EntitlementCopy.message(for: .lapsed),
            SonnyBackendCopy.sentence(for: .unreachable("dns")),
            SonnyBackendCopy.sentence(for: .offline),
            SonnyBackendCopy.sentence(for: .api(SonnyBackendAPIError(
                code: .limitRate, statusCode: 429, message: "", requestID: nil,
                retryAfter: 30, envelopeSaysRetryable: true
            ))),
            SonnyBackendCopy.sentence(for: .api(SonnyBackendAPIError(
                code: .limitSpend, statusCode: 429, message: "", requestID: nil,
                retryAfter: nil, envelopeSaysRetryable: false
            )))
        ]
        #expect(Set(sentences).count == sentences.count, "two of these read alike: \(sentences)")
    }

    @Test
    func noneOfThemExplainsHowAnyOfThisWorks() {
        // The standing rule since 2026-08-14: the product does not explain itself. A sentence naming
        // a token, a claim, a server, a signature or an entitlement is disclosure copy, and that
        // lives on the website.
        let forbidden = ["token", "claim", "server", "signature", "entitlement", "gateway", "cache"]
        for refusal in allRefusals {
            let sentence = EntitlementCopy.message(for: refusal).lowercased()
            for word in forbidden {
                #expect(!sentence.contains(word), "\(refusal) says \"\(word)\": \(sentence)")
            }
        }
    }

    @Test
    func everyRefusalIsCovered() {
        // The population, so a case added later is a failing test rather than a silent gap.
        // `EntitlementRefusal` is `CaseIterable` since SONNY-442, and this list stays hand-written
        // anyway: the compiler's exhaustiveness check below is what holds it, and it fails to
        // compile rather than failing at run time — a population held two ways, not one.
        for refusal in allRefusals {
            #expect(!EntitlementCopy.message(for: refusal).isEmpty)
        }
        #expect(allRefusals.count == 7)
    }

    /// Every case, written out through an exhaustive switch so the compiler refuses a stale list.
    private var allRefusals: [EntitlementRefusal] {
        let cases: [EntitlementRefusal] = [
            .notSignedIn, .noClaim, .unreadableClaim, .claimIsForAnotherSession,
            .clockUnusable, .lapsed, .notEntitled
        ]
        // The switch is the check: adding a case to the enum stops this compiling until it is added
        // above as well. `_ =` because the value is not the point — the exhaustiveness is.
        for refusal in cases {
            switch refusal {
            case .notSignedIn, .noClaim, .unreadableClaim, .claimIsForAnotherSession,
                 .clockUnusable, .lapsed, .notEntitled:
                continue
            }
        }
        return cases
    }

    @Test
    func aServerSideEntitlementRefusalReadsAsASentenceRatherThanARetry() {
        // §7.2 cases 2 and 2a reaching the app. Before this ticket both fell through
        // `SignInFailure` to `.unexpected` — "Sonny couldn't finish this one. Try again." — which
        // invites a retry guaranteed to produce the identical answer.
        let required = SonnyBackendCopy.sentence(for: .api(SonnyBackendAPIError(
            code: .entitlementRequired, statusCode: 403, message: "server words", requestID: nil,
            retryAfter: nil, envelopeSaysRetryable: false
        )))
        let expired = SonnyBackendCopy.sentence(for: .api(SonnyBackendAPIError(
            code: .entitlementExpired, statusCode: 403, message: "server words", requestID: nil,
            retryAfter: nil, envelopeSaysRetryable: false
        )))

        #expect(required == "This isn't part of your plan.")
        #expect(expired == "Sonny couldn't check your plan recently enough. Reconnect and try again.")
        // §7.1: the server's own `message` is never displayed.
        #expect(!required.contains("server words"))
        #expect(!expired.contains("server words"))
        // And the local refusal and the wire refusal say the same thing about the same state, which
        // is why both read out of `EntitlementCopy` rather than being written twice.
        #expect(required == EntitlementCopy.message(for: .notEntitled))
        #expect(expired == EntitlementCopy.message(for: .lapsed))
    }

    @Test
    func theTwoLimitsAreToldApartAndNeitherIsAnEntitlementProblem() {
        // §7.2 case 3 clears by waiting; case 3a does not, and gets no `Retry-After` for that reason.
        // The sentences differ accordingly, and neither of them says anything about a plan.
        let rate = SonnyBackendCopy.sentence(for: .api(SonnyBackendAPIError(
            code: .limitRate, statusCode: 429, message: "", requestID: nil,
            retryAfter: 30, envelopeSaysRetryable: true
        )))
        let spend = SonnyBackendCopy.sentence(for: .api(SonnyBackendAPIError(
            code: .limitSpend, statusCode: 429, message: "", requestID: nil,
            retryAfter: nil, envelopeSaysRetryable: false
        )))
        #expect(rate == "Too many requests just now. Try again shortly.")
        #expect(spend == "You're out of allowance for this period.")
        #expect(rate != spend)
    }
}
