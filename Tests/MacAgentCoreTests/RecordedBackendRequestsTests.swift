import Foundation
import Testing
import MacAgentTestSupport

/// SONNY-331. `RecordedBackendRequests.only` says "exactly one", and now checks it.
///
/// **Why a helper needs its own suite.** `only` read
/// `try #require(all.first, "expected exactly one request, saw \(all.count)")`, which is satisfied
/// by one request and by fifty — `all.first` is non-nil at any count at or above one — so the
/// message could only ever print when the array was empty, the single case where "saw N" reads
/// `saw 0`. A guarantee whose failure text can never appear beside a count that disproves it is a
/// guarantee nothing holds, and twenty-four call sites across six files were reading `try
/// recorded.only` as "the one request".
///
/// **The tightening broke nothing, and that is the finding rather than a relief.** Run over the
/// whole tree the honest version failed no test at all, so every one of those twenty-four sites did
/// send exactly one request; what was missing was never a correct call site, it was anything that
/// would notice an incorrect one. Which means the new check is unexercised by the suite it protects
/// — nothing in the tree sends two requests to a stub and then asks for the only one — and this
/// file is what exercises it. Without it the change would be the same class of thing it fixes: a
/// promise nobody tests.
///
/// `withKnownIssue` is how a guard proves it fires, following `HangBackstopTests`, which does the
/// same for the backstop's two verdicts.
@Suite
struct RecordedBackendRequestsTests {
    /// The ordinary reading, so the failures below are about the count and not about the helper
    /// being broken outright.
    @Test
    func onlyReturnsTheOneRequestWhenThereIsExactlyOne() throws {
        let recorded = RecordedBackendRequests()
        recorded.append(request(path: "/v1/plan"))

        #expect(try recorded.only.path == "/v1/plan")
        #expect(recorded.all.count == 1)
    }

    /// **The whole ticket, in one assertion.** Before this, `only` returned the *first* of two and
    /// the caller read it as the one.
    @Test
    func onlyRefusesASecondRequestRatherThanReturningTheFirstOfTwo() throws {
        let recorded = RecordedBackendRequests()
        recorded.append(request(path: "/v1/plan"))
        recorded.append(request(path: "/v1/plan"))

        withKnownIssue("`only` must refuse two requests — that is the whole of what its name claims") {
            _ = try recorded.only
        }

        // And the lenient reading is still available under its own name, which is what a call site
        // that genuinely wants the first of several should be saying. Nothing was taken away; a
        // claim was made checkable.
        #expect(recorded.all.count == 2)
        #expect(recorded.all.first?.path == "/v1/plan")
    }

    /// The empty case, which is the one the old message could actually print for — kept so the
    /// tightening cannot be read as having traded one direction for the other.
    @Test
    func onlyStillRefusesNoRequestsAtAll() throws {
        let recorded = RecordedBackendRequests()

        withKnownIssue("`only` must refuse an empty recording") {
            _ = try recorded.only
        }

        #expect(recorded.all.isEmpty)
    }

    /// **The message has to name the count it is complaining about, because the old one described a
    /// check it did not perform.** Asserted on the numbers and the paths the message must carry,
    /// never by comparing a whole sentence — the same rule `HangBackstopTests` states for its own
    /// wordings, and for the sharper reason there: a test's failure text is read by
    /// `scripts/mutate-untrusted-failures`, so quoting a sentence is how a guard ends up matching a
    /// declared signature.
    @Test
    func theRefusalNamesHowManyItSawAndWhichPathsTheyWere() throws {
        let recorded = RecordedBackendRequests()
        recorded.append(request(path: "/v1/plan"))
        recorded.append(request(path: "/v1/research/synthesize"))

        try withKnownIssue {
            _ = try recorded.only
        } matching: { issue in
            let text = String(describing: issue)
            return text.contains("2")
                && text.contains("/v1/plan")
                && text.contains("/v1/research/synthesize")
        }
    }

    private func request(path: String) -> URLRequest {
        URLRequest(url: URL(string: "https://example.invalid\(path)")!)
    }
}
