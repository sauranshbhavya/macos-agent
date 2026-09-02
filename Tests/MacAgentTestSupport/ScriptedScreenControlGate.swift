import Foundation
import MacAgentCore

/// A ``ScreenControlGating`` a test drives, for both of SONNY-213's consult sites.
///
/// **In `MacAgentTestSupport` rather than in one suite**, for the reason that target exists
/// (SONNY-172): the gate is asked at the session entry, which `MacAgentCoreTests` exercises through
/// the adapter, and at a step boundary, which `MacAgentTests` exercises through the live loop. Two
/// copies of a double that decides a refusal is how the two suites come to test different rules.
///
/// It records every consult in order, which is what makes "the door decides the first step and the
/// boundary decides the rest" checkable rather than argued — a test asserts the *sequence of
/// moments*, not merely the outcome.
public final class ScriptedScreenControlGate: ScreenControlGating, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [ScreenControlGateDecision]
    private var fallback: ScreenControlGateDecision
    private var recorded: [ScreenControlGateMoment] = []

    /// - Parameters:
    ///   - answers: consumed one per consult, in order.
    ///   - thereafter: what every consult past `answers` gets. Defaults to `.allowed` so a test that
    ///     only cares about the first few answers does not have to count the rest.
    public init(
        answers: [ScreenControlGateDecision] = [],
        thereafter: ScreenControlGateDecision = .allowed
    ) {
        self.answers = answers
        self.fallback = thereafter
    }

    /// Always allowed. The shape almost every existing vision test wants — it is not about billing.
    public static func permissive() -> ScriptedScreenControlGate {
        ScriptedScreenControlGate(answers: [], thereafter: .allowed)
    }

    /// Allowed for `steps` consults and refused from then on — the mid-run exhaustion shape.
    public static func allowing(
        steps: Int,
        thenRefusing refusal: ScreenControlGateRefusal
    ) -> ScriptedScreenControlGate {
        ScriptedScreenControlGate(
            answers: Array(repeating: .allowed, count: steps),
            thereafter: .refused(refusal)
        )
    }

    /// Every moment this gate was asked about, in order.
    public var consults: [ScreenControlGateMoment] {
        lock.withLock { recorded }
    }

    public func decide(at moment: ScreenControlGateMoment) async -> ScreenControlGateDecision {
        lock.withLock {
            recorded.append(moment)
            guard !answers.isEmpty else { return fallback }
            return answers.removeFirst()
        }
    }
}

/// A ``ScreenControlEntitlementConfirming`` that answers whatever it was built with.
public struct StubEntitlementConfirmation: ScreenControlEntitlementConfirming {
    private let answer: EntitlementDecision

    public init(_ answer: EntitlementDecision) {
        self.answer = answer
    }

    public func claimConfirmation() async -> EntitlementDecision { answer }
}

/// A ``ScreenControlAllowanceReading`` that answers a run count, or throws.
///
/// **The throw is a first-class case rather than an afterthought**: `SonnyScreenControlGate` reads a
/// failed allowance fetch differently at each of its two moments, and that asymmetry is the single
/// most attackable thing in the gate — it is where a fail-closed rule is deliberately not applied.
public final class StubAllowanceReading: ScreenControlAllowanceReading, @unchecked Sendable {
    public enum Answer: Sendable {
        /// Whole runs in hand, with the credit remainder that implies. Models `runCredits == 1.0`,
        /// so `runsLeft` and the remainder agree the way the gateway guarantees they do.
        case runsLeft(Int)
        /// **The two figures apart, which is the state a session in flight is actually in** and the
        /// one PR #190's F1 turned on: the account's own iterations have been subtracted, so the
        /// floor has reached zero while real credit is still unspent. No `runsLeft` value can
        /// express it, which is why reading one figure for both moments looked correct.
        case runsAndCredits(runsLeft: Int, creditsRemaining: Double)
        case failure
    }

    public struct ReadFailed: Error, Equatable {
        public init() {}
    }

    private let lock = NSLock()
    private var scripted: [Answer]
    private let fallback: Answer
    private var fetches = 0

    /// The same answer to every read.
    public init(_ answer: Answer) {
        self.scripted = []
        self.fallback = answer
    }

    /// A read that changes partway through — **the shape the gate's asymmetry needs**. A session
    /// admitted with runs in hand and then losing the network is the only way to reach the step
    /// boundary's read-failure branch at all: a reader that failed from the first call would be
    /// refused at the door, which is the other branch.
    public init(answers: [Answer], thereafter: Answer) {
        self.scripted = answers
        self.fallback = thereafter
    }

    /// How many times the gate actually asked. **A class rather than a struct for this one field**:
    /// the gate refuses on the local entitlement half before it opens a request, and "never asked"
    /// is the only way to assert that — an outcome assertion alone passes just as well if the gate
    /// asks and then discards the answer.
    public var fetchCount: Int {
        lock.withLock { fetches }
    }

    public func fetch() async throws -> ScreenControlAllowance {
        let answer: Answer = lock.withLock {
            fetches += 1
            guard !scripted.isEmpty else { return fallback }
            return scripted.removeFirst()
        }
        switch answer {
        case .failure:
            throw ReadFailed()
        case .runsLeft(let runs):
            return Self.allowance(runsLeft: runs, creditsRemaining: Double(runs))
        case .runsAndCredits(let runs, let credits):
            return Self.allowance(runsLeft: runs, creditsRemaining: credits)
        }
    }

    private static func allowance(runsLeft: Int, creditsRemaining: Double) -> ScreenControlAllowance {
        ScreenControlAllowance(
            plan: "test.plan",
            runsLeft: runsLeft,
            runsIncluded: max(runsLeft, 1),
            creditsRemaining: creditsRemaining,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 2_678_400)
        )
    }
}
