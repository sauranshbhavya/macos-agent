import Foundation
import Testing

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
/// on a different pipeline — `URLSession`, the stub's own threads, the cooperative pool — and a
/// poller that is running fine says nothing about whether that pipeline is. So the witness is a
/// canary: a trivial round trip through the same kind of pipeline. Before ``deadline`` nothing is
/// decided and no canary runs. From the deadline on, the canary runs back to back, and **only round
/// trips that begin after the deadline count** — a burst of healthy trips before a stall began would
/// otherwise vouch for a pipeline that was frozen when the verdict was taken. Each trip ends one of
/// three ways (``Trip``), and ``verdict(elapsed:completed:failed:deadline:ceiling:canaryFloor:)``
/// reads the counts:
///
/// - the condition held: nothing is recorded and control returns;
/// - ``canaryFloor`` fresh trips **completed** while the condition stayed false — **stuck**. The
///   pipeline was demonstrably working, so the thing that should have made the condition true did
///   not happen, and that is a real failure. It records the declared give-up wording **and a second
///   issue in wording no declaration matches**, which is what lets `scripts/mutate` count the test
///   as a kill (`CLAUDE.md`'s SONNY-259 rule — a construct whose every wording is declared can never
///   be one);
/// - ``canaryFloor`` fresh trips came back **failed** — **broken**. Something answered every time,
///   so this is not a busy machine, and the test says so in a second issue nothing declares;
/// - the ceiling arrived first — **starved**. The canary got no answer at all, so this run says
///   nothing about the code, and only declared wordings are recorded.
///
/// **The canary never runs through the code under test** (PR #277's review, F3). Its first version
/// sent a real `SonnyBackendClient.send`, so a mutant that broke `send` failed every canary trip on
/// an idle machine, and the wait called that a busy machine — the sentence was false and the log
/// could not tell the two apart. ``Canary/stubTransport`` now asks `URLSession` and the stub
/// directly, ``Canary/actorHop`` hops onto an actor of its own, and a trip that comes back failed is
/// counted as an answer rather than as silence.
///
/// Every failure **ends the test** by throwing `HangBackstop.Abandoned` (PR #153's F2): a wait that
/// gives up and returns leaves its test asserting against a precondition that never arrived, and
/// every one of those assertions is an undeclared issue a battery reads as a kill.
///
/// **What this does not cover, stated so it is not assumed.** A request a test holds open is still
/// inside the client's own transport timeout (`SonnyBackendTimeouts`), which is the product's clock
/// and not this type's; a test starved past it between two of its own steps still fails in the
/// client's words. That residue is SONNY-530, deferred by founder decision on 2026-09-19.
public enum CanaryBackstop {
    /// The wall clock before which nothing is decided. Ten seconds is what the three waits this
    /// replaced already used; the number was never the defect, the lack of a witness was.
    public static let deadline: TimeInterval = 10

    /// The wall clock at which a wait whose canary never earned a verdict gives up as starved. Six
    /// times the deadline, and still well past the longest waits measured on this branch — a stub
    /// handler queued 7.352 s for a thread before the thread-per-request change, and three real
    /// waits that ran to 12.7 s and 14.0 s after it, all of which ended held — while still bounded.
    public static let ceiling: TimeInterval = 60

    /// How many canary trips, each begun after the deadline, make "it stayed false" a statement
    /// about the code.
    ///
    /// **A hundred, and the margin is measured** (PR #277's review, F4). It was twenty. The review
    /// raced the canary against a real flow of one and a half round trips, started at the same
    /// instant — the worst timing, the one a stall ending exactly at the deadline produces — three
    /// hundred times inside a full run under ten CPU burners at a load average up to 109.81: all
    /// three hundred held, and the most trips the canary had completed when the flow landed was
    /// 18, of twenty. A hundred is more than five times that. That was the first canary, which went
    /// through a `SonnyBackendClient`; this one asks `URLSession` directly, and it is *slower* per
    /// trip rather than faster, which was checked rather than assumed because a faster canary would
    /// have eaten into the margin: a hundred trips took 0.060 to 0.143 s against 0.027 to 0.066 s for
    /// the client's path, five batches each, at a load average between 23.50 and 58.81. So it reaches
    /// fewer trips in the same window, the safe direction, and the raise costs the stuck path about a
    /// tenth of a second.
    public static let canaryFloor = 100

    /// How one canary round trip ended.
    public enum Trip: Equatable, Sendable {
        /// It came back as the canary expected: the pipeline is carrying requests.
        case completed
        /// It came back, but not as expected. Something answered, so this is not silence.
        case failed
        /// It never got an answer — it timed out or was cancelled. Counts towards nothing.
        case unanswered
    }

    /// What one look decided.
    public enum Verdict: Equatable, Sendable {
        case keepWaiting
        case stuck
        case broken
        case starved
    }

    /// The counts a verdict was reached on.
    public struct Tally: Equatable, Sendable {
        public let elapsed: TimeInterval
        public let completed: Int
        public let failed: Int

        public init(elapsed: TimeInterval, completed: Int, failed: Int) {
            self.elapsed = elapsed
            self.completed = completed
            self.failed = failed
        }
    }

    /// How a wait ended.
    public enum Outcome: Equatable, Sendable {
        /// The condition was observed to be true.
        case held
        /// The condition stayed false while the canary completed at least the floor.
        case stuck(Tally)
        /// The condition stayed false while the canary came back failed at least the floor.
        case broken(Tally)
        /// The ceiling arrived before the canary could reach the floor either way.
        case starved(Tally)
    }

    /// One round trip through the kind of pipeline a wait depends on.
    public struct Canary: Sendable {
        public let roundTrip: @Sendable () async -> Trip

        public init(roundTrip: @escaping @Sendable () async -> Trip) {
            self.roundTrip = roundTrip
        }

        /// A request through `URLSession` and `BackendStubURLProtocol` to a stub host of its own that
        /// answers at once — the transport every backend-client test's requests take, with nothing
        /// from `Sources/` on the path. Its host is registered when the canary is built and
        /// unregistered when the last trip holding it is gone.
        public static var stubTransport: Canary {
            let host = TransportCanaryHost()
            return Canary { await host.roundTrip() }
        }

        /// A detached task hopping onto an actor of its own — the cooperative pool and actor
        /// scheduling that a detached caller's hop onto a client takes, without the client.
        public static var actorHop: Canary {
            let hop = CanaryHop()
            return Canary {
                await hop.touch()
                return .completed
            }
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

    // MARK: - The verdict

    /// The whole decision, as a pure function of the counts.
    ///
    /// Stuck, broken and starved are `HangBackstop.verdict`'s arithmetic with the canary's counts in
    /// place of looks, and **stuck is checked first**, for that function's reason: a canary that got
    /// through, enough times, outranks how long it took. Broken comes before starved because a
    /// canary that keeps getting an answer is, whatever else, not evidence of a busy machine.
    public static func verdict(
        elapsed: TimeInterval,
        completed: Int,
        failed: Int,
        deadline: TimeInterval = deadline,
        ceiling: TimeInterval = ceiling,
        canaryFloor: Int = canaryFloor
    ) -> Verdict {
        let onCompletedTrips = HangBackstop.verdict(
            elapsed: elapsed,
            observations: completed,
            deadline: deadline,
            ceiling: ceiling,
            observationFloor: canaryFloor
        )
        if onCompletedTrips == .stuck { return .stuck }
        if elapsed >= deadline, failed >= canaryFloor { return .broken }
        return onCompletedTrips == .starved ? .starved : .keepWaiting
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
        let tally: Tally
        let evidence: String?
        switch outcome {
        case .held:
            return
        case let .stuck(counts):
            tally = counts
            evidence = stuckMessage(description, canaryRoundTrips: counts.completed)
        case let .broken(counts):
            tally = counts
            evidence = brokenMessage(description, failedRoundTrips: counts.failed)
        case let .starved(counts):
            tally = counts
            evidence = nil
        }
        Issue.record(
            Comment(rawValue: gaveUpMessage(description, tally: tally, canaryFloor: canaryFloor)),
            sourceLocation: sourceLocation
        )
        if let evidence {
            Issue.record(Comment(rawValue: evidence), sourceLocation: sourceLocation)
        }
        throw HangBackstop.Abandoned(description: HangBackstop.abandonedMessage(description))
    }

    // MARK: - Wordings

    /// Recorded whenever a wait gives up, whatever the verdict, and the signature
    /// `scripts/mutate-untrusted-failures` declares. Kept on one rendered line from `This is a`
    /// onward, because the harness matches a literal fragment of it.
    public static func gaveUpMessage(
        _ description: String,
        tally: Tally,
        canaryFloor: Int = canaryFloor
    ) -> String {
        """
        gave up after \(String(format: "%.1f", tally.elapsed))s waiting for: \(description). After the \
        deadline, \(tally.completed) canary round trips completed and \(tally.failed) came back failed, \
        against a floor of \(canaryFloor).
        This is a canary-judged backstop, not a timing assertion — on its own it says nothing about \
        the code under test, and a run in which no canary trip got an answer at all is a busy \
        machine rather than a defect.
        """
    }

    /// Recorded beside the give-up wording only when the canary proved the pipeline was working, and
    /// deliberately matching no declaration — it is the issue that makes a stuck wait count as
    /// evidence.
    public static func stuckMessage(_ description: String, canaryRoundTrips: Int) -> String {
        """
        a real failure: \(canaryRoundTrips) requests through the same pipeline went through after the \
        deadline while this wait, for \(description), never saw it — so the pipeline was working, and \
        whatever should have made it true did not.
        """
    }

    /// Recorded beside the give-up wording when the canary kept getting answers that were failures,
    /// and deliberately matching no declaration: whatever is wrong, it is not a busy machine, and a
    /// log that said so would send the reader after load that was never there.
    public static func brokenMessage(_ description: String, failedRoundTrips: Int) -> String {
        """
        not a busy machine: \(failedRoundTrips) canary requests came back failed after the deadline \
        while this wait, for \(description), never saw it — something answered every time, so the \
        canary's own path is broken; for the canaries CanaryBackstop ships, that path is the test \
        harness and never Sources/.
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
                        switch await canary.roundTrip() {
                        case .completed:
                            trips.increment("completed")
                            // A trip that never suspends would otherwise hold its thread until the
                            // wait gives up, and the wait needs a thread of its own to look.
                            await Task.yield()
                        case .failed:
                            trips.increment("failed")
                            // A trip that fails at once must not become a hot loop beside the wait.
                            try? await Task.sleep(nanoseconds: 1_000_000)
                        case .unanswered:
                            try? await Task.sleep(nanoseconds: 1_000_000)
                        }
                    }
                }
            }
            let tally = Tally(
                elapsed: elapsed,
                completed: trips.count("completed"),
                failed: trips.count("failed")
            )
            switch CanaryBackstop.verdict(
                elapsed: elapsed,
                completed: tally.completed,
                failed: tally.failed,
                deadline: deadline,
                ceiling: ceiling,
                canaryFloor: canaryFloor
            ) {
            case .keepWaiting:
                return nil
            case .stuck:
                return .stuck(tally)
            case .broken:
                return .broken(tally)
            case .starved:
                return .starved(tally)
            }
        }

        func stop() {
            canaryTask?.cancel()
        }
    }
}

/// The stub host ``CanaryBackstop/Canary/stubTransport`` sends through.
private final class TransportCanaryHost: @unchecked Sendable {
    private let host: String
    private let session: URLSession
    private let url: URL

    init() {
        let stub = BackendStubURLProtocol.makeSession()
        host = stub.host
        session = stub.session
        url = stub.baseURL.appendingPathComponent("canary")
        BackendStubURLProtocol.register(host: stub.host) { _ in
            .reply(statusCode: 204, headers: [:], body: Data())
        }
    }

    deinit {
        BackendStubURLProtocol.unregister(host: host)
    }

    func roundTrip() async -> CanaryBackstop.Trip {
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 204 ? .completed : .failed
        } catch let error as URLError where error.code == .timedOut || error.code == .cancelled {
            return .unanswered
        } catch {
            return .failed
        }
    }
}

/// The actor ``CanaryBackstop/Canary/actorHop`` hops onto.
private actor CanaryHop {
    func touch() {}
}
