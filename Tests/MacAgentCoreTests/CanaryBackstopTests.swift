import Foundation
import MacAgentTestSupport
import Testing

/// SONNY-515. What a canary-judged backstop may conclude from running out of wall clock.
///
/// **Driven by counts, never by a window a busy machine can blow through.** `HangBackstopTests`
/// records what happened when its own first drafts used small deadlines: both went red inside a full
/// run, having managed two looks in 10.8 seconds. So every verdict here is reached with a deadline of
/// zero and a ceiling nothing can approach, and decided by how many canary round trips completed —
/// except the two tests that are *about* a wall clock, which assert only a lower bound, the one
/// direction load can only reinforce.
///
/// **Nothing here quotes a wording `scripts/mutate-untrusted-failures` declares**, for the reason
/// `HangBackstopTests` gives: a guard whose own failure text carries a declared signature is a guard
/// the declaration file switches off. The declared signatures are read from that file instead.
@Suite
struct CanaryBackstopTests {
    private static let unreachableWallClock: TimeInterval = 3600

    /// The ceiling for the two broken-verdict waits: long enough that no load reaches it before three
    /// instant failed trips are counted, short enough that a mutant which removes the broken verdict
    /// fails the test as starved instead of hanging a battery for the hour `unreachableWallClock`
    /// would cost.
    private static let aCeilingOnlyAMutantReaches: TimeInterval = 120

    /// A canary that answers at once with `trip`, and counts how often it was sent.
    private static func countingCanary(
        _ sent: StubCounter,
        answering trip: CanaryBackstop.Trip = .completed
    ) -> CanaryBackstop.Canary {
        CanaryBackstop.Canary {
            sent.increment("sent")
            return trip
        }
    }

    // MARK: - The async wait

    /// A condition that already holds ends the wait at once, and no canary is ever built for it —
    /// the case every passing wait lives in.
    @Test
    func aConditionAlreadyTrueIsHeldAndNoCanaryIsSent() async throws {
        let sent = StubCounter()
        let outcome = try await CanaryBackstop.wait(
            deadline: 0,
            ceiling: Self.unreachableWallClock,
            canaryFloor: 3,
            canary: Self.countingCanary(sent)
        ) { true }
        #expect(outcome == .held)
        #expect(sent.count("sent") == 0)
    }

    /// Before the deadline nothing is sent, however long the wait runs: the canary is evidence only
    /// about the pipeline *after* the deadline, and a canary running from the start would bank trips
    /// completed before a stall began.
    @Test
    func noCanaryIsSentBeforeTheDeadline() async throws {
        let sent = StubCounter()
        let looks = StubCounter()
        let outcome = try await CanaryBackstop.wait(
            deadline: Self.unreachableWallClock,
            ceiling: Self.unreachableWallClock,
            canaryFloor: 1,
            canary: Self.countingCanary(sent)
        ) { looks.increment("look") >= 50 }
        #expect(outcome == .held)
        #expect(looks.count("look") == 50)
        #expect(sent.count("sent") == 0)
    }

    /// **The verdict that counts as evidence.** The condition never holds and the canary keeps
    /// completing, so the pipeline was working and the thing being waited for did not happen. The
    /// floor decides it: three round trips, not three seconds.
    @Test
    func aFalseConditionBesideACanaryThatGetsThroughIsStuck() async throws {
        let sent = StubCounter()
        let outcome = try await CanaryBackstop.wait(
            deadline: 0,
            ceiling: Self.unreachableWallClock,
            canaryFloor: 3,
            canary: Self.countingCanary(sent)
        ) { false }
        guard case let .stuck(tally) = outcome else {
            Issue.record("a live canary beside a false condition was judged \(outcome), not stuck")
            return
        }
        #expect(tally.completed >= 3)
        #expect(tally.failed == 0)
        #expect(sent.count("sent") >= 3)
    }

    /// **A canary that keeps getting an answer is not a busy machine, even when every answer is a
    /// failure** (PR #277's review, F3). The first canary counted a failed trip as silence, so a
    /// mutant that broke the path it travelled was reported starved — "a busy machine rather than a
    /// defect" — on an idle machine. Failed trips are counted now, and reaching the floor on them is
    /// its own verdict.
    @Test
    func aFalseConditionBesideACanaryThatComesBackFailedIsBrokenRatherThanStarved() async throws {
        let sent = StubCounter()
        let outcome = try await CanaryBackstop.wait(
            deadline: 0,
            ceiling: Self.aCeilingOnlyAMutantReaches,
            canaryFloor: 3,
            canary: Self.countingCanary(sent, answering: .failed)
        ) { false }
        guard case let .broken(tally) = outcome else {
            Issue.record("a canary that kept coming back failed was judged \(outcome), not broken")
            return
        }
        #expect(tally.failed >= 3)
        #expect(tally.completed == 0)
    }

    /// **The verdict that is not evidence.** No trip gets an answer, so the ceiling ends the wait and
    /// the run is a busy machine. Only a lower bound on the time is asserted — a starved machine
    /// reaches the ceiling late, never early.
    @Test
    func aFalseConditionBesideACanaryThatGetsNoAnswerIsStarvedAtTheCeiling() async throws {
        let sent = StubCounter()
        let start = Date()
        let outcome = try await CanaryBackstop.wait(
            deadline: 0,
            ceiling: 0.3,
            canaryFloor: 3,
            canary: Self.countingCanary(sent, answering: .unanswered)
        ) { false }
        guard case let .starved(tally) = outcome else {
            Issue.record("a canary that never got an answer was judged \(outcome), not starved")
            return
        }
        #expect(tally.completed == 0)
        #expect(tally.failed == 0)
        #expect(tally.elapsed >= 0.3)
        #expect(Date().timeIntervalSince(start) >= 0.3)
        // It was really asked — starved because nothing got an answer, not because nothing was sent.
        #expect(sent.count("sent") >= 1)
    }

    /// Every canary trip begins at or after the deadline. A lower bound on each trip's start, so it
    /// is the direction load reinforces: a busy machine starts the canary later, never earlier.
    @Test
    func everyCanaryTripBeginsAfterTheDeadline() async throws {
        let start = Date()
        let startedAt = RecordedStrings()
        let outcome = try await CanaryBackstop.wait(
            deadline: 0.5,
            ceiling: Self.unreachableWallClock,
            canaryFloor: 3,
            canary: CanaryBackstop.Canary {
                startedAt.record(String(Date().timeIntervalSince(start)))
                return .completed
            }
        ) { false }
        guard case .stuck = outcome else {
            Issue.record("expected stuck, got \(outcome)")
            return
        }
        let offsets = startedAt.recorded.compactMap(Double.init)
        #expect(offsets.count >= 3)
        #expect(offsets.allSatisfy { $0 >= 0.5 }, "a canary trip began before the deadline: \(offsets.sorted().prefix(3))")
    }

    // MARK: - The blocking wait

    /// The same four verdicts from the form a stub handler uses. Run on a thread of its own, which
    /// is the only place that form may run.
    @Test
    func theBlockingFormReachesTheSameFourVerdicts() async {
        let held = await Self.onAThreadOfItsOwn {
            CanaryBackstop.block(
                deadline: 0,
                ceiling: Self.unreachableWallClock,
                canaryFloor: 3,
                canary: Self.countingCanary(StubCounter())
            ) { true }
        }
        #expect(held == .held)

        let stuck = await Self.onAThreadOfItsOwn {
            CanaryBackstop.block(
                deadline: 0,
                ceiling: Self.unreachableWallClock,
                canaryFloor: 3,
                canary: Self.countingCanary(StubCounter())
            ) { false }
        }
        guard case let .stuck(stuckTally) = stuck else {
            Issue.record("a live canary beside a false condition was judged \(stuck), not stuck")
            return
        }
        #expect(stuckTally.completed >= 3)

        let broken = await Self.onAThreadOfItsOwn {
            CanaryBackstop.block(
                deadline: 0,
                ceiling: Self.aCeilingOnlyAMutantReaches,
                canaryFloor: 3,
                canary: Self.countingCanary(StubCounter(), answering: .failed)
            ) { false }
        }
        guard case let .broken(brokenTally) = broken else {
            Issue.record("a canary that kept coming back failed was judged \(broken), not broken")
            return
        }
        #expect(brokenTally.failed >= 3)

        let starved = await Self.onAThreadOfItsOwn {
            CanaryBackstop.block(
                deadline: 0,
                ceiling: 0.3,
                canaryFloor: 3,
                canary: Self.countingCanary(StubCounter(), answering: .unanswered)
            ) { false }
        }
        guard case let .starved(starvedTally) = starved else {
            Issue.record("a canary that never got an answer was judged \(starved), not starved")
            return
        }
        #expect(starvedTally.completed == 0)
        #expect(starvedTally.failed == 0)
        #expect(starvedTally.elapsed >= 0.3)
    }

    private static func onAThreadOfItsOwn(
        _ body: @escaping @Sendable () -> CanaryBackstop.Outcome
    ) async -> CanaryBackstop.Outcome {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: body()) }.start()
        }
    }

    // MARK: - The verdict's order

    /// Stuck outranks broken: a canary that completed the floor saw a working pipeline, whatever
    /// else it saw. Broken outranks starved: a canary that kept getting answers is not evidence of a
    /// busy machine however long it took. And failures below the floor at the ceiling are starved,
    /// because too few answers came back to say anything.
    @Test
    func stuckOutranksBrokenAndBrokenOutranksStarved() {
        #expect(CanaryBackstop.verdict(elapsed: 11, completed: 100, failed: 100, deadline: 10, ceiling: 60, canaryFloor: 100) == .stuck)
        #expect(CanaryBackstop.verdict(elapsed: 61, completed: 99, failed: 100, deadline: 10, ceiling: 60, canaryFloor: 100) == .broken)
        #expect(CanaryBackstop.verdict(elapsed: 61, completed: 99, failed: 99, deadline: 10, ceiling: 60, canaryFloor: 100) == .starved)
        #expect(CanaryBackstop.verdict(elapsed: 11, completed: 99, failed: 99, deadline: 10, ceiling: 60, canaryFloor: 100) == .keepWaiting)
    }

    /// Before the deadline nothing is decided, however many trips of either kind were counted.
    @Test
    func beforeTheDeadlineNoCountDecidesAnything() {
        #expect(CanaryBackstop.verdict(elapsed: 9.999, completed: 5_000, failed: 5_000, deadline: 10, ceiling: 60, canaryFloor: 100) == .keepWaiting)
    }

    // MARK: - What a give-up records

    /// **The property that lets a stuck wait count as a kill** (`CLAUDE.md`'s SONNY-259 rule): the
    /// declared give-up wording, then a second issue in wording nothing declares, then the thrown
    /// abandonment — and the line after the call never runs.
    @Test
    func aStuckOutcomeRecordsASecondIssueAndEndsTheTest() throws {
        let tally = CanaryBackstop.Tally(elapsed: 10.2, completed: 125, failed: 0)
        let (recorded, reachedTheLineAfter) = try Self.issuesRecorded {
            try CanaryBackstop.abandonUnlessHeld(.stuck(tally), waitingFor: "the refresh to reach the stub")
        }
        #expect(recorded.count == 3)
        #expect(recorded.first == CanaryBackstop.gaveUpMessage("the refresh to reach the stub", tally: tally))
        #expect(recorded.dropFirst().first == CanaryBackstop.stuckMessage(
            "the refresh to reach the stub",
            canaryRoundTrips: 125
        ))
        #expect(recorded.last?.hasPrefix("error: ") == true)
        #expect(reachedTheLineAfter == false, "a stuck wait returned to its caller instead of ending the test")
    }

    /// A broken outcome records the give-up wording and the sentence saying it was not a busy
    /// machine, and ends the test.
    @Test
    func aBrokenOutcomeSaysItWasNotABusyMachineAndEndsTheTest() throws {
        let tally = CanaryBackstop.Tally(elapsed: 10.1, completed: 0, failed: 100)
        let (recorded, reachedTheLineAfter) = try Self.issuesRecorded {
            try CanaryBackstop.abandonUnlessHeld(.broken(tally), waitingFor: "the refresh to reach the stub")
        }
        #expect(recorded.count == 3)
        #expect(recorded.first == CanaryBackstop.gaveUpMessage("the refresh to reach the stub", tally: tally))
        #expect(recorded.dropFirst().first == CanaryBackstop.brokenMessage(
            "the refresh to reach the stub",
            failedRoundTrips: 100
        ))
        #expect(recorded.last?.hasPrefix("error: ") == true)
        #expect(reachedTheLineAfter == false)
    }

    /// A starved outcome records the declared wording and the abandonment, and nothing else — no
    /// issue a battery would read as evidence.
    @Test
    func aStarvedOutcomeRecordsNoIssueThatCountsAsEvidence() throws {
        let tally = CanaryBackstop.Tally(elapsed: 60.1, completed: 2, failed: 0)
        let (recorded, reachedTheLineAfter) = try Self.issuesRecorded {
            try CanaryBackstop.abandonUnlessHeld(.starved(tally), waitingFor: "the refresh to reach the stub")
        }
        #expect(recorded.count == 2)
        #expect(recorded.first == CanaryBackstop.gaveUpMessage("the refresh to reach the stub", tally: tally))
        #expect(recorded.last?.hasPrefix("error: ") == true)
        #expect(reachedTheLineAfter == false)
    }

    /// Held hands control back and records nothing — the direction a mutant that always throws
    /// would break.
    @Test
    func aHeldOutcomeRecordsNothingAndHandsControlBack() throws {
        var reachedTheLineAfter = false
        try CanaryBackstop.abandonUnlessHeld(.held, waitingFor: "anything")
        reachedTheLineAfter = true
        #expect(reachedTheLineAfter)
    }

    /// **The give-up wording is declared exactly once, and the two evidence wordings nowhere.** Read
    /// from the declaration file rather than quoted, so this test's own text carries no signature.
    ///
    /// The first half is what makes a starved wait UNATTRIBUTED rather than a manufactured kill; the
    /// second is what makes a stuck or broken one count. A reword that let either evidence sentence
    /// match a declaration would switch that off without anything else going red.
    @Test
    func theGiveUpWordingIsDeclaredAndTheEvidenceWordingsAreNot() throws {
        let signatures = try Self.declaredSignatures()
        #expect(!signatures.isEmpty, "read no signatures at all, so the checks below would pass on nothing")

        let gaveUp = CanaryBackstop.gaveUpMessage("x", tally: CanaryBackstop.Tally(elapsed: 10, completed: 0, failed: 0))
        #expect(signatures.filter { gaveUp.contains($0) }.count == 1)

        let stuck = CanaryBackstop.stuckMessage("x", canaryRoundTrips: 125)
        #expect(signatures.filter { stuck.contains($0) }.isEmpty)

        let broken = CanaryBackstop.brokenMessage("x", failedRoundTrips: 100)
        #expect(signatures.filter { broken.contains($0) }.isEmpty)

        let abandoned = HangBackstop.abandonedMessage("x")
        #expect(signatures.filter { abandoned.contains($0) }.count == 1)
    }

    /// The wordings carry the numbers that justify them and can be told apart. The give-up wording
    /// states the counts and the floor separately, so a count past the floor never reads as
    /// "125 of 100".
    @Test
    func theWordingsNameTheirNumbersAndDiffer() {
        let gaveUp = CanaryBackstop.gaveUpMessage(
            "the refresh",
            tally: CanaryBackstop.Tally(elapsed: 10.2, completed: 7, failed: 2),
            canaryFloor: 100
        )
        let stuck = CanaryBackstop.stuckMessage("the refresh", canaryRoundTrips: 125)
        let broken = CanaryBackstop.brokenMessage("the refresh", failedRoundTrips: 101)
        #expect(gaveUp.contains("after 10.2s"))
        #expect(gaveUp.contains("7 canary round trips completed and 2 came back failed"))
        #expect(gaveUp.contains("a floor of 100"))
        #expect(gaveUp.contains("the refresh"))
        #expect(stuck.contains("125"))
        #expect(stuck.contains("the refresh"))
        #expect(broken.contains("101"))
        #expect(broken.contains("the refresh"))
        #expect(!gaveUp.contains(stuck))
        #expect(!gaveUp.contains(broken))
        #expect(stuck != broken)
    }

    /// The shipped numbers, as values. The handler-side hold (`StubSignal`) is set from the ceiling,
    /// and has to outlast it, so a slow test can never make a handler release itself first.
    @Test
    func theShippedNumbers() {
        #expect(CanaryBackstop.deadline == 10)
        #expect(CanaryBackstop.ceiling == 60)
        #expect(CanaryBackstop.canaryFloor == 100)
    }

    // MARK: - The canaries

    /// The stub-transport canary really completes a round trip. Its host is a `.invalid` name only
    /// the stub answers, so `.completed` here came through `BackendStubURLProtocol`.
    @Test
    func theStubTransportCanaryCompletesARoundTripThroughTheStub() async {
        let canary = CanaryBackstop.Canary.stubTransport
        #expect(await canary.roundTrip() == .completed)
        #expect(await canary.roundTrip() == .completed)
    }

    @Test
    func theActorHopCanaryCompletes() async {
        let canary = CanaryBackstop.Canary.actorHop
        #expect(await canary.roundTrip() == .completed)
    }

    // MARK: - Helpers

    /// Every issue `body` records, in order, as text — comments as their text and a thrown error as
    /// `error: ` and its description — and whether the line after `body` ran.
    private static func issuesRecorded(_ body: () throws -> Void) throws -> ([String], Bool) {
        let seen = RecordedStrings()
        var reachedTheLineAfter = false
        // `rethrows` in this overload, for an issue the matcher refuses; this one refuses none.
        try withKnownIssue("a give-up records its issues and throws") {
            try body()
            reachedTheLineAfter = true
        } matching: { issue in
            if case let .errorCaught(error) = issue.kind {
                seen.record("error: \(error)")
            } else {
                seen.record(issue.comments.map(\.rawValue).joined(separator: "\n"))
            }
            return true
        }
        return (seen.recorded, reachedTheLineAfter)
    }

    private static func declaredSignatures() throws -> [String] {
        let file = TestSourceTree.repositoryRoot.appendingPathComponent("scripts/mutate-untrusted-failures")
        return try String(contentsOf: file, encoding: .utf8)
            .components(separatedBy: "\n")
            .compactMap { line in
                guard line.hasPrefix(">>> signature ") else { return nil }
                let signature = line.dropFirst(">>> signature ".count).trimmingCharacters(in: .whitespaces)
                return signature.isEmpty ? nil : signature
            }
    }
}
