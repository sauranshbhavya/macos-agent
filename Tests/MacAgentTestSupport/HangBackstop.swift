import Foundation
import Testing

/// The deadline a test waits under when it is polling for something another task will make true,
/// and — the part this type exists for — the rule that decides what reaching that deadline *means*
/// (SONNY-302).
///
/// **The claim a hang backstop makes is "I looked, repeatedly, and it was never true."** That
/// sentence is what makes a timeout a real failure rather than a note about the hardware, and it is
/// a claim about observations, not about seconds. A wall-clock deadline was standing in for it, on
/// the assumption that thirty seconds of wall clock buys thousands of looks. In this test process it
/// buys two.
///
/// **Why it buys two.** Both test targets are one process, `MacAgentTests` is full of `@MainActor`
/// suites, and Swift Testing runs suites concurrently — so every `@MainActor` test in the run
/// interleaves on the *one* main actor, and its queue under that concurrency is hundreds of jobs
/// deep. A poll loop that sleeps and re-checks gets exactly one turn per lap of that queue, and a
/// lap is seconds to tens of seconds long. The waiter is not slow and the machine is not
/// overloaded; the waiter simply is not being asked whether it is done.
///
/// **Measured on `fix/starvation-is-not-a-deadlock`, with `f65e72e` (the branch point) checked out
/// plus a probe patch that only counted — it recorded each wait's observations and gaps to a file
/// and changed no behaviour — while five other sessions built and tested on the same Mac, which is
/// the load this is written for.** Five runs: one `--filter VisionSessionRunTests` and four full
/// ones, of which two went red. A wait is counted as having completed when its elapsed stayed under
/// the 30 s deadline and as having reached it otherwise. The probe's own output files are scratch
/// artifacts and are not in this repository, so the figures are quoted rather than re-derivable.
///
/// - **537 waits completed.** The most observations any of them needed was **62**; the 99th
///   percentile was 25 and the median 6.
/// - **177 waits reached the deadline**, all of them in the two red runs. **145 of those had made
///   one or two observations** in the whole window — the thirty seconds spent almost entirely in
///   one or two blind spells, the longest single gap between consecutive looks being **34.0 s**.
/// - A detached probe ticking every 10 ms off the main actor ran at **56–91 ticks/s across every
///   wait in every run**, red and green alike, against a nominal 100. The process was being
///   scheduled normally throughout. Nothing here is about CPU.
///
/// So the two populations are separated by two orders of magnitude — 62 observations at the very
/// worst for work that finished, against 1 or 2 for work that was denied its turns — and that gap,
/// not the clock, is what a backstop can safely read.
///
/// **What the rule is.** A timeout may be called a deadlock only once the wait has actually
/// evaluated its condition ``observationFloor`` times. Until then, reaching the wall-clock deadline
/// says nothing, so the wait continues — bounded by ``starvationCeiling``, at which point it fails
/// as *starvation*, in its own words, naming how few looks it got. Both outcomes fail. Neither
/// hangs.
///
/// **What this deliberately is not.** It is not a longer timer. On an unloaded machine
/// ``observationFloor`` observations arrive in about three seconds, so the thirty-second deadline is
/// still the binding constraint and a genuinely stuck loop still fails at thirty seconds, with the
/// same wording it failed with before. The only runs whose behaviour changes are the ones that were
/// never measuring anything.
///
/// **What this replaces, and the measurements that belong to it.** Three earlier investigations
/// moved this deadline from three and four seconds to thirty, for a reason that was right as far as
/// it went: the old numbers were close enough to real running time that they fired on a busy
/// machine. Their measurements are kept here because they are the record of how this deadline got
/// its length, and deleting them along with the wall-clock rule would lose it. On `main` at
/// `89e317b`, twelve consecutive full-suite runs at ordinary load produced eleven passes and one
/// failure — 42 issues in the failing run, 7.656 s against a 5.2–5.5 s norm. SONNY-159 measured the
/// same rate more carefully on a quiet machine: 17 of 18 on `main` at `7b9fec9`, and 15 of 16 on
/// `feature/terminal-screen-check` at `315419e`, indistinguishable at that sample size; its worst
/// observed run produced 88 issues. SONNY-161 measured the other direction: two legitimately heavy
/// task-history tests took the failure rate from zero in four runs to one in three, and it rejected
/// tuning against a threshold nobody had measured — correctly, and this is not that. Thirty seconds
/// survives unchanged. What SONNY-302 found is that the quantity being compared against it was
/// never the one the sentence beside it claimed.
///
/// **The cascade this ends, which is why the old shape cost more than the tests it failed.** A
/// starved wait recorded its issue and *returned*, and the test then carried on with a precondition
/// that had never arrived — an approval never raised, a run never started. Every later wait in that
/// test then timed out too, at a perfectly healthy six-millisecond cadence, which is exactly what a
/// genuine deadlock looks like from the outside. In the fourth full run above, **19 of 19** such
/// timeouts — ones that had collected a thousand observations or more — were preceded, inside the
/// same test, by a timeout that had collected two or fewer; **73 starved waits became 195 issues
/// across 68 test functions**. A red run of that shape does not read as "the machine was busy" to
/// anybody — it reads as sixty-eight broken tests.
public enum HangBackstop {
    /// How long the poll loop sleeps between looks. Not a tuning knob: on a quiet actor it sets the
    /// observation rate (about 160/s measured, against a nominal 200), and on a busy one it is
    /// irrelevant because the wait is queued rather than sleeping.
    public static let pollInterval: Duration = .milliseconds(5)

    /// The wall clock after which an unmet condition *may* be called a deadlock — never on its own,
    /// only together with ``observationFloor``. Thirty seconds because that is what it already was
    /// (SONNY-159/160/161), and because nothing measured here argues about the number: the defect
    /// was never the length of the deadline, it was that the deadline was the only thing consulted.
    public static let deadlockDeadline: TimeInterval = 30

    /// How many times the condition must have been evaluated before "it was never true" is a claim
    /// about the code rather than about the queue.
    ///
    /// **500, which is eight times the worst case ever observed for a wait that finished** (62, over
    /// 532 completing waits) and two hundred and fifty times what a starved wait manages. The margin
    /// is deliberately coarse: this is a backstop, and the two populations it separates are two
    /// orders of magnitude apart, so a number anywhere between about 200 and a few thousand behaves
    /// identically. What it must not be is small enough for a starved wait to reach, or large enough
    /// that a free-running poll loop cannot reach it — a wait polling at the measured healthy rate
    /// collects 500 observations in about three seconds.
    public static let observationFloor = 500

    /// The wall clock at which a wait gives up regardless, and the reason a starved wait cannot turn
    /// into a hang.
    ///
    /// Six times ``deadlockDeadline``. The waits that starved in the measurements above were blocked
    /// for a single spell of up to 31 s and would have completed on the next lap; the green runs'
    /// slowest completing wait took 21.3 s. Three minutes is far outside both and still bounded.
    ///
    /// **It overshoots, and by design it cannot not.** Both the deadline and the ceiling are read
    /// inside the poll loop, which only runs when the actor gives it a turn — so a wait whose lap is
    /// twenty seconds long discovers it is past the ceiling up to a lap late. The measured overshoot
    /// on the thirty-second deadline was to about 50 s. The bound is "one lap past the ceiling",
    /// which is finite for the same reason the ceiling is worth having; it is not the tight bound a
    /// timing assertion would need, and this is not one.
    public static let starvationCeiling: TimeInterval = 180

    /// What a poll loop should do at the moment it checks.
    public enum Verdict: Equatable, Sendable {
        /// The wait has not earned a verdict yet — either it is inside the deadline, or it is past
        /// it without having looked enough times to say anything.
        case keepWaiting
        /// The condition was observed to be false, enough times, over long enough. A real failure.
        case stuck
        /// The wait ran out of wall clock without ever getting enough turns to observe anything.
        /// A statement about the machine.
        case starved
    }

    /// The whole decision, as a pure function of two numbers, so that every boundary of it is
    /// testable without a busy machine to reproduce.
    ///
    /// `.stuck` is checked first on purpose: a wait that has both run past the ceiling *and*
    /// collected its observations is a wait that looked, and what it saw outranks how long it took.
    public static func verdict(
        elapsed: TimeInterval,
        observations: Int,
        deadline: TimeInterval = deadlockDeadline,
        ceiling: TimeInterval = starvationCeiling,
        observationFloor: Int = observationFloor
    ) -> Verdict {
        if elapsed >= deadline, observations >= observationFloor { return .stuck }
        if elapsed >= ceiling { return .starved }
        return .keepWaiting
    }

    /// Seconds to one decimal place. `Int(elapsed)` truncated, so a wait that gave up after 0.4 s
    /// reported "after 0s" — a number that reads like a bug in the harness rather than a duration.
    private static func formatted(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds)
    }

    /// The wording for `.stuck`. Kept on one rendered line from `This deadline` onward, because
    /// `scripts/mutate-untrusted-failures` matches a literal fragment of it and a fragment split
    /// across rendered lines matches nothing.
    public static func stuckMessage(
        _ description: String,
        elapsed: TimeInterval,
        observations: Int,
        observationFloor: Int = observationFloor
    ) -> String {
        """
        timed out after \(formatted(elapsed))s waiting for: \(description), having evaluated the condition \
        \(observations) times without it ever being true.
        This deadline is a deadlock backstop, not a timing assertion — it is allowed to fire only \
        after the wait has actually looked at least \(observationFloor) times, so a run that was \
        denied its turns on the shared actor reports starvation instead of arriving here. Treat it \
        as a real failure and look for what is not completing.
        """
    }

    /// The wording for `.starved`, and the signature `scripts/mutate-untrusted-failures` declares so
    /// that a mutation battery reads it as the non-evidence it is.
    public static func starvedMessage(
        _ description: String,
        elapsed: TimeInterval,
        observations: Int,
        observationFloor: Int = observationFloor
    ) -> String {
        """
        gave up after \(formatted(elapsed))s waiting for: \(description), having managed to evaluate the \
        condition only \(observations) times.
        This is main-actor starvation and not a stuck loop — the test never got enough turns on the \
        shared actor to observe anything, so this run says nothing about whether the code under test \
        works. It is not a defect in the code and not a mutation kill; re-run on a quieter machine. \
        A backstop needs at least \(observationFloor) looks before it is entitled to a verdict.
        """
    }

    /// The error ``waitOrAbandon(for:deadline:ceiling:observationFloor:sourceLocation:until:)`` throws
    /// when it gives up, so the test **ends** instead of carrying on (SONNY-136, PR #153's F2).
    ///
    /// **Why an error and not a returned verdict.** ``wait(for:...)`` records its issue and returns,
    /// which is correct for a caller that wants to keep going — and is the cascade this type's own
    /// doc describes when the caller does not: the test runs on with a precondition that never
    /// arrived and records ordinary `Expectation failed` assertions, one per line it would have
    /// checked. Those are the issues `scripts/mutate-untrusted-failures` cannot excuse, because they
    /// are indistinguishable from real ones, so a starved run comes back looking exactly like a
    /// mutation kill. Throwing is what makes the set of issues such a test can record *finite and
    /// declared*: the backstop's own, and this one.
    ///
    /// `CustomStringConvertible` rather than a bare `Error`, because swift-testing renders a thrown
    /// error as `Caught error: <description>` and a struct printed by its synthesized description
    /// would carry no sentence for the classifier to match.
    public struct Abandoned: Error, CustomStringConvertible {
        public let description: String

        public init(description: String) {
            self.description = description
        }
    }

    /// The wording ``Abandoned`` carries, and the signature `scripts/mutate-untrusted-failures`
    /// declares so a battery reads it as the non-evidence it is.
    ///
    /// It says what happened to the *test*, not what happened to the code: the wait above has
    /// already recorded whether it was stuck or starved, and this is only the reason nothing after
    /// it ran.
    public static func abandonedMessage(_ description: String) -> String {
        "the wait for \(description) was abandoned, so this test stopped here rather than asserting against a precondition that never arrived."
    }

    /// ``wait(for:...)``, except that giving up **ends the test** rather than returning to it.
    ///
    /// Use this wherever the thing being waited for is a *precondition* — a run that has to finish
    /// before its result can be read, a published value that has to settle before a row can be
    /// checked. Use ``wait(for:...)`` where the wait is the assertion itself and the caller has
    /// nothing further to do.
    ///
    /// **The condition is evaluated once more after the wait returns**, rather than trusting the
    /// wait's own exit: `wait` returns an observation count for both the success and the give-up
    /// paths, so the count cannot say which happened, and re-reading the condition is cheaper than
    /// a second return channel.
    @MainActor
    public static func waitOrAbandon(
        for description: String,
        deadline: TimeInterval = deadlockDeadline,
        ceiling: TimeInterval = starvationCeiling,
        observationFloor: Int = observationFloor,
        sourceLocation: SourceLocation = #_sourceLocation,
        until condition: @MainActor () -> Bool
    ) async throws {
        _ = try await wait(
            for: description,
            deadline: deadline,
            ceiling: ceiling,
            observationFloor: observationFloor,
            sourceLocation: sourceLocation,
            until: condition
        )
        guard condition() else { throw Abandoned(description: abandonedMessage(description)) }
    }

    /// Polls `condition` on the caller's actor until it is true, or until ``verdict(elapsed:observations:deadline:ceiling:observationFloor:)``
    /// says to stop, and records the matching issue when it does.
    ///
    /// **`@MainActor`, and that is the mechanism rather than a convenience.** The count this returns
    /// is only meaningful because the loop and the condition run on the very actor whose
    /// availability is in question: each observation is one turn on that actor, so counting
    /// observations counts laps of its queue. A helper hopping to some other executor to hold the
    /// clock would poll happily while the actor under it was unavailable, and would measure nothing.
    ///
    /// - Returns: how many times the condition was evaluated, so a caller that wants to assert on
    ///   the number can. `VisionSessionRunTests` does not; the tests for this type do.
    @discardableResult
    @MainActor
    public static func wait(
        for description: String,
        deadline: TimeInterval = deadlockDeadline,
        ceiling: TimeInterval = starvationCeiling,
        observationFloor: Int = observationFloor,
        sourceLocation: SourceLocation = #_sourceLocation,
        until condition: @MainActor () -> Bool
    ) async throws -> Int {
        let start = Date()
        var observations = 0
        while true {
            observations += 1
            if condition() { return observations }
            let elapsed = Date().timeIntervalSince(start)
            switch verdict(
                elapsed: elapsed,
                observations: observations,
                deadline: deadline,
                ceiling: ceiling,
                observationFloor: observationFloor
            ) {
            case .keepWaiting:
                break
            case .stuck:
                Issue.record(
                    Comment(rawValue: stuckMessage(
                        description,
                        elapsed: elapsed,
                        observations: observations,
                        observationFloor: observationFloor
                    )),
                    sourceLocation: sourceLocation
                )
                return observations
            case .starved:
                Issue.record(
                    Comment(rawValue: starvedMessage(
                        description,
                        elapsed: elapsed,
                        observations: observations,
                        observationFloor: observationFloor
                    )),
                    sourceLocation: sourceLocation
                )
                return observations
            }
            try await Task.sleep(for: pollInterval)
        }
    }
}
