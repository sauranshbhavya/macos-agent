import Foundation
import Testing
@testable import MacAgentCore

/// A wait on something another pipeline makes true — a request reaching a stub handler, a detached
/// caller coming back — whose give-up is judged by a **canary sent through that same pipeline**, not
/// by the clock alone (SONNY-515).
///
/// **Why the clock alone is not enough here, measured rather than argued.** Three
/// `SonnyBackendClientTests` waits polled a real signal with a ten-second backstop, and a reviewer's
/// loaded full-suite run failed all three at 18.9 s, 18.9 s and 28.9 s while each passed alone in
/// under 0.03 s. A probe on the stub transport found where the time went: in each of three loaded
/// full runs exactly 48 stub requests waited a second or more for a thread on the stub's one shared
/// dispatch queue, longest 3.992 s, 4.037 s and 6.980 s, growing with load (the figures are
/// SONNY-515's own record, quoted rather than re-derivable). So the backstop was a threshold the
/// test raced, and its failure wording was declared nowhere — a battery that crossed it under load
/// counted a kill nothing earned (`CLAUDE.md`, SONNY-224).
///
/// **The rule, which is `HangBackstop`'s with a different witness.** `HangBackstop` counts its own
/// turns on the main actor, because the main actor is what its waits depend on. These waits depend
/// on a different pipeline — a client's actor, `URLSession`, the stub's own threads — and a poller
/// that is running fine says nothing about whether that pipeline is. So the witness is a canary: a
/// trivial round trip through the same pipeline. Before ``deadline`` nothing is decided and no canary
/// runs. From the deadline on, the canary runs back to back, and **only round trips that begin after
/// the deadline count** — a burst of healthy trips before a stall began would otherwise vouch for a
/// pipeline that was frozen when the verdict was taken. The verdict itself is
/// `HangBackstop.verdict(elapsed:observations:deadline:ceiling:observationFloor:)`, fed the canary's
/// count in place of looks:
///
/// - the condition held: nothing is recorded and control returns;
/// - ``canaryFloor`` fresh round trips completed while the condition stayed false — **stuck**. The
///   pipeline was demonstrably working, so the thing that should have made the condition true did
///   not happen, and that is a real failure. It records the declared give-up wording **and a second
///   issue in wording no declaration matches**, which is what lets `scripts/mutate` count the test
///   as a kill (`CLAUDE.md`'s SONNY-259 rule — a construct whose every wording is declared can never
///   be one);
/// - the ceiling arrived first — **starved**. The canary could not get through either, so this run
///   says nothing about the code, and only the declared wording is recorded.
///
/// Both failures **end the test** by throwing `HangBackstop.Abandoned` (PR #153's F2): a wait that
/// gives up and returns leaves its test asserting against a precondition that never arrived, and
/// every one of those assertions is an undeclared issue a battery reads as a kill.
///
/// **What this does not cover, stated so it is not assumed.** A request a test holds open is still
/// inside the client's own transport timeout (`SonnyBackendTimeouts`), which is the product's clock
/// and not this type's; a test starved past it between two of its own steps still fails in the
/// client's words. The thread-per-request change in `BackendStubURLProtocol` is what took the
/// measured stall out of that window.
public enum CanaryBackstop {
    /// The wall clock before which nothing is decided. Ten seconds is what the three waits this
    /// replaced already used; the number was never the defect, the lack of a witness was.
    public static let deadline: TimeInterval = 10

    /// The wall clock at which a wait whose canary never earned a verdict gives up as starved. Six
    /// times the deadline, and well past the longest stall measured (6.98 s at a one-minute load
    /// average of 240), while still bounded.
    public static let ceiling: TimeInterval = 60

    /// How many canary round trips, each begun after the deadline, make "it stayed false" a
    /// statement about the code. A held stub request that a working pipeline would have delivered
    /// is still undelivered after this many fresh requests went through the same pipeline.
    public static let canaryFloor = 20

    /// How a wait ended.
    public enum Outcome: Equatable, Sendable {
        /// The condition was observed to be true.
        case held
        /// The condition stayed false while the canary completed at least the floor.
        case stuck(elapsed: TimeInterval, canaryRoundTrips: Int)
        /// The ceiling arrived before the canary could complete the floor.
        case starved(elapsed: TimeInterval, canaryRoundTrips: Int)
    }

    /// One round trip through the pipeline a wait depends on, answering whether it completed.
    public struct Canary: Sendable {
        public let roundTrip: @Sendable () async -> Bool

        public init(roundTrip: @escaping @Sendable () async -> Bool) {
            self.roundTrip = roundTrip
        }

        /// A request through `BackendStubURLProtocol` from a `SonnyBackendClient` of its own, to a
        /// stub host of its own that answers at once — the path every backend-client test's own
        /// requests take. Its host is registered when the canary is built and unregistered when the
        /// last round trip holding it is gone.
        public static var stubTransport: Canary {
            let host = TransportCanaryHost()
            return Canary { await host.roundTrip() }
        }
    }

    /// Where a wait running inside a stub handler leaves its outcome for the test body.
    ///
    /// A handler runs on a thread no test owns, so an issue recorded there is recorded against no
    /// test; ``block(deadline:ceiling:canaryFloor:canary:until:)`` hands its outcome here instead,
    /// and the test passes it to ``abandonUnlessHeld(_:waitingFor:canaryFloor:sourceLocation:)``.
    public final class Handoff: @unchecked Sendable {
        private let lock = NSLock()
        private var handed: Outcome?

        public init() {}

        public func hand(_ outcome: Outcome) {
            lock.lock()
            handed = outcome
            lock.unlock()
        }

        /// Nil until a handler has handed something back.
        public var outcome: Outcome? {
            lock.lock()
            defer { lock.unlock() }
            return handed
        }
    }

    // MARK: - Waiting

    /// Polls `condition` until it holds or the verdict says to stop, and reports which.
    ///
    /// Suspends between looks rather than blocking, so it is the one to use from a test body. It
    /// records nothing; ``waitOrAbandon(for:deadline:ceiling:canaryFloor:canary:sourceLocation:until:)``
    /// is the form that turns a failure into issues and an ended test.
    public static func wait(
        deadline: TimeInterval = deadline,
        ceiling: TimeInterval = ceiling,
        canaryFloor: Int = canaryFloor,
        canary: @autoclosure @escaping @Sendable () -> Canary = .stubTransport,
        until condition: @Sendable () -> Bool
    ) async throws -> Outcome {
        let watch = Watch(deadline: deadline, ceiling: ceiling, canaryFloor: canaryFloor, canary: canary)
        defer { watch.stop() }
        while true {
            if let outcome = watch.check(conditionHolds: condition()) { return outcome }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// ``wait(deadline:ceiling:canaryFloor:canary:until:)``, blocking the calling thread between looks.
    ///
    /// **Only for a thread nothing else is waiting on** — a `BackendStubURLProtocol` handler, which
    /// runs on a thread of its own. Never from the main actor or a task: a blocked cooperative thread
    /// is exactly the kind of stall this type exists to tell apart from a failure.
    public static func block(
        deadline: TimeInterval = deadline,
        ceiling: TimeInterval = ceiling,
        canaryFloor: Int = canaryFloor,
        canary: @autoclosure @escaping @Sendable () -> Canary = .stubTransport,
        until condition: () -> Bool
    ) -> Outcome {
        let watch = Watch(deadline: deadline, ceiling: ceiling, canaryFloor: canaryFloor, canary: canary)
        defer { watch.stop() }
        while true {
            if let outcome = watch.check(conditionHolds: condition()) { return outcome }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    /// ``wait(deadline:ceiling:canaryFloor:canary:until:)``, and then ``abandonUnlessHeld(_:waitingFor:canaryFloor:sourceLocation:)``.
    public static func waitOrAbandon(
        for description: String,
        deadline: TimeInterval = deadline,
        ceiling: TimeInterval = ceiling,
        canaryFloor: Int = canaryFloor,
        canary: @autoclosure @escaping @Sendable () -> Canary = .stubTransport,
        sourceLocation: SourceLocation = #_sourceLocation,
        until condition: @Sendable () -> Bool
    ) async throws {
        let outcome = try await wait(
            deadline: deadline,
            ceiling: ceiling,
            canaryFloor: canaryFloor,
            canary: canary(),
            until: condition
        )
        try abandonUnlessHeld(outcome, waitingFor: description, canaryFloor: canaryFloor, sourceLocation: sourceLocation)
    }

    /// Returns when `outcome` is ``Outcome/held``. Otherwise records what the verdict entitles the
    /// test to say and **ends it** by throwing `HangBackstop.Abandoned`.
    ///
    /// Separate from the wait so that a wait running where no test is — inside a stub handler — can
    /// hand its outcome back to the test body, which is the only place an issue can be recorded
    /// against the right test.
    public static func abandonUnlessHeld(
        _ outcome: Outcome,
        waitingFor description: String,
        canaryFloor: Int = canaryFloor,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        switch outcome {
        case .held:
            return
        case let .stuck(elapsed, trips), let .starved(elapsed, trips):
            Issue.record(
                Comment(rawValue: gaveUpMessage(description, elapsed: elapsed, canaryRoundTrips: trips, canaryFloor: canaryFloor)),
                sourceLocation: sourceLocation
            )
            if case .stuck = outcome {
                Issue.record(
                    Comment(rawValue: stuckMessage(description, canaryRoundTrips: trips)),
                    sourceLocation: sourceLocation
                )
            }
            throw HangBackstop.Abandoned(description: HangBackstop.abandonedMessage(description))
        }
    }

    // MARK: - Wordings

    /// Recorded whenever a wait gives up, stuck or starved, and the signature
    /// `scripts/mutate-untrusted-failures` declares. Kept on one rendered line from `This is a`
    /// onward, because the harness matches a literal fragment of it.
    public static func gaveUpMessage(
        _ description: String,
        elapsed: TimeInterval,
        canaryRoundTrips: Int,
        canaryFloor: Int = canaryFloor
    ) -> String {
        """
        gave up after \(String(format: "%.1f", elapsed))s waiting for: \(description), with \(canaryRoundTrips) of \
        \(canaryFloor) canary round trips through the same pipeline completed after the deadline.
        This is a canary-judged backstop, not a timing assertion — on its own it says nothing about \
        the code under test, and a run where the canary could not get through either is a busy \
        machine rather than a defect.
        """
    }

    /// Recorded beside ``gaveUpMessage(_:elapsed:canaryRoundTrips:canaryFloor:)`` only when the
    /// canary proved the pipeline was working, and deliberately matching no declaration — it is the
    /// issue that makes a stuck wait count as evidence.
    public static func stuckMessage(_ description: String, canaryRoundTrips: Int) -> String {
        """
        a real failure: \(canaryRoundTrips) requests through the same pipeline went through after the \
        deadline while this wait, for \(description), never saw it — so the pipeline was working, and \
        whatever should have made it true did not.
        """
    }

    // MARK: - The watch both loops share

    /// The per-look decision both ``wait(deadline:ceiling:canaryFloor:canary:until:)`` and
    /// ``block(deadline:ceiling:canaryFloor:canary:until:)`` make, so that the async and blocking
    /// loops differ only in how they pause.
    private final class Watch: @unchecked Sendable {
        private let start = Date()
        private let deadline: TimeInterval
        private let ceiling: TimeInterval
        private let canaryFloor: Int
        private let makeCanary: @Sendable () -> Canary
        private let trips = StubCounter()
        private var canaryTask: Task<Void, Never>?

        init(
            deadline: TimeInterval,
            ceiling: TimeInterval,
            canaryFloor: Int,
            canary: @escaping @Sendable () -> Canary
        ) {
            self.deadline = deadline
            self.ceiling = ceiling
            self.canaryFloor = canaryFloor
            self.makeCanary = canary
        }

        /// Nil to keep looking; otherwise how the wait ended.
        func check(conditionHolds: Bool) -> Outcome? {
            if conditionHolds { return .held }
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= deadline, canaryTask == nil {
                // Built here and not before: a canary begun earlier could vouch for the pipeline
                // with trips it completed before a stall.
                let canary = makeCanary()
                let trips = trips
                canaryTask = Task.detached {
                    while !Task.isCancelled {
                        if await canary.roundTrip() {
                            trips.increment("round trip")
                            // A trip that never suspends would otherwise hold its thread until the
                            // wait gives up, and the wait needs a thread of its own to look.
                            await Task.yield()
                        } else {
                            // A trip that failed at once must not become a hot loop beside the wait.
                            try? await Task.sleep(nanoseconds: 1_000_000)
                        }
                    }
                }
            }
            let completed = trips.count("round trip")
            switch HangBackstop.verdict(
                elapsed: elapsed,
                observations: completed,
                deadline: deadline,
                ceiling: ceiling,
                observationFloor: canaryFloor
            ) {
            case .keepWaiting:
                return nil
            case .stuck:
                return .stuck(elapsed: elapsed, canaryRoundTrips: completed)
            case .starved:
                return .starved(elapsed: elapsed, canaryRoundTrips: completed)
            }
        }

        func stop() {
            canaryTask?.cancel()
        }
    }
}

/// The stub host and client ``CanaryBackstop/Canary/stubTransport`` sends through.
private final class TransportCanaryHost: @unchecked Sendable {
    private let host: String
    private let client: SonnyBackendClient

    init() {
        let stub = BackendStubURLProtocol.makeSession()
        host = stub.host
        BackendStubURLProtocol.register(host: stub.host) { _ in
            .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        client = SonnyBackendClient(
            environment: SonnyBackendEnvironment(baseURL: stub.baseURL, source: .debugOverride),
            tokenStore: KeychainAccountTokenStore(secretStore: InMemoryKeychainSecretStore()),
            session: stub.session
        )
    }

    deinit {
        BackendStubURLProtocol.unregister(host: host)
    }

    func roundTrip() async -> Bool {
        let request = SonnyBackendRequest(
            method: "GET",
            path: "/v1/canary",
            body: nil,
            authentication: .none,
            idempotencyKey: nil,
            timeout: SonnyBackendTimeouts.auth,
            isRetrySafe: false
        )
        return (try? await client.send(request)) != nil
    }
}
