import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// Web search, **against Sonny's own backend** (SONNY-130).
///
/// **Every test in the environment-key version of this file is accounted for**, and one of the six
/// is retired rather than migrated:
///
/// | before | after |
/// |---|---|
/// | `searchPostsTheQueryAndClampedLimitWithABearerAuthHeader` | `searchPostsTheQueryAndClampedLimitUnderTheUsersOwnSession` |
/// | `searchMapsTavilyResultsIntoWebSearchResults` | `searchMapsBackendResultsIntoWebSearchResults` |
/// | `initThrowsWhenTheAPIKeyIsMissingOrEmpty` | **retired** — replaced by `searchTellsAnUnsignedInUserToSignIn` |
/// | `searchThrowsWithStatusAndBodyOnANon2xxResponse` | `searchSurfacesABackendFailureWithTheAppsOwnWords` |
/// | `searchSkipsResultsWhoseURLDoesNotParseOrIsNotHTTP` | same name |
/// | `searchReturnsAnEmptyArrayForEmptyResults` | same name |
///
/// **The retirement is the one worth stating.** `initThrowsWhenTheAPIKeyIsMissingOrEmpty` asserted
/// that construction refused a missing or blank `TAVILY_API_KEY`, which was the whole degradation
/// path: `AgentViewModel` wrote `try? TavilySearchProvider()` and fell back to
/// `UnavailableWebSearchProvider` when it threw. There is no key to be missing now, construction
/// cannot fail, and the `try?` is gone with it. What replaces the coverage is the failure a user can
/// actually reach — a request made with no session — which is a refusal at the request rather than
/// at construction, and carries a sentence rather than a silent fallback.
///
/// The suite is also no longer `@Suite(.serialized)`. That was forced by a single shared static
/// handler on a per-file `URLProtocol`; `BackendStubURLProtocol` keys handlers by host, so each
/// fixture here has one of its own.
struct TavilySearchProviderTests {
    @Test
    @MainActor
    func searchPostsTheQueryAndClampedLimitUnderTheUsersOwnSession() async throws {
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return ModelRouteFixtures.reply(ModelRouteFixtures.searchJSON(results: []))
        }
        defer { fixture.unregister() }
        let provider = Self.provider(fixture)

        _ = try await provider.search(query: "Swift concurrency", limit: 5)
        _ = try await provider.search(query: "Swift concurrency", limit: 500)
        _ = try await provider.search(query: "Swift concurrency", limit: 0)

        let requests = recorded.all
        #expect(requests.count == 3)
        for request in requests {
            #expect(request.method == "POST")
            #expect(request.path == "/v1/search")
            // The user's own Sonny session, not a vendor key.
            #expect(request.authorization == "Bearer test-access-token")
            #expect(request.idempotencyKey?.isEmpty == false)
            #expect(request.json["query"] as? String == "Swift concurrency")
            #expect(request.json["task_id"] as? String == "task-fixture-1")
            #expect(request.json["retention"] as? String == "standard")
        }
        // §4.3 clamps to 1–20 on both sides; 0 would be a paid request for an empty list.
        #expect(requests.map { $0.json["max_results"] as? Int } == [5, 20, 1])
    }

    @Test
    @MainActor
    func theRequestNamesNoProviderAndNoVendorEndpoint() async throws {
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return ModelRouteFixtures.reply(ModelRouteFixtures.searchJSON(results: []))
        }
        defer { fixture.unregister() }

        _ = try await Self.provider(fixture).search(query: "swift", limit: 3)

        let sent = try recorded.only
        let wire = sent.text.lowercased()
        for forbidden in ["tavily", "api.tavily.com", "tvly-", "search_depth"] {
            #expect(!wire.contains(forbidden), "request body names \(forbidden)")
        }
        #expect(sent.path == "/v1/search")
    }

    @Test
    @MainActor
    func searchMapsBackendResultsIntoWebSearchResults() async throws {
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.reply(ModelRouteFixtures.searchJSON(results: [
                ["title": "Swift One", "url": "https://example.com/one", "snippet": "First snippet"],
                ["title": "Swift Two", "url": "https://example.com/two", "snippet": NSNull()],
            ]))
        }
        defer { fixture.unregister() }

        let results = try await Self.provider(fixture).search(query: "swift", limit: 2)

        #expect(results == [
            WebSearchResult(
                title: "Swift One",
                url: URL(string: "https://example.com/one")!,
                snippet: "First snippet"
            ),
            WebSearchResult(
                title: "Swift Two",
                url: URL(string: "https://example.com/two")!,
                snippet: nil
            ),
        ])
    }

    @Test
    @MainActor
    func searchTellsAnUnsignedInUserToSignIn() async throws {
        // The successor to `initThrowsWhenTheAPIKeyIsMissingOrEmpty`. The failure moved from
        // construction to the request, which is where a user can now actually meet it.
        let client = makeHermeticBackendClient(
            environment: SonnyBackendEnvironment(
                baseURL: URL(string: "https://sonny-unreached.invalid")!,
                source: .debugOverride
            )
        )
        let provider = TavilySearchProvider(
            client: client,
            taskContext: ModelRouteFixtures.standardContext
        )

        do {
            _ = try await provider.search(query: "swift", limit: 3)
            Issue.record("Expected a search with no session to be refused before it was sent.")
        } catch let error as TavilySearchError {
            #expect(error == .backend(.notSignedIn))
            #expect(error.errorDescription == "Sign in to Sonny to run this.")
        }
    }

    @Test
    @MainActor
    func searchSurfacesABackendFailureWithTheAppsOwnWords() async throws {
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.failure(
                status: 502,
                code: "provider.unavailable",
                message: "upstream exploded at 10.0.3.14:443",
                retryable: true
            )
        }
        defer { fixture.unregister() }

        do {
            _ = try await Self.provider(fixture).search(query: "swift", limit: 3)
            Issue.record("Expected the backend failure to surface as TavilySearchError.backend.")
        } catch let error as TavilySearchError {
            guard case .backend(.api(let api)) = error else {
                Issue.record("Expected .backend(.api), got \(error).")
                return
            }
            #expect(api.code == .providerUnavailable)
            #expect(api.statusCode == 502)
            let shown = try #require(error.errorDescription)
            #expect(shown == "Sonny couldn't finish this one. Try again.")
            #expect(!shown.contains("10.0.3.14"))
            #expect(!shown.contains("502"))
        }
    }

    /// Garbage entries in an otherwise-good response are dropped rather than sinking the whole
    /// search. Policy validation (private addresses etc.) is deliberately NOT here — that stays
    /// in the adapter's `SafeURL.validateWebURL`, the single authority, where a private-address
    /// result still fails the task loudly. The gateway drops the same entries, so this is the second
    /// of two filters; it stays because a client that trusts its server to have filtered is a client
    /// that stops filtering the day the server changes.
    @Test
    @MainActor
    func searchSkipsResultsWhoseURLDoesNotParseOrIsNotHTTP() async throws {
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.reply(ModelRouteFixtures.searchJSON(results: [
                ["title": "Good", "url": "https://example.com/good", "snippet": "kept"],
                ["title": "Empty", "url": "", "snippet": "dropped"],
                ["title": "Not a web URL", "url": "ftp://example.com/file", "snippet": "dropped"],
                ["title": "Schemeless", "url": "just some text", "snippet": "dropped"],
            ]))
        }
        defer { fixture.unregister() }

        let results = try await Self.provider(fixture).search(query: "swift", limit: 4)

        #expect(results.map(\.title) == ["Good"])
    }

    @Test
    @MainActor
    func searchReturnsAnEmptyArrayForEmptyResults() async throws {
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.reply(ModelRouteFixtures.searchJSON(results: []))
        }
        defer { fixture.unregister() }

        let results = try await Self.provider(fixture).search(query: "nothing", limit: 5)

        #expect(results.isEmpty)
    }

    @Test
    @MainActor
    func searchReportsNoLocalUsage() async throws {
        // **Stated as a test rather than left as an omission.** §4.3's response carries no `usage`
        // block at all, and search has never fed the local per-task summary — there is no
        // `AIUsageCallKind` for it. This ticket's requirement is that the summary must not silently
        // go blank for what already worked; search is the one of the four routes that never did, and
        // adding it is new behaviour rather than preserved behaviour.
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.reply(ModelRouteFixtures.searchJSON(results: []))
        }
        defer { fixture.unregister() }

        let recorder = TaskUsageRecorder()
        _ = try await Self.provider(fixture).search(query: "swift", limit: 3)

        #expect(recorder.snapshot().requestCount == 0)
        // And there is no kind for it to be recorded under, which is the checkable half of the
        // claim above: adding one is what a ticket that wants search in the summary would do.
        #expect(AIUsageCallKind(rawValue: "search") == nil)
        #expect(AIUsageCallKind(rawValue: "web_search") == nil)
        #expect(AIUsageCallKind(rawValue: "planner") == .planner)
    }

    @MainActor
    private static func provider(_ fixture: SignedInBackendFixture) -> TavilySearchProvider {
        TavilySearchProvider(client: fixture.client, taskContext: ModelRouteFixtures.standardContext)
    }
}
