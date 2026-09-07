import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-245 and SONNY-256. The wall check, run over six real pages saved verbatim under
/// `Tests/Fixtures/WebResearch/`. (This read "three" while four were committed, from SONNY-245
/// onward; it was stale before SONNY-256 added the last two, and PR #210's F5 sweep is what found
/// it — the ordinal it flagged in the README was one of three sites, not one of two.)
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
            phrase: "confirm you are a human",
            evidence: .visibleText,
            visibleTextLength: 523
        ))
    }

    // MARK: - SONNY-256: a short article about a wall

    /// The ticket's own example, and the page the founders called a first-ten-minutes failure.
    ///
    /// An ordinary link-blog post, 1 110 visible characters, whose entire mention of the subject is
    /// one sentence: "neat concept: a third party service for ensuring that an openid has passed a
    /// captcha." SONNY-245 refused it, because `captcha` was visible-text evidence and the page was
    /// under `interstitialVisibleTextLimit`.
    ///
    /// The assertions before the verdict are what keep this honest, and they are the ones that
    /// establish SONNY-245's verdict: the word is in the *visible* text and the page is *under* the
    /// interstitial limit, which is SONNY-245's rule spelled out. `oldRuleReason` beside them is the
    /// **pre**-SONNY-245 rule — a weaker statement, since it matches markup too — and it is here as a
    /// second witness that the page still carries the evidence, not as a model of SONNY-245
    /// (PR #210 review, F6).
    @Test
    func theShortArticleAboutAWallIsServed() throws {
        let html = try WebResearchFixture.simonWillisonBotBouncer.html()

        let visible = RestrictedContentDetector.visibleText(inHTML: html)
        #expect(visible.count == 1_110)
        #expect(visible.contains("a third party service for ensuring that an openid has passed a captcha"))
        #expect(visible.count < RestrictedContentDetector.interstitialVisibleTextLimit)
        #expect(oldRuleReason(inHTML: html) == "CAPTCHAs")

        #expect(RestrictedContentDetector.finding(inHTML: html) == nil)
    }

    /// The same class arriving from a different kind of page, so the fix is not read as a property of
    /// one blog's template.
    ///
    /// A Hacker News comment page, 327 visible characters — well inside the band where nothing else
    /// saves it — whose whole body is one comment saying "surely you could provide a reference not
    /// behind a paywall?".
    ///
    /// As above, the visible-text and under-the-limit assertions are what establish SONNY-245's
    /// refusal; `oldRuleReason` is the pre-SONNY-245 rule and is the weaker witness (PR #210, F6).
    @Test
    func theShortCommentPageAboutAPaywallIsServed() throws {
        let html = try WebResearchFixture.hackerNewsPaywallComment.html()

        let visible = RestrictedContentDetector.visibleText(inHTML: html)
        #expect(visible.count == 327)
        #expect(visible.contains("surely you could provide a reference not behind a paywall?"))
        #expect(visible.count > RestrictedContentDetector.contentlessVisibleTextLimit)
        #expect(oldRuleReason(inHTML: html) == "paywalls")

        #expect(RestrictedContentDetector.finding(inHTML: html) == nil)
    }

    /// Google's reCAPTCHA attribution is boilerplate a licence requires, it is visible text, and it
    /// says nothing about this reader being gated.
    ///
    /// It is the population PR #108's review found widest: any short page with a reCAPTCHA-protected
    /// contact form, signup or comment box carries it, and under SONNY-245 every one of them under
    /// 2 000 characters was refused. Measured live, `accounts.spotify.com/en/login` (216 visible
    /// characters, 93 of them this notice) and `pixiv.net` (599) were both refused on it.
    ///
    /// **It is served now with no carve-out for the notice**, which is the point: nothing here
    /// excludes a vendor string by name. The badge stopped mattering because `captcha` stopped being
    /// visible-text evidence at all. A rule that named the notice would have had to name the next
    /// one too.
    @Test
    func aShortPageCarryingOnlyTheRecaptchaBadgeIsServed() {
        let notice = "This site is protected by reCAPTCHA and the Google Privacy Policy and Terms of Service apply."
        let filler = String(repeating: "a", count: 300)
        let html = "<html><body><p>\(filler)</p><p>\(notice)</p></body></html>"

        let visible = RestrictedContentDetector.visibleText(inHTML: html)
        #expect(visible.contains("this site is protected by recaptcha"))
        #expect(visible.count > RestrictedContentDetector.contentlessVisibleTextLimit)
        #expect(visible.count < RestrictedContentDetector.interstitialVisibleTextLimit)
        #expect(oldRuleReason(inHTML: html) == "CAPTCHAs")

        #expect(RestrictedContentDetector.finding(inHTML: html) == nil)
    }

    /// The other half of the split, and the one that keeps it fail-closed: a subject noun stops being
    /// visible-text evidence, and wall *speech* on the very same page still refuses it.
    ///
    /// Both pages are 500 visible characters — inside the band, above the markup limit — so length
    /// decides nothing and only the wording does. Without the second case this test would show the
    /// check being narrowed and nothing showing it still fires.
    @Test
    func aSubjectNounIsNotVisibleEvidenceAndWallSpeechOnTheSamePageStillIs() {
        let mentions = page(visibleCharacters: 500, saying: "captcha")
        let speaks = page(visibleCharacters: 500, saying: "please confirm you are a human")

        #expect(RestrictedContentDetector.visibleText(inHTML: mentions).count == 500)
        #expect(RestrictedContentDetector.finding(inHTML: mentions) == nil)

        let refused = RestrictedContentDetector.finding(inHTML: speaks)
        #expect(refused?.reason == "CAPTCHAs")
        #expect(refused?.phrase == "confirm you are a human")
        #expect(refused?.evidence == .visibleText)
        #expect(refused?.visibleTextLength == 500)
    }

    /// The wordings `wallSpeechPhrases` reaches, and — the half that matters — the ones it must not.
    ///
    /// **The control here used to be a sentence containing none of the phrases**, which controls
    /// nothing: a page *discussing* a wall contains the wording, so a sentence that avoids it cannot
    /// show the list is not too loose. PR #210's F1 was found in exactly that gap — the list then
    /// carried `you are human`, `you are a human` and `are you a robot`, and 41 innocent Hacker News
    /// comment pages were refused by it. **The controls below are four of those real comments**,
    /// verbatim, so this test fails if any of those three wordings comes back.
    ///
    /// The reached set is the wall side: Cloudflare's modern and legacy interstitials, ScienceDirect's
    /// gate and Bluehost's security step, in the words those pages actually use.
    @Test
    func wallSpeechReachesRealGateWordingsAndNotReadersTalkingAboutThem() {
        let reached = [
            "Verifying you are human. This may take a few seconds.",
            "Please confirm you are a human by completing the captcha challenge below.",
            "Completing the CAPTCHA proves you are human and gives you access to the web property.",
            "Completing the CAPTCHA proves you are a human and gives you temporary access."
        ]
        for wording in reached {
            let html = page(visibleCharacters: 600, saying: wording)
            #expect(RestrictedContentDetector.finding(inHTML: html)?.reason == "CAPTCHAs", "wording \(wording)")
            #expect(RestrictedContentDetector.finding(inHTML: html)?.evidence == .visibleText, "wording \(wording)")
        }

        let served = [
            "When you think about that $6B company, which if you are human you will do from time to time",
            "The experience is broken by 'are you a robot' walls, subscribe to my blog walls, paywalls",
            "Are you suggesting somehow automating the process of proving you are a human?",
            "How do you prove you are human without handing over yet another phone number?"
        ]
        for comment in served {
            let html = page(visibleCharacters: 600, saying: comment)
            #expect(RestrictedContentDetector.finding(inHTML: html) == nil, "comment \(comment)")
        }
    }

    /// The concatenation order decides which noun a two-phrase page's refusal names, and nothing
    /// asserted that until PR #210's F3 — the claim was checked against the Zillow fixture, which
    /// carries no wall-speech phrase and therefore cannot exercise the ordering at all.
    ///
    /// `phrases` is `wallSpeechPhrases + readerQuotedPhrases + subjectPhrases`, so a contentless page
    /// whose markup carries
    /// both a reCAPTCHA vendor script and a login wording is refused as a **login wall**, not as a
    /// CAPTCHA — the order changed that from SONNY-245, where `captcha` was first. Fail-closed is
    /// intact either way; what moved is the noun the user is shown, and that is worth pinning rather
    /// than discovering.
    @Test
    func aPageCarryingTwoPhrasesInMarkupIsNamedByTheEarlierListEntry() {
        let filler = String(repeating: "a", count: 100)
        let html = """
        <html><body><p>\(filler)</p><!-- Please log in --> \
        <script src="https://www.google.com/recaptcha/api.js"></script></body></html>
        """

        let refused = RestrictedContentDetector.finding(inHTML: html)
        #expect(refused?.evidence == .markup)
        #expect(refused?.reason == "login walls")
        #expect(refused?.phrase == "please log in")

        // The control: with the login wording gone, the same page is a CAPTCHA refusal.
        let captchaOnly = "<html><body><p>\(filler)</p>"
            + "<script src=\"https://www.google.com/recaptcha/api.js\"></script></body></html>"
        let alone = RestrictedContentDetector.finding(inHTML: captchaOnly)
        #expect(alone?.reason == "CAPTCHAs")
        #expect(alone?.phrase == "captcha")
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
            "sciencedirect-captcha-challenge": "CAPTCHAs",
            "simonwillison-botbouncer": "CAPTCHAs",
            "hackernews-paywall-comment": "paywalls"
        ])
        #expect(newVerdicts == [
            "wikipedia-machine-learning": "served",
            "wikipedia-captcha": "served",
            "zillow-perimeterx-block": "CAPTCHAs",
            "sciencedirect-captcha-challenge": "CAPTCHAs",
            "simonwillison-botbouncer": "served",
            "hackernews-paywall-comment": "served"
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
        // A `wallSpeechPhrases` entry, because SONNY-429 moved the login and paywall wordings to
        // markup-only and this test's subject is the limit rather than the phrase.
        let atLimit = page(visibleCharacters: RestrictedContentDetector.interstitialVisibleTextLimit - 1, saying: "confirm you are a human")
        let pastLimit = page(visibleCharacters: RestrictedContentDetector.interstitialVisibleTextLimit, saying: "confirm you are a human")

        let refused = RestrictedContentDetector.finding(inHTML: atLimit)
        #expect(refused?.reason == "CAPTCHAs")
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
        let hidden = "<html><body><p title=\"confirm you are a human\">\(filler)</p>"
            + "<!-- confirm you are a human --></body></html>"
        let spoken = "<html><body><p>confirm you are a human \(filler)</p></body></html>"

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

    /// The phrases keep their nouns, and the earlier match in the list wins. SONNY-256 split them in
    /// two, so both lists are pinned by value and so is the order they concatenate in — the order is
    /// load-bearing, since `firstPhrase` returns the first entry that matches and the `reason` a
    /// refusal names comes from it.
    ///
    /// **Compared as ordered arrays rather than through `Dictionary(uniqueKeysWithValues:)`, and that
    /// is not a style choice.** The dictionary form traps on a duplicate key, and the process dying
    /// takes the whole run's evidence with it: SONNY-256's first battery had exactly that, a mutant
    /// putting `captcha` back into `wallSpeechPhrases` reported as `KILLED — the run failed but named
    /// no test` in 38 seconds, with `Fatal error: Duplicate values for key: 'captcha'` at the end of
    /// a log naming none of the tests that had caught it. The mutant really was caught; nothing in
    /// the report could say by what. (`CLAUDE.md`, "a trapped test costs a mutant its evidence".)
    @Test
    func eachPhraseKeepsItsOwnRefusalNoun() {
        let expectedWallSpeech = [
            ("verify you are human", "CAPTCHAs"),
            ("verifying you are human", "CAPTCHAs"),
            ("verifying you are a human", "CAPTCHAs"),
            ("confirm you are human", "CAPTCHAs"),
            ("confirm you are a human", "CAPTCHAs"),
            ("proves you are human", "CAPTCHAs"),
            ("proves you are a human", "CAPTCHAs")
        ]
        let expectedReaderQuoted = [
            ("please log in", "login walls"),
            ("sign in to continue", "login walls"),
            ("subscribe to continue", "paywalls")
        ]
        let expectedSubjects = [
            ("captcha", "CAPTCHAs"),
            ("subscription required", "paywalls"),
            ("paywall", "paywalls")
        ]

        #expect(RestrictedContentDetector.wallSpeechPhrases.map { [$0.phrase, $0.reason] }
            == expectedWallSpeech.map { [$0.0, $0.1] })
        #expect(RestrictedContentDetector.readerQuotedPhrases.map { [$0.phrase, $0.reason] }
            == expectedReaderQuoted.map { [$0.0, $0.1] })
        #expect(RestrictedContentDetector.subjectPhrases.map { [$0.phrase, $0.reason] }
            == expectedSubjects.map { [$0.0, $0.1] })
        #expect(RestrictedContentDetector.phrases.map { [$0.phrase, $0.reason] }
            == (expectedWallSpeech + expectedReaderQuoted + expectedSubjects).map { [$0.0, $0.1] })

        // Every phrase still names its own noun. A page carrying only the phrase is under
        // `contentlessVisibleTextLimit`, so the three markup-only entries are reached here too.
        for (phrase, reason) in expectedWallSpeech + expectedReaderQuoted + expectedSubjects {
            let html = "<html><body><p>\(phrase)</p></body></html>"
            #expect(RestrictedContentDetector.reason(inHTML: html) == reason, "phrase \(phrase)")
        }
    }

    /// SONNY-429's property: the three login and paywall wordings SONNY-245 introduced are no longer
    /// visible-text evidence, because a reader discussing a wall quotes it **verbatim**.
    ///
    /// This is a different failure from the one `wallSpeechPhrases` guards against. There the person
    /// of the verb separates a wall from a reader — a wall says "verifying you are human", a reader
    /// asks "how do you prove you are human?". Here there is no difference to find: the commenter is
    /// pasting the gate's own sentence, so the wall's string and the reader's string are the same
    /// string. Measured over 425 real pages sampled on these three wordings themselves, they refused
    /// **56 innocent in-band pages** and **0 of 22 real gates in the band**.
    ///
    /// The served set below is four of those real comments — real text, lowercased, and two of them
    /// abridged, which is what "verbatim" overstated before PR #222 recorded it — so this test fails
    /// if any of the three comes back into `wallSpeechPhrases`. It is the control shape PR #210's F1
    /// forced on `wallSpeechReachesRealGateWordingsAndNotReadersTalkingAboutThem`. The case fold they
    /// therefore skip is covered by `matchingFoldsCaseAndDiacriticsAndCollapsesWhitespace` and
    /// `phraseMatchingIsLocaleIndependent`.
    @Test
    func aReaderQuotingALoginOrPaywallWallIsServedInTheInterstitialBand() {
        let served = [
            "\"please log in to continue.\" seriously? one might think they would prioritize "
                + "raising awareness over increasing facebook userbase.",
            "\"sign in to continue\" - as you are new to hn i can tell you that is a big stopper right there.",
            "\"you are in private mode. subscribe to continue reading.\" ok, that's one more i will "
                + "not open anymore; seems bloomberg started using similar \"privacy mode\" detection as nyt.",
            "> we noticed you still have your ad blocker on, please log in to continue to the site. "
                + "> login with forbes but they don't actually say how to signup."
        ]
        for comment in served {
            let html = page(visibleCharacters: 600, saying: comment)
            #expect(RestrictedContentDetector.finding(inHTML: html) == nil, "comment \(comment)")
        }

        // The control that says the band is reachable at all: a CAPTCHA-side wall speech phrase on a
        // page of the identical size is still refused, so these four are served by the phrase table
        // rather than by the page being out of range.
        let stillRefused = page(visibleCharacters: 600, saying: "Please confirm you are a human.")
        #expect(RestrictedContentDetector.finding(inHTML: stillRefused)?.reason == "CAPTCHAs")
        #expect(RestrictedContentDetector.finding(inHTML: stillRefused)?.evidence == .visibleText)
    }

    /// The other half of the same change: the three keep every bit of their markup coverage, so
    /// stage 2 is untouched and `phrases` stays a literal superset of SONNY-245's seven.
    ///
    /// **Every sample here used to sit in an HTML comment, which is a page shape the surviving route
    /// always sees** (PR #222, F3). A phrase in a comment can never be split by an inline tag and
    /// never carries an entity, so the test could not exercise the claim its own doc comment made —
    /// which is about a page whose *visible text* is the gate's sentence. That is `CLAUDE.md`'s
    /// held-sample gotcha in its milder form: nothing asserted was wrong, and what it did not touch
    /// was upstream of it.
    @Test
    func theThreeQuotedWordingsAreStillMarkupEvidenceOnAContentlessPage() {
        for (phrase, reason) in RestrictedContentDetector.readerQuotedPhrases {
            let filler = String(repeating: "a", count: 100)
            let html = "<html><body><p>\(filler)</p><!-- \(phrase) --></body></html>"
            let refused = RestrictedContentDetector.finding(inHTML: html)
            #expect(refused?.reason == reason, "phrase \(phrase)")
            #expect(refused?.phrase == phrase, "phrase \(phrase)")
            #expect(refused?.evidence == .markup, "phrase \(phrase)")
            #expect(refused?.visibleTextLength == 100, "phrase \(phrase)")
        }

        // The control: the same comment on a page above the contentless limit is not evidence, so
        // what refuses the pages above is the limit rather than the comment existing.
        let filler = String(repeating: "a", count: 300)
        let roomy = "<html><body><p>\(filler)</p><!-- please log in --></body></html>"
        #expect(RestrictedContentDetector.finding(inHTML: roomy) == nil)
    }

    /// The shape the test above could not reach: a real login wall below `contentlessVisibleTextLimit`
    /// whose **visible text** is the gate's sentence, written the three ways a gate is really written.
    ///
    /// This is PR #222's F2. Stage 1 reads rendered text and stage 2 read raw markup, so a phrase
    /// that renders contiguously is not necessarily contiguous in the source: an inline `<a>` on the
    /// words "log in", or a `&nbsp;` between them, survives in the markup and defeats the substring
    /// match. Measured over 14 gate wordings, the pre-SONNY-429 rule refuses 8 and the first version
    /// of SONNY-429's rule refused **0** of the anchored pages and **0** of the entity pages. Stage 2
    /// reads the rendered text as well now, which restores all three constructions to the same
    /// verdict.
    ///
    /// The plain row is the control: it passed before the fix too, so a green plain row alone never
    /// distinguished the fixed rule from the broken one.
    @Test
    func aGateBelowTheContentlessLimitIsRefusedHoweverItsSentenceIsWrittenInTheMarkup() throws {
        let constructions: [(label: String, body: String)] = [
            ("plain", "Please log in to continue."),
            ("inline anchor", "Please <a href=\"/account\">log in</a> to continue."),
            ("entities", "Please&nbsp;log&nbsp;in&nbsp;to&nbsp;continue.")
        ]
        for (label, body) in constructions {
            let html = "<html><head><title>Access</title></head><body><main><h1>\(body)</h1>"
                + "<form action=\"/account\" method=\"post\"><input type=\"email\"></form></main></body></html>"
            let visible = RestrictedContentDetector.visibleText(inHTML: html)
            #expect(visible.count < RestrictedContentDetector.contentlessVisibleTextLimit, "\(label) is in range")

            let refused = try #require(RestrictedContentDetector.finding(inHTML: html), "construction \(label)")
            #expect(refused.reason == "login walls", "construction \(label)")
            #expect(refused.phrase == "please log in", "construction \(label)")
            #expect(refused.evidence == .markup, "construction \(label)")
        }

        // The control that says the fold is doing this rather than the page being short: a page of
        // the same three shapes carrying no phrase at all is served.
        for body in ["Welcome <a href=\"/x\">back</a>.", "Welcome&nbsp;back&nbsp;here."] {
            let html = "<html><body><main><h1>\(body)</h1></main></body></html>"
            #expect(RestrictedContentDetector.finding(inHTML: html) == nil, "control \(body)")
        }
    }

    /// Case and diacritics fold, and a phrase broken across markup whitespace still matches.
    @Test
    func matchingFoldsCaseAndDiacriticsAndCollapsesWhitespace() {
        // Markup route: every page here is under `contentlessVisibleTextLimit`, and raw markup is
        // folded before it is searched, so a phrase broken across indentation still matches.
        #expect(RestrictedContentDetector.reason(inHTML: "<html><body><p>CAPTCHA</p></body></html>") == "CAPTCHAs")
        #expect(RestrictedContentDetector.reason(inHTML: "<html><body><p>Please\n   log\tin</p></body></html>") == "login walls")

        // Visible-text route. `&nbsp;` is an entity in the markup and U+00A0 only after SwiftSoup
        // renders it, so this line can match through `visibleText` and through nothing else — which
        // is why it needs a phrase visible text is still trusted for (SONNY-429).
        #expect(RestrictedContentDetector.reason(inHTML: "<html><body><p>Vérify you are human</p></body></html>") == "CAPTCHAs")
        let entities = "<html><body><p>Confirm&nbsp;you&nbsp;are&nbsp;a&nbsp;human now \(String(repeating: "a", count: 400))</p></body></html>"
        #expect(RestrictedContentDetector.reason(inHTML: entities) == "CAPTCHAs")
        #expect(RestrictedContentDetector.finding(inHTML: entities)?.evidence == .visibleText)

        // **The assertion this branch deleted, restored** (PR #222, F2). It was dropped when the
        // login wordings stopped being visible-text evidence, and it is the one line in the suite
        // that would have gone red on the raw-markup gap: below the contentless limit an entity
        // inside the phrase survives in the source, so this page is reachable only once stage 2
        // reads rendered text too. The inline-anchor twin beside it is the same property in the
        // construction a real login wall actually uses.
        #expect(RestrictedContentDetector.reason(
            inHTML: "<html><body><p>Please&nbsp;log&nbsp;in now</p></body></html>") == "login walls")
        #expect(RestrictedContentDetector.reason(
            inHTML: "<html><body><p>Please <a href=\"/a\">log in</a> now</p></body></html>") == "login walls")
    }

    // MARK: - Helpers

    /// **The rule SONNY-245 replaced — the *pre*-SONNY-245 rule, not SONNY-245's own.** It
    /// lowercases the whole raw HTML and matches any phrase anywhere, with no visible-text stage and
    /// no length gate; SONNY-245's rule has both. Call sites must say which they mean, because "the
    /// old rule" is ambiguous once two rules have been replaced (PR #210 review, F6).
    ///
    /// Copied from `PublicWebPageLoader.restrictedContentReason(in:)` as it stood at `94afca1`. It
    /// lives in the test rather than in the source because its only remaining job is to fail.
    ///
    /// One property of it is worth knowing before it is read as a fixed baseline: it searches
    /// `RestrictedContentDetector.phrases`, which SONNY-256 changed, so what it models is
    /// "match anything in today's list anywhere in the markup" rather than a frozen 2026-08-23 list.
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
    case simonWillisonBotBouncer = "simonwillison-botbouncer"
    case hackerNewsPaywallComment = "hackernews-paywall-comment"

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
