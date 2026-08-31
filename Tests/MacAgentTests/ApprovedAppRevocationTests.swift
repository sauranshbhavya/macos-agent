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

    // MARK: - Whether Remove All is offered, and the route it keeps open

    /// **The gate is on the store's count, not on the rendered list** (PR #175 review, F1).
    ///
    /// The pair that carries the whole finding: a file holding only grants the deny list refuses
    /// renders no rows, so a gate on the rendered list hides Remove All — and Remove All is then the
    /// one control that could have reached them. The first expectation is the positive control, so a
    /// filter that removed everything cannot make this pass as "no rows, correctly".
    @Test
    func removeAllIsOfferedWheneverTheStoreHoldsSomethingEvenWhenNoRowIsRendered() throws {
        let terminal = try #require(ScreenControlPolicy.terminalBundleIdentifiers.sorted().first)
        let stored = [Self.app(terminal, "A Terminal")]

        #expect(stored.count == 1)
        #expect(ApprovedAppRevocationPresentation.rows(for: stored).isEmpty)
        #expect(ApprovedAppRevocationPresentation.offersRemoveAll(storedGrantCount: stored.count))
    }

    /// The other direction, so the gate is not simply "always true": an empty store offers nothing.
    @Test
    func removeAllIsNotOfferedWhenTheStoreHoldsNothing() {
        #expect(!ApprovedAppRevocationPresentation.offersRemoveAll(storedGrantCount: 0))
        #expect(ApprovedAppRevocationPresentation.offersRemoveAll(storedGrantCount: 1))
    }

    /// The view reads the gate rather than re-deriving one, and reads it off the pre-filter count.
    @Test
    func theViewGatesRemoveAllOnTheStoresCountAndNotOnTheRenderedList() throws {
        let list = try Self.revocationListSource()

        #expect(list.contains("ApprovedAppRevocationPresentation.offersRemoveAll("))
        #expect(
            !list.contains("if !rows.isEmpty"),
            "gating on the rendered list is the defect PR #175's F1 is about"
        )
    }

    /// **Both readers of the store's count, checked at their own call sites** (found by this round's
    /// own battery, S3).
    ///
    /// The gate and the empty state each read `viewModel.storedApprovedAppCount`, and the scans above
    /// asked only whether the section *mentions* it — so a mutant that fed the empty state a literal
    /// zero, leaving the gate's own reading in place, passed the whole suite. A presence check over a
    /// string two call sites share cannot see one of them stop reading it. This slices each call and
    /// asks separately, and pins the count at two so a third reader arrives here rather than
    /// silently.
    @Test
    func bothTheGateAndTheEmptyStateReadTheStoresCountAtTheirOwnCallSites() throws {
        let list = try Self.revocationListSource()
        let token = "storedGrantCount: viewModel.storedApprovedAppCount"

        #expect(list.components(separatedBy: token).count - 1 == 2)
        #expect(try Self.callSite("ApprovedAppRevocationPresentation.emptyState(", in: list).contains(token))
        #expect(try Self.callSite("ApprovedAppRevocationPresentation.offersRemoveAll(", in: list).contains(token))
    }

    // MARK: - The two states that are not a list

    /// **Both arms, asserted** (PR #175 review, F4). The view picked icon, title and message with
    /// three separate ternaries and a mutant forcing all three to the empty arm survived the whole
    /// suite. One function, and both of its answers pinned.
    @Test
    func theEmptyAndUnreadableStatesAreDifferentInAllThreeFields() {
        let empty = ApprovedAppRevocationPresentation.emptyState(for: .readable, storedGrantCount: 0)
        let unreadable = ApprovedAppRevocationPresentation.emptyState(for: .unreadable, storedGrantCount: 0)

        #expect(empty.systemImage == ApprovedAppRevocationPresentation.emptySystemImage)
        #expect(empty.title == ApprovedAppRevocationPresentation.emptyTitle)
        #expect(empty.message == ApprovedAppRevocationPresentation.emptyMessage)

        #expect(unreadable.systemImage == ApprovedAppRevocationPresentation.unreadableSystemImage)
        #expect(unreadable.title == ApprovedAppRevocationPresentation.unreadableTitle)
        #expect(unreadable.message == ApprovedAppRevocationPresentation.unreadableMessage)

        #expect(empty.systemImage != unreadable.systemImage)
        #expect(empty.title != unreadable.title)
        #expect(empty.message != unreadable.message)
    }

    /// `.partlyUnreadable` cannot reach this list — it needs a count above zero and the empty state
    /// runs only at zero — and if it ever does it takes the unreadable arm, which is the conservative
    /// direction: a file that will not open is news and an empty list is not.
    @Test
    func theUnreachablePartlyUnreadableStateFailsTowardsTheNewsRatherThanTheSilence() {
        let partly = ApprovedAppRevocationPresentation.emptyState(for: .partlyUnreadable, storedGrantCount: 0)

        // **All three fields, like its sibling above** (PR #175 cycle 3, G5). `systemImage` was the
        // one this test did not assert, so a mutation of the icon alone would have lived here while
        // the battery's N1 — which changes all three at once — died either way.
        #expect(partly.systemImage == ApprovedAppRevocationPresentation.unreadableSystemImage)
        #expect(partly.title == ApprovedAppRevocationPresentation.unreadableTitle)
        #expect(partly.message == ApprovedAppRevocationPresentation.unreadableMessage)
    }

    /// **A store holding grants none of which can be rendered is neither empty nor unreadable**
    /// (PR #175 cycle 3, G2).
    ///
    /// It used to be shown the empty state, so a user whose allowed app had joined the terminal deny
    /// list in a release read "No allowed apps yet" above a sentence inviting them to allow an app
    /// that would not surface the one they had — both false — with Remove All beside it. The state is
    /// reachable by an ordinary release rather than by a hand-edited file: the deny list is
    /// extensible by design and has already grown once, the verdict is recomputed on every load, and
    /// the store never prunes.
    @Test
    func aStoreHoldingOnlyHiddenGrantsSaysSoRatherThanSayingItIsEmpty() {
        let held = ApprovedAppRevocationPresentation.emptyState(for: .readable, storedGrantCount: 1)
        let empty = ApprovedAppRevocationPresentation.emptyState(for: .readable, storedGrantCount: 0)
        let unreadable = ApprovedAppRevocationPresentation.emptyState(for: .unreadable, storedGrantCount: 0)

        #expect(held.title == ApprovedAppRevocationPresentation.heldButNotHonouredTitle)
        #expect(held.message == ApprovedAppRevocationPresentation.heldButNotHonouredMessage)
        #expect(held.systemImage == ApprovedAppRevocationPresentation.heldButNotHonouredSystemImage)

        // The two sentences it replaces, named so a revert to either fails here rather than in prose.
        #expect(held.title != empty.title)
        #expect(held.message != empty.message)
        #expect(held.title != unreadable.title)
        #expect(held.message != unreadable.message)

        // It names the control that ends the state, which is this repository's empty-state
        // convention and the whole reason the old copy was wrong: it named one that cannot.
        #expect(held.message.contains(ApprovedAppRevocationPresentation.removeAllLabel))
        #expect(!held.message.contains("will appear here"))
    }

    /// **An unreadable file is the bigger news and wins the ordering**, and its count is zero anyway.
    /// Asserted because the two arms are now chosen by two inputs rather than one.
    @Test
    func anUnreadableFileOutranksAHeldGrantInTheEmptyStatesOrdering() {
        let bothAtOnce = ApprovedAppRevocationPresentation.emptyState(for: .unreadable, storedGrantCount: 3)

        #expect(bothAtOnce.title == ApprovedAppRevocationPresentation.unreadableTitle)
        #expect(bothAtOnce.message == ApprovedAppRevocationPresentation.unreadableMessage)
    }

    /// The view calls the one function rather than re-deriving the choice per field.
    @Test
    func theViewAsksForTheWholeStateRatherThanTernaryingEachField() throws {
        let list = try Self.revocationListSource()

        #expect(list.contains("ApprovedAppRevocationPresentation.emptyState("))
        #expect(list.contains("for: readability,"))
        #expect(
            !list.contains("readability == .readable"),
            "a ternary per field is the shape whose swapped arm no test could see"
        )
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

    /// Whether any file in `Sources/MacAgent/` contains `token`.
    ///
    /// The positive control for the System A guard below: it forbids a set of System B tokens from
    /// this section, and a token the tree does not contain anywhere cannot appear here either, so
    /// forbidding it is a clean zero dressed as a check.
    private static func appSourcesContain(_ token: String) throws -> Bool {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = packageRoot.appendingPathComponent("Sources/MacAgent")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in names where name.hasSuffix(".swift") {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            if text.contains(token) {
                return true
            }
        }
        return false
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

    /// The body of one of the two views this section is built from, isolated from the rest of the
    /// file.
    ///
    /// **Bounded by the next declaration rather than by brace counting**, which a scan over SwiftUI
    /// cannot do reliably; a scan that silently read the whole file would pass on evidence from
    /// anywhere in six thousand lines. **A bound that matches nothing is a failure, not a fall back
    /// to the rest of the file** — the earlier version defaulted to `endIndex`, so the split of this
    /// section into two views would have silently widened every scan below instead of failing.
    private static func sectionSource(
        from declaration: String,
        until terminator: String
    ) throws -> String {
        let source = try commandCenterSource()
        let start = try #require(
            source.range(of: declaration),
            "\(declaration) is not in CommandCenterView.swift"
        )
        let rest = source[start.upperBound...]
        let end = try #require(
            rest.range(of: terminator),
            "the scan's end marker \(terminator) is gone, so this scan would have read the whole file"
        )
        return String(rest[..<end.lowerBound])
    }

    /// The text of one call, from its opening marker to the first character that closes it.
    ///
    /// Both bounds are required rather than defaulted, for the reason `sectionSource(from:until:)`
    /// gives: a scan that silently widens when its marker moves reports on text nobody asked about.
    private static func callSite(_ marker: String, in source: String) throws -> String {
        let start = try #require(source.range(of: marker), "\(marker) is not in this section")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: ")"), "the call opened by \(marker) is never closed")
        return String(rest[..<end.lowerBound])
    }

    /// The list: the heading row, Remove All and its dialog, the empty state, the `ForEach`.
    private static func revocationListSource() throws -> String {
        try sectionSource(
            from: "private struct ApprovedAppRevocationList: View {",
            until: "\n/// One allowed app and the Remove that takes it back"
        )
    }

    /// One row: the labels, its Remove, and the confirmation that press needs.
    private static func revocationRowSource() throws -> String {
        try sectionSource(
            from: "private struct ApprovedAppRevocationRow: View {",
            until: "\n/// Split out of Security & Access"
        )
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
        let row = try Self.revocationRowSource()

        // One each: the heading row carrying Remove All, and the per-app row.
        #expect(list.components(separatedBy: "SettingsAdaptiveControlRow").count - 1 == 1)
        #expect(row.components(separatedBy: "SettingsAdaptiveControlRow").count - 1 == 1)
        for (name, source) in [("the list", list), ("the row", row)] {
            #expect(
                !source.contains("HStack("),
                "\(name) hand-rolls an HStack, which is the shape SettingsAdaptiveControlRow replaced"
            )
        }
    }

    /// Every rendered app has its own Remove, and the list is a `ForEach` over the rows rather than
    /// anything hand-enumerated.
    @Test
    func eachRowCarriesItsOwnRemoveAndTheListIsDrivenByTheRows() throws {
        let list = try Self.revocationListSource()
        let row = try Self.revocationRowSource()

        #expect(list.contains("ForEach(rows) { row in"))
        #expect(list.contains("remove(row)"))
        #expect(row.contains("ApprovedAppRevocationPresentation.removeLabel"))
        #expect(row.contains("row.removeAccessibilityLabel"))
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
    /// **Per-row Remove confirms, like every other row delete in Command Center** (PR #175 review,
    /// F2). It shipped as a single press, which contradicted an invariant written in this same file
    /// — *nothing else in the app deletes a row on one press* — that names a revoked app grant as its
    /// own example of an unrecoverable misclick.
    ///
    /// The commit is reachable only through the dialog's destructive button, which is what makes
    /// cancelling remove nothing: the row's own Remove raises the dialog and does not commit. Counted
    /// rather than eyeballed, because a second call site added outside the dialog is exactly the
    /// defect and would leave every behavioural test green.
    @Test
    func perRowRemoveConfirmsFirstAndCommitsOnlyFromInsideItsDialog() throws {
        let row = try Self.revocationRowSource()

        #expect(row.contains(".confirmationDialog("))
        #expect(row.contains("Button(\"Cancel\", role: .cancel) {}"))
        // Twice: the stored closure, and the one place it is called — the dialog's destructive
        // button. A third occurrence is a second commit path, which is the defect.
        #expect(row.components(separatedBy: "onRemove").count - 1 == 2)

        let flat = Self.normalized(row)
        let dialog = try #require(flat.range(of: ".confirmationDialog("))
        #expect(
            !flat[..<dialog.lowerBound].contains("action: onRemove"),
            "the commit sits inside the dialog, not on the button that raises it"
        )
        #expect(flat[..<dialog.lowerBound].contains("showRemoveConfirmation = true"))
    }

    /// **The invariant this branch broke and now honours, quoted from the file that states it.**
    ///
    /// It is asserted here rather than trusted because the whole failure was that the ticket's
    /// premise — per-row Remove is reversible so it needs no dialog — was written four days before
    /// the invariant landed and was implemented from its letter anyway. A test that reads both means
    /// a future branch cannot re-open the same gap on this row without seeing the rule.
    @Test
    func commandCentersOwnRuleThatNothingDeletesARowOnOnePressStillCoversThisRow() throws {
        let flat = Self.normalized(try Self.commandCenterSource())

        #expect(flat.contains("nothing else in the app deletes a row on one press"))
        #expect(flat.contains("a revoked app grant"))
        // And the reason the branch's original argument was wrong, recorded where the copy lives.
        #expect(
            Self.normalized(
                try String(
                    contentsOf: URL(fileURLWithPath: #filePath)
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .appendingPathComponent("Sources/MacAgent/ApprovedAppRevocationPresentation.swift"),
                    encoding: .utf8
                )
            ).contains("stops that session")
        )
    }

    /// **Neither control is disabled while a task runs, and the reasoning is written down** (PR #175
    /// review, F3). Per-row Remove cannot be gated — removing the app a session is controlling is how
    /// a user stops that session, which is this ticket's acceptance criterion — and Remove All follows
    /// it rather than splitting one section into two answers.
    ///
    /// Asserted as an absence *plus* its recorded reason, because an unexplained absence is exactly
    /// what F2 caught: the scan below would pass just as well on a branch that had never thought
    /// about it, so the sentence is what distinguishes the two.
    @Test
    func neitherControlIsRunGatedAndTheAnswerIsRecordedRatherThanLeftAsAnAbsence() throws {
        let list = try Self.revocationListSource()
        let row = try Self.revocationRowSource()
        let flat = Self.normalized(try Self.commandCenterSource())

        #expect(!list.contains(".disabled(viewModel.isRunning)"))
        #expect(!row.contains(".disabled("))
        #expect(flat.contains("Neither control is disabled while a task runs."))
        // **The disproved leg is recorded as disproved, not deleted** (PR #175 cycle 3, G6). The
        // first version of this assertion read the argument that removing the app is *how* a user
        // stops a session — which F2's own confirmation, the emergency-stop hotkey and the Memory
        // section's ungated door between them falsified. A scan that still demanded that sentence
        // would pin the branch to a premise this review disproved.
        #expect(flat.contains("That leg does not hold and is recorded here rather than quietly dropped"))
        #expect(flat.contains("gating both controls was always available"))
        #expect(flat.contains("two answers to one question about one store"))
    }

    /// The section is System A: the row action is `CommandCenterRowActionStyle(tone: .danger)`, the
    /// same danger treatment every other in-place remove in Command Center uses, and nothing from
    /// System B's glass/shadow set appears.
    ///
    /// **The forbidden set is only the tokens the tree actually holds** (PR #175 review, F6). It
    /// included `.ultraThinMaterial`, which appears nowhere in `Sources/` and never has — a negative
    /// assertion over a string that cannot occur is a clean zero that reads like a guard. Every entry
    /// below is checked against a positive control first, in this test, so the set cannot go vacuous
    /// again without failing.
    @Test
    func theListUsesSystemATokensAndBorrowsNothingFromTheWidgetsSet() throws {
        let list = try Self.revocationListSource()
        let row = try Self.revocationRowSource()

        #expect(list.components(separatedBy: "CommandCenterRowActionStyle(tone: .danger)").count - 1 == 1)
        #expect(row.components(separatedBy: "CommandCenterRowActionStyle(tone: .danger)").count - 1 == 1)
        for widgetToken in ["WidgetTheme", "WidgetType", "shadow(", "NSVisualEffectView"] {
            // The positive control: a token the tree has never held is a guard about nothing.
            #expect(
                try Self.appSourcesContain(widgetToken),
                "\(widgetToken) is nowhere in Sources/MacAgent, so forbidding it here proves nothing"
            )
            #expect(!list.contains(widgetToken), "\(widgetToken) is System B and may not enter Settings")
            #expect(!row.contains(widgetToken), "\(widgetToken) is System B and may not enter Settings")
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
