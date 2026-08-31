import Foundation
import MacAgentCore

/// The two sentences the product says about the screen-control allowance (SONNY-214).
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
    /// No denominator here, unlike the Command Center line: the widget is 472pt of glass over the
    /// user's work while Sonny is about to move their cursor, and the only figure that matters at
    /// that moment is how many they have got left.
    static func inTaskLine(runsLeft: Int) -> String {
        "\(runsLeft) \(runsLeft == 1 ? "run" : "runs") left"
    }

    /// What Command Center's stats area shows — "12 of 20 runs left this month".
    ///
    /// The denominator is what makes this a *usage* line rather than a countdown: 12 of 20 says
    /// eight were used, which is what the page is for. `runsIncluded` exists on
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
}
