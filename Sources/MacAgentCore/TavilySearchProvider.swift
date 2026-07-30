import Foundation

public enum TavilySearchError: Error, Equatable, LocalizedError {
    case missingAPIKey
    case badResponse(Int, String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "TAVILY_API_KEY is not set. Add it to the environment before launching the app."
        case .badResponse(let status, let body):
            return "Tavily search failed with HTTP \(status): \(body)"
        }
    }
}

/// The real `WebSearchProviding` conformance — Tavily, resolved 2026-07-15 (see the changelog's
/// branch 16 note), $0.008 per search, pay-as-you-go.
///
/// The key follows `OPENAI_API_KEY`'s pattern exactly: read from the environment at construction,
/// used only in the Authorization header, never persisted anywhere. A missing key throws here so
/// the composition root (`AgentViewModel.makeExecutor()`) can fall back to
/// `UnavailableWebSearchProvider` and the existing "Web search provider not configured." error —
/// absence degrades, it does not invent a new failure surface.
///
/// This provider deliberately does no `SafeURL` policy validation. Result URLs are policy-checked
/// once, in `WebResearchMarkdownCapabilityAdapter.sourceURLs(for:context:log:)`, and again by
/// `PublicWebPageLoader.load` — a private-address URL in a search result must keep failing loudly
/// there, not be quietly filtered here where nothing would ever surface it. What *is* dropped here
/// is response garbage: an entry whose URL string does not parse, or parses without an http(s)
/// scheme, is a malformed API payload with no meaningful downstream handling, not a policy call.
@MainActor
public struct TavilySearchProvider: WebSearchProviding {
    private let apiKey: String
    private let endpoint: URL
    private let session: URLSession

    public init(
        apiKey: String? = ProcessInfo.processInfo.environment["TAVILY_API_KEY"],
        endpoint: URL = URL(string: "https://api.tavily.com/search")!,
        session: URLSession = .shared
    ) throws {
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TavilySearchError.missingAPIKey
        }
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.session = session
    }

    public func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        // Tavily documents max_results as 0-20 (default 5). 0 would be a pointless paid request
        // for an empty list, so the floor is 1; the ceiling is the API's own.
        let clampedLimit = min(max(limit, 1), 20)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "max_results": clampedLimit
        ])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TavilySearchError.badResponse(-1, "No HTTP response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            throw TavilySearchError.badResponse(httpResponse.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(TavilySearchResponse.self, from: data)
        return decoded.results.compactMap { result in
            guard let url = URL(string: result.url),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return nil
            }
            return WebSearchResult(title: result.title, url: url, snippet: result.content)
        }
    }
}

/// Plain `Decodable` ignores fields it does not declare (`score`, `raw_content`, `answer`, ...),
/// which is the tolerance a third-party response shape needs without hand-written decoding.
private struct TavilySearchResponse: Decodable {
    var results: [TavilyResult]
}

private struct TavilyResult: Decodable {
    var title: String
    var url: String
    var content: String?
}
