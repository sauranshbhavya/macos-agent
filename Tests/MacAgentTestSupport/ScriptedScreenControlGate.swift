import Foundation
import MacAgentCore

/// The fixture price every suite's top-up setting carries (SONNY-215's F6).
///
/// **A fixture number and not a plan's**, exactly as `TEST_CREDIT_PLANS` is on the server side: this
/// repository names no amount, and a test that is *about* a price builds its own.
public let TEST_PACK_PRICE = ScreenControlMoney(amount: 500, currency: "usd")

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

    /// A gate whose door waits until the run is stopped and then answers as the real one does
    /// after a cut-short wait — a refusal, never "stopped" (SONNY-442, PR #229's F1). The wait is
    /// a cancellable sleep that nothing but cancellation ends inside a test's life, so what a test
    /// over this gate measures is whether the caller turns the refusal into a cancellation.
    public static func holdingUntilStopped() -> ScriptedScreenControlGate {
        let gate = ScriptedScreenControlGate(answers: [], thereafter: .refused(.allowanceUnknown))
        gate.holdsUntilStopped = true
        return gate
    }

    private var holdsUntilStopped = false

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
        let holds = lock.withLock {
            recorded.append(moment)
            return holdsUntilStopped
        }
        if holds {
            try? await Task.sleep(for: .seconds(600))
        }
        return lock.withLock {
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

    /// Nothing is ever in flight for a fixed answer, so this returns at once — which is exactly what
    /// `EntitlementService.awaitPendingRefresh()` does when no refresh was started.
    public func awaitPendingRefresh() async {}
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
    private let autoTopUp: ScreenControlAutoTopUp
    private var fetches = 0

    /// The same answer to every read.
    ///
    /// **`autoTopUp` defaults to `.none`, which is the fixture half of "off by default"**
    /// (SONNY-215): nothing offered and nothing agreed, so every test written before this parameter
    /// existed keeps meaning what it meant, and a test about a purchase has to say so in words.
    public init(_ answer: Answer, autoTopUp: ScreenControlAutoTopUp = .none) {
        self.scripted = []
        self.fallback = answer
        self.autoTopUp = autoTopUp
    }

    /// A read that changes partway through — **the shape the gate's asymmetry needs**. A session
    /// admitted with runs in hand and then losing the network is the only way to reach the step
    /// boundary's read-failure branch at all: a reader that failed from the first call would be
    /// refused at the door, which is the other branch.
    public init(
        answers: [Answer],
        thereafter: Answer,
        autoTopUp: ScreenControlAutoTopUp = .none
    ) {
        self.scripted = answers
        self.fallback = thereafter
        self.autoTopUp = autoTopUp
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
            return Self.allowance(
                runsLeft: runs,
                creditsRemaining: Double(runs),
                autoTopUp: autoTopUp
            )
        case .runsAndCredits(let runs, let credits):
            return Self.allowance(runsLeft: runs, creditsRemaining: credits, autoTopUp: autoTopUp)
        }
    }

    /// An allowance a test can build without naming every field. **`autoTopUp` has no default here**
    /// even though the initializers above do — a reading built by hand is one a test is saying
    /// something specific about, and the two callers that matter say opposite things.
    public static func allowance(
        runsLeft: Int,
        creditsRemaining: Double,
        autoTopUp: ScreenControlAutoTopUp
    ) -> ScreenControlAllowance {
        ScreenControlAllowance(
            plan: "test.plan",
            runsLeft: runsLeft,
            runsIncluded: max(runsLeft, 1),
            creditsRemaining: creditsRemaining,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 2_678_400),
            autoTopUp: autoTopUp,
            // **No charge on record, which is what an account that has never bought one looks
            // like** (SONNY-215's F6). A fixture that carried one by default would put a receipt on
            // a surface no test in the gate's suites mentions.
            lastTopUp: nil
        )
    }
}

/// A ``ScreenControlTopUpPurchasing`` that answers a purchase, or throws (SONNY-215).
///
/// **The count is the point, and it is why this is a class.** The ticket's hard requirement is a
/// negative — no charge without the explicit opt-in — and an outcome assertion alone passes just as
/// well against a gate that buys a pack and then refuses anyway. `purchaseCount` is the only way to
/// assert that nothing was bought.
public final class StubTopUpPurchasing: ScreenControlTopUpPurchasing, @unchecked Sendable {
    public enum Answer: Sendable {
        /// The purchase landed, and this is the allowance that followed it.
        case granted(runsLeft: Int, creditsRemaining: Double)
        /// Every way a purchase does not happen. The gate treats them all alike, on purpose.
        case failure
    }

    public struct PurchaseFailed: Error, Equatable {
        public init() {}
    }

    private let lock = NSLock()
    private let answer: Answer
    private let autoTopUp: ScreenControlAutoTopUp
    private var purchases = 0

    /// - Parameters:
    ///   - answer: what every purchase returns.
    ///   - autoTopUp: the setting the *post-purchase* reading carries. Defaults to opted in with one
    ///     attempt left, because an allowance handed back by a successful purchase describes an
    ///     account that has just made one.
    public init(
        _ answer: Answer,
        autoTopUp: ScreenControlAutoTopUp = ScreenControlAutoTopUp(
            isOffered: true,
            isOptedIn: true,
            attemptsLeft: 1,
            price: ScreenControlMoney(amount: 500, currency: "usd")
        )
    ) {
        self.answer = answer
        self.autoTopUp = autoTopUp
    }

    /// A purchaser that is not expected to be reached.
    ///
    /// **What that buys differs by call site, and the name promises more than it can deliver at some
    /// of them** (PR #196's F7c). In `ScreenControlGateTests` the surrounding tests assert
    /// `purchaseCount == 0`, so a gate that started buying fails on the count. In
    /// `VisionSessionRunTests` nothing asserts the count, and what makes those tests safe is a
    /// different fact: they build their readings with `autoTopUp: .none`, so `mayPurchase` is false
    /// and the gate never reaches a purchaser at all. Throwing rather than granting is the third
    /// line of defence — if one were reached, the run would refuse rather than silently continuing
    /// on credit nobody bought.
    public static func neverCalled() -> StubTopUpPurchasing {
        StubTopUpPurchasing(.failure)
    }

    /// How many times the gate actually tried to buy something.
    public var purchaseCount: Int {
        lock.withLock { purchases }
    }

    public func purchaseTopUp() async throws -> ScreenControlAllowance {
        lock.withLock { purchases += 1 }
        switch answer {
        case .failure:
            throw PurchaseFailed()
        case .granted(let runs, let credits):
            return StubAllowanceReading.allowance(
                runsLeft: runs,
                creditsRemaining: credits,
                autoTopUp: autoTopUp
            )
        }
    }
}
