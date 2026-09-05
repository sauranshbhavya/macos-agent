import Foundation

/// What this Mac can say about the account's subscription, read from the cached entitlement claim
/// (SONNY-216).
///
/// **This type exists because the claim carries no status field and one was deliberately not added.**
/// `EntitlementClaim` carries `plan` and `capabilities` and nothing else about billing — verified at
/// `server/src/entitlement/claim.ts`, which returns exactly those on every path. Adding a status
/// would change the claim's shape, which is a contract change to §4.1 and §5.3 under §8.2's
/// breaking-change rule, on work that merged the same day. The founders declined it on 2026-08-31
/// and the ruling was: say what the claim can prove.
///
/// **So this is that, and no more.** Every value below is derived from the claim the gateway signed,
/// judged at an instant the service establishes; nothing here asks the network and nothing here
/// guesses.
public struct SubscriptionSnapshot: Equatable, Sendable {
    /// The plan key, exactly as the gateway signed it.
    ///
    /// **Opaque, and shown to the user opaque.** `EntitlementClaim` says this repository never
    /// enumerates plan keys and SONNY-212 owns what the plans are; mapping `"paid"` onto a marketing
    /// name here would be taking that decision in this ticket.
    public let plan: String
    public let status: SubscriptionStatus

    public init(plan: String, status: SubscriptionStatus) {
        self.plan = plan
        self.status = status
    }
}

/// The two states a signed claim can establish about a subscription that exists.
///
/// **There is still no `pastDue` here, and that is now a division of labour rather than a gap.**
/// Spec §16.4 keeps every capability through the grace window on purpose — billing never cuts a
/// user off mid-task — so a claim minted for an account whose payment has failed is
/// indistinguishable from a healthy one, by design, and this type is what the *claim* can prove.
/// What a past-due account looks like arrives separately, as `BillingPaymentState` below, read from
/// `GET /v1/billing/payment-state` (SONNY-380).
///
/// (This doc used to end "nothing here builds for it", recording SONNY-380 as filed and unbuilt.
/// That is the sentence this branch is the answer to. The 14-day `BILLING_GRACE_DAYS` default it
/// named as compounding with the silence was **reviewed and kept** by the founders on 2026-09-05,
/// on the reasoning that the state line removes the silence the ticket was filed for.)
public enum SubscriptionStatus: Equatable, Sendable {
    /// The claim is current and grants at least one capability.
    case active
    /// The claim is current and grants nothing — the shape a revoked subscription takes.
    ///
    /// `server/src/entitlement/store.ts` mints exactly this on a cancellation: "a revoked
    /// entitlement keeps its plan key and loses every capability", so that a refreshing client stops
    /// allowing gated features immediately rather than waiting out the claim it already holds. A
    /// product `BILLING_PLANS` does not name lands here too, fail-closed.
    case ended
}

/// What the gateway says about payment on this account, or the absence of an answer (SONNY-380).
///
/// **It is not on the signed claim and could not have been cheaply.** `EntitlementClaim` carries
/// `plan` and `capabilities`; adding a status field to it is a change to §4.1 and §5.3 under §8.2's
/// breaking-change rule, and the founders declined that trade on 2026-08-31 and again on
/// 2026-09-05. So this arrives on its own unsigned route instead — and it is affordable to be
/// unsigned precisely because nothing is allowed to depend on it: it picks a word on one line and a
/// label on one control, and every question about what the account may *do* is still answered by
/// the claim, by `EntitlementJudgement` and by `decision(for:)`.
///
/// **`unrecognised` is §8.2 item 7's required fallback and it is present from the first release.**
/// The contract makes adding a value to a wire enum a breaking change unless every client already
/// tolerates one, so this case is what buys the server that freedom — and what it does with it is
/// the honest thing: an unrecognised value says *nothing* about payment, so the line falls back to
/// what the claim proves rather than asserting a state this build cannot interpret.
///
/// **What that costs, stated rather than left to be discovered.** A future value meaning something
/// *worse* than `past_due` would read on an old build exactly as a healthy account does, which is
/// this ticket's own defect arriving through the version door. That is §8.4's ladder to solve —
/// `recommended_client`, then `minimum_supported_client` — and not something this enum can, because
/// by construction an old build does not know what the new value means.
public enum BillingPaymentState: Equatable, Sendable {
    /// No payment failure is outstanding. **Not a claim that a payment succeeded**: an account with
    /// no subscription, an operator-granted one and a customer who cancelled on purpose all answer
    /// this, because none of them has a failure recorded.
    case current
    /// A payment has failed and has not been resolved — inside its grace window or past it. Both are
    /// the same fact about the customer's card, and the control that fixes either is the same one.
    case pastDue
    /// A value this build does not know. See the paragraphs above.
    case unrecognised

    /// The wire value, mapped. **Total by construction** — `default` is what makes item 7's
    /// tolerance real, and a `switch` over known cases with no default is what would have made a
    /// new server value a crash in every shipped build.
    public init(wire: String) {
        switch wire {
        case "current": self = .current
        case "past_due": self = .pastDue
        default: self = .unrecognised
        }
    }
}

/// Reading a subscription out of a claim, as a pure function of a claim, a session and an instant.
///
/// **Pure and separate from the service, for the reason `EntitlementJudgement` is.** Every edge worth
/// pinning — a claim belonging to somebody else, a claim outside its own window, an account that has
/// never subscribed — is a question about these three values, and a test that had to build an actor
/// and a Keychain to ask one of them would be testing the wiring.
public enum SubscriptionReading {
    /// The plan key the gateway sends for an account with no plan record at all.
    ///
    /// **A client-side dependency on a server literal, named here so it is one visible place rather
    /// than a bare string in a view.** `server/src/entitlement/store.ts:133` mints it in
    /// `unprovisioned`, and its own comment states that `'none'` "is not a tier name. It is the
    /// absence of a plan record. SONNY-212 owns the real keys." That sentence is what this depends
    /// on, and it is the one string in this repository whose meaning is set on the other side of the
    /// wire — so if SONNY-212 renames it, this is what has to move with it, and
    /// `theAbsenceOfAPlanIsNotASubscription` is what fails.
    public static let absentPlan = "none"

    /// What to say about this account's subscription, or `nil` when the claim establishes nothing.
    ///
    /// **`nil` is a refusal to guess, and it is the answer in four different situations**: the claim
    /// is about another session, this Mac's clock puts it in the future, it is past its own honoured
    /// window, or the account has no plan record. They are one answer here because they are one
    /// answer to the user — there is nothing this Mac can currently prove about a subscription — and
    /// because the alternative in every case is a line stating something the signed claim does not
    /// support.
    ///
    /// **The never-subscribed case is the one that had to be separable, and it is what
    /// `absentPlan` is for.** Without it a signed-in user who has never paid reads as `ended`, and
    /// the app offers them a Manage-subscription control that leads to a portal the provider has no
    /// customer for. The gateway refuses that with `409 entitlement.no_subscription` — but a control
    /// that only fails when pressed is a broken control, and not showing it is the actual
    /// requirement (founder direction, 2026-08-31).
    public static func read(
        claim: EntitlementClaim,
        session: SonnyAccountIdentity,
        now: Date
    ) -> SubscriptionSnapshot? {
        // Checked first, for `EntitlementJudgement.judge`'s reason: a claim about somebody else is
        // not stale, it is irrelevant, and reporting its plan would show the previous user's
        // subscription to whoever signed in next.
        guard claim.subject == session.userID else { return nil }
        guard now >= claim.honouredFrom, now <= claim.honouredUntil else { return nil }
        guard claim.plan != absentPlan, !claim.plan.isEmpty else { return nil }
        return SubscriptionSnapshot(
            plan: claim.plan,
            status: claim.capabilities.isEmpty ? .ended : .active
        )
    }
}

/// The words the Account section uses for a subscription, in the app's own vocabulary (SONNY-216).
///
/// **The same rule and the same reason as `EntitlementCopy` beside it**: §7.1 forbids displaying a
/// sentence the server authored, so what the user reads is owned here.
///
/// **And the standing rule that the product does not explain itself applies hardest to this one.** A
/// subscription state line says the state. It does not say what the state means, what the portal is
/// for, what happens next, or why a subscription might have ended — that belongs in website terms
/// and fine print, not in a dialog. Every string below is one or two words for exactly that reason.
public enum SubscriptionCopy {
    /// The plan and its state, as one line: `Paid · Active`.
    ///
    /// **The plan key is capitalised and otherwise untouched.** It is opaque here by
    /// `EntitlementClaim`'s own rule and SONNY-212 owns what the plans are, so mapping `"paid"` onto
    /// a marketing name would be taking that ticket's decision inside this one. If a key ever reads
    /// badly to a user, the fix is the key the gateway sends, not a translation table here.
    ///
    /// **`payment` has no default, and that is the whole of how SONNY-380's defect is kept fixed.**
    /// A defaulted parameter would let a second host of this line render it without answering the
    /// payment question — which is exactly the state the app was in before this ticket, and it read
    /// `Active` for a customer whose card had been declined. Required, a caller that has no answer
    /// says `nil` in words, and a new call site that forgets is a compile error rather than a quiet
    /// `Active`. (The same argument `SignInDialogView` makes for its own required parameters.)
    public static func line(for snapshot: SubscriptionSnapshot, payment: BillingPaymentState?) -> String {
        "\(snapshot.plan.capitalized) · \(word(for: snapshot.status, payment: payment))"
    }

    /// The one word the line ends with.
    ///
    /// **A past-due reading wins over the claim's own word, in both directions, and that is the
    /// ticket's central decision.** Against `.active` it is the defect being fixed: §16.4 keeps the
    /// capabilities through the grace window on purpose, so a declined card and a healthy account
    /// mint identical claims and this is the only thing that can tell them apart. Against `.ended`
    /// it is the more accurate of the two: a window that has closed empties the capabilities, so the
    /// claim then looks exactly like a cancellation — but nobody cancelled, the card is still
    /// declined, and "Ended" would send the user looking for a subscribe button instead of the
    /// control that actually fixes it. A customer who genuinely cancelled never reaches this arm:
    /// `writeFor`'s `ended` case clears `past_due_since`, so the gateway answers `current` for them.
    ///
    /// **`nil` and `.unrecognised` are the same answer — say nothing about payment** — and that is
    /// what the founders' decision of 2026-09-05 asks for offline: "the line shows nothing about
    /// payment state, which is acceptable because the grace window keeps capabilities working
    /// offline anyway". Falling back to the claim's word is not a statement about payment; it is the
    /// only thing this Mac can prove without the network.
    public static func word(for status: SubscriptionStatus, payment: BillingPaymentState?) -> String {
        if payment == .pastDue { return pastDueWord }
        switch status {
        case .active:
            return "Active"
        case .ended:
            return "Ended"
        }
    }

    /// **Two words, and no third.** The standing rule against explanatory copy is at its sharpest
    /// here: this line does not say what a grace window is, how long one runs, when access ends, or
    /// what happens next. It names a state, and the control beside it names the fix.
    public static let pastDueWord = "Past due"

    /// The control that opens the provider's hosted portal.
    ///
    /// **Named for what it resolves, which is why it is a function rather than one string.** The
    /// founders' decision of 2026-09-05 asks for "a state line that names the state and the control
    /// that resolves it" — and what resolves a past-due account is not managing a subscription, it
    /// is paying for it. Both labels open the same hosted portal; the word is what tells the user
    /// which door they are being pointed at.
    ///
    /// **Named for where it goes, not for what lives there** — the rule the `.manage` half has
    /// always followed. Listing what the portal offers, or explaining why the payment needs
    /// updating, would be the product explaining itself, and the portal's own page says all of it.
    public static func controlLabel(for payment: BillingPaymentState?) -> String {
        payment == .pastDue ? updatePaymentLabel : manageLabel
    }

    public static let manageLabel = "Manage subscription"
    public static let updatePaymentLabel = "Update payment"
}
