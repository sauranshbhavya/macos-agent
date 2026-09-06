import Foundation
import Testing
@testable import MacAgentCore

/// What a stub saw, shared by both test targets (SONNY-130; moved here by PR #139's F1).
///
/// It started in `Tests/MacAgentCoreTests/ModelRouteFixtures.swift`, where the four migrated
/// per-route suites use it. F1's fix needs the same reading from `Tests/MacAgentTests`, because the
/// scheduled path's `task_id` is only observable on the wire — so it lives beside
/// `BackendStubURLProtocol`, which is the thing it reads, rather than being written twice.

/// One recorded upstream request, read the way `URLProtocol` actually sees one.
public struct RecordedBackendRequest: @unchecked Sendable {
    public let path: String
    /// The URL's query string, or `nil` when it has none. Read by SONNY-404's cutoff test: a bound
    /// this client sends as a query parameter is invisible in `path`.
    public let query: String?
    public let method: String?
    public let authorization: String?
    public let idempotencyKey: String?
    public let contentType: String?
    /// Every header the request carried **as `URLProtocol` sees it**, which is not every header that
    /// reaches the wire (SONNY-131). `URLSession` adds `Accept-Encoding` and its own transport
    /// headers below this layer, so their absence here says nothing about the socket; what this can
    /// answer is which headers the *client* set.
    public let headers: [String: String]
    public let body: Data

    public var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    public var text: String { String(data: body, encoding: .utf8) ?? "" }

    public init(_ request: URLRequest) {
        path = request.url?.path ?? ""
        query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.query }
        method = request.httpMethod
        authorization = request.value(forHTTPHeaderField: "Authorization")
        idempotencyKey = request.value(forHTTPHeaderField: "Idempotency-Key")
        contentType = request.value(forHTTPHeaderField: "Content-Type")
        headers = request.allHTTPHeaderFields ?? [:]
        body = BackendStubURLProtocol.body(of: request)
    }
}

/// Every request a suite's stub saw, in order.
public final class RecordedBackendRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RecordedBackendRequest] = []

    public init() {}

    public func append(_ request: URLRequest) {
        lock.lock()
        recorded.append(RecordedBackendRequest(request))
        lock.unlock()
    }

    /// Forgets everything recorded so far, so a test can assert about one phase of a scenario
    /// rather than about every request the whole scenario made (SONNY-404).
    ///
    /// The alternative is a suffix assertion, and a suffix assertion is satisfied by a prefix that
    /// is wrong — which is the shape `only`'s own doc records paying for.
    public func removeAll() {
        lock.lock()
        recorded.removeAll()
        lock.unlock()
    }

    public var all: [RecordedBackendRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The one request this suite's stub saw, and it now checks that there was exactly one.
    ///
    /// **It read `try #require(all.first, "expected exactly one request, saw \(all.count)")`, which
    /// passes for one request and for fifty** (SONNY-331). `all.first` is non-nil at any count at or
    /// above one, so the sentence a reader takes the guarantee from could only ever be printed when
    /// the array was *empty* — the one case where "saw N" reads `saw 0`, and so the one case where
    /// it could never appear beside a count that disproved it. The name compounded it: `try
    /// recorded.only` reads at a call site as "the one request", and that is how it was read.
    ///
    /// What it cost is worth keeping, because a mutation score could not have surfaced it.
    /// SONNY-320 added a cancellation test to each of the four text routes; three pinned the count
    /// beside their `only` read and the fourth relied on this. A mutant giving
    /// `SonnyBackendError.cancelled` a retry budget — which the contract's §9.3 says it must never
    /// have — therefore failed three of the four instead of four, and was still killed. A weak test
    /// among stronger siblings is invisible to a battery; a reviewer reading the assertion found it.
    ///
    /// The message now names the paths as well as the count, because "saw 3" does not say which
    /// three, and the reason a second request is there is usually visible in its path.
    public var only: RecordedBackendRequest {
        get throws {
            let requests = all
            try #require(
                requests.count == 1,
                "expected exactly one request, saw \(requests.count): \(requests.map(\.path))"
            )
            return try #require(requests.first)
        }
    }
}
