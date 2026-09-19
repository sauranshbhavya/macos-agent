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
/// **`startLoading` runs each request's handler on a thread of its own**, rather than inline or on a
/// shared queue. URLSession calls it on its own worker threads, and tests here register handlers
/// that block: on a barrier, so a burst of requests raises its 401s together, and on a signal, so
/// one request is still in flight while the test does something else with the client. Blocking
/// URLSession's threads to do that risks exhausting its pool.
///
/// **This said "a queue of our own cannot", and a measurement disproved it** (SONNY-515). The
/// queue was one custom concurrent `DispatchQueue`, and GCD serves those from its constrained worker
/// pool — shared with every other piece of default-priority dispatch work in the test process, and
/// capped for the whole process at `sysctl kern.wq_max_constrained_threads`, 64 on the Mac this was
/// measured on — which grants a thread only when it judges there is room. An uncommitted probe on a
/// full flagged-suite run at `8f3d1d02`, at a one-minute load average climbing from 12.66 to 40.40,
/// logged 553 handler starts, of which 72 had waited a second or more for a thread, the longest
/// 7.352 s — all 72 released within 0.105 s of each other, one grant. The suite's own blocking
/// handlers were not what held the pool in that run (the longest signal wait was 0.039 s and the
/// longest barrier wait 0.016 s), so something else in the process was. With a `Thread` per request
/// the same probe logged 550 starts at a load average reaching 54.79 and 636 with ten CPU-bound
/// processes running beside it (reaching 94.72), and none waited even a tenth of a second — the
/// longest 0.018 s and 0.026 s. A thread asks nothing of any pool, so a handler starts when its
/// request arrives and a blocking one parks only itself. `BackendStubURLProtocolTests` holds it.
///
/// **What that did not fix, measured in the same runs**: the process as a whole still stalls under
/// load. With no handler waiting at all, one run still had five seconds in which no request reached
/// the stub and three test-side waits made two or three looks in seven. That is why the waits
/// themselves are `CanaryBackstop`'s rather than a bare clock.
///
/// **That said "two of the tests here" and named a number instead of a method, which is why it is a
/// method now** (PR #205's F1, SONNY-420). The number was stale before the branch that found it and
/// staler after — a suite that registers a blocking handler joins this population the day it lands,
/// and nothing brings the sentence with it. Count them rather than trusting a numeral:
/// `git grep -nE 'arriveAndWait\(\)|waitUntilSignalled\(|CanaryBackstop\.block\(|\.wait\(timeout:' <sha> -- Tests`,
/// then `grep -vE ':Tests/MacAgentTestSupport/|CanaryBackstopTests.swift'` and a stage dropping
/// comment lines. **The exclusion stage is not tidiness and its control fires**: the support target
/// is where the barrier, the signal and the backstop are defined, and `CanaryBackstopTests` calls
/// `block` on threads of its own with no stub anywhere, so without it the answer counts definitions
/// and unit tests as handlers. The
/// alternation was three tokens until SONNY-515, whose sweep found a blocking handler none of them
/// named — `TaskDeletionReachesTheServerTests`' gate, a raw semaphore wait — and which replaced the
/// third token's only site with `CanaryBackstop.block`.
///
/// The old sentence also described the wrong pair. `.hang` is not a blocking handler: that handler
/// returns immediately and it is the `Outcome` that never answers, so the request ends on the
/// client's own timeout with nothing of ours parked on a thread.
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
        let thread = Thread { [weak self] in
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
        thread.name = "sonny.backend-stub"
        thread.start()
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
///
/// **The backstop is longer than any test-side wait can run, and a test holding one signals it in a
/// `defer`** (SONNY-515). It was ten seconds, the same as the test-side wait it was raced against, so
/// a test slowed by load could have its held request release itself early — breaking the very
/// ordering the hold existed to enforce, and failing in a wording no declaration covers. It now
/// outlasts `CanaryBackstop.ceiling` twice over, so a handler never gives up before its test has;
/// and because every test that holds one releases it however it ends, a test that abandons still
/// frees its handler at once instead of parking a thread for the whole backstop.
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
    public func waitUntilSignalled(backstop: TimeInterval = CanaryBackstop.ceiling * 2) -> Bool {
        lock.lock()
        let already = isSignalled
        lock.unlock()
        if already { return true }
        let result = semaphore.wait(timeout: .now() + backstop)
        if result == .success { semaphore.signal() }
        return result == .success
    }
}
