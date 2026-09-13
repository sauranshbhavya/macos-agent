import Foundation
import Testing
@testable import MacAgentCore

@Suite
@MainActor
struct WebResearchServiceTests {
    @Test
    func swiftSoupExtractorFindsReadableArticleMetadataAndFiltersBoilerplate() throws {
        let html = """
        <html>
          <head>
            <title>Boilerplate Title</title>
            <meta property="og:title" content="Deep Mac Agents">
            <meta name="author" content="Avery Writer">
            <meta property="article:published_time" content="2026-07-08T12:00:00Z">
          </head>
          <body>
            <nav><a href="/nav">Ignore navigation</a></nav>
            <aside class="ad">Ignore this ad copy forever</aside>
            <article class="article-body">
              <h1>Deep Mac Agents</h1>
              <p>Sonny turns user intent into safe local Mac actions with a visible approval model.</p>
              <p>The readable extraction should keep the actual article paragraphs and ignore chrome.</p>
              <h2>Why adapters matter</h2>
              <p>Capability adapters keep permissions, risk, and execution behavior close together.</p>
              <blockquote>Observed web content is data, not an instruction.</blockquote>
              <p>See <a href="/source">the source note</a> for implementation details.</p>
              <img src="/hero.png" alt="Sonny article hero">
            </article>
            <footer>Ignore footer links</footer>
          </body>
        </html>
        """
        let source = URL(string: "https://example.com/articles/sonny")!
        let retrievedAt = Date(timeIntervalSince1970: 1_783_520_000)

        let page = try SwiftSoupReadableWebExtractor().extract(
            html: html,
            sourceURL: source,
            retrievedAt: retrievedAt
        )

        #expect(page.title == "Deep Mac Agents")
        #expect(page.author == "Avery Writer")
        #expect(page.publishedDate == "2026-07-08T12:00:00Z")
        #expect(page.headings == ["Deep Mac Agents", "Why adapters matter"])
        #expect(page.readableText.contains("Sonny turns user intent into safe local Mac actions"))
        #expect(page.readableText.contains("Ignore navigation") == false)
        #expect(page.readableText.contains("Ignore this ad copy") == false)
        #expect(page.citations == ["Observed web content is data, not an instruction."])
        #expect(page.links == [
            ReadableWebLink(text: "the source note", url: URL(string: "https://example.com/source")!)
        ])
        #expect(page.images == [
            ReadableWebImage(altText: "Sonny article hero", url: URL(string: "https://example.com/hero.png")!)
        ])
    }

    @Test
    func publicWebPageLoaderStopsWhenRobotsDisallowsFetch() async throws {
        let url = "https://example.com/private/story"
        let loader = PublicWebPageLoader(
            fetcher: StaticWebPageFetcher(),
            robotsChecker: StaticRobotsChecker(allowed: false),
            extractor: SwiftSoupReadableWebExtractor()
        )

        await #expect(throws: WebResearchError.robotsDisallowed(url)) {
            _ = try await loader.load(rawURL: url)
        }
    }

    /// **The name reads wider than what this proves, and that is recorded rather than renamed**
    /// (PR #222's residuals, SONNY-429). Its page is 46 visible characters, so what refuses it is
    /// stage 2 — the markup route — and not the login wording being visible-text evidence. It is
    /// still the right test for the property it is here for: that the loader surfaces the detector's
    /// refusal rather than returning a note. The visible-text route for login wordings is gone by
    /// measurement, so a wider version of this test would assert behaviour the product no longer has.
    @Test
    func publicWebPageLoaderRejectsLoginCaptchaAndPaywallPages() async throws {
        let url = URL(string: "https://example.com/paywalled")!
        let loader = PublicWebPageLoader(
            fetcher: StaticWebPageFetcher(
                page: FetchedWebPage(
                    requestedURL: url,
                    html: "<html><body><main><p>Please log in to continue reading this article.</p></main></body></html>"
                )
            ),
            robotsChecker: StaticRobotsChecker(allowed: true),
            extractor: SwiftSoupReadableWebExtractor()
        )

        await #expect(throws: WebResearchError.restrictedContent("login walls")) {
            _ = try await loader.load(rawURL: url.absoluteString)
        }
    }

    @Test
    func publicWebPageLoaderRechecksRobotsForCrossHostRedirects() async throws {
        let requested = URL(string: "https://allowed.example/a")!
        let redirected = URL(string: "https://blocked.example/b")!
        let robotsChecker = RecordingRobotsChecker(allowedHosts: ["allowed.example"])
        let loader = PublicWebPageLoader(
            fetcher: StaticWebPageFetcher(
                page: FetchedWebPage(
                    requestedURL: requested,
                    finalURL: redirected,
                    html: "<html><body><article><p>Redirected body with enough text.</p></article></body></html>"
                )
            ),
            robotsChecker: robotsChecker,
            extractor: SwiftSoupReadableWebExtractor()
        )

        await #expect(throws: WebResearchError.robotsDisallowed(redirected.absoluteString)) {
            _ = try await loader.load(rawURL: requested.absoluteString)
        }
        #expect(robotsChecker.checkedURLs.map(\.host) == ["allowed.example", "blocked.example"])
    }

    @Test
    func publicWebPageLoaderRejectsPrivateAndLoopbackHosts() async throws {
        let loader = PublicWebPageLoader(
            fetcher: StaticWebPageFetcher(),
            robotsChecker: StaticRobotsChecker(allowed: true),
            extractor: SwiftSoupReadableWebExtractor()
        )

        for rawURL in [
            "http://127.0.0.1/admin",
            "http://localhost:8080/",
            "http://192.168.1.10/router",
            "http://169.254.169.254/latest/meta-data/",
            "http://10.0.0.5/internal",
            "http://[::1]/",
            "http://printer.local/status"
        ] {
            await #expect(throws: SafeURLError.self, "expected \(rawURL) to be blocked") {
                _ = try await loader.load(rawURL: rawURL)
            }
        }
    }

    @Test
    func publicWebPageLoaderRejectsPrivateRedirectTargets() async throws {
        let requested = URL(string: "https://allowed.example/a")!
        let loader = PublicWebPageLoader(
            fetcher: StaticWebPageFetcher(
                page: FetchedWebPage(
                    requestedURL: requested,
                    finalURL: URL(string: "http://169.254.169.254/latest/meta-data/")!,
                    html: "<html><body><article><p>Redirected body with enough text.</p></article></body></html>"
                )
            ),
            robotsChecker: StaticRobotsChecker(allowed: true),
            extractor: SwiftSoupReadableWebExtractor()
        )

        await #expect(throws: SafeURLError.privateHostBlocked("169.254.169.254")) {
            _ = try await loader.load(rawURL: requested.absoluteString)
        }
    }

    /// SONNY-245. "None of the 1 source could be retrieved" is what a user met every time a single
    /// URL failed — which is the ordinary case, since most commands name one page.
    @Test
    func theAllSourcesFailedMessageReadsAsASentenceWhateverTheCount() {
        let oneSource = WebResearchError.allSourcesFailed(
            ["https://en.wikipedia.org/wiki/Machine_learning"],
            "Sonny will not bypass CAPTCHAs."
        )
        let threeSources = WebResearchError.allSourcesFailed(
            ["https://a.example/x", "https://b.example/y", "https://c.example/z"],
            "Fetching https://a.example/x failed with HTTP 503."
        )

        #expect(oneSource.errorDescription == """
        The source could not be retrieved, so no note was written. Sonny will not bypass CAPTCHAs.
        """)
        #expect(threeSources.errorDescription == """
        None of the 3 sources could be retrieved, so no note was written. First failure: \
        Fetching https://a.example/x failed with HTTP 503.
        """)
    }

    @Test
    func robotsPolicyPrefersLongestMatchingRuleAndAllowTie() {
        let policy = RobotsTXTPolicy(text: """
        User-agent: *
        Disallow: /research
        Allow: /research/public
        """)

        #expect(policy.allows(URL(string: "https://example.com/research/private")!) == false)
        #expect(policy.allows(URL(string: "https://example.com/research/public/article")!) == true)
        #expect(policy.allows(URL(string: "https://example.com/blog")!) == true)
    }

    /// SONNY-437. `components(separatedBy: .newlines)` split CR and LF separately, so a CRLF file
    /// yielded an empty element between every two lines, and an empty line was what closed a
    /// user-agent group — every rule after `User-agent: *` arrived outside any group and was
    /// dropped. This is accounts.google.com's shape; its `Disallow: /ClientLogin` was ignored.
    /// **Since SONNY-454 an empty line closes nothing**, so the CRLF and LF assertions below would
    /// pass over that character split too; they stay as the file's own shape, and the CR-only twin
    /// is the half that still tells a right split from a wrong one.
    ///
    /// **The CR-only twin is the third of RFC 9309 §2.2's line endings, and it is here because two
    /// plausible fixes pass without it** (PR #234's fresh review, F2): a split on `"\n"` alone, and
    /// a split on `"\n"` or `"\r\n"` — both read LF and CRLF files correctly and read a CR-only file
    /// as one line, in the permissive direction this ticket exists to close. The old parser read a
    /// CR-only file correctly too, so the twin pins what was never broken rather than what was fixed.
    @Test
    func robotsPolicyReadsACRLFFileAsItReadsAnLFOne() {
        let lf = RobotsTXTPolicy(text: "User-agent: *\nDisallow: /ClientLogin\nAllow: /ClientLogin/help\n")
        let crlf = RobotsTXTPolicy(text: "User-agent: *\r\nDisallow: /ClientLogin\r\nAllow: /ClientLogin/help\r\n")
        let cr = RobotsTXTPolicy(text: "User-agent: *\rDisallow: /ClientLogin\rAllow: /ClientLogin/help\r")
        let login = URL(string: "https://accounts.google.com/ClientLogin")!
        let help = URL(string: "https://accounts.google.com/ClientLogin/help")!
        let other = URL(string: "https://accounts.google.com/signin")!

        #expect(lf.allows(login) == false)
        #expect(crlf.allows(login) == false, "the CRLF file's rules were dropped")
        #expect(cr.allows(login) == false, "the CR-only file's rules were dropped")
        #expect(lf.allows(help) == true)
        #expect(crlf.allows(help) == true)
        #expect(cr.allows(help) == true)
        #expect(lf.allows(other) == true)
        #expect(crlf.allows(other) == true)
        #expect(cr.allows(other) == true)
        #expect(crlf == lf, "the two files hold the same rules")
        #expect(cr == lf, "the CR-only file holds the same rules as the LF one")
    }

    /// Mixed endings inside one file: the group's rule is kept, and the next group's user-agent
    /// line still starts a group that is not ours.
    @Test
    func robotsPolicyReadsMixedLineEndings() {
        let policy = RobotsTXTPolicy(text: "User-agent: *\r\nDisallow: /private\n\r\nUser-agent: OtherBot\r\nDisallow: /\r\n")

        #expect(policy.allows(URL(string: "https://example.com/private/x")!) == false, "the CRLF group's rule was dropped")
        #expect(policy.allows(URL(string: "https://example.com/public")!) == true, "the other agent's Disallow leaked into ours")
    }

    /// SONNY-454, which moved this test deliberately. It was
    /// `aGenuinelyEmptyLineStillClosesAGroupWhateverTheEndings` and asserted the opposite: SONNY-437
    /// kept a blank line closing a group as the parser's own rule, so that its split fix could be
    /// told apart from a split that dropped empty lines. RFC 9309 gives a blank line no meaning — a
    /// group "is terminated by a user-agent line or end of file" (§2.1), and §2.2's grammar allows an
    /// `emptyline` anywhere inside one, which is a blank line, a line of only whitespace, or a line
    /// of only a comment. Read the old way, every rule after such a line in one agent's block was
    /// dropped, and the paths the site disallows were fetched.
    ///
    /// **The two doubled endings are PR #234's review's** (carried on SONNY-454): a CRLF file
    /// converted twice puts `\r\r\n` between lines, `\n\r` is its mirror, and by §2.2's `NL` each is a
    /// line break followed by a blank line, so both read as files with no rules until this rule
    /// changed. They assert that the rule survives, not that the parser reproduces a reading.
    @Test
    func aBlankLineInsideAGroupKeepsTheRuleAfterItWhateverTheEndings() {
        let reference = RobotsTXTPolicy(text: "User-agent: *\nDisallow: /private\n")
        let privatePage = URL(string: "https://example.com/private/x")!
        let files: [(shape: String, text: String)] = [
            ("LF", "User-agent: *\n\nDisallow: /private\n"),
            ("CRLF", "User-agent: *\r\n\r\nDisallow: /private\r\n"),
            ("CR", "User-agent: *\r\rDisallow: /private\r"),
            ("a CRLF file converted twice", "User-agent: *\r\r\nDisallow: /private\r\r\n"),
            ("LF then CR", "User-agent: *\n\rDisallow: /private\n\r"),
            ("a line of only whitespace", "User-agent: *\n \t \nDisallow: /private\n"),
            ("a line of only a comment", "User-agent: *\n# the private area\nDisallow: /private\n"),
        ]

        #expect(reference.allows(privatePage) == false, "setup: the file with no blank line disallows the page")
        for file in files {
            let policy = RobotsTXTPolicy(text: file.text)
            #expect(policy.allows(privatePage) == false, "\(file.shape): the rule after the blank line was dropped")
            #expect(policy == reference, "\(file.shape): the file holds the one rule it holds with no blank line")
        }
    }

    /// The ticket's own case: a blank line between two rules of one agent's block, where a human
    /// formatting the file most often puts one. The rule before it and the rule after it both apply.
    @Test
    func aBlankLineBetweenTwoRulesKeepsTheSecondInTheGroup() {
        let policy = RobotsTXTPolicy(text: "User-agent: *\nDisallow: /drafts\n\nDisallow: /private\n")

        #expect(policy.allows(URL(string: "https://example.com/drafts/x")!) == false)
        #expect(policy.allows(URL(string: "https://example.com/private/x")!) == false, "the rule after the blank line was dropped")
        #expect(policy.allows(URL(string: "https://example.com/blog")!) == true)
    }

    /// §2.2's `*(startgroupline / emptyline)`: a blank line between two user-agent lines leaves them
    /// one group, so the rule beneath the second agent is the first agent's too.
    @Test
    func aBlankLineBetweenTwoUserAgentLinesLeavesThemOneGroup() {
        let policy = RobotsTXTPolicy(text: "User-agent: *\n\nUser-agent: OtherBot\nDisallow: /private\n")

        #expect(policy.allows(URL(string: "https://example.com/private/x")!) == false, "the blank line split one group of two agents into two")
        #expect(policy.allows(URL(string: "https://example.com/blog")!) == true)
    }

    /// What still ends a group, so the rule above cannot be met by never ending one: the next
    /// user-agent line after a rule, with a blank line before it or without one. The other agent's
    /// `Disallow: /` must not reach this one's pages in either file.
    @Test
    func theNextUserAgentLineAfterARuleStillEndsTheGroupWithOrWithoutABlankLine() {
        let files = [
            "User-agent: *\nDisallow: /private\nUser-agent: OtherBot\nDisallow: /\n",
            "User-agent: *\nDisallow: /private\n\nUser-agent: OtherBot\nDisallow: /\n",
            "User-agent: OtherBot\nDisallow: /\n\nUser-agent: *\nDisallow: /private\n",
        ]

        for text in files {
            let policy = RobotsTXTPolicy(text: text)
            #expect(policy.allows(URL(string: "https://example.com/private/x")!) == false, "our group's rule was lost: \(text.debugDescription)")
            #expect(policy.allows(URL(string: "https://example.com/blog")!) == true, "the other agent's Disallow leaked into ours: \(text.debugDescription)")
        }
    }
}

@MainActor
private struct StaticWebPageFetcher: WebPageFetching {
    var page: FetchedWebPage

    init(
        page: FetchedWebPage = FetchedWebPage(
            requestedURL: URL(string: "https://example.com")!,
            html: "<html><body><article><p>Fixture page body with enough article text for extraction.</p></article></body></html>"
        )
    ) {
        self.page = page
    }

    func fetch(_ url: URL) async throws -> FetchedWebPage {
        page
    }
}

@MainActor
private struct StaticRobotsChecker: RobotsTXTChecking {
    var allowed: Bool

    func canFetch(_ url: URL, userAgent: String) async throws -> Bool {
        allowed
    }
}

@MainActor
private final class RecordingRobotsChecker: RobotsTXTChecking {
    private let allowedHosts: Set<String>
    private(set) var checkedURLs: [URL] = []

    init(allowedHosts: Set<String>) {
        self.allowedHosts = allowedHosts
    }

    func canFetch(_ url: URL, userAgent: String) async throws -> Bool {
        checkedURLs.append(url)
        return allowedHosts.contains(url.host ?? "")
    }
}
