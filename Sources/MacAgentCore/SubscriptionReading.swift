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
/// **There is no `pastDue`, and its absence is a design fact rather than a gap.** Spec §16.4 keeps
/// every capability through the grace window on purpose — billing never cuts a user off mid-task —
/// so a claim minted for an account whose payment has failed is indistinguishable from a healthy
/// one, by design. This Mac therefore reads `active` while a card has been declined, and the
/// customer's only notice is the provider's own dunning email. §16.4 exists to stop a surprise wall
/// and that is a quiet route to one; it is filed as **SONNY-380**, together with the unreviewed
/// 14-day `BILLING_GRACE_DAYS` default it compounds with, and nothing here builds for it.
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
    public static func line(for snapshot: SubscriptionSnapshot) -> String {
        "\(snapshot.plan.capitalized) · \(word(for: snapshot.status))"
    }

    public static func word(for status: SubscriptionStatus) -> String {
        switch status {
        case .active:
            return "Active"
        case .ended:
            return "Ended"
        }
    }

    /// The control that opens the provider's hosted portal.
    ///
    /// **Named for where it goes, not for what lives there.** "Manage subscription" is what the user
    /// wants to do; listing what the portal offers — payment method, invoices, cancel — would be the
    /// product explaining itself, and the portal's own page says all of it anyway.
    public static let manageLabel = "Manage subscription"
}
