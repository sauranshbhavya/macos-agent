import Foundation
import MacAgentCore

/// The words the product says about the screen-control allowance (SONNY-214).
///
/// Pure and in one place, because no SwiftUI inspection harness exists here to pin what a view
/// renders — the same reason `AgentActivityPresentation` beside it is a type rather than a pile of
/// string literals in `FloatingWidgetView`.
///
/// **Both are the number and nothing else, and that is the ticket's own constraint rather than
/// terseness for its own sake.** A usage line says how many runs are left. It does not say what a
/// run is, what draws on the allowance, or what happens when it reaches zero — the last of those is
/// SONNY-213's behaviour and not a sentence this surface gets to promise.
enum ScreenControlUsagePresentation {
    /// What the widget shows while a screen-control task is in flight — "12 runs left".
    ///
    /// No denominator here, unlike the Account line: the widget is 472pt of glass over the
    /// user's work while Sonny is about to move their cursor, and the only figure that matters at
    /// that moment is how many they have got left.
    static func inTaskLine(runsLeft: Int) -> String {
        "\(runsLeft) \(runsLeft == 1 ? "run" : "runs") left"
    }

    /// What the Account section calls the figure it shows beside the plan.
    ///
    /// **Here rather than inline in the view, which is where it used to be** (PR #188's F12 named
    /// the gap: this type's own doc claims to be the copy's one home, and a third literal sat in
    /// `CommandCenterView` outside it). Widening the prohibition test to cover the product's copy as
    /// a population is SONNY-399's, not this line's; what this does is make the claim above true.
    ///
    /// It is a label and not an explanation. Beside `Pro · Active` and a Manage-subscription button,
    /// "12 of 20 runs left this month" on its own would not say runs *of what*.
    static let label = "Screen Control"

    /// What the Account section shows beside the plan — "12 of 20 runs left this month".
    ///
    /// The denominator is what makes this a *usage* line rather than a countdown: 12 of 20 says
    /// eight were used, which is what somebody looking at their plan is there to find out.
    /// `runsIncluded` exists on
    /// `ScreenControlAllowance` for exactly this — its own doc comment calls it "the denominator of
    /// '3 of 20 left'".
    ///
    /// **"this month" is the period, not an explanation.** The server's period is the UTC calendar
    /// month (`server/src/entitlement/period.ts`), and a count of what is left with no period
    /// attached is a number a reader cannot use.
    /// **The noun agrees with the denominator, not with the numerator.** "1 of 20 run left" is what
    /// the obvious spelling produces, and it is wrong: the unit being counted here is the plan's
    /// twenty, and the one is a quantity of them.
    static func usageLine(_ allowance: ScreenControlAllowance) -> String {
        "\(allowance.runsLeft) of \(allowance.runsIncluded) "
            + "\(allowance.runsIncluded == 1 ? "run" : "runs") left this month"
    }

    /// The auto-top-up control's name (SONNY-215).
    ///
    /// **A precise label rather than a label plus an explanation**, which is the pattern the founders
    /// recorded on 2026-08-16 and this is the fourth application of it: narrow the name until the
    /// sentence beside it is unnecessary. "Auto top-up" is what every record calls this feature and
    /// it is exactly the name that would need one — it says neither what is bought nor when, so the
    /// obvious remedy is a line of how-it-works copy, which the no-explanatory-copy rule of
    /// 2026-08-14 forbids.
    ///
    /// So the name carries all three: **buy** (it costs money), **more runs** (of the thing named
    /// directly above it), and **when these run out** (not on a schedule, and not now). "These"
    /// has a referent on screen — the row above is ``label`` and ``usageLine`` — which is the same
    /// device "Delete what Sonny did on screen" uses, reusing the section title beside it so the
    /// object of the verb is literally visible.
    ///
    /// **What it deliberately does not say** is what a pack costs, how many can be bought in a
    /// month, or what happens when a card is declined. Those are real and they belong on the
    /// website's terms; the product says what the control does and stops.
    static let autoTopUpLabel = "Buy more runs when these run out"

    /// The same control's name **with the price on it** (SONNY-215's F6, founder decision option B).
    ///
    /// **A price is what a purchase always carries, and that is why this is not explanatory copy
    /// under the 2026-08-14 rule.** The rule forbids sentences telling a user how a feature works;
    /// what a thing costs is not how it works, it is the terms of the thing itself, and a switch
    /// that authorises a standing charge without naming the amount is the one place a number is
    /// owed rather than optional. The founder's decision is exactly that, and the line is held here:
    /// the price goes on the control, and **nothing explains why it is there**.
    ///
    /// **Parenthesised rather than made into a clause**, so the label still reads once at a glance
    /// — "Buy more runs when these run out ($5.00)" is a name with a price after it, and "which
    /// costs $5.00 each time" would be the sentence the pattern of 2026-08-16 exists to avoid.
    ///
    /// Falls back to the bare name when the deployment sent no price. That is a shape the app should
    /// not render at all — `SignInView` requires `isOffered`, and a gateway that offers a pack sends
    /// its price — so this is the honest answer to an impossible state rather than a supported one:
    /// a name with no number beats a name with a wrong one.
    static func autoTopUpLabel(price: ScreenControlMoney?) -> String {
        guard let price, let formatted = money(price) else { return autoTopUpLabel }
        return "\(autoTopUpLabel) (\(formatted))"
    }

    /// What the Account section calls the record of the last charge.
    static let lastTopUpLabel = "Last top-up"

    /// The record itself — "$5.00 on 14 August".
    ///
    /// **Amount and date, and nothing else.** It is a receipt line rather than a history: what was
    /// taken and when. It does not say what it bought, whether it worked, or that more may follow —
    /// the first is the runs line above it and the last two would be the explanation this surface is
    /// not allowed to write.
    ///
    /// **No year**, for the reason the usage line says "this month": the charge a user is checking
    /// is a recent one, and a year on it reads as an archive rather than a receipt. The full instant
    /// is in the accessibility label so a screen reader is not left guessing.
    static func lastTopUpLine(_ charge: ScreenControlTopUpCharge) -> String? {
        guard let formatted = money(charge.price) else { return nil }
        return "\(formatted) on \(dayAndMonth.string(from: charge.at))"
    }

    /// Minor units and an ISO code → what a person reads, in their own locale.
    ///
    /// **The divisor comes from the currency rather than from a constant.** Most currencies have two
    /// decimal places and some — yen among them — have none, so dividing by a hard-coded hundred
    /// would show a ¥500 charge as ¥5. `NumberFormatter` knows each currency's own exponent, and
    /// asking it is the only way to get this right without a table this repository would have to
    /// maintain.
    ///
    /// `nil` when the code is one this build cannot format, which renders no line at all — the same
    /// call every other figure on this surface makes, and for the same reason: a number nobody can
    /// read is worse than none.
    private static func money(_ price: ScreenControlMoney) -> String? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = price.currency.uppercased()
        guard formatter.currencySymbol != nil else { return nil }
        let places = formatter.maximumFractionDigits
        let divisor = pow(10.0, Double(places))
        let value = Double(price.amount) / (divisor == 0 ? 1 : divisor)
        return formatter.string(from: NSNumber(value: value))
    }

    /// "14 August", in the reader's own locale. Built once; `DateFormatter` is expensive.
    private static let dayAndMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return formatter
    }()
}
