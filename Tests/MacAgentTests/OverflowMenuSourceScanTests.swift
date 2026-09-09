import Foundation
import Testing
@testable import MacAgent

/// The overflow lane's move of Delete — and, on the workspace card, Mark as team — off three rows'
/// faces and into `SonnyOverflowMenu` (founder ask, 2026-09-09: "Hamburger menu for all the extra
/// fields in workspaces and memory especially for destructive actions like delete. Answered
/// 2026-09-09: an ellipsis in a circle, the Mac convention; Delete moves into it in red, still
/// confirmed; the main action stays a visible button.").
///
/// This repository has no SwiftUI inspection harness, so what shipped is read from the source the
/// way every other structural property in this file is scanned — `MacAgentSource`'s brace-block
/// extraction, with both comment syntaxes already stripped (see that type's own doc comment for why
/// a scan any comment could satisfy holds nothing).
@MainActor
@Suite
struct OverflowMenuSourceScanTests {
    @Test
    func theWorkspaceCardHoldsExactlyOneOverflowMenuAndNoDangerButtonOnItsFace() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let card = try MacAgentSource.braceBlock(of: source, openedBy: "private struct WorkspaceCard: View {")
        // The two moved actions keep the disabled predicate the buttons had, inside the menu, and
        // a label that names the workspace, as the buttons did (phase 11 review, F1, F2 and F5).
        let menu = try MacAgentSource.braceBlock(
            of: card,
            openedBy: "SonnyOverflowMenu(accessibilityLabel: presentation.moreActionsAccessibilityLabel) {"
        )
        #expect(menu.components(separatedBy: ".disabled(isTaskInFlight)").count - 1 == 2)
        #expect(menu.contains(".accessibilityLabel(\"Mark \\(presentation.name) as a team workspace\")"))
        #expect(menu.contains(".accessibilityLabel(\"Delete \\(presentation.name)\")"))

        // One menu, counted rather than merely found present — a second one added later without
        // updating this test would otherwise read as the same clean pass.
        #expect(card.components(separatedBy: "SonnyOverflowMenu(").count - 1 == 1)
        // Open and New task keep their tones; the danger tone that used to sit on the card's own
        // Delete button is gone from the region entirely now that it dispatches through the menu.
        #expect(!card.contains("tone: .danger"))
        #expect(card.contains("Delete workspace"))
        #expect(card.contains("role: .destructive"))
        // The confirmation dialog Delete used to open stays, unmoved, with its existing message.
        #expect(card.contains("This deletes its saved apps and URLs. Past task history mentioning this workspace is not deleted."))
    }

    /// `teamTypeRow`'s solo branch used to carry its own "Mark as team" button; it now keeps only
    /// the label text, and the affordance lives in the card's overflow menu instead (asserted
    /// above by the menu holding `markAsTeam` below).
    @Test
    func theSoloTeamTypeRowKeepsOnlyItsLabelText() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let card = try MacAgentSource.braceBlock(of: source, openedBy: "private struct WorkspaceCard: View {")
        let teamTypeRow = try MacAgentSource.braceBlock(of: card, openedBy: "private var teamTypeRow: some View {")

        #expect(teamTypeRow.contains("Text(\"Just you\")"))
        #expect(!teamTypeRow.contains("Mark as team"))
        #expect(!teamTypeRow.contains("Button(action: markAsTeam)"))
        // The affordance moved rather than vanished: the card's body dispatches it from the menu.
        #expect(card.contains("Button(action: markAsTeam)"))
    }

    @Test
    func theMemoryRowHoldsExactlyOneOverflowMenuAndNoDangerButton() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let row = try MacAgentSource.braceBlock(of: source, openedBy: "private struct MemoryRow: View {")

        #expect(row.components(separatedBy: "SonnyOverflowMenu(").count - 1 == 1)
        #expect(!row.contains("tone: .danger"))
        #expect(row.contains("Button(\"Delete\", role: .destructive, action: delete)"))
        // The disabled predicate SONNY-239 built travels with the button into the menu unchanged,
        // asserted as the adjacent pair so it cannot be satisfied by that predicate on some other
        // control in the row (phase 11 review, F6).
        #expect(row.contains(
            "Button(\"Delete\", role: .destructive, action: delete)\n                    .disabled(!presentation.canDelete)"
        ))
        #expect(row.contains(".accessibilityLabel(\"Delete \\(presentation.title)\")"))
    }

    @Test
    func theMemoryEntryRowHoldsExactlyOneOverflowMenuAndNoDangerButton() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let row = try MacAgentSource.braceBlock(of: source, openedBy: "private struct MemoryEntryRow: View {")

        #expect(row.components(separatedBy: "SonnyOverflowMenu(").count - 1 == 1)
        #expect(!row.contains("tone: .danger"))
        #expect(row.contains("Button(\"Delete\", role: .destructive, action: delete)"))
        #expect(row.contains(".accessibilityLabel(\"Delete \\(entry.title)\")"))
        // Continue is unaffected by the move — still its own visible button, still secondary tone.
        #expect(row.contains("tone: .secondary, size: .small"))
    }

    /// The per-entry Remove controls this lane deliberately left alone, so a future scan of "every
    /// danger button moved into a menu" does not silently widen to cover them. Recorded here as a
    /// scoped positive control rather than only in the lane's report: `WorkspaceDetailView`'s
    /// `entryRow` and `ApprovedAppRevocationRow` are per-entry removes inside an editor list, not a
    /// card or row action, and stay on their own buttons (overflow lane decision, 2026-09-09).
    @Test
    func theEditorListRemovesTheOverflowLaneLeftAloneStillStandOnTheirOwnButtons() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let entryRow = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "private func entryRow(_ entry: WorkspaceScopeEntryPresentation) -> some View {"
        )
        #expect(!entryRow.contains("SonnyOverflowMenu("))
        #expect(entryRow.contains("Label(\"Remove\", systemImage: \"minus\")"))

        let revocationRow = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "private struct ApprovedAppRevocationRow: View {"
        )
        #expect(!revocationRow.contains("SonnyOverflowMenu("))
        #expect(revocationRow.contains("SonnyButtonStyle(tone: .danger, size: .small)"))
    }

    /// Positive control for the "no `tone: .danger` button" assertions above — the token has to
    /// exist somewhere in the tree, or its absence from these two rewritten regions proves nothing
    /// (CLAUDE.md's clean-zero family: a search that cannot produce a hit has not been tested).
    @Test
    func toneDangerStillExistsElsewhereInTheAppSoItsAbsenceFromTheRewrittenRowsIsMeaningful() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        #expect(source.contains("tone: .danger"))
        #expect(source.contains("SonnyOverflowMenu("))
    }
}
