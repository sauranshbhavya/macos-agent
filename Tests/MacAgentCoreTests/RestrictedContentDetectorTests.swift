import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-245. The wall check, run over three real pages saved verbatim under
/// `Tests/Fixtures/WebResearch/`.
///
/// **Why fixtures rather than hand-written HTML, stated here because the ticket makes the point and
/// it is the reason this suite exists at all:** a string like
/// `"<html><body><p>captcha</p></body></html>"` is refused by the rule that shipped the defect *and*
/// by the rule that fixes it. It cannot tell them apart, so no test written that way could have
/// caught this — and the suite that was here was written that way. What separates the two rules is
/// where the word sits in a page a server really sent: in a script blob, in an attribute, or in a
/// sentence addressed to a reader. Only a real page carries that.
///
/// The synthetic cases below do a different job, and it is one fixtures cannot: pinning the two
/// limits at their edges, which no naturally-occurring page happens to sit on.
@Suite
@MainActor
struct RestrictedContentDetectorTests {

    // MARK: - The reported defect

    /// The command was `summarize https://en.wikipedia.org/wiki/Machine_learning`, and Sonny
    /// answered "Sonny will not bypass CAPTCHAs".
    ///
    /// Every assertion here is about the *same page* the founder's manual pass hit. The first two
    /// are what keeps this test honest: they prove the fixture still carries the old rule's
    /// evidence, so that a green result means the rule changed rather than that the page did.
    @Test
    func theWikipediaArticleIsServedThoughItsMarkupNamesACaptchaAndAPaywall() throws {
        let html = try WebResearchFixture.wikipediaMachineLearning.html()

        #expect(html.count == 1_142_704)
        #expect(oldRuleReason(inHTML: html) == "CAPTCHAs")
        #expect(occurrences(of: "captcha", inCaseFolded: html) == 4)
        #expect(occurrences(of: "subscription required", inCaseFolded: html) == 2)

        let visible = RestrictedContentDetector.visibleText(inHTML: html)
        #expect(visible.count == 130_932)
        #expect(visible.contains("captcha") == false)
        #expect(visible.contains("subscription required") == false)
        #expect(visible.contains("machine learning (ml) is a field of study in artificial intelligence"))

        #expect(RestrictedContentDetector.finding(inHTML: html) == nil)
    }

    /// Where the two matches actually live, asserted rather than described — a script body and an
    /// attribute value, the two places `Element.text()` does not reach.
    @Test
    func theWikipediaMatchesAreInAScriptBodyAndAnAttributeValue() throws {
        let html = try WebResearchFixture.wikipediaMachineLearning.html()
        let folded = caseFolded(html)

        #expect(folded.contains("\"wgconfirmedithcaptchasitekey\""))
        #expect(folded.contains("title=\"paid subscription required\""))
    }

    /// The ticket's own sentence, on a page that makes it literally true: "A page *about* a thing is
    /// treated as a page *guarded by* that thing."
    ///
    /// Wikipedia's CAPTCHA article says the word to a reader 167 times, so unlike the
    /// machine-learning article it carries visible-text evidence and not only markup evidence. What
    /// serves it is `interstitialVisibleTextLimit`: at 30 785 visible characters it is an article,
    /// and an article that discusses CAPTCHAs is still an article.
    @Test
    func theCaptchaArticleIsServedThoughItSaysTheWordToAReaderThroughout() throws {
        let html = try WebResearchFixture.wikipediaCaptcha.html()

        #expect(html.count == 330_488)
        #expect(oldRuleReason(inHTML: html) == "CAPTCHAs")

        let visible = RestrictedContentDetector.visibleText(inHTML: html)
        #expect(visible.count == 30_785)
        #expect(occurrences(of: "captcha", inCaseFolded: visible) == 167)
        #expect(visible.count > RestrictedContentDetector.interstitialVisibleTextLimit)

        #expect(RestrictedContentDetector.finding(inHTML: html) == nil)
    }

    // MARK: - Genuine walls, one of each shape

    /// A wall that says nothing, because JavaScript was going to say it. The only trace in what the
    /// server sent is the vendor's script — which is exactly the evidence the old rule used, and it
    /// was right here and wrong on Wikipedia for the same reason.
    @Test
    func theZillowBlockPageIsRefusedOnMarkupBecauseItShowsAReaderNothingAtAll() throws {
        let html = try WebResearchFixture.zillowPerimeterXBlock.html()

        #expect(RestrictedContentDetector.visibleText(inHTML: html).isEmpty)
        #expect(occurrences(of: "captcha", inCaseFolded: html) == 31)
        #expect(caseFolded(html).contains("<title>access to this page has been denied</title>"))

        #expect(RestrictedContentDetector.finding(inHTML: html) == RestrictedContentDetector.Finding(
            reason: "CAPTCHAs",
            phrase: "captcha",
            evidence: .markup,
            visibleTextLength: 0
        ))
    }

    /// A wall that does speak: "Are you a robot? Please confirm you are a human by completing the
    /// captcha challenge below."
    ///
    /// 1.2 MB of markup, 523 characters of text. Beside the Wikipedia fixture's 1.1 MB of markup and
    /// 130 932 characters of text, this is the whole fix in two files: page size decides nothing.
    @Test
    func theScienceDirectGateIsRefusedOnWhatItSaysToTheReader() throws {
        let html = try WebResearchFixture.scienceDirectCaptchaChallenge.html()

        let visible = RestrictedContentDetector.visibleText(inHTML: html)
        #expect(html.count == 1_207_696)
        #expect(visible.count == 523)
        #expect(visible.contains("are you a robot? please confirm you are a human by completing the captcha challenge below."))

        #expect(RestrictedContentDetector.finding(inHTML: html) == RestrictedContentDetector.Finding(
            reason: "CAPTCHAs",
            phrase: "captcha",
            evidence: .visibleText,
            visibleTextLength: 523
        ))
    }

    // MARK: - Both ways, on the same three pages

    /// The assertion the ticket asks for in so many words: the old rule cannot separate these pages
    /// and the new one can.
    ///
    /// This is the test that would have failed before the change — every other test in this suite
    /// asserts one page's verdict, and a reader can always wonder whether the fixtures were chosen
    /// to agree with the code. Here the two rules run over the identical input and disagree in
    /// exactly two places: the two encyclopedia articles.
    @Test
    func theOldRuleRefusedEveryFixtureAndTheNewRuleRefusesOnlyTheTwoWalls() throws {
        var oldVerdicts: [String: String] = [:]
        var newVerdicts: [String: String] = [:]
        for fixture in WebResearchFixture.allCases {
            let html = try fixture.html()
            oldVerdicts[fixture.rawValue] = oldRuleReason(inHTML: html) ?? "served"
            newVerdicts[fixture.rawValue] = RestrictedContentDetector.reason(inHTML: html) ?? "served"
        }

        #expect(oldVerdicts == [
            "wikipedia-machine-learning": "CAPTCHAs",
            "wikipedia-captcha": "CAPTCHAs",
            "zillow-perimeterx-block": "CAPTCHAs",
            "sciencedirect-captcha-challenge": "CAPTCHAs"
        ])
        #expect(newVerdicts == [
            "wikipedia-machine-learning": "served",
            "wikipedia-captcha": "served",
            "zillow-perimeterx-block": "CAPTCHAs",
            "sciencedirect-captcha-challenge": "CAPTCHAs"
        ])
    }

    // MARK: - The whole loader, on the same pages

    @Test
    func theLoaderExtractsTheWikipediaArticleItUsedToRefuse() async throws {
        let url = URL(string: "https://en.wikipedia.org/wiki/Machine_learning")!
        let loader = PublicWebPageLoader(
            fetcher: FixtureWebPageFetcher(
                page: FetchedWebPage(
                    requestedURL: url,
                    html: try WebResearchFixture.wikipediaMachineLearning.html()
                )
            ),
            robotsChecker: AlwaysAllowingRobotsChecker(),
            extractor: SwiftSoupReadableWebExtractor()
        )

        let page = try await loader.load(rawURL: url.absoluteString)

        #expect(page.title == "Machine learning - Wikipedia")
        #expect(page.readableText.count == 112_757)
        #expect(page.readableText.contains("Machine learning (ML) is a field of study in artificial intelligence"))
    }

    @Test
    func theLoaderStillRefusesARealBlockPageAndNamesTheWall() async throws {
        let url = URL(string: "https://www.zillow.com/")!
        let loader = PublicWebPageLoader(
            fetcher: FixtureWebPageFetcher(
                page: FetchedWebPage(
                    requestedURL: url,
                    html: try WebResearchFixture.zillowPerimeterXBlock.html()
                )
            ),
            robotsChecker: AlwaysAllowingRobotsChecker(),
            extractor: SwiftSoupReadableWebExtractor()
        )

        await #expect(throws: WebResearchError.restrictedContent("CAPTCHAs")) {
            _ = try await loader.load(rawURL: url.absoluteString)
        }
    }

    // MARK: - The two limits, at their edges

    /// Visible-text evidence is trusted right up to `interstitialVisibleTextLimit` and not past it.
    ///
    /// Synthetic on purpose: no page in the corpus sits on the boundary, and a constant nothing
    /// asserts is a constant anyone may quietly change.
    @Test
    func aPhraseAReaderCanSeeCountsUpToTheInterstitialLimitAndNotBeyondIt() {
        let atLimit = page(visibleCharacters: RestrictedContentDetector.interstitialVisibleTextLimit - 1, saying: "please log in")
        let pastLimit = page(visibleCharacters: RestrictedContentDetector.interstitialVisibleTextLimit, saying: "please log in")

        let refused = RestrictedContentDetector.finding(inHTML: atLimit)
        #expect(refused?.reason == "login walls")
        #expect(refused?.evidence == .visibleText)
        #expect(refused?.visibleTextLength == 1_999)

        #expect(RestrictedContentDetector.finding(inHTML: pastLimit) == nil)
    }

    /// Markup evidence needs the page to be showing a reader essentially nothing.
    ///
    /// The second case is the one this narrow limit is for: a small page that has something to say
    /// and loads a CAPTCHA widget for its own comment form. The old rule refused it.
    @Test
    func aPhraseOnlyInMarkupCountsUpToTheContentlessLimitAndNotBeyondIt() {
        let nearlyEmpty = pageWithScript(
            visibleCharacters: RestrictedContentDetector.contentlessVisibleTextLimit - 1,
            scriptSource: "https://www.google.com/recaptcha/api.js"
        )
        let smallButRealPage = pageWithScript(
            visibleCharacters: RestrictedContentDetector.contentlessVisibleTextLimit,
            scriptSource: "https://www.google.com/recaptcha/api.js"
        )

        let refused = RestrictedContentDetector.finding(inHTML: nearlyEmpty)
        #expect(refused?.reason == "CAPTCHAs")
        #expect(refused?.evidence == .markup)
        #expect(refused?.visibleTextLength == 199)

        #expect(RestrictedContentDetector.finding(inHTML: smallButRealPage) == nil)
    }

    /// A comment and an attribute are not what a page says to a reader — the two places the
    /// Wikipedia article's own matches live, isolated here on a page short enough that the
    /// difference decides the verdict.
    ///
    /// 1 000 visible characters is between the two limits on purpose: the visible-text stage is in
    /// range and finds nothing, and the markup stage — which would find both — is out of range. Move
    /// the same word into the paragraph and the page is refused, which is the control.
    @Test
    func aCommentAndAnAttributeAreNotWhatAPageSaysToAReader() {
        let filler = String(repeating: "a", count: 1_000)
        let hidden = "<html><body><p title=\"captcha\">\(filler)</p><!-- captcha --></body></html>"
        let spoken = "<html><body><p>captcha \(filler)</p></body></html>"

        #expect(RestrictedContentDetector.visibleText(inHTML: hidden).count == 1_000)
        #expect(RestrictedContentDetector.finding(inHTML: hidden) == nil)
        #expect(RestrictedContentDetector.finding(inHTML: spoken)?.evidence == .visibleText)
    }

    /// An inline icon must not erase the page's visible text.
    ///
    /// `<svg><style>…</style></svg>` matches the detector's removal selector twice, parent first, so
    /// the second removal acts on an orphan. It is a no-op today — SwiftSoup 2.13.5's
    /// `Node.remove()` optional-chains through the parent — and this test exists because of what
    /// happens if that ever stops being true: a throw abandons the removal loop, `visibleText`
    /// returns "", and a page with nothing on it is judged on its markup, which here names a CAPTCHA
    /// script. A decorative icon would then be enough to refuse an ordinary page.
    ///
    /// Stated as verified rather than as reasoning, since the first version of this comment had the
    /// mechanism backwards: the plain `try` was measured, and the test passes with it.
    @Test
    func anInlineIconWithItsOwnStyleDoesNotEraseThePagesVisibleText() {
        let filler = String(repeating: "a", count: 1_000)
        let html = """
        <html><body><svg><style>.logo { fill: red }</style></svg><p>\(filler)</p>\
        <script src="https://cdn.example/captcha.js"></script></body></html>
        """

        #expect(RestrictedContentDetector.visibleText(inHTML: html).count == 1_000)
        #expect(RestrictedContentDetector.finding(inHTML: html) == nil)
    }

    /// Markup evidence is folded and whitespace-collapsed before it is searched, and **that is the
    /// stage that catches every modern bot wall** — so it needs its own test rather than sharing the
    /// visible-text one.
    ///
    /// PR #108's review found this unheld: `visibleText` already normalises what it returns, so
    /// stage 1 keeps working with the normalisation removed from `firstPhrase`, and only stage 2 —
    /// which is handed raw markup — notices. A mutation that dropped it survived the whole suite.
    @Test
    func markupEvidenceIsFoldedAndCollapsedBeforeItIsSearched() {
        let filler = String(repeating: "a", count: 100)
        let mixedCase = "<html><body><p>\(filler)</p><script src=\"https://ct.CAPTCHA-Delivery.com/c.js\"></script></body></html>"
        let brokenAcrossLines = "<html><body><p>\(filler)</p><!-- Please\n      log in --></body></html>"

        let vendorScript = RestrictedContentDetector.finding(inHTML: mixedCase)
        #expect(vendorScript?.reason == "CAPTCHAs")
        #expect(vendorScript?.evidence == .markup)
        #expect(vendorScript?.visibleTextLength == 100)

        let splitPhrase = RestrictedContentDetector.finding(inHTML: brokenAcrossLines)
        #expect(splitPhrase?.reason == "login walls")
        #expect(splitPhrase?.evidence == .markup)
    }

    /// Two Macs must not disagree about the same page, and the hazard is measured rather than
    /// supposed.
    ///
    /// Three of the seven phrases contain the letter `i`, and a Turkish or Azerbaijani locale folds
    /// uppercase `I` to dotless `ı` — so `PLEASE LOG IN` folds to `please log ın` under
    /// `locale: .current` on a Mac set to Turkish, and stops matching. The rule this replaced folded
    /// with `.current`; this one folds with `nil`.
    ///
    /// **The test process cannot show that behaviourally** — its locale is en_IN, where `.current`
    /// and `nil` agree — so the property is held by a scan of the source, and the scan is shown to
    /// flag the code it exists to forbid before it is believed (`CLAUDE.md`: a source scan is only a
    /// guard once it has been shown to flag the defect it names). PR #108's review found a mutation
    /// putting `.current` back surviving the whole suite.
    @Test
    func phraseMatchingIsLocaleIndependent() throws {
        let uppercase = "PLEASE LOG IN"
        #expect(fold(uppercase, locale: Locale(identifier: "tr_TR")) == "please log ın")
        #expect(fold(uppercase, locale: nil) == "please log in")
        #expect(RestrictedContentDetector.reason(inHTML: "<html><body><p>\(uppercase)</p></body></html>") == "login walls")

        let historical = """
        let normalized = html
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        """
        #expect(Self.localeDependentFoldingLines(in: historical) == [2])

        let source = try String(contentsOf: Self.detectorSourceURL, encoding: .utf8)
        #expect(Self.localeDependentFoldingLines(in: source) == [])
    }

    /// A wall that answers 4xx never reaches the detector, and until PR #108's review (F7) nothing
    /// in the repository constructed a non-2xx `FetchedWebPage` at all — so `validate`'s ordering
    /// was unexercised while this branch's own documentation leaned on it as a safety argument.
    ///
    /// The status here is the one the Zillow fixture was really fetched with, recorded in
    /// `Tests/Fixtures/WebResearch/README.md`. Its pair is
    /// `theLoaderStillRefusesARealBlockPageAndNamesTheWall`, which serves the identical bytes at 200
    /// and gets the wall's name instead — so the two together pin which check speaks, not merely
    /// that something refuses.
    @Test
    func aWallThatAnswersWithAnErrorStatusIsRefusedOnTheStatusBeforeTheDetectorRuns() async throws {
        let url = URL(string: "https://www.zillow.com/")!
        let loader = PublicWebPageLoader(
            fetcher: FixtureWebPageFetcher(
                page: FetchedWebPage(
                    requestedURL: url,
                    statusCode: 403,
                    html: try WebResearchFixture.zillowPerimeterXBlock.html()
                )
            ),
            robotsChecker: AlwaysAllowingRobotsChecker(),
            extractor: SwiftSoupReadableWebExtractor()
        )

        await #expect(throws: WebResearchError.badHTTPStatus(403, url.absoluteString)) {
            _ = try await loader.load(rawURL: url.absoluteString)
        }
    }

    /// The phrases keep their nouns, and the earlier match in the list wins — unchanged from the
    /// rule this replaces, since SONNY-245 changed the evidence and not the coverage.
    @Test
    func eachPhraseKeepsItsOwnRefusalNoun() {
        let expected: [String: String] = [
            "captcha": "CAPTCHAs",
            "verify you are human": "CAPTCHAs",
            "please log in": "login walls",
            "sign in to continue": "login walls",
            "subscribe to continue": "paywalls",
            "subscription required": "paywalls",
            "paywall": "paywalls"
        ]

        #expect(Dictionary(uniqueKeysWithValues: RestrictedContentDetector.phrases.map { ($0.phrase, $0.reason) }) == expected)

        for (phrase, reason) in expected {
            let html = "<html><body><p>\(phrase)</p></body></html>"
            #expect(RestrictedContentDetector.reason(inHTML: html) == reason, "phrase \(phrase)")
        }
    }

    /// Case and diacritics fold, and a phrase broken across markup whitespace still matches.
    @Test
    func matchingFoldsCaseAndDiacriticsAndCollapsesWhitespace() {
        #expect(RestrictedContentDetector.reason(inHTML: "<html><body><p>CAPTCHA</p></body></html>") == "CAPTCHAs")
        #expect(RestrictedContentDetector.reason(inHTML: "<html><body><p>Vérify you are human</p></body></html>") == "CAPTCHAs")
        #expect(RestrictedContentDetector.reason(inHTML: "<html><body><p>Please\n   log\tin</p></body></html>") == "login walls")
        #expect(RestrictedContentDetector.reason(inHTML: "<html><body><p>Please&nbsp;log&nbsp;in now</p></body></html>") == "login walls")
    }

    // MARK: - Helpers

    /// The rule SONNY-245 replaced, reimplemented here so both can be run over the same page.
    ///
    /// Copied from `PublicWebPageLoader.restrictedContentReason(in:)` as it stood at `94afca1`. It
    /// lives in the test rather than in the source because its only remaining job is to fail.
    private func oldRuleReason(inHTML html: String) -> String? {
        let normalized = html
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return RestrictedContentDetector.phrases.first { normalized.contains($0.phrase) }?.reason
    }

    /// The detector's own source, for the locale scan.
    static let detectorSourceURL = TestSourceTree.root
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MacAgentCore/RestrictedContentDetector.swift")

    /// 1-based numbers of the **code** lines that fold with a locale-dependent locale.
    ///
    /// Comment-prefixed lines are excluded by `TestSourceTree.codeLines`, which matters here rather
    /// than being tidiness: the doc comment on `normalized` says the words `locale: .current` while
    /// explaining why the code does not use them, and a scan that could not tell the two apart would
    /// fail against the fixed tree.
    static func localeDependentFoldingLines(in source: String) -> [Int] {
        TestSourceTree.codeLines(of: source)
            .filter { $0.text.contains("folding(") || $0.text.contains("locale:") }
            .filter { $0.text.contains("locale: .current") }
            .map(\.number)
    }

    private func fold(_ value: String, locale: Locale?) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale).lowercased()
    }

    private func caseFolded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    private func occurrences(of needle: String, inCaseFolded value: String) -> Int {
        caseFolded(value).components(separatedBy: needle).count - 1
    }

    /// A page carrying exactly `visibleCharacters` characters of body text, `saying` among them.
    private func page(visibleCharacters: Int, saying phrase: String) -> String {
        let filler = String(repeating: "a", count: max(0, visibleCharacters - phrase.count - 1))
        return "<html><body><p>\(phrase) \(filler)</p></body></html>"
    }

    /// A page carrying exactly `visibleCharacters` characters of body text and no wall phrase in any
    /// of them, plus a script the phrase appears in.
    private func pageWithScript(visibleCharacters: Int, scriptSource: String) -> String {
        let filler = String(repeating: "a", count: max(0, visibleCharacters))
        return "<html><body><p>\(filler)</p><script src=\"\(scriptSource)\"></script></body></html>"
    }
}

/// The saved pages, by the name they are filed under.
enum WebResearchFixture: String, CaseIterable {
    case wikipediaMachineLearning = "wikipedia-machine-learning"
    case wikipediaCaptcha = "wikipedia-captcha"
    case zillowPerimeterXBlock = "zillow-perimeterx-block"
    case scienceDirectCaptchaChallenge = "sciencedirect-captcha-challenge"

    enum FixtureError: Error {
        case unreadable(String)
    }

    /// Decoded the way `URLSessionWebPageFetcher` decodes a response body, so the tests see what the
    /// app would see rather than what a more forgiving reader would.
    func html() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/WebResearch/\(rawValue).html")
        let data = try Data(contentsOf: url)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw FixtureError.unreadable(rawValue)
        }
        return html
    }
}

@MainActor
private struct FixtureWebPageFetcher: WebPageFetching {
    var page: FetchedWebPage

    func fetch(_ url: URL) async throws -> FetchedWebPage {
        page
    }
}

@MainActor
private struct AlwaysAllowingRobotsChecker: RobotsTXTChecking {
    func canFetch(_ url: URL, userAgent: String) async throws -> Bool {
        true
    }
}
