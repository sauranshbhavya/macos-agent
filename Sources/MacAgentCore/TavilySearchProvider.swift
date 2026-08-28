import Foundation

/// Everything a search through Sonny's backend can fail with.
///
/// **`missingAPIKey` and `badResponse(Int, String)` are gone** (SONNY-136). SONNY-130 kept both
/// unreachable — no search provider reads a vendor key and none reads an HTTP status — because the
/// sentence naming `TAVILY_API_KEY` was the environment-variable surface, and that surface belonged
/// to the ticket that owns it. Removing the sentence and keeping the case would have left an enum
/// case nothing can construct and nothing can throw, so both went together.
///
/// **One case is what is left, and that is not an oversight.** A failed search is a failed call to
/// Sonny's backend, in every direction there now is.
public enum TavilySearchError: Error, Equatable, LocalizedError, CarriesBackendError {
    /// A call to Sonny's backend failed. The user sees `SonnyBackendCopy`'s sentence, never the
    /// server's own `message` (§7.1).
    case backend(SonnyBackendError)

    /// ``CarriesBackendError``: so a cancellation raised inside the shared client is still
    /// recognisable after this type wraps it (SONNY-320). A search runs inside the step loop, so a
    /// stop mid-search reaches `performStart`'s catch, which asks
    /// ``SonnyBackendError/isCancellation(_:)`` — without this it answered `false` and a deliberate
    /// stop was written to task history as a failed run.
    public var backendError: SonnyBackendError? {
        guard case .backend(let error) = self else { return nil }
        return error
    }

    public var errorDescription: String? {
        switch self {
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
