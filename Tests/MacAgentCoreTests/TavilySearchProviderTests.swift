import Foundation
import Testing
@testable import MacAgentCore

/// Fixture-backed only — nothing here touches the live Tavily API, per this project's testing
/// convention. Request-shape assertions read `httpBodyStream` because `URLProtocol` never sees
/// `httpBody` directly.
///
/// Serialized because every network test installs its own handler on the one shared
/// `TavilyFixtureURLProtocol.handler` static — run in parallel, one test's teardown nils the
/// handler out from under another. (`WebResearchSynthesizerTests` gets away without this only
/// because its tests never reset the handler.)
@Suite(.serialized)
struct TavilySearchProviderTests {
    @Test
    @MainActor
    func searchPostsTheQueryAndClampedLimitWithABearerAuthHeader() async throws {
        var capturedRequests: [(method: String?, auth: String?, body: [String: Any])] = []
        TavilyFixtureURLProtocol.handler = { request in
            capturedRequests.append((
                method: request.httpMethod,
                auth: request.value(forHTTPHeaderField: "Authorization"),
                body: try bodyJSON(of: request)
            ))
            return (try fixtureResponse(for: request), Data(#"{"results": []}"#.utf8))
        }
        defer { TavilyFixtureURLProtocol.handler = nil }
        let provider = try makeProvider()

        _ = try await provider.search(query: "Swift concurrency", limit: 5)
        _ = try await provider.search(query: "Swift concurrency", limit: 500)
        _ = try await provider.search(query: "Swift concurrency", limit: 0)

        #expect(capturedRequests.count == 3)
        for request in capturedRequests {
            #expect(request.method == "POST")
            #expect(request.auth == "Bearer test-key")
            #expect(request.body["query"] as? String == "Swift concurrency")
        }
        // Tavily's documented max_results range is 0-20; 0 would be a paid request for nothing.
        #expect(capturedRequests[0].body["max_results"] as? Int == 5)
        #expect(capturedRequests[1].body["max_results"] as? Int == 20)
        #expect(capturedRequests[2].body["max_results"] as? Int == 1)
    }

    @Test
    @MainActor
    func searchMapsTavilyResultsIntoWebSearchResults() async throws {
        TavilyFixtureURLProtocol.handler = { request in
            let json = #"""
            {
                "query": "swift",
                "results": [
                    {"title": "Swift One", "url": "https://example.com/one", "content": "First snippet", "score": 0.9},
                    {"title": "Swift Two", "url": "https://example.com/two", "score": 0.5}
                ],
                "response_time": 0.4
            }
            """#
            return (try fixtureResponse(for: request), Data(json.utf8))
        }
        defer { TavilyFixtureURLProtocol.handler = nil }
        let provider = try makeProvider()

        let results = try await provider.search(query: "swift", limit: 2)

        #expect(results == [
            WebSearchResult(title: "Swift One", url: URL(string: "https://example.com/one")!, snippet: "First snippet"),
            WebSearchResult(title: "Swift Two", url: URL(string: "https://example.com/two")!, snippet: nil)
        ])
    }

    @Test
    @MainActor
    func initThrowsWhenTheAPIKeyIsMissingOrEmpty() {
        #expect(throws: TavilySearchError.missingAPIKey) {
            _ = try TavilySearchProvider(apiKey: nil)
        }
        #expect(throws: TavilySearchError.missingAPIKey) {
            _ = try TavilySearchProvider(apiKey: "   ")
        }
    }

    @Test
    @MainActor
    func searchThrowsWithStatusAndBodyOnANon2xxResponse() async throws {
        TavilyFixtureURLProtocol.handler = { request in
            (try fixtureResponse(for: request, statusCode: 500), Data("upstream exploded".utf8))
        }
        defer { TavilyFixtureURLProtocol.handler = nil }
        let provider = try makeProvider()

        await #expect(throws: TavilySearchError.badResponse(500, "upstream exploded")) {
            _ = try await provider.search(query: "swift", limit: 3)
        }
    }

    /// Garbage entries in an otherwise-good response are dropped rather than sinking the whole
    /// search. Policy validation (private addresses etc.) is deliberately NOT here — that stays
    /// in the adapter's `SafeURL.validateWebURL`, the single authority, where a private-address
    /// result still fails the task loudly.
    @Test
    @MainActor
    func searchSkipsResultsWhoseURLDoesNotParseOrIsNotHTTP() async throws {
        TavilyFixtureURLProtocol.handler = { request in
            let json = #"""
            {
                "results": [
                    {"title": "Good", "url": "https://example.com/good", "content": "kept"},
                    {"title": "Empty", "url": "", "content": "dropped"},
                    {"title": "Not a web URL", "url": "ftp://example.com/file", "content": "dropped"},
                    {"title": "Schemeless", "url": "just some text", "content": "dropped"}
                ]
            }
            """#
            return (try fixtureResponse(for: request), Data(json.utf8))
        }
        defer { TavilyFixtureURLProtocol.handler = nil }
        let provider = try makeProvider()

        let results = try await provider.search(query: "swift", limit: 4)

        #expect(results.map(\.title) == ["Good"])
    }

    @Test
    @MainActor
    func searchReturnsAnEmptyArrayForEmptyResults() async throws {
        TavilyFixtureURLProtocol.handler = { request in
            (try fixtureResponse(for: request), Data(#"{"results": []}"#.utf8))
        }
        defer { TavilyFixtureURLProtocol.handler = nil }
        let provider = try makeProvider()

        let results = try await provider.search(query: "nothing", limit: 5)

        #expect(results.isEmpty)
    }

    @MainActor
    private func makeProvider() throws -> TavilySearchProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TavilyFixtureURLProtocol.self]
        return try TavilySearchProvider(
            apiKey: "test-key",
            session: URLSession(configuration: configuration)
        )
    }
}

private func fixtureResponse(for request: URLRequest, statusCode: Int = 200) throws -> HTTPURLResponse {
    let url = try #require(request.url)
    return try #require(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
}

private func bodyJSON(of request: URLRequest) throws -> [String: Any] {
    guard let stream = request.httpBodyStream else {
        throw TavilyFixtureError.missingBody
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        guard read > 0 else { break }
        data.append(buffer, count: read)
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TavilyFixtureError.bodyIsNotAJSONObject
    }
    return json
}

private enum TavilyFixtureError: Error {
    case missingBody
    case bodyIsNotAJSONObject
}

/// Same shape as `WebResearchFixtureURLProtocol`, which is private to its own test file.
private final class TavilyFixtureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: TavilyFixtureError.missingBody)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
