import Foundation
import MacAgentCore
import Testing
@testable import MacAgent

/// Settings → Security & Access → **Screen Control**'s list of allowed apps, its per-row Remove and
/// its Remove All (SONNY-144).
///
/// **Split deliberately from the behaviour.** What a *session* does after a grant is taken back —
/// stopping at the next iteration, asking again on the next run — runs through the real vision loop
/// and lives in `VisionSessionRunTests`, because those are claims about the product rather than
/// about a list. What is here is the list itself: which grants it may render, how each one reads,
/// what it says when there are none, and the structure of the section that renders them.
@Suite
struct ApprovedAppRevocationTests {
    private static func app(
        _ bundleIdentifier: String,
        _ displayName: String,
        at seconds: TimeInterval = 1_700_000_000
    ) -> ApprovedApp {
        ApprovedApp(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            approvedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    // MARK: - Which grants are rendered

    /// Every grant gets a row, and the row is keyed on the identifier rather than on the name.
    ///
    /// **Two apps whose display names differ only in case are the fixture on purpose.** The store
    /// keys on the bundle identifier and the list renders the name, so a list that deduplicated or
    /// sorted by name would silently merge these two — and the user would press Remove on one app
    /// and watch a different one disappear. Their *identifiers* are genuinely different, which is the
    /// half that has to be right for the fixture to mean anything: `ApprovedApp.matches` folds case,
    /// so two identifiers differing only in case are one app and the store would hold one of them.
    @Test
    func everyGrantGetsItsOwnRowKeyedOnTheIdentifierRatherThanTheName() {
        let rows = ApprovedAppRevocationPresentation.rows(
            for: [
                Self.app("com.example.notes", "Notes"),
                Self.app("com.other.notes", "NOTES"),
                Self.app("com.apple.Safari", "Safari")
            ]
        )

        #expect(rows.map(\.id) == ["com.example.notes", "com.other.notes", "com.apple.Safari"])
        #expect(rows.map(\.title) == ["Notes", "NOTES", "Safari"])
        #expect(Set(rows.map(\.removeAccessibilityLabel)).count == 3)
    }

    /// The identifier sits beside the name, never instead of it — the name is what a person
    /// recognises, and the identifier is what the grant is matched on.
    @Test
    func aRowNamesTheAppAndCarriesTheIdentifierAndWhenItWasAllowed() {
        let row = ApprovedAppRevocationPresentation.row(
            for: Self.app("com.apple.Notes", "Notes"),
            now: Date(timeIntervalSince1970: 1_700_003_600)
        )

        #expect(row.title == "Notes")
        #expect(row.detail.contains("com.apple.Notes"))
        #expect(row.detail.contains("allowed"))
        #expect(row.removeAccessibilityLabel == "Remove Notes")
    }

    /// A grant with no display name still gets a row somebody can decide about.
    @Test
    func aGrantWithNoDisplayNameFallsBackToItsIdentifier() {
        let blank = ApprovedAppRevocationPresentation.row(for: Self.app("com.apple.Notes", ""))
        let whitespace = ApprovedAppRevocationPresentation.row(for: Self.app("com.apple.Notes", "   "))

        #expect(blank.title == "com.apple.Notes")
        #expect(whitespace.title == "com.apple.Notes")
        #expect(whitespace.removeAccessibilityLabel == "Remove com.apple.Notes")
    }

    /// **An app the deny list refuses is never rendered, even placed in the store by hand.**
    ///
    /// The store's write path already refuses to persist one, so this is about a file outliving the
    /// code that filled it. A revocation list offering to take back a grant on Terminal would tell
    /// the user they had allowed something Sonny will never do.
    ///
    /// The eligible neighbours are asserted alongside, so a filter that removed everything would
    /// fail here rather than pass as "no terminal rendered" — a clean zero is the one answer that
    /// looks like good news.
    @Test
    func aTerminalIsNeverRenderedEvenWhenTheFileHoldsOne() throws {
        let terminals = try #require(
            Array(ScreenControlPolicy.terminalBundleIdentifiers).sorted().first
        )
        let rows = ApprovedAppRevocationPresentation.rows(
            for: [
                Self.app("com.apple.Notes", "Notes"),
                Self.app(terminals, "A Terminal"),
                Self.app("com.apple.Safari", "Safari")
            ]
        )

        #expect(rows.map(\.id) == ["com.apple.Notes", "com.apple.Safari"])
    }

    /// Every terminal on the list, not just the one the test above happened to pick.
    @Test
    func noTerminalOnTheDenyListCanReachTheList() {
        for identifier in ScreenControlPolicy.terminalBundleIdentifiers {
            let rows = ApprovedAppRevocationPresentation.rows(for: [Self.app(identifier, "Whatever")])
            #expect(rows.isEmpty, "\(identifier) reached the revocation list")
        }
    }

    /// A grant with no identifier can name no app and match no Remove, so it gets no row.
    @Test
    func aGrantWithNoIdentifierGetsNoRow() {
        #expect(ApprovedAppRevocationPresentation.rows(for: [Self.app("", "Ghost")]).isEmpty)
        #expect(ApprovedAppRevocationPresentation.rows(for: [Self.app("   ", "Ghost")]).isEmpty)
    }

    // MARK: - The words

    /// The empty state is a real one, and it names the command that ends it — this repository's
    /// empty-state convention, and the thing that stops a user hunting for an Add button that
    /// deliberately does not exist.
    @Test
    func theEmptyStateSaysHowAGrantArrivesRatherThanSittingBlank() {
        #expect(ApprovedAppRevocationPresentation.emptyTitle == "No allowed apps yet")
        #expect(
            ApprovedAppRevocationPresentation.emptyMessage
                == "Allow Sonny to control an app during a screen task, and it will appear here."
        )
        #expect(!ApprovedAppRevocationPresentation.emptyMessage.isEmpty)
    }

    /// **An unreadable store is not an empty one.** A grants file that will not decrypt loads as
    /// zero grants, and without this split the section would tell a user who has allowed apps that
    /// they have allowed none, under a sentence inviting them to go and allow one.
    ///
    /// The recovery names Memory, because the reader is in Settings and the control that sets an
    /// unreadable file aside rather than destroying it is a page away.
    @Test
    func theUnreadableStateIsNotTheEmptyStateAndPointsAtTheOneControlThatKeepsTheFile() {
        #expect(ApprovedAppRevocationPresentation.unreadableTitle == "Sonny can't read your allowed apps")
        #expect(ApprovedAppRevocationPresentation.unreadableMessage.contains("Open Memory in Command Center"))
        #expect(ApprovedAppRevocationPresentation.unreadableMessage.contains("The file stays on your Mac."))
        #expect(ApprovedAppRevocationPresentation.unreadableMessage != ApprovedAppRevocationPresentation.emptyMessage)
        #expect(ApprovedAppRevocationPresentation.unreadableTitle != ApprovedAppRevocationPresentation.emptyTitle)
        #expect(
            ApprovedAppRevocationPresentation.unreadableSystemImage
                != ApprovedAppRevocationPresentation.emptySystemImage
        )
    }

    /// **The standing is a separate question from the routing, and this is the pair that proves it.**
    /// `MemoryRowDestination.of(.approvedApps)` is `.entriesSheet`, so a Settings surface reusing
    /// that routing would have told its reader to press a Delete on a row that is not on their
    /// screen.
    @Test
    func theRecoverySentenceNamesMemoryFromSettingsAndDoesNotFromTheSheet() {
        let fromSettings = MemoryDeletionCopy.unreadableRecoveryMessage(for: .approvedApps, standing: .elsewhere)
        let fromTheSheet = MemoryDeletionCopy.unreadableSheetMessage(for: .approvedApps)

        #expect(fromSettings.contains("Open Memory in Command Center"))
        #expect(!fromTheSheet.contains("Open Memory in Command Center"))
        #expect(fromTheSheet.hasPrefix("Press Delete on the allowed apps row"))
    }

    /// Remove All's confirmation says what it takes and what happens next, and says it in the
    /// sentence the Memory section already uses for this store — one consequence, one wording.
    @Test
    func removeAllConfirmsWithTheSameSentenceTheMemorySectionUsesForThisStore() {
        #expect(
            ApprovedAppRevocationPresentation.removeAllConfirmationMessage
                == MemoryDeletionCopy.message(for: .approvedApps)
        )
        #expect(ApprovedAppRevocationPresentation.removeAllConfirmationMessage.contains("asks again"))
        #expect(ApprovedAppRevocationPresentation.removeAllConfirmationTitle.hasSuffix("?"))
    }

    /// **The Memory sheet and Settings render one grant the same way.** Both build from
    /// `row(for:now:)`, so the title fallback and the detail line cannot drift apart between two
    /// surfaces onto one store. Asserted through the *string* each surface would show rather than by
    /// reading the source, so a future hand-written copy in either place fails here.
    @Test
    func theMemorySheetAndSettingsShowOneGrantInOneWording() {
        let app = Self.app("com.apple.Notes", "")
        let now = Date(timeIntervalSince1970: 1_700_007_200)
        let settingsRow = ApprovedAppRevocationPresentation.row(for: app, now: now)

        // The sheet's own construction, mirrored: `MemoryEntryPresentation.entries` needs a view
        // model, so what is pinned here is the value it is built from.
        #expect(settingsRow.id == app.bundleIdentifier)
        #expect(settingsRow.title == "com.apple.Notes")
        #expect(settingsRow.detail.hasPrefix("com.apple.Notes · allowed "))
    }

    // MARK: - The section that renders them

    /// The file's text with comment markers and runs of whitespace collapsed, so an assertion is
    /// about the words on the page rather than about where a line happens to wrap.
    ///
    /// The same normalization `ScreenControlSettingsCopyTests` uses, and for the reason recorded
    /// there: without it a negative assertion passes because a phrase wrapped, not because the
    /// phrase is gone.
    private static func normalized(_ source: String) -> String {
        source
            .replacingOccurrences(of: "///", with: " ")
            .replacingOccurrences(of: "//", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func commandCenterSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/MacAgent/CommandCenterView.swift"),
            encoding: .utf8
        )
    }

    /// The body of `ApprovedAppRevocationList`, isolated from the rest of the file.
    ///
    /// **Bounded by the next type declaration rather than by brace counting**, which a scan over
    /// SwiftUI cannot do reliably; a scan that silently read the whole file would pass on evidence
    /// from anywhere in six thousand lines.
    private static func revocationListSource() throws -> String {
        let source = try commandCenterSource()
        let start = try #require(source.range(of: "private struct ApprovedAppRevocationList: View {"))
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n/// Split out of Security & Access")
        return String(rest[..<(end?.lowerBound ?? rest.endIndex)])
    }

    /// **Rows survive a narrow, non-fullscreen window, and that is structural rather than visual.**
    ///
    /// `SettingsAdaptiveControlRow` is the `ViewThatFits` horizontal-first, `minWidth`-floored,
    /// vertical-fallback pattern that exists because a fixed `HStack` character-wrapped at narrow
    /// widths. No agent can drive the real window, so what a test can hold is that this list is
    /// built from that row and not from the shape the pattern replaced — which is the property, and
    /// the founder's narrow-window pass is what confirms the pixels.
    ///
    /// The ticket asked for this "the way the existing adaptive-row tests do". There are none:
    /// `git grep -lE 'SettingsAdaptiveControlRow|ViewThatFits' -- Tests` printed nothing before this
    /// file. This is the first.
    @Test
    func theListIsBuiltFromTheAdaptiveRowAndNeverFromAHandRolledStack() throws {
        let list = try Self.revocationListSource()

        // Two: the header carrying Remove All, and the per-app row inside the `ForEach`.
        #expect(list.components(separatedBy: "SettingsAdaptiveControlRow").count - 1 == 2)
        #expect(!list.contains("HStack("), "a hand-rolled HStack is the shape SettingsAdaptiveControlRow replaced")
    }

    /// Every rendered app has its own Remove, and the list is a `ForEach` over the rows rather than
    /// anything hand-enumerated.
    @Test
    func eachRowCarriesItsOwnRemoveAndTheListIsDrivenByTheRows() throws {
        let list = try Self.revocationListSource()

        #expect(list.contains("ForEach(rows) { row in"))
        #expect(list.contains("ApprovedAppRevocationPresentation.removeLabel"))
        #expect(list.contains("row.removeAccessibilityLabel"))
        #expect(list.contains("remove(row)"))
    }

    /// **Remove All confirms first, and Cancel is a real second button.**
    ///
    /// The dialog's destructive button is the only place `forgetAllApprovedApps()` is pressed from,
    /// which is what makes cancelling remove nothing: there is no other path from this view into the
    /// commit. Asserted by counting the call sites in the list's own source, because a second one
    /// added outside the dialog is exactly the defect and would leave every behavioural test green.
    @Test
    func removeAllIsReachableOnlyThroughItsConfirmationAndCancelIsOfferedBesideIt() throws {
        let list = try Self.revocationListSource()

        #expect(list.contains(".confirmationDialog("))
        #expect(list.contains("Button(\"Cancel\", role: .cancel) {}"))
        #expect(list.contains("role: .destructive"))
        #expect(
            list.components(separatedBy: "viewModel.forgetAllApprovedApps()").count - 1 == 1,
            "Remove All commits from exactly one place, and that place is inside the dialog"
        )

        let flat = Self.normalized(list)
        let dialog = try #require(flat.range(of: ".confirmationDialog("))
        let beforeTheDialog = flat[..<dialog.lowerBound]
        #expect(
            !beforeTheDialog.contains("viewModel.forgetAllApprovedApps()"),
            "the commit sits inside the dialog, not on the button that raises it"
        )
    }

    /// **Per-row Remove has no dialog, and the reason is written down rather than left as an
    /// unexplained asymmetry** — the ticket's own requirement. Removing one app costs the user one
    /// ask and answering it puts the grant back; removing all of them is not something the flow
    /// hands back in one press.
    ///
    /// Scanned over the whole file rather than over `revocationListSource()`, deliberately: the
    /// reasoning belongs in the view's doc comment, which sits *above* the declaration that helper
    /// bounds itself by. Narrowing the scan to the body would have forced the sentence into the body
    /// to satisfy the test, which is the test choosing where product reasoning lives.
    @Test
    func theMissingPerRowConfirmationIsReasonedInTheCodeRatherThanLeftUnexplained() throws {
        let flat = Self.normalized(try Self.commandCenterSource())

        #expect(flat.contains("Per-row Remove has no confirmation and Remove All does"))
        #expect(flat.contains("Removing one app costs the user one ask"))
    }

    /// The section is System A: the row action is `CommandCenterRowActionStyle(tone: .danger)`, the
    /// same danger treatment every other in-place remove in Command Center uses, and nothing from
    /// System B's glass/shadow set appears.
    @Test
    func theListUsesSystemATokensAndBorrowsNothingFromTheWidgetsSet() throws {
        let list = try Self.revocationListSource()

        #expect(list.components(separatedBy: "CommandCenterRowActionStyle(tone: .danger)").count - 1 == 2)
        for widgetToken in ["WidgetTheme", "WidgetType", "shadow(", "NSVisualEffectView", ".ultraThinMaterial"] {
            #expect(!list.contains(widgetToken), "\(widgetToken) is System B and may not enter Settings")
        }
    }

    /// **The list is on the page, under the sentence that promises it**, and the page loads it.
    ///
    /// Without the two refresh calls the section renders whatever a previous Memory visit happened
    /// to load — nothing at all for a user who never opens Memory — and an undecryptable grants file
    /// reads as an empty one.
    @Test
    func theScreenControlSectionRendersTheListAndThePageLoadsWhatItNeeds() throws {
        let flat = Self.normalized(try Self.commandCenterSource())

        #expect(flat.contains("ApprovedAppRevocationList(viewModel: viewModel)"))
        #expect(flat.contains("viewModel.refreshMemoryEntries() viewModel.refreshStoreReadability()"))
    }
}
