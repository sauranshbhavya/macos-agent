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

    /// A canary that answers at once, and counts how often it was sent.
    private static func countingCanary(_ sent: StubCounter, completes: Bool = true) -> CanaryBackstop.Canary {
        CanaryBackstop.Canary {
            sent.increment("sent")
            return completes
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
        guard case let .stuck(_, trips) = outcome else {
            Issue.record("a live canary beside a false condition was judged \(outcome), not stuck")
            return
        }
        #expect(trips >= 3)
        #expect(sent.count("sent") >= 3)
    }

    /// **The verdict that is not evidence.** Nothing gets through, so the ceiling ends the wait and
    /// the run is a busy machine. Only a lower bound on the time is asserted — a starved machine
    /// reaches the ceiling late, never early.
    @Test
    func aFalseConditionBesideACanaryThatCannotGetThroughIsStarvedAtTheCeiling() async throws {
        let sent = StubCounter()
        let start = Date()
        let outcome = try await CanaryBackstop.wait(
            deadline: 0,
            ceiling: 0.3,
            canaryFloor: 3,
            canary: Self.countingCanary(sent, completes: false)
        ) { false }
        guard case let .starved(elapsed, trips) = outcome else {
            Issue.record("a canary that never got through was judged \(outcome), not starved")
            return
        }
        #expect(trips == 0)
        #expect(elapsed >= 0.3)
        #expect(Date().timeIntervalSince(start) >= 0.3)
        // It was really asked — starved because nothing completed, not because nothing was sent.
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
                return true
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

    /// The same three verdicts from the form a stub handler uses. Run on a thread of its own, which
    /// is the only place that form may run.
    @Test
    func theBlockingFormReachesTheSameThreeVerdicts() async {
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
        guard case let .stuck(_, trips) = stuck else {
            Issue.record("a live canary beside a false condition was judged \(stuck), not stuck")
            return
        }
        #expect(trips >= 3)

        let starved = await Self.onAThreadOfItsOwn {
            CanaryBackstop.block(
                deadline: 0,
                ceiling: 0.3,
                canaryFloor: 3,
                canary: Self.countingCanary(StubCounter(), completes: false)
            ) { false }
        }
        guard case let .starved(elapsed, starvedTrips) = starved else {
            Issue.record("a canary that never got through was judged \(starved), not starved")
            return
        }
        #expect(starvedTrips == 0)
        #expect(elapsed >= 0.3)
    }

    private static func onAThreadOfItsOwn(
        _ body: @escaping @Sendable () -> CanaryBackstop.Outcome
    ) async -> CanaryBackstop.Outcome {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: body()) }.start()
        }
    }

    // MARK: - What a give-up records

    /// **The property that lets a stuck wait count as a kill** (`CLAUDE.md`'s SONNY-259 rule): the
    /// declared give-up wording, then a second issue in wording nothing declares, then the thrown
    /// abandonment — and the line after the call never runs.
    @Test
    func aStuckOutcomeRecordsASecondIssueAndEndsTheTest() throws {
        let (recorded, reachedTheLineAfter) = try Self.issuesRecorded {
            try CanaryBackstop.abandonUnlessHeld(
                .stuck(elapsed: 10.2, canaryRoundTrips: 25),
                waitingFor: "the refresh to reach the stub"
            )
        }
        #expect(recorded.count == 3)
        #expect(recorded.first == CanaryBackstop.gaveUpMessage(
            "the refresh to reach the stub",
            elapsed: 10.2,
            canaryRoundTrips: 25
        ))
        #expect(recorded.dropFirst().first == CanaryBackstop.stuckMessage(
            "the refresh to reach the stub",
            canaryRoundTrips: 25
        ))
        #expect(recorded.last?.hasPrefix("error: ") == true)
        #expect(reachedTheLineAfter == false, "a stuck wait returned to its caller instead of ending the test")
    }

    /// A starved outcome records the declared wording and the abandonment, and nothing else — no
    /// issue a battery would read as evidence.
    @Test
    func aStarvedOutcomeRecordsNoIssueThatCountsAsEvidence() throws {
        let (recorded, reachedTheLineAfter) = try Self.issuesRecorded {
            try CanaryBackstop.abandonUnlessHeld(
                .starved(elapsed: 60.1, canaryRoundTrips: 2),
                waitingFor: "the refresh to reach the stub"
            )
        }
        #expect(recorded.count == 2)
        #expect(recorded.first == CanaryBackstop.gaveUpMessage(
            "the refresh to reach the stub",
            elapsed: 60.1,
            canaryRoundTrips: 2
        ))
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

    /// **The give-up wording is declared exactly once, and the stuck wording nowhere.** Read from the
    /// declaration file rather than quoted, so this test's own text carries no signature.
    ///
    /// The first half is what makes a starved wait UNATTRIBUTED rather than a manufactured kill; the
    /// second is what makes a stuck one a kill. A reword that let the stuck sentence match a
    /// declaration would switch the second half off without anything else going red.
    @Test
    func theGiveUpWordingIsDeclaredAndTheStuckWordingIsNot() throws {
        let signatures = try Self.declaredSignatures()
        #expect(!signatures.isEmpty, "read no signatures at all, so the checks below would pass on nothing")

        let gaveUp = CanaryBackstop.gaveUpMessage("x", elapsed: 10, canaryRoundTrips: 0)
        #expect(signatures.filter { gaveUp.contains($0) }.count == 1)

        let stuck = CanaryBackstop.stuckMessage("x", canaryRoundTrips: 25)
        #expect(signatures.filter { stuck.contains($0) }.isEmpty)

        let abandoned = HangBackstop.abandonedMessage("x")
        #expect(signatures.filter { abandoned.contains($0) }.count == 1)
    }

    /// The two wordings carry the numbers that justify them and can be told apart.
    @Test
    func theTwoWordingsNameTheirNumbersAndDiffer() {
        let gaveUp = CanaryBackstop.gaveUpMessage("the refresh", elapsed: 10.2, canaryRoundTrips: 7, canaryFloor: 20)
        let stuck = CanaryBackstop.stuckMessage("the refresh", canaryRoundTrips: 25)
        #expect(gaveUp.contains("after 10.2s"))
        #expect(gaveUp.contains("7 of 20"))
        #expect(gaveUp.contains("the refresh"))
        #expect(stuck.contains("25"))
        #expect(stuck.contains("the refresh"))
        #expect(!gaveUp.contains(stuck))
        #expect(!stuck.contains(gaveUp))
    }

    /// The shipped numbers, as values. The handler-side hold (`StubSignal`) is set from the ceiling,
    /// and has to outlast it, so a slow test can never make a handler release itself first.
    @Test
    func theShippedNumbers() {
        #expect(CanaryBackstop.deadline == 10)
        #expect(CanaryBackstop.ceiling == 60)
        #expect(CanaryBackstop.canaryFloor == 20)
    }

    // MARK: - The transport canary

    /// The stub-transport canary really completes a round trip. Its host is a `.invalid` name only
    /// the stub answers, so a `true` here came through `BackendStubURLProtocol`.
    @Test
    func theStubTransportCanaryCompletesARoundTripThroughTheStub() async {
        let canary = CanaryBackstop.Canary.stubTransport
        #expect(await canary.roundTrip())
        #expect(await canary.roundTrip())
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
