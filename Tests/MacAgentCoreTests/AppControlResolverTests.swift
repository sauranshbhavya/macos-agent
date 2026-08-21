import Foundation
import Testing
@testable import MacAgentCore

/// The per-app control resolver (SONNY-143) — the pure half. The half that matters more is the
/// real-path one in `VisionSessionRunTests`: row I shipped a resolver hook that nothing ever called,
/// and a component test on a pure function is exactly what that looked like from inside.
@Suite
struct AppControlResolverTests {
    private static let starter: Set<String> = ["com.apple.notes", "com.apple.safari"]

    private static func approved(_ identifiers: String...) -> [ApprovedApp] {
        identifiers.map { ApprovedApp(bundleIdentifier: $0, displayName: $0, approvedAt: .appControlFixture) }
    }

    /// **The founder's own acceptance criterion, in one test: one app, three modes, three answers.**
    ///
    /// The correction it exists for, 2026-08-16: it is possible to read the requirement switch's
    /// signature and this resolver's signature and still write a resolver that ignores the mode —
    /// and built that way the starter list would grant standing in Safe too, which silently undoes
    /// the one thing switching to Safe is for. A mode-blind implementation cannot pass this.
    @Test
    func oneStarterListAppResolvesDifferentlyInEachOfTheThreeModes() {
        func standing(_ mode: AgentInteractionMode) -> AppControlStanding {
            AppControlResolver.standing(
                mode: mode,
                targetBundleIdentifier: "com.apple.Notes",
                starterList: Self.starter,
                approvedApps: []
            )
        }

        // Normal starts from the starter list, so a listed app needs no question.
        #expect(standing(.normal) == .allowed)
        // Safe starts from nothing. The user never approved Notes by hand, so Safe asks — this is
        // the line a mode-blind resolver gets wrong.
        #expect(standing(.safe) == .needsApproval)
        // Power asks about no app at all.
        #expect(standing(.power) == .allowed)
    }

    /// The other half of the founder's rule: the user's own approvals contribute in all three modes.
    @Test
    func aUserApprovedAppIsAllowedInAllThreeModesIncludingSafe() {
        for mode in AgentInteractionMode.allCases {
            #expect(
                AppControlResolver.standing(
                    mode: mode,
                    targetBundleIdentifier: "com.example.unlisted",
                    starterList: Self.starter,
                    approvedApps: Self.approved("com.example.unlisted")
                ) == .allowed,
                "\(mode)"
            )
        }
    }

    /// **Founder decision 4, as behaviour rather than intent**: Normal → Safe keeps the user's own
    /// list and drops the starter list's contribution. Written as one before/after pair over two
    /// apps, because the decision is precisely that the two are treated differently.
    ///
    /// The founder asked that the reasoning be kept verbatim: *auto-clearing destroys user data on
    /// a toggle, which the consequence rule says should ask first.* So there is exactly one user
    /// list, per app, forever, and a mode switch changes only what it starts from — nothing is
    /// erased, which is why the same `approvedApps` value is passed on both sides here.
    @Test
    func switchingFromNormalToSafeKeepsTheUsersOwnListAndDropsTheStarterList() {
        let approvedByHand = Self.approved("com.example.approvedbyhand")
        func standing(_ mode: AgentInteractionMode, _ identifier: String) -> AppControlStanding {
            AppControlResolver.standing(
                mode: mode,
                targetBundleIdentifier: identifier,
                starterList: Self.starter,
                approvedApps: approvedByHand
            )
        }

        // In Normal both are allowed, for two different reasons.
        #expect(standing(.normal, "com.apple.Notes") == .allowed)
        #expect(standing(.normal, "com.example.approvedbyhand") == .allowed)

        // Switch to Safe. The starter list's contribution is gone; the user's own survives.
        #expect(standing(.safe, "com.apple.Notes") == .needsApproval)
        #expect(standing(.safe, "com.example.approvedbyhand") == .allowed)
    }

    /// List-driven over the **production** starter list, so this cannot pass by agreeing with a
    /// two-entry fixture. Every real starter entry is allowed in Normal and asks in Safe.
    @Test
    func noProductionStarterEntryEverContributesInSafe() {
        for identifier in AppControlStarterList.bundleIdentifiers {
            #expect(
                AppControlResolver.standing(
                    mode: .normal,
                    targetBundleIdentifier: identifier,
                    starterList: AppControlStarterList.bundleIdentifiers,
                    approvedApps: []
                ) == .allowed,
                "\(identifier) in Normal"
            )
            #expect(
                AppControlResolver.standing(
                    mode: .safe,
                    targetBundleIdentifier: identifier,
                    starterList: AppControlStarterList.bundleIdentifiers,
                    approvedApps: []
                ) == .needsApproval,
                "\(identifier) in Safe"
            )
        }
    }

    /// Power's cell is "the gate does not run", not "everything is on a list" — so an app nobody has
    /// ever named resolves allowed there, and nothing is added to anybody's list to make it so.
    @Test
    func powerAllowsAnAppNobodyListedAndNobodyApproved() {
        #expect(
            AppControlResolver.standing(
                mode: .power,
                targetBundleIdentifier: "com.example.nobodyhaseverheardofthis",
                starterList: AppControlStarterList.bundleIdentifiers,
                approvedApps: []
            ) == .allowed
        )
    }

    /// A plan that controls no app has no per-app question, in every mode. `nil` is the answer a
    /// call site gives; it is not a default this function assumes.
    @Test
    func aPlanThatControlsNoAppResolvesNotApplicableInEveryMode() {
        for mode in AgentInteractionMode.allCases {
            #expect(
                AppControlResolver.standing(
                    mode: mode,
                    targetBundleIdentifier: nil,
                    starterList: AppControlStarterList.bundleIdentifiers,
                    approvedApps: Self.approved("com.example.anything")
                ) == .notApplicable,
                "\(mode)"
            )
            // A blank or whitespace identifier is the same fact wearing a different shape.
            #expect(
                AppControlResolver.standing(
                    mode: mode,
                    targetBundleIdentifier: "   ",
                    starterList: AppControlStarterList.bundleIdentifiers,
                    approvedApps: []
                ) == .notApplicable,
                "\(mode)"
            )
        }
    }

    /// Both comparisons fold case on both sides, through the one normalizer. Launch Services matches
    /// identifiers case-insensitively, and a string carried through a run picks up whitespace.
    @Test
    func bothTheStarterListAndTheUserListMatchCaseInsensitively() {
        for spelling in ["com.apple.Notes", "COM.APPLE.NOTES", "  com.apple.notes  "] {
            #expect(
                AppControlResolver.standing(
                    mode: .normal,
                    targetBundleIdentifier: spelling,
                    starterList: Self.starter,
                    approvedApps: []
                ) == .allowed,
                "starter list, \(spelling)"
            )
            #expect(
                AppControlResolver.standing(
                    mode: .safe,
                    targetBundleIdentifier: spelling,
                    starterList: Self.starter,
                    approvedApps: Self.approved("com.apple.NOTES")
                ) == .allowed,
                "user list, \(spelling)"
            )
        }
    }

    /// **The resolver does not know about terminals, and that is deliberate.** A terminal is refused
    /// above this by the deny list's three doors and by the runtime screen check, never by a cell of
    /// a consent table — folding it in here would demote a structural refusal into something a
    /// stored grant could argue with. This pins the resolver's honest answer so nobody later reads
    /// it as a hole: the refusal's absence here is covered by the real-path test that drives a
    /// terminal through `performStart` with the store containing it.
    @Test
    func theResolverItselfDoesNotRefuseATerminalBecauseThatIsNotItsJob() {
        #expect(
            AppControlResolver.standing(
                mode: .normal,
                targetBundleIdentifier: "com.apple.Terminal",
                starterList: AppControlStarterList.bundleIdentifiers,
                approvedApps: Self.approved("com.apple.Terminal")
            ) == .allowed
        )
        // And the door that really answers is unmoved by the grant.
        #expect(
            ScreenControlPolicy.verdict(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal").refusal
                == .terminal
        )
    }

    /// The plan-side half of the two production call sites: what a plan reports as its target.
    @Test
    func onlyAResolvedVisionStepReportsAnAppControlTarget() {
        let ordinary = AgentPlan(summary: "s", requiresConfirmation: false, steps: [
            AgentStep(id: "a", operation: .openApp, description: "d", appName: "Safari")
        ])
        #expect(ordinary.appControlTargetBundleIdentifier == nil)

        let unresolved = AgentPlan(summary: "s", requiresConfirmation: false, steps: [
            AgentStep(id: "v", operation: .visionSession, description: "d", appName: "Safari", visionGoal: "g")
        ])
        // An unresolved vision plan has not passed the resolve door, so it is not executable and
        // reports no target. Correct, not a hole.
        #expect(unresolved.appControlTargetBundleIdentifier == nil)

        var resolvedStep = AgentStep(
            id: "v",
            operation: .visionSession,
            description: "d",
            appName: "Safari",
            visionGoal: "g"
        )
        resolvedStep.resolvedAppName = "Safari"
        resolvedStep.resolvedBundleIdentifier = "com.apple.Safari"
        let resolved = AgentPlan(summary: "s", requiresConfirmation: false, steps: [resolvedStep])
        #expect(resolved.appControlTargetBundleIdentifier == "com.apple.Safari")
    }
}

private extension Date {
    static let appControlFixture = Date(timeIntervalSince1970: 1_700_000_000)
}
