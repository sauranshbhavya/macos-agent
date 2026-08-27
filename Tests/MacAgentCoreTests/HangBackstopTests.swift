import Foundation
import Testing
import MacAgentTestSupport

/// SONNY-302. What a hang backstop is allowed to conclude from running out of wall clock.
///
/// **The decision is a pure function of two numbers, and that is why it can be tested at all.** The
/// condition this suite is really about — a main actor whose queue is so deep that a poll loop gets
/// two turns in thirty seconds — cannot be reproduced on demand inside a test; it needs a full
/// run of the whole tree and, at the branch point, went red in two runs out of five. So `HangBackstop.verdict` takes the elapsed time
/// and the observation count and nothing else, every boundary of it is checked below against
/// concrete values, and the loop that feeds it is checked separately with injected deadlines small
/// enough to run in milliseconds.
///
/// **Nothing here quotes the wording `scripts/mutate-untrusted-failures` declares.** A test's own
/// failure text is read by that classifier, so a guard whose failure carries a declared signature is
/// a guard the declaration file switches off — the same trap
/// `UntrustedFailureDeclarationTests` documents at length and closes for itself.
/// `theTwoWordingsAreDistinguishableFromEachOther` checks the messages by comparing them and by
/// looking for the numbers they must carry, never by asserting a sentence.
@Suite
struct HangBackstopTests {
    // MARK: - The verdict, at every boundary

    /// Inside the deadline, nothing is decided however few looks there have been. This is the case
    /// every ordinary passing wait lives in, and it must not depend on the observation count: a wait
    /// that completes on its first look completes.
    @Test
    func beforeTheDeadlineTheVerdictIsAlwaysToKeepWaiting() {
        for observations in [0, 1, 62, 499, 500, 5_000] {
            #expect(
                HangBackstop.verdict(elapsed: 29.999, observations: observations, deadline: 30, ceiling: 180, observationFloor: 500)
                    == .keepWaiting
            )
        }
    }

    /// The deadline alone decides nothing — this is the whole change. Two looks in thirty seconds is
    /// exactly the shape the measurements found on a loaded machine, and it must not produce a
    /// verdict about the code.
    @Test
    func pastTheDeadlineWithTooFewLooksTheWaitContinues() {
        #expect(
            HangBackstop.verdict(elapsed: 30, observations: 2, deadline: 30, ceiling: 180, observationFloor: 500)
                == .keepWaiting
        )
        #expect(
            HangBackstop.verdict(elapsed: 179.999, observations: 499, deadline: 30, ceiling: 180, observationFloor: 500)
                == .keepWaiting
        )
    }

    /// Both conditions together, at the exact boundary of each: the deadline is `>=` and so is the
    /// floor. A mutant flipping either comparison to `>` fails here.
    @Test
    func theDeadlineAndTheFloorTogetherAreWhatMakeAWaitStuck() {
        #expect(
            HangBackstop.verdict(elapsed: 30, observations: 500, deadline: 30, ceiling: 180, observationFloor: 500)
                == .stuck
        )
        #expect(
            HangBackstop.verdict(elapsed: 30, observations: 499, deadline: 30, ceiling: 180, observationFloor: 500)
                == .keepWaiting
        )
        #expect(
            HangBackstop.verdict(elapsed: 29.999, observations: 500, deadline: 30, ceiling: 180, observationFloor: 500)
                == .keepWaiting
        )
    }

    /// The ceiling is what keeps a starved wait from becoming a hang, and it is reached only by a
    /// wait that never collected its looks.
    @Test
    func theCeilingEndsAStarvedWaitRatherThanLettingItRunForever() {
        #expect(
            HangBackstop.verdict(elapsed: 180, observations: 2, deadline: 30, ceiling: 180, observationFloor: 500)
                == .starved
        )
        #expect(
            HangBackstop.verdict(elapsed: 179.999, observations: 2, deadline: 30, ceiling: 180, observationFloor: 500)
                == .keepWaiting
        )
    }

    /// A wait that both ran past the ceiling *and* collected its looks is stuck, not starved: it
    /// looked, and what it saw outranks how long it took. This is the ordering inside `verdict`, and
    /// swapping the two checks would silently reclassify every genuine deadlock that happened to be
    /// slow as a machine problem — the direction that loses coverage without saying so.
    @Test
    func lookingEnoughOutranksRunningPastTheCeiling() {
        #expect(
            HangBackstop.verdict(elapsed: 600, observations: 5_000, deadline: 30, ceiling: 180, observationFloor: 500)
                == .stuck
        )
    }

    /// The shipped numbers, asserted as values rather than referred to. A wait polling at the
    /// measured healthy rate reaches the floor long before thirty seconds, which is what keeps an
    /// unloaded machine behaving exactly as it did before this change; a starved wait's one or two
    /// looks reach it never.
    @Test
    func theShippedDefaultsClassifyTheTwoMeasuredPopulations() {
        #expect(HangBackstop.deadlockDeadline == 30)
        #expect(HangBackstop.observationFloor == 500)
        #expect(HangBackstop.starvationCeiling == 180)
        #expect(HangBackstop.pollInterval == .milliseconds(5))

        // The worst completing wait in the measurements needed 62 looks; a starved one made 1 or 2.
        // Neither is entitled to a verdict at the deadline.
        #expect(HangBackstop.verdict(elapsed: 30, observations: 62) == .keepWaiting)
        #expect(HangBackstop.verdict(elapsed: 30, observations: 2) == .keepWaiting)
        // A free-running poll loop at the measured healthy rate has looked far more than this.
        #expect(HangBackstop.verdict(elapsed: 30, observations: 4_830) == .stuck)
    }

    // MARK: - The loop

    /// A condition that is already true costs one look and records nothing. The count is asserted
    /// exactly, because "returned quickly" would also be true of a loop that polled a few times.
    @Test
    @MainActor
    func aConditionAlreadyTrueIsObservedOnceAndNothingIsRecorded() async throws {
        let observations = try await HangBackstop.wait(for: "a condition that is already true") { true }
        #expect(observations == 1)
    }

    /// A wall clock no loaded machine can reach, so that the two tests below are decided by the
    /// number of looks and by nothing else.
    ///
    /// **These two tests were written with small deadlines first — 0.05 s and 0.2 s — and both went
    /// red inside a full suite run on this branch, having managed two looks in 10.8 seconds.** That
    /// is the defect this whole ticket is about, reproduced by its own tests: a wall-clock window
    /// small enough to be convenient is a window a starved actor blows straight through, and the
    /// assertion then measures the queue. `CLAUDE.md` states the rule they broke — wait on a real
    /// signal and make the state being asserted unable to expire on its own. An hour is not a
    /// timeout anything here is expected to approach; it is the number that takes the clock out of
    /// the experiment.
    private static let unreachableWallClock: TimeInterval = 3600

    /// A condition another task makes true is waited for, and the wait ends on the change rather
    /// than on the clock — the ordinary case, and the one that must keep working. Both wall-clock
    /// bounds are unreachable, so the only thing that can end this wait is the condition, and the
    /// count is exact however busy the machine is.
    @Test
    @MainActor
    func aConditionThatBecomesTrueEndsTheWaitOnTheChange() async throws {
        var looks = 0
        let observations = try await HangBackstop.wait(
            for: "a condition that becomes true on the third look",
            deadline: Self.unreachableWallClock,
            ceiling: Self.unreachableWallClock,
            observationFloor: 3
        ) {
            looks += 1
            return looks >= 3
        }
        #expect(observations == 3)
        #expect(looks == 3)
    }

    /// **The property this change was not allowed to break.** A condition that never becomes true
    /// still fails, and fails as the code's problem rather than the machine's.
    ///
    /// The deadline is zero and the ceiling unreachable, which isolates the half being tested: the
    /// wall-clock half of the rule is satisfied from the first instant, so the floor is the only
    /// thing that can decide, and the wait ends on the exact look that reaches it. Four looks, not
    /// four seconds — so this is as deterministic on a thrashed machine as on an idle one, and it is
    /// the shipped arithmetic either way.
    @Test
    @MainActor
    func aConditionThatNeverBecomesTrueOnAHealthyActorStillFails() async throws {
        var observations = 0
        await withKnownIssue("the backstop must fire when the condition never becomes true") {
            observations = try await HangBackstop.wait(
                for: "something that never happens",
                deadline: 0,
                ceiling: Self.unreachableWallClock,
                observationFloor: 4
            ) { false }
        }
        // Exactly the floor: it stopped on the look that earned the verdict, neither before nor
        // after, and it stopped because it had looked enough rather than because time ran out.
        #expect(observations == 4)
    }

    /// A wait that cannot reach the floor ends at the ceiling instead of running forever. The floor
    /// here is unreachable by construction, which is what a wait denied its turns looks like from
    /// the inside.
    @Test
    @MainActor
    func aWaitThatCannotReachTheFloorEndsAtTheCeiling() async throws {
        let start = Date()
        var observations = 0
        await withKnownIssue("the ceiling must end a wait that never gets enough looks") {
            observations = try await HangBackstop.wait(
                for: "something observed too rarely to judge",
                deadline: 0.05,
                ceiling: 0.4,
                observationFloor: Int.max
            ) { false }
        }
        let elapsed = Date().timeIntervalSince(start)
        // Bounded, which is the point — it stopped rather than hanging. Only a *lower* bound is
        // asserted, and that is what makes this one safe where the two above were not: a busy actor
        // discovers the ceiling late, so an upper bound would be the wall-clock bet this whole
        // ticket is about, while a lower bound can only be reinforced by load.
        #expect(elapsed >= 0.4)
        #expect(observations >= 1)
    }

    // MARK: - The two wordings

    /// The two messages must be tellable apart by a reader and by `scripts/mutate`, and each must
    /// carry the numbers that justify it. Compared against each other and searched for their
    /// numbers, never quoted — see this suite's own note on why.
    @Test
    func theTwoWordingsAreDistinguishableFromEachOther() {
        let stuck = HangBackstop.stuckMessage("the run to finish", elapsed: 30, observations: 4_830)
        let starved = HangBackstop.starvedMessage("the run to finish", elapsed: 180, observations: 2)

        #expect(stuck != starved)
        // Neither is a prefix or substring of the other, so a classifier matching a fragment of one
        // cannot match the other by accident.
        #expect(!stuck.contains(starved))
        #expect(!starved.contains(stuck))

        #expect(stuck.contains("4830"))
        #expect(stuck.contains("the run to finish"))
        #expect(starved.contains("only 2 times"))
        #expect(starved.contains("180.0s"))
    }

    /// The floor a message names is the floor that was actually applied. It used to be read off the
    /// static default while the loop used the caller's, so a wait running under an injected floor
    /// reported a number that had decided nothing.
    /// Seconds are rendered to one decimal place, not truncated to an `Int`. A wait that gave up
    /// after 0.4 s used to report "after 0s", which reads as a broken harness rather than a
    /// duration — and sub-second waits are exactly what the injected-deadline tests above produce.
    @Test
    func aMessageRendersASubSecondDurationRatherThanTruncatingItToZero() {
        #expect(HangBackstop.stuckMessage("x", elapsed: 0.4, observations: 8).contains("after 0.4s"))
        #expect(HangBackstop.starvedMessage("x", elapsed: 0.4, observations: 8).contains("after 0.4s"))
        #expect(!HangBackstop.stuckMessage("x", elapsed: 0.4, observations: 8).contains("after 0s"))
    }

    @Test
    func aMessageNamesTheFloorThatWasActuallyApplied() {
        let withDefault = HangBackstop.stuckMessage("x", elapsed: 30, observations: 600)
        let withInjected = HangBackstop.stuckMessage("x", elapsed: 30, observations: 600, observationFloor: 7)
        #expect(withDefault.contains("500"))
        #expect(withInjected.contains("7"))
        #expect(!withInjected.contains("500"))

        let starvedInjected = HangBackstop.starvedMessage("x", elapsed: 180, observations: 2, observationFloor: 7)
        #expect(starvedInjected.contains("7"))
        #expect(!starvedInjected.contains("500"))
    }
}
