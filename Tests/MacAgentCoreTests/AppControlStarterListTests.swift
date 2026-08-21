import Foundation
import Testing
@testable import MacAgentCore

/// The starter list (SONNY-141). Nothing consumes it yet — SONNY-143's resolver does — so these are
/// the two founder-required guards, the literal pin that keeps them honest, and the evidence record.
@Suite
struct AppControlStarterListTests {
    // MARK: - Guard (a): the terminal deny list

    /// **Founder condition, guard (a).** Driven off both production lists, so appending a terminal
    /// to the starter list without this failing is impossible. This is not a formality: the obvious
    /// shortcut for building a starter list — reusing `MacAppCatalog.default` — would have shipped
    /// `com.apple.Terminal` on the silent side of the gate.
    @Test
    func noStarterEntryIsOnTheTerminalDenyList() {
        let overlap = AppControlStarterList.bundleIdentifiers
            .intersection(ScreenControlPolicy.terminalBundleIdentifiers)

        #expect(overlap.isEmpty, "a terminal is on the starter list: \(overlap.sorted())")

        // And through the production door rather than only as set arithmetic, because the door is
        // what a real plan meets: every entry is an app the deny list does not refuse.
        for identifier in AppControlStarterList.bundleIdentifiers {
            let verdict = ScreenControlPolicy.verdict(bundleIdentifier: identifier, displayName: "starter")
            #expect(verdict.isEligible, "\(identifier) is refused by the deny list")
        }
    }

    // MARK: - Guard (b): editors and script hosts

    /// **Founder condition, guard (b).** The exclusion set is production code with its own name, so
    /// this compares two production lists rather than a production list against a literal repeated
    /// inside a test — which would only ever prove that whoever wrote the test agreed with
    /// themselves.
    @Test
    func noStarterEntryIsACodeEditorOrScriptHost() {
        let overlap = AppControlStarterList.bundleIdentifiers
            .intersection(AppControlStarterList.excludedCodeAndScriptEditorIdentifiers)

        #expect(overlap.isEmpty, "an editor or script host is on the starter list: \(overlap.sorted())")
    }

    // MARK: - The literal pin

    /// **Every list-driven assertion above also passes against an emptied list**, which is exactly
    /// how a guard test stops guarding without anyone noticing. Following
    /// `theTwoFounderNamedTerminalsAreOnTheList`'s precedent and for the identical reason: this
    /// proves the list says a specific thing, not merely that the mechanism is consistent with
    /// whatever it says.
    ///
    /// The two negatives are pinned beside the positives on purpose. They are the two entries the
    /// founder verified by hand in `MacAppCatalog.default` when he ruled that table out, and a list
    /// that reacquired either would be the exact failure this ticket exists to prevent.
    @Test
    func theStarterListSaysTheSpecificThingItWasRatifiedToSay() {
        let list = AppControlStarterList.bundleIdentifiers

        #expect(list.contains("com.apple.safari"))
        #expect(list.contains("com.apple.notes"))
        #expect(list.contains("com.apple.mail"))
        #expect(list.contains("com.apple.iwork.pages"))
        #expect(list.contains("com.google.chrome"))
        #expect(list.contains("com.microsoft.word"))
        #expect(list.contains("com.tinyspeck.slackmacgap"))

        #expect(!list.contains("com.apple.terminal"), "a terminal must never be pre-allowed")
        #expect(!list.contains("com.microsoft.vscode"), "an embedded-shell host must never be pre-allowed")

        // A gutted list fails here rather than passing every list-driven guard above.
        #expect(list.count > 30, "the starter list has been emptied or gutted: \(list.count) entries")
    }

    /// The same pin for the exclusion set, which the guard above is only as strong as. An emptied
    /// exclusion set makes `noStarterEntryIsACodeEditorOrScriptHost` vacuously true.
    @Test
    func theExcludedEditorListSaysTheSpecificThingItWasRatifiedToSay() {
        let excluded = AppControlStarterList.excludedCodeAndScriptEditorIdentifiers

        #expect(excluded.contains("com.microsoft.vscode"))
        #expect(excluded.contains("com.todesktop.230313mzl4w4u92"), "Cursor's ToDesktop id, as read from the bundle")
        #expect(excluded.contains("com.apple.dt.xcode"))
        #expect(excluded.contains("com.jetbrains.intellij"))
        #expect(excluded.contains("com.apple.scripteditor2"))
        #expect(excluded.contains("com.apple.shortcuts"), "a Shortcut can Run Shell Script — the founder's own ground")

        #expect(excluded.count > 8, "the exclusion set has been emptied or gutted: \(excluded.count) entries")
    }

    // MARK: - The evidence record

    /// **The evidence split, pinned so the record cannot drift from the list** —
    /// `theEvidenceSplitMatchesTheList`'s shape, for the same reason: a claim about a list's
    /// contents rots the moment someone appends an entry and leaves the doc comment alone, and that
    /// is the failure a comment cannot defend against and a test can.
    @Test
    func theEvidenceSplitMatchesTheStarterList() {
        // Read from each bundle's own Info.plist on the founder's Mac, 2026-08-20, by walking
        // /Applications, /System/Applications and /System/Applications/Utilities and reading
        // CFBundleIdentifier out of each — then lowercased.
        let readFromABundle: Set<String> = [
            "com.apple.safari",
            "com.apple.notes",
            "com.apple.mail",
            "com.apple.ical",
            "com.apple.reminders",
            "com.apple.mobilesms",
            "com.apple.preview",
            "com.apple.photos",
            "com.apple.music",
            "com.apple.maps",
            "com.apple.addressbook",
            "com.apple.facetime",
            "com.apple.textedit",
            "com.apple.calculator",
            "com.apple.iwork.pages",
            "com.apple.iwork.numbers",
            "com.apple.iwork.keynote",
            "com.apple.freeform",
            "com.apple.ibooksx",
            "com.apple.podcasts",
            "com.apple.tv",
            "com.apple.news",
            "com.apple.weather",
            "com.apple.voicememos",
            "com.apple.stickies",
            "com.google.chrome",
            "com.microsoft.word",
            "com.microsoft.excel",
            "com.microsoft.powerpoint",
            "com.microsoft.outlook",
            "com.microsoft.teams2",
            "com.tinyspeck.slackmacgap",
            "us.zoom.xos",
            "com.spotify.client",
            "net.whatsapp.whatsapp",
            "ru.keepcoder.telegram",
            "com.hnc.discord",
            "notion.id"
        ]
        // Taken from each project's published bundle configuration; no bundle was inspected, because
        // none of the three is installed on that Mac.
        let fromPublishedConfiguration: Set<String> = [
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "org.whispersystems.signal-desktop"
        ]

        #expect(readFromABundle.count == 38)
        #expect(fromPublishedConfiguration.count == 3)
        #expect(readFromABundle.isDisjoint(with: fromPublishedConfiguration))
        #expect(
            readFromABundle.union(fromPublishedConfiguration) == AppControlStarterList.bundleIdentifiers,
            "the starter list and the evidence record in its doc comment have diverged"
        )
    }

    /// The exclusion set carries the same record for the same reason. It is a guard rather than a
    /// deny list, so a wrong entry costs sharpness and never safety — but a reader deciding whether
    /// to trust one still deserves to know which kind of claim it is.
    @Test
    func theEvidenceSplitMatchesTheExcludedEditorList() {
        let readFromABundle: Set<String> = [
            "com.microsoft.vscode",
            "com.todesktop.230313mzl4w4u92",
            "com.jetbrains.intellij",
            "com.jetbrains.pycharm",
            "com.apple.dt.xcode",
            "com.sublimetext.4",
            "com.apple.scripteditor2",
            "com.apple.automator",
            "com.apple.shortcuts"
        ]
        let fromPublishedConfiguration: Set<String> = [
            "com.microsoft.vscodeinsiders",
            "com.jetbrains.webstorm",
            "dev.zed.zed"
        ]

        #expect(readFromABundle.count == 9)
        #expect(fromPublishedConfiguration.count == 3)
        #expect(readFromABundle.isDisjoint(with: fromPublishedConfiguration))
        #expect(
            readFromABundle.union(fromPublishedConfiguration)
                == AppControlStarterList.excludedCodeAndScriptEditorIdentifiers,
            "the exclusion set and the evidence record in its doc comment have diverged"
        )
    }

    // MARK: - Shape

    /// Entries are already `normalize`'s output, so a membership check folds the candidate and
    /// nothing else. Asserted through the production normalizer rather than against a hand-written
    /// lowercase rule, which is the "shared rather than re-implemented" half of the requirement:
    /// if `normalize` ever changes, this test moves with it instead of silently disagreeing.
    @Test
    func everyEntryIsAlreadyInTheCanonicalComparisonForm() {
        for identifier in AppControlStarterList.bundleIdentifiers
            .union(AppControlStarterList.excludedCodeAndScriptEditorIdentifiers) {
            #expect(
                ScreenControlPolicy.normalize(identifier) == identifier,
                "\(identifier) is not in the canonical comparison form"
            )
            #expect(!identifier.isEmpty)
            // Reverse-DNS shaped, which is what every real bundle identifier is. Catches a display
            // name pasted in by mistake as much as a typo.
            #expect(identifier.contains("."), "\(identifier) does not look like a bundle identifier")
            #expect(
                identifier.trimmingCharacters(in: .whitespacesAndNewlines) == identifier,
                "\(identifier) carries whitespace"
            )
        }
    }

    /// **The list is derived, never the alias table** (founder condition). Pinned as behaviour
    /// rather than trusted to the fact that they are two separate declarations: the two entries the
    /// founder verified in `MacAppCatalog.default` himself are the ones that make reuse
    /// disqualifying, and both must be absent from the starter list while still being present in the
    /// catalog — so this fails if anyone ever re-points one at the other.
    @Test
    func theStarterListIsNotTheAppCatalogAndContainsNeitherOfItsTwoDisqualifyingEntries() {
        let catalogIdentifiers = Set(
            MacAppCatalog.default.apps.map { ScreenControlPolicy.normalize($0.bundleIdentifier) }
        )

        // The catalog still holds both, so the assertions below are about the starter list rather
        // than about the catalog having quietly changed underneath them.
        #expect(catalogIdentifiers.contains("com.apple.terminal"))
        #expect(catalogIdentifiers.contains("com.microsoft.vscode"))

        #expect(!AppControlStarterList.bundleIdentifiers.contains("com.apple.terminal"))
        #expect(!AppControlStarterList.bundleIdentifiers.contains("com.microsoft.vscode"))
        #expect(AppControlStarterList.bundleIdentifiers != catalogIdentifiers)
    }
}
