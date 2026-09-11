import Foundation
import Testing
@testable import MacAgent

/// Founder ask (2026-09-10): "when I hover over a particular routine, the gray color which appears
/// upon hovering is too tight and has no proper margin between itself and the text."
///
/// The fix, everywhere this phase touches, is one of two shapes already proven elsewhere in this
/// file (`TaskHistoryRow`, `WorkspaceBreakdownRow`): an inner horizontal padding smaller than the
/// row's own inset by `SonnySpacing.sm`, then `.sonnyHoverHighlight(`, then an outer padding that
/// restores the difference — so the highlight floats clear of the text and clear of the row's own
/// edges, while the text keeps sitting exactly where it always did. **Counting rather than
/// `contains`, and checking index order rather than mere presence**, per this file's own scan
/// doctrine (`MacAgentSourceScan.swift`'s header): a mutant that moves the highlight back outside the
/// padding pair, or drops one padding literal, leaves every substring still present in the block —
/// only the order between them changes.
@Suite
@MainActor
struct HoverInsetSourceScanTests {
    // MARK: - Rows converted to the split-inset shape

    /// `RoutineRow` used to apply `.sonnyHoverHighlight` directly to its content, before the row's
    /// own `xl` outer padding — so the fill hugged the icon tile, the title and the badges with no
    /// margin at all. Converted to the same split `TaskHistoryRow` already uses: inner `xl - sm`,
    /// highlight, outer `sm`, so the text keeps its usual `xl` inset while the fill floats `sm` clear
    /// of the row's true edge on each side.
    @Test
    func routineRowsHighlightSitsBetweenASplitInsetPaddingPair() throws {
        let row = try MacAgentSource.braceBlock(
            of: try MacAgentSource.read("CommandCenterView.swift"),
            openedBy: "private struct RoutineRow: View {"
        )
        // Order: inner inset, then the highlight, then the outer inset restoring `xl` — the
        // `TaskHistoryRow` order.
        try Self.assertOrder(
            [
                ".padding(.horizontal, SonnySpacing.xl - SonnySpacing.sm)",
                ".sonnyHoverHighlight(cornerRadius: SonnyRadius.control)",
                ".padding(.horizontal, SonnySpacing.sm)"
            ],
            in: row
        )
    }

    /// `JumpToPaletteRow`'s highlight used to wrap the Button exactly at the Button's own `lg`-inset
    /// size — no margin beyond that, so the fill reached all the way to the palette dialog's true
    /// edges (the LazyVStack around these rows carries no horizontal padding of its own). Converted
    /// the same way, at this row's own `lg` inset rather than `xl`.
    @Test
    func jumpToPaletteRowsHighlightSitsBetweenASplitInsetPaddingPair() throws {
        let row = try MacAgentSource.braceBlock(
            of: try MacAgentSource.read("JumpToPaletteView.swift"),
            openedBy: "private struct JumpToPaletteRow: View {"
        )
        try Self.assertOrder(
            [
                ".padding(.horizontal, SonnySpacing.lg - SonnySpacing.sm)",
                ".sonnyHoverHighlight()",
                ".padding(.horizontal, SonnySpacing.sm)"
            ],
            in: row
        )
    }

    // MARK: - Rows already on the sibling shape, pinned so they cannot regress

    /// `WorkspaceBreakdownRow` already uses the sibling shape (`sm` padded in around the content,
    /// then `-sm` after the highlight to give it room to float without changing the row's own
    /// layout width). Nothing to convert; pinned so a future edit cannot collapse it back to a bare
    /// `.sonnyHoverHighlight` with no surrounding pair.
    @Test
    func workspaceBreakdownRowKeepsItsSiblingInsetShape() throws {
        let row = try MacAgentSource.braceBlock(
            of: try MacAgentSource.read("CommandCenterView.swift"),
            openedBy: "private struct WorkspaceBreakdownRow: View {"
        )
        // Order: inner `sm` (inside the Button, growing the box), then the outer `-sm` (on the
        // Button itself, giving the layout its original width back), then the highlight — the
        // negative padding has to land *before* the highlight or the highlight would match the
        // row's original, un-grown size instead of the floated one.
        try Self.assertOrder(
            [
                ".padding(.horizontal, SonnySpacing.sm)",
                ".padding(.horizontal, -SonnySpacing.sm)",
                ".sonnyHoverHighlight(cornerRadius: SonnyRadius.control)"
            ],
            in: row
        )
    }

    /// `InsightsRecentActivityRow`: the same sibling shape, same reason.
    @Test
    func insightsRecentActivityRowKeepsItsSiblingInsetShape() throws {
        let row = try MacAgentSource.braceBlock(
            of: try MacAgentSource.read("CommandCenterView.swift"),
            openedBy: "private struct InsightsRecentActivityRow: View {"
        )
        try Self.assertOrder(
            [
                ".padding(.horizontal, SonnySpacing.sm)",
                ".padding(.horizontal, -SonnySpacing.sm)",
                ".sonnyHoverHighlight(cornerRadius: SonnyRadius.control)"
            ],
            in: row
        )
    }

    // MARK: - Rows left alone, by a stated decision rather than an oversight

    /// `StandingWatcherRow` gets no whole-row highlight, by decision (2026-09-10): unlike
    /// `RoutineRow`, nothing about the row itself opens anything — there is no `openDetail`, no tap
    /// gesture, no pointer cursor — only its own "Stop" button does something, and that button
    /// already has `SonnyButtonStyle`'s own hover. A whole-row glow with no press behind it would be
    /// an affordance the founder did not ask for, so this pins the row carries none rather than
    /// adding one silently.
    @Test
    func standingWatcherRowCarriesNoWholeRowHighlight() throws {
        let row = try MacAgentSource.braceBlock(
            of: try MacAgentSource.read("CommandCenterView.swift"),
            openedBy: "private struct StandingWatcherRow: View {"
        )
        #expect(MacAgentSource.count(of: ".sonnyHoverHighlight(", inText: row) == 0)
    }

    /// `SettingsDialogView`'s sidebar rows already have air on both sides: `sm` between the text and
    /// the fill (this row's own inner padding), and `md` between the fill and the sidebar's true
    /// edge (`settingsSidebar`'s own outer padding, wrapping every row). Nothing to convert; pinned
    /// so removing that outer wrap does not silently reopen the edge-to-edge fill this phase is
    /// about.
    @Test
    func settingsSidebarRowsKeepTheOuterInsetTheirHighlightReliesOn() throws {
        let sidebar = try MacAgentSource.braceBlock(
            of: try MacAgentSource.read("CommandCenterView.swift"),
            openedBy: "private var settingsSidebar: some View {"
        )
        #expect(MacAgentSource.count(of: ".sonnyHoverHighlight()", inText: sidebar) == 1)
        #expect(MacAgentSource.count(of: ".padding(.horizontal, SonnySpacing.md)", inText: sidebar) == 1)
    }

    /// `CommandCenterGroupHeader`'s disclosure toggle is a full-width band matching its own
    /// always-visible `surfaceRaised` background and divider — not a floating row. Its highlight
    /// already reaches past the text by the header's whole `xl` inset on each side, the opposite of
    /// tight, so this phase leaves it as designed. Pinned so a future edit does not narrow it into a
    /// floating chip, which would then sit oddly inside a background and a divider that still span
    /// the full width.
    @Test
    func groupHeaderDisclosureHighlightStaysTheFullWidthBand() throws {
        let header = try MacAgentSource.braceBlock(
            of: try MacAgentSource.read("CommandCenterView.swift"),
            openedBy: "private struct CommandCenterGroupHeader: View {"
        )
        #expect(MacAgentSource.count(of: ".sonnyHoverHighlight(cornerRadius: 0)", inText: header) == 1)
    }

    // MARK: - Shape assertion

    /// Every literal present is not enough — a mutant that reorders the pair, or moves the
    /// highlight outside it, leaves every substring here still in the text. This walks the given
    /// literals and requires each one to occur strictly after the previous one ends, so it is the
    /// *order* that is pinned, not mere containment.
    private static func assertOrder(_ literalsInOrder: [String], in block: String) throws {
        var searchStart = block.startIndex
        for literal in literalsInOrder {
            let range = try #require(
                block.range(of: literal, range: searchStart..<block.endIndex),
                "expected next, in order, after position \(block.distance(from: block.startIndex, to: searchStart)): \(literal)"
            )
            searchStart = range.upperBound
        }
    }
}
