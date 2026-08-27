import Foundation

public enum TavilySearchError: Error, Equatable, LocalizedError {
    /// **Unreachable since SONNY-130 and deliberately kept.** No search provider reads a vendor key
    /// any more; removing the case and the sentence naming the variable is
    /// `feature/row-12-degradation`'s, which cannot run until both gateways land.
    case missingAPIKey
    /// Unreachable for the same reason: no HTTP status is read here any more.
    case badResponse(Int, String)
    /// A call to Sonny's backend failed. The user sees `SonnyBackendCopy`'s sentence, never the
    /// server's own `message` (§7.1).
    case backend(SonnyBackendError)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "TAVILY_API_KEY is not set. Add it to the environment before launching the app."
        case .badResponse(let status, let body):
            return "Tavily search failed with HTTP \(status): \(body)"
        case .backend(let error):
            return SonnyBackendCopy.sentence(for: error)
        }
    }
}

/// The real `WebSearchProviding` conformance, **through Sonny's backend** (SONNY-130).
///
/// Search was resolved to a paid provider on 2026-07-15 (see the changelog's branch 16 note) and ran
/// on a key read from the user's own environment until this ticket. The key, the endpoint and the
/// choice of provider now live in `server/src/model/`, and nothing here names any of the three.
///
/// **This provider still does no `SafeURL` policy validation, and that is unchanged by the move.**
/// Result URLs are policy-checked once, in
/// `WebResearchMarkdownCapabilityAdapter.sourceURLs(for:context:log:)`, and again by
/// `PublicWebPageLoader.load` — a private-address URL in a search result must keep failing loudly
/// there, not be quietly filtered here where nothing would ever surface it. §4.3 of the contract
/// says the same of the server, and for the sharper reason: moving URL policy across a network call
/// would put a safety decision on the far side of one, which is the thing this row exists not to do.
///
/// What *is* dropped here is response garbage — an entry whose URL string does not parse, or parses
/// without an http(s) scheme. The server drops the same entries, so this is the second of two
/// filters rather than the only one, and it stays because a client that trusts its server to have
/// filtered is a client that stops filtering the day the server changes.
@MainActor
public struct TavilySearchProvider: WebSearchProviding {
    private let client: SonnyBackendClient
    private let taskContext: BackendTaskContext

    public init(client: SonnyBackendClient, taskContext: BackendTaskContext) {
        self.client = client
        self.taskContext = taskContext
    }

    public func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        // §4.3: clamped to 1–20 on both sides. The floor is 1 because 0 would be a paid request for
        // an empty list; the ceiling is the contract's.
        let clampedLimit = min(max(limit, 1), 20)

        var body = taskContext.wireFields
        body["query"] = query
        body["max_results"] = clampedLimit

        let decoded: SonnySearchRouteResponse
        do {
            decoded = try await client.modelRouteResponse(
                SonnySearchRouteResponse.self,
                route: .search,
                body: try JSONSerialization.data(withJSONObject: body)
            )
        } catch let error as SonnyBackendError {
            throw TavilySearchError.backend(error)
        }

        return decoded.results.compactMap { result in
            guard let url = URL(string: result.url),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return nil
            }
            return WebSearchResult(title: result.title ?? "", url: url, snippet: result.snippet)
        }
    }
}
