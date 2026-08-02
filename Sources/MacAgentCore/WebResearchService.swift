import Foundation
import SwiftSoup

public enum WebResearchError: Error, Equatable, LocalizedError {
    case robotsDisallowed(String)
    case badHTTPStatus(Int, String)
    case unsupportedContentType(String?)
    case invalidTextEncoding(String)
    case restrictedContent(String)
    case noReadableContent(String)
    case searchProviderNotConfigured
    case noSearchResults(String)
    case allSourcesFailed([String], String)

    public var errorDescription: String? {
        switch self {
        case .robotsDisallowed(let url):
            return "Robots.txt does not allow Sonny to fetch \(url)."
        case .badHTTPStatus(let status, let url):
            return "Fetching \(url) failed with HTTP \(status)."
        case .unsupportedContentType(let mimeType):
            return "Expected an HTML page, got \(mimeType ?? "unknown content type")."
        case .invalidTextEncoding(let url):
            return "Could not decode \(url) as readable text."
        case .restrictedContent(let reason):
            return "Sonny will not bypass \(reason)."
        case .noReadableContent(let url):
            // Investigated 2026-07-30 via `summarize ycombinator.com/companies`: this fires for
            // JavaScript-rendered pages (a directory app with no article-shaped static HTML) —
            // the extractor working correctly on what the server actually sent, not a fetch, URL,
            // or search-provider failure. The copy hints at that cause because it is the dominant
            // real-world one for a page the user can see fine in a browser, phrased as "may"
            // because a genuinely empty static page lands here too.
            return "No readable article content was found at \(url). The page may render its content with JavaScript, which Sonny does not run."
        case .searchProviderNotConfigured:
            return "Web search provider not configured."
        case .noSearchResults(let query):
            return "No web search results were found for \(query)."
        case .allSourcesFailed(let urls, let firstReason):
            let count = urls.count
            return "None of the \(count) source\(count == 1 ? "" : "s") could be retrieved, so no note was written. First failure: \(firstReason)"
        }
    }
}

public struct FetchedWebPage: Equatable, Sendable {
    public var requestedURL: URL
    public var finalURL: URL
    public var statusCode: Int
    public var mimeType: String?
    public var html: String
    public var retrievedAt: Date

    @MainActor
    public init(
        requestedURL: URL,
        finalURL: URL? = nil,
        statusCode: Int = 200,
        mimeType: String? = "text/html",
        html: String,
        retrievedAt: Date = Date()
    ) {
        self.requestedURL = requestedURL
        self.finalURL = finalURL ?? requestedURL
        self.statusCode = statusCode
        self.mimeType = mimeType
        self.html = html
        self.retrievedAt = retrievedAt
    }
}

public struct ReadableWebPage: Equatable, Sendable {
    public var sourceURL: URL
    public var retrievedAt: Date
    public var title: String
    public var author: String?
    public var publishedDate: String?
    public var headings: [String]
    public var links: [ReadableWebLink]
    public var images: [ReadableWebImage]
    public var citations: [String]
    public var readableText: String

    public init(
        sourceURL: URL,
        retrievedAt: Date,
        title: String,
        author: String? = nil,
        publishedDate: String? = nil,
        headings: [String] = [],
        links: [ReadableWebLink] = [],
        images: [ReadableWebImage] = [],
        citations: [String] = [],
        readableText: String
    ) {
        self.sourceURL = sourceURL
        self.retrievedAt = retrievedAt
        self.title = title
        self.author = author
        self.publishedDate = publishedDate
        self.headings = headings
        self.links = links
        self.images = images
        self.citations = citations
        self.readableText = readableText
    }
}

public struct ReadableWebLink: Equatable, Sendable {
    public var text: String
    public var url: URL

    public init(text: String, url: URL) {
        self.text = text
        self.url = url
    }
}

public struct ReadableWebImage: Equatable, Sendable {
    public var altText: String?
    public var url: URL

    public init(altText: String? = nil, url: URL) {
        self.altText = altText
        self.url = url
    }
}

@MainActor
public protocol WebPageFetching {
    func fetch(_ url: URL) async throws -> FetchedWebPage
}

@MainActor
public protocol RobotsTXTChecking {
    func canFetch(_ url: URL, userAgent: String) async throws -> Bool
}

public protocol ReadableWebExtracting {
    func extract(html: String, sourceURL: URL, retrievedAt: Date) throws -> ReadableWebPage
}

public struct WebSearchResult: Equatable, Sendable {
    public var title: String
    public var url: URL
    public var snippet: String?

    public init(title: String, url: URL, snippet: String? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

@MainActor
public protocol WebSearchProviding {
    func search(query: String, limit: Int) async throws -> [WebSearchResult]
}

public struct UnavailableWebSearchProvider: WebSearchProviding {
    public init() {}

    public func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        throw WebResearchError.searchProviderNotConfigured
    }
}

public struct PublicWebPageLoader {
    public var fetcher: any WebPageFetching
    public var robotsChecker: any RobotsTXTChecking
    public var extractor: any ReadableWebExtracting
    public var userAgent: String

    public init(
        fetcher: any WebPageFetching,
        robotsChecker: any RobotsTXTChecking,
        extractor: any ReadableWebExtracting = SwiftSoupReadableWebExtractor(),
        userAgent: String = "Sonny/1.0"
    ) {
        self.fetcher = fetcher
        self.robotsChecker = robotsChecker
        self.extractor = extractor
        self.userAgent = userAgent
    }

    @MainActor
    public static func live(userAgent: String = "Sonny/1.0") -> PublicWebPageLoader {
        PublicWebPageLoader(
            fetcher: URLSessionWebPageFetcher(),
            robotsChecker: URLSessionRobotsTXTChecker(),
            extractor: SwiftSoupReadableWebExtractor(),
            userAgent: userAgent
        )
    }

    @MainActor
    public func load(rawURL: String) async throws -> ReadableWebPage {
        let url = try SafeURL.validateWebURL(rawURL)
        guard try await robotsChecker.canFetch(url, userAgent: userAgent) else {
            throw WebResearchError.robotsDisallowed(url.absoluteString)
        }

        let page = try await fetcher.fetch(url)
        // Redirects can land on a different host whose robots.txt was never consulted and whose
        // address may be private. This check is reactive — the redirect target has already been
        // fetched once by then — but it keeps the content from being used or synthesized.
        if page.finalURL.host?.lowercased() != url.host?.lowercased() {
            let finalURL = try SafeURL.validateWebURL(page.finalURL.absoluteString)
            guard try await robotsChecker.canFetch(finalURL, userAgent: userAgent) else {
                throw WebResearchError.robotsDisallowed(finalURL.absoluteString)
            }
        }
        try validate(page)
        return try extractor.extract(
            html: page.html,
            sourceURL: page.finalURL,
            retrievedAt: page.retrievedAt
        )
    }

    private func validate(_ page: FetchedWebPage) throws {
        guard (200..<300).contains(page.statusCode) else {
            throw WebResearchError.badHTTPStatus(page.statusCode, page.finalURL.absoluteString)
        }

        if let mimeType = page.mimeType?.lowercased(),
           !mimeType.hasPrefix("text/html"),
           !mimeType.hasPrefix("application/xhtml+xml") {
            throw WebResearchError.unsupportedContentType(page.mimeType)
        }

        if let reason = Self.restrictedContentReason(in: page.html) {
            throw WebResearchError.restrictedContent(reason)
        }
    }

    private static func restrictedContentReason(in html: String) -> String? {
        let normalized = html
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let checks: [(needle: String, reason: String)] = [
            ("captcha", "CAPTCHAs"),
            ("verify you are human", "CAPTCHAs"),
            ("please log in", "login walls"),
            ("sign in to continue", "login walls"),
            ("subscribe to continue", "paywalls"),
            ("subscription required", "paywalls"),
            ("paywall", "paywalls")
        ]

        return checks.first { normalized.contains($0.needle) }?.reason
    }
}

public final class URLSessionWebPageFetcher: WebPageFetching {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    public func fetch(_ url: URL) async throws -> FetchedWebPage {
        var request = URLRequest(url: url)
        request.setValue("Sonny/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebResearchError.badHTTPStatus(-1, url.absoluteString)
        }

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw WebResearchError.invalidTextEncoding(httpResponse.url?.absoluteString ?? url.absoluteString)
        }

        return FetchedWebPage(
            requestedURL: url,
            finalURL: httpResponse.url ?? url,
            statusCode: httpResponse.statusCode,
            mimeType: httpResponse.mimeType,
            html: html
        )
    }
}

public final class URLSessionRobotsTXTChecker: RobotsTXTChecking {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    public func canFetch(_ url: URL, userAgent: String) async throws -> Bool {
        guard let robotsURL = Self.robotsURL(for: url) else {
            return false
        }

        var request = URLRequest(url: robotsURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return true
        }

        guard httpResponse.statusCode == 200 else {
            return true
        }

        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return true
        }

        return RobotsTXTPolicy(text: text).allows(url, userAgent: userAgent)
    }

    private static func robotsURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/robots.txt"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

public struct RobotsTXTPolicy: Equatable, Sendable {
    private struct Rule: Equatable {
        var allows: Bool
        var path: String
    }

    private var rules: [Rule]

    public init(text: String, userAgent: String = "Sonny/1.0") {
        self.rules = Self.parse(text: text, userAgent: userAgent)
    }

    public func allows(_ url: URL, userAgent: String = "Sonny/1.0") -> Bool {
        let path = url.path.isEmpty ? "/" : url.path
        let matching = rules.filter { rule in
            !rule.path.isEmpty && path.hasPrefix(rule.path)
        }
        guard let best = matching.sorted(by: { lhs, rhs in
            if lhs.path.count == rhs.path.count {
                return lhs.allows && !rhs.allows
            }
            return lhs.path.count > rhs.path.count
        }).first else {
            return true
        }
        return best.allows
    }

    private static func parse(text: String, userAgent: String) -> [Rule] {
        let normalizedUserAgent = normalizeAgent(userAgent)
        var currentApplies = false
        var sawRuleInCurrentGroup = false
        var rules: [Rule] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let withoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let line = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                currentApplies = false
                sawRuleInCurrentGroup = false
                continue
            }

            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            switch key {
            case "user-agent":
                if sawRuleInCurrentGroup {
                    currentApplies = false
                    sawRuleInCurrentGroup = false
                }
                let agent = normalizeAgent(value)
                if agent == "*" || normalizedUserAgent.contains(agent) {
                    currentApplies = true
                }
            case "allow", "disallow":
                sawRuleInCurrentGroup = true
                guard currentApplies else {
                    continue
                }
                if key == "disallow", value.isEmpty {
                    continue
                }
                rules.append(Rule(allows: key == "allow", path: value))
            default:
                continue
            }
        }

        return rules
    }

    private static func normalizeAgent(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public struct SwiftSoupReadableWebExtractor: ReadableWebExtracting {
    public init() {}

    public func extract(html: String, sourceURL: URL, retrievedAt: Date) throws -> ReadableWebPage {
        let document = try SwiftSoup.parse(html, sourceURL.absoluteString)
        try removeBoilerplate(from: document)

        guard let content = try bestContentElement(in: document) else {
            throw WebResearchError.noReadableContent(sourceURL.absoluteString)
        }

        let readableText = try readableLines(in: content)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !readableText.isEmpty else {
            throw WebResearchError.noReadableContent(sourceURL.absoluteString)
        }

        return ReadableWebPage(
            sourceURL: sourceURL,
            retrievedAt: retrievedAt,
            title: try title(in: document, content: content),
            author: try firstNonEmpty([
                metaContent(in: document, selector: "meta[name=author]"),
                metaContent(in: document, selector: "meta[property=article:author]"),
                text(in: document, selector: "[rel=author]"),
                text(in: document, selector: ".byline"),
                text(in: document, selector: ".author")
            ]),
            publishedDate: try firstNonEmpty([
                metaContent(in: document, selector: "meta[property=article:published_time]"),
                metaContent(in: document, selector: "meta[name=date]"),
                attr(in: document, selector: "time[datetime]", name: "datetime"),
                text(in: document, selector: "time")
            ]),
            headings: try uniqueTexts(in: content, selector: "h1, h2, h3", limit: 20),
            links: try links(in: content, limit: 50),
            images: try images(in: content, limit: 30),
            citations: try uniqueTexts(in: content, selector: "blockquote, q, cite", limit: 20),
            readableText: readableText
        )
    }

    private func removeBoilerplate(from document: Document) throws {
        let selector = [
            "script",
            "style",
            "noscript",
            "nav",
            "footer",
            "header",
            "aside",
            "form",
            "iframe",
            "svg",
            "canvas",
            "button",
            "input",
            "textarea",
            "select",
            "[role=navigation]",
            "[aria-hidden=true]",
            ".ad",
            ".ads",
            ".advertisement",
            ".cookie",
            ".promo",
            ".newsletter",
            ".subscribe",
            ".sidebar",
            ".menu",
            ".comments"
        ].joined(separator: ", ")

        for element in try document.select(selector).array() {
            try element.remove()
        }
    }

    private func bestContentElement(in document: Document) throws -> Element? {
        let candidates = try document.select(
            "article, main, [role=main], .article, .post, .entry-content, .content, #content, body"
        ).array()

        return try candidates
            .map { element in
                (element: element, score: try score(element))
            }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .first?
            .element
    }

    private func score(_ element: Element) throws -> Double {
        let textLength = Double(try element.text().count)
        guard textLength >= 80 else {
            return 0
        }

        let paragraphs = try element.select("p").array()
        let paragraphLength = try paragraphs.reduce(0) { partial, paragraph in
            partial + (try paragraph.text().count)
        }
        let headingCount = try element.select("h1, h2, h3").array().count
        let linkLength = try element.select("a").array().reduce(0) { partial, link in
            partial + (try link.text().count)
        }
        let linkDensity = Double(linkLength) / max(textLength, 1)
        let hint = try classAndIDHint(for: element)

        return Double(paragraphLength) * (1 - min(linkDensity, 0.95)) + Double(headingCount * 30) + hint
    }

    private func classAndIDHint(for element: Element) throws -> Double {
        let value = "\(element.id()) \(try element.className())".lowercased()
        let positive = ["article", "post", "entry", "content", "main", "story", "body"].contains { value.contains($0) }
        let negative = ["nav", "menu", "sidebar", "comment", "footer", "promo", "ad"].contains { value.contains($0) }
        return (positive ? 120 : 0) - (negative ? 160 : 0)
    }

    private func title(in document: Document, content: Element) throws -> String {
        if let value = try firstNonEmpty([
            metaContent(in: document, selector: "meta[property=og:title]"),
            metaContent(in: document, selector: "meta[name=twitter:title]"),
            text(in: document, selector: "h1"),
            try document.title()
        ]) {
            return value
        }

        if let heading = try content.select("h1, h2").first()?.text(), let value = clean(heading) {
            return value
        }

        return "Untitled page"
    }

    private func readableLines(in element: Element) throws -> [String] {
        var lines: [String] = []
        for child in try element.select("h1, h2, h3, p, li, blockquote").array() {
            guard let text = clean(try child.text()) else {
                continue
            }
            let tag = child.tagName().lowercased()
            switch tag {
            case "h1":
                lines.append("# \(text)")
            case "h2":
                lines.append("## \(text)")
            case "h3":
                lines.append("### \(text)")
            case "li":
                lines.append("- \(text)")
            case "blockquote":
                lines.append("> \(text)")
            default:
                lines.append(text)
            }
        }
        return lines
    }

    private func links(in element: Element, limit: Int) throws -> [ReadableWebLink] {
        var result: [ReadableWebLink] = []
        for link in try element.select("a[href]").array() {
            guard let text = clean(try link.text()),
                  let url = URL(string: try link.attr("abs:href")),
                  result.contains(where: { $0.url == url }) == false else {
                continue
            }
            result.append(ReadableWebLink(text: text, url: url))
            if result.count == limit {
                break
            }
        }
        return result
    }

    private func images(in element: Element, limit: Int) throws -> [ReadableWebImage] {
        var result: [ReadableWebImage] = []
        for image in try element.select("img[src]").array() {
            guard let url = URL(string: try image.attr("abs:src")),
                  result.contains(where: { $0.url == url }) == false else {
                continue
            }
            result.append(ReadableWebImage(altText: clean(try image.attr("alt")), url: url))
            if result.count == limit {
                break
            }
        }
        return result
    }

    private func uniqueTexts(in element: Element, selector: String, limit: Int) throws -> [String] {
        var seen: Set<String> = []
        var values: [String] = []
        for selected in try element.select(selector).array() {
            guard let text = clean(try selected.text()), seen.insert(text).inserted else {
                continue
            }
            values.append(text)
            if values.count == limit {
                break
            }
        }
        return values
    }

    private func metaContent(in document: Document, selector: String) throws -> String? {
        try attr(in: document, selector: selector, name: "content")
    }

    private func attr(in document: Document, selector: String, name: String) throws -> String? {
        guard let value = try document.select(selector).first()?.attr(name) else {
            return nil
        }
        return clean(value)
    }

    private func text(in document: Document, selector: String) throws -> String? {
        guard let value = try document.select(selector).first()?.text() else {
            return nil
        }
        return clean(value)
    }

    private func firstNonEmpty(_ values: [String?]) throws -> String? {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    private func clean(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}
