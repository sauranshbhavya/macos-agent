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
    /// The wait is `HangBackstop`'s, which is a right witness here and `CanaryBackstop` is not: the
    /// defect this pins exhausts the very pipeline a stub-transport canary would travel, so that
    /// canary would call every failure starved. `HangBackstop` counts its own looks on the main actor,
    /// which the defect does not touch, so a stuck verdict is a real one and records a second issue
    /// nothing declares. **The main actor is not the only such place** — a plain `Thread` is outside
    /// GCD's constrained pool too (PR #277's review, F5) — it is the one that already carries the
    /// stuck-or-starved rule.
    ///
    /// **What that witness costs, measured by the same review.** In a full run this test takes about
    /// a minute (64 to 78 s), and the time is the witness's rather than the handlers': all eighty
    /// started within 0.03 to 13 s of the requests going out, and the wait then got three looks in
    /// 16 to 54 s, because it queues behind every `@MainActor` suite in the process. A late look that
    /// finds the handlers started passes, so a slow main actor lengthens this test but cannot fail it.
    ///
    /// **It stops when the wait gives up, and asserts nothing after** (PR #277's review, F1). The wait
    /// has already said why — stuck, in a sentence that counts as evidence, or starved, in sentences
    /// declared as none. Asserting after a starved give-up added `Expectation failed` issues no
    /// declaration covers, which a battery reads as a kill nothing earned: the manufactured kill this
    /// test's branch exists to end, inside the test that branch added.
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
        guard allStarted else { return }
    }
}
