import Foundation

/// **The one gate.** Whether Sonny may run a screen-control session right now, on billing grounds
/// (SONNY-213).
///
/// Screen control is the only capability in this product that blocks on billing; every other one —
/// opening apps, listing files, routines, workspaces, instant utilities, web research, voice — runs
/// regardless of network, entitlement or allowance, and §16.3's guarantee is that a network blip
/// never breaks Sonny's instant feel.
///
/// **That direction is held by nothing else *doing* it, which is a fact about the population rather
/// than a structural impossibility** — and the difference is worth stating exactly, because this
/// comment used to claim the stronger thing (PR #190's F5). `CapabilityExecutionContext.visionSession`
/// is a plain optional field on the one context `AgentActionExecutor` builds and hands to whichever
/// adapter runs, so in the shipping app every free adapter's `execute` receives the live gate and
/// `context.visionSession?.screenControlGate.decide(...)` would compile from any of them. What stops
/// it is that none does. `ScreenControlGateReachTests` holds that as an exact-set population scan
/// over both source trees, and `ScreenControlGateFreeCapabilityTests` holds the behavioural half —
/// running free capabilities both with no billing wiring at all *and* with the live wiring the app
/// really hands them, which is the case that catches an adapter that had started reading it.
///
/// ## Two moments, one decision function, and the asymmetry between them is deliberate
///
/// The ticket names two places a gate sits: the session entry, and the mid-session loop's halt path.
/// They are the same gate consulted at two moments rather than two gates, which is what
/// ``ScreenControlGateMoment`` exists to express — a second type answering the same question is how
/// two answers come to disagree.
///
/// - At ``ScreenControlGateMoment/sessionStart`` the gate **fails closed on every ground it has**,
///   including an allowance it could not read. Nothing has happened yet, so a refusal costs the user
///   a sentence and no work — and screen control needs the gateway for its own vision call anyway,
///   so a session admitted with the network down would fail one iteration later with a worse
///   sentence.
/// - At ``ScreenControlGateMoment/stepBoundary`` an allowance that could not be *read* is **not** a
///   refusal, and only a confirmed exhaustion halts. See ``SonnyScreenControlGate`` for the bound on
///   what that concedes; the short version is that halting a running session on a transient read
///   failure is the mid-action yank the ticket forbids, arriving through the check meant to prevent
///   one.
public enum ScreenControlGateMoment: Equatable, Sendable {
    /// Before a session starts. Nothing has been captured, nothing has moved.
    case sessionStart
    /// Between two atomic steps of a running session. The step before it has completed.
    case stepBoundary
}

/// Why screen control was refused on billing grounds.
///
/// **Three cases and not a `Bool`, for ``ScreenControlRefusal``'s reason applied to a second axis**:
/// the user's next action is different for each, and a single "no" would send all three of them to
/// the same sentence. Being out of allowance is a thing to top up or wait out; a claim this Mac
/// cannot confirm is a thing to reconnect for; an allowance the gateway would not answer is a thing
/// to retry.
public enum ScreenControlGateRefusal: Equatable, Sendable {
    /// The cached entitlement claim could not be confirmed — no session, nothing cached, a claim
    /// this build cannot verify, one belonging to somebody else, or one past its honoured window.
    ///
    /// **"Confirmed" and not "paid", and the ticket's own wording is what forces the reading.**
    /// SONNY-213 says screen control refuses when "the entitlement cache cannot confirm paid", and
    /// SONNY-212 says "the free tier gets a small monthly screen-control allowance … so free users
    /// still see what makes Sonny different". Those two cannot both hold if this case means "is on a
    /// paid plan": a free user with allowance left would be refused by the very allowance the other
    /// ticket granted them. So what is required here is that the claim *confirms* — that this Mac
    /// holds a current, verifiable claim about its own session — and how much that claim grants is
    /// the allowance's question, one line below.
    ///
    /// **Which capability the claim names is row 18's (SONNY-23) and is deliberately not asked.** No
    /// capability key exists anywhere under `Sources/`, `EntitlementSourceScanTests` holds that as a
    /// population scan, and naming one here would be taking row 18's decision inside row 13's
    /// ticket. `EntitlementService.claimConfirmation()` is `decision(for:)` with exactly that one
    /// question removed and every other rule kept, so the day row 18 mints a key this becomes a
    /// `decision(for:)` call and nothing else moves.
    case entitlementUnconfirmed(EntitlementRefusal)
    /// The account has no screen-control runs left this period.
    case allowanceExhausted
    /// The gateway would not answer how many runs are left.
    case allowanceUnknown

    /// The sentence the user reads, and the same sentence the session record carries.
    ///
    /// One string for both, and phrased so it reads correctly at both moments — ``ScreenControlRefusal``
    /// makes the same call for the same reason, and a refusal the log describes differently from the
    /// panel is a refusal nobody can audit.
    public var userFacingReason: String {
        switch self {
        case .entitlementUnconfirmed(let refusal):
            // §7.1's rule, already applied: the sentence for every entitlement refusal is
            // `EntitlementCopy`'s, this repository's own words rather than the server's. A second
            // mapping here would be a second place for that rule to be got wrong.
            return EntitlementCopy.message(for: refusal)
        case .allowanceExhausted:
            // The ticket's own wording, kept verbatim. Functional, not explanatory: what happened,
            // and the two things the user can do about it.
            return "You've used your screen-control allowance — top up or wait."
        case .allowanceUnknown:
            return "Sonny couldn't check your screen-control allowance. Try again in a moment."
        }
    }

    /// The reason code the session journal records. Stable strings, distinct per case, so a reader
    /// months later can tell an exhausted allowance from an unreachable one — which are the same
    /// sentence's distance apart and entirely different facts.
    public var reasonCode: String {
        switch self {
        case .entitlementUnconfirmed: return "entitlement_unconfirmed"
        case .allowanceExhausted: return "allowance_exhausted"
        case .allowanceUnknown: return "allowance_unknown"
        }
    }
}

public enum ScreenControlGateDecision: Equatable, Sendable {
    case allowed
    case refused(ScreenControlGateRefusal)

    public var isAllowed: Bool { self == .allowed }
}

/// The gate, as the vision path consumes it.
///
/// A protocol rather than a concrete type on ``VisionSessionEnvironment`` for the reason every other
/// seam in that aggregate is one: the real implementation makes a network request, and a suite that
/// had to stand one up to ask what a refusal does would be testing the wiring.
public protocol ScreenControlGating: Sendable {
    func decide(at moment: ScreenControlGateMoment) async -> ScreenControlGateDecision
}

/// A gate that refuses everything, and **the default a build gets by saying nothing**.
///
/// `AgentViewModel.screenControlGate` starts as this and `main.swift` replaces it with the live one,
/// so a wiring that is never done refuses screen control rather than allowing it. That is the
/// fail-closed direction, and it is the direction an Optional with a `?? allowed` fallback would
/// have got backwards — the shape SONNY-350 removed from every local store's initializer for the
/// same reason.
///
/// It answers ``ScreenControlGateRefusal/allowanceUnknown``: nothing here has asked anybody
/// anything, so "Sonny couldn't check" is the true sentence, and claiming an exhausted allowance
/// would tell a user they had spent something they had not.
public struct ClosedScreenControlGate: ScreenControlGating {
    public init() {}

    public func decide(at moment: ScreenControlGateMoment) async -> ScreenControlGateDecision {
        .refused(.allowanceUnknown)
    }
}

// MARK: - The two readings the gate composes

/// Whether this Mac's cached entitlement claim confirms, right now, with no network.
///
/// Narrow on purpose. `EntitlementService` conforms; what the gate can ask it is one question with a
/// yes/no answer, and not the claim, not the capability list, and not the plan — the same narrowing
/// that service's own doc gives for why it never hands out an ``EntitlementClaim``.
public protocol ScreenControlEntitlementConfirming: Sendable {
    func claimConfirmation() async -> EntitlementDecision
    /// Waits for the background refresh a refusal may have started, if one is in flight, and
    /// returns at once when none is (SONNY-442). `EntitlementService.awaitPendingRefresh()` is the
    /// live answer; the gate uses it once, at the door, for the refusals a refresh cures.
    func awaitPendingRefresh() async
}

extension EntitlementRefusal {
    /// The refusals `EntitlementService.evaluate` starts a refresh on its way out of, because a
    /// fresh claim is the whole cure: nothing cached, bytes this build cannot read, a claim that
    /// belongs to somebody else, or a claim past its honoured window (SONNY-442). `notSignedIn`
    /// (no session to refresh with), `clockUnusable` (the clock, not the claim) and `notEntitled`
    /// (a valid claim that says no) are not on the list, and a wait would change none of them.
    public var isCuredByARefresh: Bool {
        switch self {
        case .noClaim, .unreadableClaim, .claimIsForAnotherSession, .lapsed:
            return true
        case .notSignedIn, .clockUnusable, .notEntitled:
            return false
        }
    }
}

/// How many screen-control runs are left this period, or a throw.
///
/// `ScreenControlAllowanceService` conforms. **A throw is a throw and never a number** — that type's
/// own rule, and the gate is the caller its doc comment said would decide what to do with one.
public protocol ScreenControlAllowanceReading: Sendable {
    func fetch() async throws -> ScreenControlAllowance
}

/// Buying more runs when they run out (SONNY-215).
///
/// **A second protocol beside ``ScreenControlAllowanceReading`` rather than a method on it, and the
/// separation is the point.** Reading an allowance is free and repeatable; this spends the user's
/// money. One protocol carrying both would let a later reader believe `fetch()` might charge, or —
/// worse — let a caller reach for the charging method while thinking about the reading one. The two
/// are the same object at run time and are two capabilities in the type system.
///
/// `ScreenControlAllowanceService` conforms. Like `fetch()`, **a throw is a throw and never a
/// number**: every way a purchase does not happen arrives here as an error, and the gate's answer to
/// all of them is the refusal it would have given anyway.
public protocol ScreenControlTopUpPurchasing: Sendable {
    func purchaseTopUp() async throws -> ScreenControlAllowance
}

extension EntitlementService: ScreenControlEntitlementConfirming {}
extension ScreenControlAllowanceService: ScreenControlAllowanceReading {}
extension ScreenControlAllowanceService: ScreenControlTopUpPurchasing {}

// MARK: - The live gate

/// The gate the shipping app runs: a local claim confirmation and a gateway allowance read.
///
/// ## The refusal is derived from a figure the server prices at read time, and that was decided
///
/// SONNY-212 derives the credit balance from metering rather than keeping a ledger — there is no
/// credit table, and `server/src/credit/balance.ts` sums the account's `screen.analyze` rows for the
/// period and prices them into credits. Its header flags what that costs a *refusal*, in as many
/// words: "read-time weights re-price the period already under way … The one thing that must not
/// follow from this file is a refusal derived the same way without snapshotting — that is
/// SONNY-213's decision to make, and it should make it deliberately." This is that decision, and it
/// is the third of the three options that ticket was handed: **accept the drift, bound it, and say
/// what the bound is.**
///
/// **What is accepted.** A founder deploy that changes `CREDIT_PLANS` — the weights, `runCredits`, or
/// a plan's `monthlyCredits` — re-prices every session already recorded in the period under way. A
/// user near their limit can therefore be refused by a price change rather than by their own usage,
/// and a past period's price is not reconstructable from the database because the catalogue lives in
/// an environment variable rather than in a row.
///
/// **The bound, stated so it can be checked rather than trusted.** (1) Nothing but a deploy moves it:
/// the weights are configuration with no default in the repository at all, so no request, no client
/// and no clock can change what a period costs. (2) It moves the whole population at once and in one
/// direction, so it is a visible operator action rather than a per-user drift. (3) It cannot un-run
/// what already ran: this gate only ever decides whether the *next* step happens, so a re-price
/// mid-session halts at a boundary — it never retracts an action, and never turns a completed
/// session into a refused one. (4) Iteration 1 always runs: the door's answer decides it and nothing
/// re-asks within it.
///
/// **Bound (4) used to end "the door's answer is not re-litigated, only added to", and that was
/// false in the very case the bound exists for** (PR #190's F4). A deploy landing between the door
/// and a later boundary moves the figure under a running session and can halt it — which is a
/// re-price re-deciding an admission the door granted. It is bound (3)'s territory, where it is
/// argued honestly, and the boundary re-asks the whole question by design: the entitlement half runs
/// at both moments too, so a claim that lapses or a sign-out mid-session refuses at the next
/// boundary as well, exactly as §13.5's permission-revocation shape re-checks every iteration. What
/// (4) actually buys is the `iteration > 1` guard, and that is now all it claims.
///
/// **The two options that were rejected, and why.**
///
/// - **Pinning the weights for a period**, which `balance.ts` names as its own preference because it
///   would close backward unreconstructability at the same time. Rejected *here* on two grounds, one
///   about correctness and one about scope. The correctness one: a period's price would be pinned at
///   the moment the period is first touched, so two accounts on the same plan with identical usage
///   pay different prices for the same month depending on when each of them first ran screen control
///   — invisibly, and with no way for either to find out. `usage_period.cap_units` can copy its
///   value precisely because a cap is an anti-abuse ceiling nobody is meant to reach, where being a
///   period stale costs nothing; a *price* is the number a user is spending against. The scope one:
///   pinning is a change to how credits are derived, so it belongs beside the derivation and moves
///   the reporting route (`GET /v1/account/credits`) as much as it moves this gate — and a snapshot
///   introduced inside the gate's ticket would leave the two reading the price from different eras
///   unless both moved together. It is filed rather than dropped.
/// - **Reading the refusal through a different path** — a server endpoint answering `allowed`/`not
///   allowed` instead of a number. Rejected because it moves the arithmetic without touching the
///   input: the same read-time weights over the same metering rows produce the same answer, one
///   layer further from anywhere a reader could check it. It would also give the product two
///   different sources for one fact — the number the usage surface shows (SONNY-214) and the verdict
///   the gate refuses on — which is exactly the disagreement `runsLeft <= 0` below exists to make
///   impossible.
///
/// **And a credit is still not a spend-cap unit.** SONNY-212 declined `unitsForMeteredCall`'s
/// invitation to weight the cap, because weighting per route makes the four unpaid routes weigh zero
/// and deletes the anti-abuse ceiling that bounds a leaked token (SONNY-16's recorded cost). Nothing
/// here merges them: this gate reads the allowance, the gateway's cap is untouched and still counts
/// unweighted calls on every metered route, and the two bound different things — a plan's purchase
/// and an operator's ceiling. That separation is also what makes a *client-side* gate honest rather
/// than decorative: a modified client that skips this check does not get free runs, it gets
/// `SPEND_CAP_UNITS` calls and then a `429`, exactly as it would today.
/// ## Running out is where a top-up happens, and only if the user asked (SONNY-215)
///
/// §16.4 names auto top-up as the mechanism serving its own mid-task-lapse principle: a user running
/// low tops up rather than hitting a wall. So the purchase sits at exactly the two points this gate
/// would otherwise refuse for `allowanceExhausted`, and **nowhere else** — a session with runs in
/// hand never triggers one, and neither does an unconfirmable claim or an allowance that could not
/// be read.
///
/// **The two moments keep their two questions, and the purchase does not collapse them.** That is
/// PR #190's F1 restated as a constraint on this ticket: `runsLeft` answers the door's question and
/// `creditsRemaining` answers the boundary's, and a purchase re-asks **the moment's own** question
/// against the new reading rather than a shared one. `isExhausted(_:at:)` below is one function
/// because the moment is a *parameter* of it — which is the opposite of the defect, where one
/// predicate ignored the moment entirely.
///
/// **The client's own check is an optimisation and never the enforcement.** `mayPurchase` stops a
/// request being made on behalf of a user who did not ask; what makes the guarantee is that the
/// gateway refuses independently, before it reads anything else and before any row is written
/// (`server/src/credit/topup.ts`). A modified client that asks anyway is refused there.
public struct SonnyScreenControlGate: ScreenControlGating {
    private let entitlements: any ScreenControlEntitlementConfirming
    private let allowance: any ScreenControlAllowanceReading
    private let topUp: any ScreenControlTopUpPurchasing

    /// No parameter has a default, for `EntitlementService`'s own recorded hazard: every packaged
    /// build on a Mac shares one Keychain, so a fixture that inherited a default would read the
    /// founder's real session — and for `topUp` there is a second reason of the same shape, since a
    /// defaulted purchaser is a defaulted way to spend somebody's money.
    public init(
        entitlements: any ScreenControlEntitlementConfirming,
        allowance: any ScreenControlAllowanceReading,
        topUp: any ScreenControlTopUpPurchasing
    ) {
        self.entitlements = entitlements
        self.allowance = allowance
        self.topUp = topUp
    }

    /// Has this account run out, **as this moment measures it**?
    ///
    /// One function, and the moment is what it switches on — which is the shape PR #190's F1
    /// produced by not having. The two questions are different and neither is a rounding of the
    /// other: `runsLeft` is `floor(remaining / runCredits)` over a `remaining` an in-flight session's
    /// own iterations have already been subtracted from, so it asks "can a whole further run be
    /// afforded", which is the door's question and never the boundary's.
    private func isExhausted(
        _ reading: ScreenControlAllowance,
        at moment: ScreenControlGateMoment
    ) -> Bool {
        switch moment {
        case .sessionStart:
            // May a *new* run start? The user is about to spend a run, so the question is whether
            // they have one — and this is the same field the product shows them, so the door can
            // never refuse someone reading "1 left" or admit someone reading "0 left".
            return reading.runsLeft <= 0
        case .stepBoundary:
            // May the run already admitted *continue*? Not whether another one could start — the
            // door granted this one, and a run the user was granted is theirs to finish. So the only
            // thing that halts here is the account having actually run out, which is the remainder
            // reaching zero. The server floors it at zero, so this is a confirmed exhaustion and not
            // a sign error.
            return reading.creditsRemaining <= 0
        }
    }

    /// Buy more runs, or answer `nil` — **and answer `nil` without asking anybody when the user did
    /// not ask for this** (SONNY-215).
    ///
    /// Every failure is one answer here on purpose. A declined card, a provider outage, a period
    /// whose purchases are spent and an account that never opted in all end in the same place: the
    /// refusal this gate was about to give anyway, in the sentence SONNY-213 wrote for it. That is
    /// the ticket's own non-goal — the default halt behaviour does not change — and it is also the
    /// honest reading, since "top up or wait" is still what a user whose card just failed should do.
    private func toppedUp(after reading: ScreenControlAllowance) async -> ScreenControlAllowance? {
        guard reading.autoTopUp.mayPurchase else { return nil }
        return try? await topUp.purchaseTopUp()
    }

    public func decide(at moment: ScreenControlGateMoment) async -> ScreenControlGateDecision {
        // **The local half first, at both moments.** It makes no network call and cannot block on
        // one, so a Mac with no confirmable claim is refused without waiting for a request that
        // would fail anyway — and a refusal names the ground the user can actually act on rather
        // than whichever one happened to be checked first.
        var confirmation = await entitlements.claimConfirmation()
        // **At the door, a refusal a refresh cures waits for the refresh it started, once**
        // (SONNY-442). `EntitlementService.evaluate` starts a background refresh on every one of
        // those refusals and returns the refusal at once — by design, since an answer that never
        // waits is what keeps §16.3's instant feel for everything else. Here the answer is the
        // only thing between a signed-in user and a session, and refusing "Connect once so Sonny
        // can check your plan" while that check is already on the wire sends them to press Retry a
        // moment later, which is what the founders' pass read on test 55. What puts a Mac in that
        // state is a claim that is not there when the door reads — nothing cached yet, or a sign-in
        // as another account, whose first reader discards the old claim and starts the refresh the
        // next reader lands before. A same-account sign-out and sign-in is **not** one of them:
        // `SonnyAccountService.signOut` clears the tokens and leaves the claim in the Keychain
        // (PR #229's F4), so what produced test 55's refusal on the founders' Mac is not established.
        // The Account dialog already reads twice for the same reason
        // (`SonnyAccountModel.refreshSubscription()`); this is that shape at the door. Only at
        // `.sessionStart`: a boundary that waited on the network would be the mid-session stall
        // the allowance branch below refuses to be.
        //
        // **The wait's bound is the client's, and it is not one timeout** (PR #229's F2).
        // `refreshNow()` sends with `SonnyBackendTimeouts.auth`, 20 s of idle time per request, and
        // a transport timeout is not retried — so a gateway that accepts and hangs costs 20 s. The
        // retryable codes (`server.error`, `server.unavailable`, `provider.unavailable`) get three
        // attempts with a server-named `Retry-After` honoured up to 20 s each, about 100 s in all;
        // an access-token refresh that falls due first is one more 20 s request. **A stop does not
        // wait for any of it**: `awaitPendingRefresh` returns the moment the run is cancelled, and
        // the adapter turns the cut-short answer into the run's own "Canceled." (F1).
        //
        // **Wait first, then ask — the order is the fix.** With the real service the second read
        // answers from the store, and the refresh writes the store when it ends; a read taken
        // before the wait lands on the same empty store the first one did and reports the refusal
        // this branch exists to stop. `ScreenControlGateRefreshWaitTests` holds the order by an
        // event list and by composing the real service (F3).
        if case .refused(let refusal) = confirmation, moment == .sessionStart, refusal.isCuredByARefresh {
            await entitlements.awaitPendingRefresh()
            confirmation = await entitlements.claimConfirmation()
        }
        if case .refused(let refusal) = confirmation {
            return .refused(.entitlementUnconfirmed(refusal))
        }

        let reading: ScreenControlAllowance
        do {
            reading = try await allowance.fetch()
        } catch {
            switch moment {
            case .sessionStart:
                // Fail closed. Nothing has happened, so this costs a sentence and no work.
                return .refused(.allowanceUnknown)
            case .stepBoundary:
                // **Not a refusal, and this is the one asymmetry in this type — the line the
                // adversarial review should attack, so the whole argument is here.**
                //
                // Running out is a **confirmed zero**: the gateway answered, the period's draw met
                // the allowance, and the refusal above says so. A failed read is not one — it is
                // evidence of nothing, and treating nothing as zero would assert that the user has
                // spent what nobody counted. The door's admission is also never re-litigated by
                // this branch: this session was admitted on a read that succeeded, its earlier
                // steps are done and cannot be undone, and what a boundary decides is only whether
                // the *next* step happens.
                //
                // Halting here would be §16.3's failure — a network blip breaking Sonny — arriving
                // at the one place it hurts most: mid-session, for a paying user, destroying work
                // the blip had nothing to do with, through the check written to prevent exactly
                // that yank (§13.5's graceful-halt shape).
                //
                // **What it concedes is bounded twice over**: a session is capped at
                // `VisionSessionLimits.maximumIterations` iterations, so at most that many further
                // steps can run past a read that stopped answering; and every one of them is a
                // metered call against the gateway's own spend cap, which is unweighted, per-route
                // and enforced server-side whatever this client believes.
                return .allowed
            }
        }

        // **Two moments, two questions, two figures — and reading one figure for both is what cost a
        // paying user most of their last run** (PR #190's F1).
        //
        // This block used to be a single `guard reading.runsLeft > 0`, justified by a comment
        // claiming the run count and the credit remainder were "the same predicate" and that
        // choosing the published one made it "impossible for the product to say '1 left' and refuse".
        // Both halves were wrong in the same way: they are true *at one instant*, and this gate
        // exists to span two. What the code actually did was refuse a session for spending the very
        // run it had just been admitted on — on a plan advertising ten runs, the tenth ran a single
        // iteration and halted with "You've used your screen-control allowance". The comment is
        // quoted here rather than deleted because a comment asserting a property the code lacks is
        // what kept the defect invisible through implementation and self-review.
        //
        // The arithmetic underneath it: `runsLeft` is `floor(remaining / runCredits)` over a
        // `remaining` from which the in-flight session's own metered iterations have **already** been
        // subtracted — `balance.ts` derives the whole balance from the metering rows, this session's
        // included. So `runsLeft` answers *"can this account afford a whole further run?"*, which is
        // exactly the door's question and never the boundary's.
        //
        // The step-boundary half is also what makes the ticket's own acceptance criterion mean
        // something: the halt fires when the allowance genuinely runs out mid-session, rather than
        // one step into every period's last run. And it is what the gateway already expects —
        // `balance.ts` says in as many words that "a session already in flight when the allowance
        // runs out finishes and is metered", so permitting that overdraw is the server's stated
        // design and not this client conceding something.
        guard isExhausted(reading, at: moment) else { return .allowed }

        // **Running out is where a top-up happens** (SONNY-215), and this is the only place it can:
        // the two refusals above — an unconfirmable claim and an allowance nobody could read — pass
        // through untouched, so nothing buys runs for a signed-out Mac or on the strength of a
        // request that failed.
        guard let toppedUp = await toppedUp(after: reading) else {
            return .refused(.allowanceExhausted)
        }
        // **The same moment's own question, re-asked against the new reading.** Not the other
        // moment's, and not a shared "is there anything left" — a purchase that landed on the very
        // last credit should still refuse a *new* session while letting a running one continue,
        // which is the whole distinction the two fields carry.
        guard !isExhausted(toppedUp, at: moment) else {
            return .refused(.allowanceExhausted)
        }
        return .allowed
    }
}
