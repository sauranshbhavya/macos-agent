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

    public var all: [RecordedBackendRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    public var only: RecordedBackendRequest {
        get throws { try #require(all.first, "expected exactly one request, saw \(all.count)") }
    }
}
