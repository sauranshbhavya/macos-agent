import Foundation

/// A `URLProtocol` stub for the backend client's tests, **keyed by host rather than by one shared
/// static handler**.
///
/// The six provider clients' tests each carry their own private `URLProtocol` whose handler is a
/// single `nonisolated(unsafe) static var`, and `TavilySearchProviderTests` says in its own doc why
/// that forces `@Suite(.serialized)`: run in parallel, one test's teardown nils the handler out from
/// under another. That is the pattern this follows and the one flaw it does not copy. Every stub
/// session gets a unique host, handlers live in a lock-guarded registry keyed on it, and
/// `canInit(with:)` claims only a request whose host is registered — so suites using this run in
/// parallel with each other and with everything else.
///
/// **`startLoading` dispatches rather than running the handler inline.** URLSession calls it on its
/// own worker threads, and two of the tests here need a handler that blocks: one holds ten
/// concurrent requests at a barrier so they raise their 401s together, and one never answers at all
/// so the client's own timeout is what ends the request. Blocking URLSession's threads to do that
/// risks exhausting its pool; a queue of our own cannot.
public final class BackendStubURLProtocol: URLProtocol, @unchecked Sendable {
    public enum Outcome: Sendable {
        case reply(statusCode: Int, headers: [String: String], body: Data)
        /// A transport failure, the way a dead network reaches the client.
        case failure(URLError)
        /// Never answers. The request ends when, and only when, something else ends it.
        case hang
    }

    public typealias Handler = @Sendable (URLRequest) -> Outcome

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    private static let queue = DispatchQueue(
        label: "sonny.backend-stub",
        attributes: .concurrent
    )

    public static func register(host: String, handler: @escaping Handler) {
        lock.lock()
        handlers[host] = handler
        lock.unlock()
    }

    public static func unregister(host: String) {
        lock.lock()
        handlers.removeValue(forKey: host)
        lock.unlock()
    }

    private static func handler(for host: String?) -> Handler? {
        guard let host else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return handlers[host]
    }

    /// A session wired to this protocol, and a base URL nothing else in the suite shares.
    ///
    /// Callers pair this with `register(host:handler:)` and `unregister(host:)` in a `defer`.
    public static func makeSession() -> (session: URLSession, baseURL: URL, host: String) {
        let host = "sonny-stub-\(UUID().uuidString.lowercased()).invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendStubURLProtocol.self]
        return (URLSession(configuration: configuration), URL(string: "https://\(host)")!, host)
    }

    /// A request's body. `URLProtocol` never sees `httpBody`, only `httpBodyStream` — the same
    /// reading `TavilySearchProviderTests` does by hand.
    public static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
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
        return data
    }

    public static func bodyJSON(of request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body(of: request))) as? [String: Any] ?? [:]
    }

    override public class func canInit(with request: URLRequest) -> Bool {
        handler(for: request.url?.host) != nil
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        let request = self.request
        guard let handler = Self.handler(for: request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        Self.queue.async { [weak self] in
            guard let self else { return }
            switch handler(request) {
            case .hang:
                return
            case .failure(let error):
                self.client?.urlProtocol(self, didFailWithError: error)
            case .reply(let statusCode, let headers, let body):
                guard let url = request.url,
                      let response = HTTPURLResponse(
                          url: url,
                          statusCode: statusCode,
                          httpVersion: "HTTP/1.1",
                          headerFields: headers
                      ) else {
                    self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: body)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override public func stopLoading() {}
}

/// A counter several stub handlers write from different threads at once.
public final class StubCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    public init() {}

    @discardableResult
    public func increment(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let next = (counts[key] ?? 0) + 1
        counts[key] = next
        return next
    }

    public func count(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[key] ?? 0
    }
}

/// Holds every arriving request until `expected` of them have arrived, then releases them all.
///
/// Used to make concurrent 401s genuinely concurrent. **It cannot make a test fail**: the
/// wait carries a backstop, and if the backstop fires every request simply proceeds — the
/// assertion those tests make (one refresh, not ten) holds whether the burst overlapped or not.
/// The barrier widens the window the guard has to survive; it is not the thing being asserted.
public final class StubBarrier: @unchecked Sendable {
    private let expected: Int
    private let backstop: TimeInterval
    private let lock = NSLock()
    private var arrived = 0
    private let gate = DispatchSemaphore(value: 0)

    public init(expected: Int, backstop: TimeInterval = 10) {
        self.expected = expected
        self.backstop = backstop
    }

    public func arriveAndWait() {
        lock.lock()
        arrived += 1
        let isLast = arrived >= expected
        lock.unlock()
        if isLast {
            for _ in 0..<max(expected - 1, 0) { gate.signal() }
            return
        }
        _ = gate.wait(timeout: .now() + backstop)
    }
}

/// A one-shot signal a stub handler can wait on, with a backstop so a mistake surfaces as a red
/// test rather than a hung suite.
///
/// `waitUntilSignalled` returns whether the signal actually arrived, so a caller can assert the
/// backstop did not fire — a wait that timed out and carried on would otherwise let a test pass by
/// accident, which is the exact failure mode `CLAUDE.md` records for wall-clock tests.
public final class StubSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isSignalled = false

    public init() {}

    public func signal() {
        lock.lock()
        let alreadySignalled = isSignalled
        isSignalled = true
        lock.unlock()
        if !alreadySignalled { semaphore.signal() }
    }

    @discardableResult
    public func waitUntilSignalled(backstop: TimeInterval = 10) -> Bool {
        lock.lock()
        let already = isSignalled
        lock.unlock()
        if already { return true }
        let result = semaphore.wait(timeout: .now() + backstop)
        if result == .success { semaphore.signal() }
        return result == .success
    }
}
