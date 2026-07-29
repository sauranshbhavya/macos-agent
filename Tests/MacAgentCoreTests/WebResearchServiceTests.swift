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
