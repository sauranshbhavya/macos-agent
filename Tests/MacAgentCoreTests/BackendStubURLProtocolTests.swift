import Foundation
import MacAgentTestSupport
import Testing

/// The stub transport's own guarantee, which every backend-client test leans on without stating it
/// (SONNY-515): **a request's handler starts when the request arrives, whatever other handlers are
/// doing.**
///
/// It used to be false. Handlers ran on one shared concurrent `DispatchQueue`, which GCD serves from
/// its constrained worker pool — capped for the whole process at `sysctl kern.wq_max_constrained_threads`
/// → 64 on the Mac this was written on — so once that many threads were parked, the next handler
/// waited for one to come free, and on a loaded full-suite run 72 of 553 handlers waited a second or
/// more, the longest 7.352 s (an uncommitted probe at `8f3d1d02`). `BackendStubURLProtocol` now gives
/// every request a `Thread` of its own.
@Suite
struct BackendStubURLProtocolTests {
    /// More held handlers than GCD's constrained pool has threads, then all of them must have
    /// started. On the shared queue this stopped at the pool's width; on a thread per request every
    /// one starts.
    ///
    /// **A separate stub host per request**, so URLSession's per-host connection limit cannot be the
    /// thing that holds a request back — the property is about the stub's threads, and only they
    /// can fail it.
    ///
    /// The wait is `HangBackstop`'s, which is the right witness here and `CanaryBackstop` is not: the
    /// defect this pins exhausts the very pipeline a stub-transport canary would travel, so that
    /// canary would call every failure starved. `HangBackstop` counts its own looks on the main actor,
    /// which the defect does not touch, so a stuck verdict is a real one and records a second issue
    /// nothing declares.
    @Test
    @MainActor
    func eightyHeldHandlersAllStartWhileEveryOneOfThemIsStillHeld() async throws {
        let heldRequests = 80
        let started = StubCounter()
        let release = StubSignal()
        defer { release.signal() }
        let stubs = (0..<heldRequests).map { _ in BackendStubURLProtocol.makeSession() }
        defer { stubs.forEach { BackendStubURLProtocol.unregister(host: $0.host) } }
        for stub in stubs {
            BackendStubURLProtocol.register(host: stub.host) { _ in
                started.increment("started")
                release.waitUntilSignalled()
                return .reply(statusCode: 200, headers: [:], body: Data())
            }
        }

        let requests = stubs.map { stub in
            Task.detached { _ = try? await stub.session.data(from: stub.baseURL.appendingPathComponent("held")) }
        }
        defer { requests.forEach { $0.cancel() } }

        let allStarted = try await HangBackstop.waitRecordingAStuckWait(
            for: "all \(heldRequests) held handlers to start",
            stuck: "fewer than \(heldRequests) held handlers started, and the wait looked often enough to rule out a starved actor — a handler is waiting for a thread another handler holds."
        ) { started.count("started") == heldRequests }
        #expect(allStarted)
        #expect(started.count("started") == heldRequests)
    }
}
