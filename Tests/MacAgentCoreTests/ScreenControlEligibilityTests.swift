import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-91: which apps Sonny may control, and the one class it never may.
///
/// The ticket was written against a per-app consent store. The founder deleted that on 2026-08-14 —
/// any installed app is controllable without asking — so what is pinned here is the half that
/// survived: the terminal ban, and the structural claim that an eligible verdict has exactly one
/// producer.
@Suite
struct ScreenControlEligibilityTests {
    // MARK: - Fixtures

    private static func app(_ name: String, _ bundleIdentifier: String) -> InstalledApp {
        InstalledApp(
            displayName: name,
            bundleIdentifier: bundleIdentifier,
            applicationURL: URL(fileURLWithPath: "/Applications/\(name).app")
        )
    }

    // MARK: - The ban

    /// Every entry on the list refuses, through the resolved-app door.
    ///
    /// Driven off `terminalBundleIdentifiers` itself rather than a hand-copied list, so an entry
    /// added to production without a matching refusal path cannot slip through — and so this test
    /// cannot silently stop covering an entry someone appends.
    @Test
    func everyListedTerminalIsRefusedThroughTheResolvedAppDoor() {
        #expect(!ScreenControlPolicy.terminalBundleIdentifiers.isEmpty)

        for bundleIdentifier in ScreenControlPolicy.terminalBundleIdentifiers {
            let verdict = ScreenControlPolicy.verdict(for: Self.app("Some Terminal", bundleIdentifier))

            #expect(verdict.isEligible == false, "\(bundleIdentifier)")
            #expect(verdict.refusal == .terminal, "\(bundleIdentifier)")
            #expect(verdict.bundleIdentifier == bundleIdentifier, "\(bundleIdentifier)")
        }
    }

    /// The same, through the pinned-identifier door the in-loop re-check uses. Two doors, one
    /// answer — asserted as an equality across the whole list rather than spot-checked, because a
    /// second door that drifts is exactly the failure mode a single shared implementation exists to
    /// prevent.
    @Test
    func bothDoorsAgreeOnEveryListedTerminal() {
        for bundleIdentifier in ScreenControlPolicy.terminalBundleIdentifiers {
            let viaApp = ScreenControlPolicy.verdict(for: Self.app("T", bundleIdentifier))
            let viaIdentifier = ScreenControlPolicy.verdict(
                bundleIdentifier: bundleIdentifier,
                displayName: "T"
            )

            #expect(viaApp == viaIdentifier, "\(bundleIdentifier)")
            #expect(viaIdentifier.refusal == .terminal, "\(bundleIdentifier)")
        }
    }

    /// The two identifiers the founder named by hand, pinned literally.
    ///
    /// Separate from the list-driven tests on purpose: those prove the mechanism is consistent with
    /// whatever the list says, and would still pass if someone emptied it. This one proves the list
    /// says the specific thing that was ratified.
    @Test
    func theTwoFounderNamedTerminalsAreOnTheList() {
        #expect(ScreenControlPolicy.terminalBundleIdentifiers.contains("com.apple.terminal"))
        #expect(ScreenControlPolicy.terminalBundleIdentifiers.contains("com.googlecode.iterm2"))

        #expect(ScreenControlPolicy.verdict(for: Self.app("Terminal", "com.apple.Terminal")).refusal == .terminal)
        #expect(ScreenControlPolicy.verdict(for: Self.app("iTerm", "com.googlecode.iterm2")).refusal == .terminal)
    }

    /// Launch Services treats bundle identifiers case-insensitively, and a string carried through a
    /// run picks up whitespace and decomposed Unicode forms. Each of those is a way to spell
    /// `com.apple.Terminal` that must not evade the check.
    @Test
    func spellingVariationsOfATerminalIdentifierStillRefuse() {
        let spellings = [
            "com.apple.Terminal",
            "com.apple.terminal",
            "COM.APPLE.TERMINAL",
            "  com.apple.Terminal  ",
            "\tcom.apple.Terminal\n",
            "cOm.ApPlE.tErMiNaL"
        ]

        for spelling in spellings {
            let verdict = ScreenControlPolicy.verdict(bundleIdentifier: spelling, displayName: "Terminal")
            #expect(verdict.refusal == .terminal, "\(spelling)")
            // The verdict reports the normalized spelling, so a caller that pins or logs what it
            // compared records the same string the comparison used.
            #expect(verdict.bundleIdentifier == "com.apple.terminal", "\(spelling)")
        }
    }

    // MARK: - Everything else is controllable

    /// The founder's supersession, as behavior: any installed app is eligible, with no grant, no
    /// prompt and no store consulted. Ordinary apps, a browser, and a developer tool that is not a
    /// terminal.
    @Test
    func anyInstalledNonTerminalAppIsEligibleWithoutAGrant() {
        let apps = [
            Self.app("Safari", "com.apple.Safari"),
            Self.app("Notes", "com.apple.Notes"),
            Self.app("Figma", "com.figma.Desktop"),
            Self.app("Discord", "com.hnc.Discord"),
            Self.app("Visual Studio Code", "com.microsoft.VSCode"),
            Self.app("Xcode", "com.apple.dt.Xcode")
        ]

        for app in apps {
            let verdict = ScreenControlPolicy.verdict(for: app)
            #expect(verdict.isEligible, "\(app.bundleIdentifier)")
            #expect(verdict.refusal == nil, "\(app.bundleIdentifier)")
            #expect(verdict.displayName == app.displayName)
        }
    }

    /// Identity is the bundle identifier, never the display name — the SONNY-58 anti-imposter rule
    /// applied to control.
    ///
    /// Both directions matter and both are asserted. An app that *calls itself* "Terminal" while
    /// carrying another identifier is a different app and is controllable, because controlling
    /// arbitrary apps is what was authorized. And the real Terminal stays refused under any display
    /// name at all, so a renamed copy gains nothing.
    @Test
    func eligibilityFollowsTheBundleIdentifierAndNeverTheDisplayName() {
        let imposter = ScreenControlPolicy.verdict(for: Self.app("Terminal", "com.example.NotAShell"))
        #expect(imposter.isEligible)

        let renamedRealTerminal = ScreenControlPolicy.verdict(
            for: Self.app("Totally Harmless Notes", "com.apple.Terminal")
        )
        #expect(renamedRealTerminal.refusal == .terminal)
    }

    /// A near-miss identifier is not a terminal. Pinned because the check is exact-set membership
    /// and must not quietly become a prefix or substring match — `com.apple.Terminal.Helper` is a
    /// different bundle, and a substring rule would also catch, say, an app named
    /// `com.vendor.TerminalTracker` that is a shipping-parcel tracker.
    @Test
    func identifiersThatMerelyResembleATerminalAreEligible() {
        let nearMisses = [
            "com.apple.Terminal.Helper",
            "com.apple.Terminalx",
            "com.vendor.TerminalTracker",
            "iterm2",
            "com.googlecode.iterm",
            "org.alacritty.helper"
        ]

        for identifier in nearMisses {
            let verdict = ScreenControlPolicy.verdict(bundleIdentifier: identifier, displayName: "X")
            #expect(verdict.isEligible, "\(identifier)")
        }
    }

    /// An empty or whitespace-only identifier is not on the list, so it is eligible by this rule.
    ///
    /// Pinned deliberately rather than left to chance: it records that *existence* is not this
    /// type's question. Nothing reaches control with an empty identifier, because the resolver is
    /// what produces a target and it returns `nil` rather than an empty one — but stating the
    /// boundary here is what keeps a future reader from adding an existence check to a policy that
    /// is only about authority.
    @Test
    func anEmptyIdentifierIsNotTreatedAsATerminal() {
        #expect(ScreenControlPolicy.verdict(bundleIdentifier: "", displayName: "").isEligible)
        #expect(ScreenControlPolicy.verdict(bundleIdentifier: "   ", displayName: "").isEligible)
    }

    /// The normalizer's two steps, pinned directly.
    @Test
    func theNormalizerTrimsAndLowercases() {
        #expect(ScreenControlPolicy.normalize("  com.Example.App \n") == "com.example.app")
        #expect(ScreenControlPolicy.normalize("\tcom.EXAMPLE.app") == "com.example.app")
        // Locale-independent lowercasing: a Turkish-locale fold would send "I" to "ı" and miss.
        #expect(ScreenControlPolicy.normalize("COM.ITERM.APP") == "com.iterm.app")
    }

    /// Why the normalizer has no Unicode-precomposition step, pinned as the measurement that
    /// settled it rather than as a sentence in a comment.
    ///
    /// A decomposed spelling of a deny-list identifier is the obvious way to try to slip past set
    /// membership. Swift closes it without help: `String` compares *and hashes* by canonical
    /// equivalence, so two spellings that differ in byte length are one key in a `Set<String>`.
    /// This test exists so that if that ever stopped being true, the failure would land here — on
    /// the assumption itself — rather than as a quietly controllable terminal.
    @Test
    func swiftStringSetMembershipIsAlreadyCanonicalEquivalenceSafe() {
        let decomposed = "com.cafe\u{0301}.app"
        let precomposed = "com.caf\u{00E9}.app"

        // Genuinely different byte sequences...
        #expect(Array(decomposed.utf8).count == 14)
        #expect(Array(precomposed.utf8).count == 13)
        // ...that Swift treats as one string, one hash, one set key.
        #expect(decomposed == precomposed)
        #expect(decomposed.hashValue == precomposed.hashValue)
        #expect(Set([precomposed]).contains(decomposed))
    }

    // MARK: - The verdict type's own guarantees

    /// `isEligible` is derived from `refusal`, not stored beside it, so the two can never disagree.
    /// Asserted over the whole refusal domain plus `nil` rather than on one value.
    @Test
    func eligibilityIsExactlyTheAbsenceOfARefusal() {
        for refusal in ScreenControlRefusal.allCases {
            let refused = ScreenControlPolicy.verdict(
                bundleIdentifier: Self.identifierProducing(refusal),
                displayName: "X"
            )
            #expect(refused.refusal == refusal)
            #expect(refused.isEligible == false)
        }

        let eligible = ScreenControlPolicy.verdict(bundleIdentifier: "com.example.App", displayName: "X")
        #expect(eligible.refusal == nil)
        #expect(eligible.isEligible)
    }

    /// One identifier known to produce each refusal ground, so the test above stays exhaustive over
    /// `ScreenControlRefusal` when a second ground is added — the new case will fail to compile
    /// here until someone supplies its identifier, which is the reminder.
    private static func identifierProducing(_ refusal: ScreenControlRefusal) -> String {
        switch refusal {
        case .terminal:
            return "com.apple.Terminal"
        }
    }

    /// Every refusal carries copy that names the ban and says it is not overridable — the "refusal,
    /// not a prompt" half of the rule, as a user-visible string rather than an internal flag.
    @Test
    func everyRefusalCarriesHonestNonNegotiableCopy() {
        for refusal in ScreenControlRefusal.allCases {
            let reason = refusal.userFacingReason
            #expect(!reason.isEmpty, "\(refusal)")
            // Not a phrase match on the whole sentence — that would break on any rewording. What is
            // pinned is that the copy states the refusal is not something the user can grant, which
            // is the one thing it must never quietly lose.
            #expect(reason.lowercased().contains("never") || reason.lowercased().contains("cannot"), "\(refusal)")
        }
        #expect(ScreenControlRefusal.terminal.userFacingReason.contains("terminal"))
    }
}
