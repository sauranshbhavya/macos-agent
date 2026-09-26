import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// What the Account section says about an account's credits.
@Suite
struct CreditPresentationTests {
    private func balance(allowance: Double, remaining: Double) -> CreditBalance {
        CreditBalance(
            plan: "test-plan",
            creditsAllowance: allowance,
            creditsRemaining: remaining,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 86_400),
            autoTopUp: .none,
            lastTopUp: nil
        )
    }

    @Test
    func theUsageLineShowsWholeCreditsLeftOfTheMonthsAllowance() {
        let line = CreditPresentation.usageLine(balance(allowance: 2000, remaining: 1240.8))
        #expect(line == "\(Self.whole(1240)) of \(Self.whole(2000)) credits left this month")
    }

    @Test
    func aRemainderBelowOneCreditReadsAsNoneRatherThanOne() {
        #expect(CreditPresentation.usageLine(balance(allowance: 10, remaining: 0.6)).hasPrefix("0 of 10"))
    }

    @Test
    func theTopUpControlNamesCreditsAndItsPrice() {
        #expect(CreditPresentation.autoTopUpLabel == "Buy more credits when these run out")
        let priced = CreditPresentation.autoTopUpLabel(price: CreditMoney(amount: 500, currency: "usd"))
        #expect(priced.hasPrefix("Buy more credits when these run out ("))
    }

    private static func whole(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value))!
    }
}
