import AppKit
import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// SONNY-441, PR #228's F1. The widget's result panel shows a summary on three lines at most, so
/// `FinderSelectionSummary`'s character budget is measured here against the panel's real width
/// and type with AppKit's own layout, over the name shapes macOS produces, rather than chosen.
///
/// TextKit's line fragments at the panel's text width are an estimate of SwiftUI's layout, not a
/// screenshot; the reviewer's measure of the pre-fix sentence used the same instrument and read
/// four lines where the panel showed an ellipsis. The panel's width, padding, line cap and font are
/// read from the source, so a change to any of them fails here rather than silently widening or
/// narrowing what the budget was measured against.
@Suite
struct FinderSelectionSentenceFitsTheWidgetTests {
    private static let padding: CGFloat = 18
    private static let pointSize: CGFloat = 13

    private static var textWidth: CGFloat { WidgetTheme.panelWidth - 2 * padding }

    private static func lines(of text: String) -> Int {
        let storage = NSTextStorage(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: pointSize, weight: .regular)]
        )
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var count = 0
        var glyph = 0
        while glyph < layout.numberOfGlyphs {
            var range = NSRange()
            _ = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            glyph = NSMaxRange(range)
            count += 1
        }
        return count
    }

    private static func names(_ shape: (Int) -> String, count: Int) -> [String] {
        (1...count).map(shape)
    }

    /// The panel's numbers, read from the source so the measurement below is against the panel
    /// that ships: the result panel caps its summary at three lines of `WidgetType.caption`, and
    /// the styled panel around it pads 18 pt inside `WidgetTheme.panelWidth`, 472 pt.
    @Test
    @MainActor
    func theMeasurementReadsThePanelThatShips() throws {
        let view = try MacAgentSource.read("FloatingWidgetView.swift")
        let result = try MacAgentSource.braceBlock(of: view, openedBy: "private struct WidgetResultPanel: View {")
        #expect(result.contains(".lineLimit(3)"))
        #expect(result.contains(".font(WidgetType.caption)"))
        let styled = try MacAgentSource.braceBlock(of: view, openedBy: "private var styledPanel: some View {")
        #expect(styled.contains(".padding(\(Int(Self.padding)))"))
        #expect(styled.contains(".frame(width: WidgetTheme.panelWidth"))
        let theme = try MacAgentSource.read("SonnyWidgetTheme.swift")
        #expect(theme.contains("static let caption = Font.system(size: \(Int(Self.pointSize)), weight: .regular, design: .default)"))
        #expect(WidgetTheme.panelWidth == 472)
    }

    /// Two, five, seven and fifty items in each of the name shapes the reviewer measured, and an
    /// all-capitals shape: every sentence lays out on three lines or fewer at the panel's width.
    ///
    /// **What the budget does not hold, measured rather than implied**: a name made only of the
    /// widest Latin glyphs (`MWMWMW…`, thirty-seven characters) reads five lines at the same
    /// budget (`wide × 5` and `× 7`, four at `× 50`, measured here at `44efacea`'s fix round).
    /// A character count is a proxy for a width in points; the count leading the sentence is what
    /// holds when the proxy does not, and the entry's Known limitations says so.
    @Test
    func theSentenceForLongLatinNamesLaysOutOnThreeLinesOrFewer() {
        let shapes: [(String, (Int) -> String)] = [
            ("screenshots", { "Screenshot 2026-09-11 at 09.14.0\($0).png" }),
            ("invoices", { "Invoice 2026-0\($0) Acme Holdings.pdf" }),
            ("uppercase", { "PROJECT PROPOSAL FINAL VERSION 2026 Q\($0).PDF" }),
        ]
        for (label, shape) in shapes {
            for count in [2, 5, 7, 50] {
                let sentence = FinderSelectionSummary.sentence(naming: Self.names(shape, count: count))
                let lines = Self.lines(of: sentence)
                #expect(lines <= 3, "\(label) × \(count): \(lines) lines for \(sentence)")
            }
        }
    }

    /// The count leads even where the proxy fails: the widest-glyph shape runs past three lines,
    /// and its sentence still opens with the total.
    @Test
    func theCountLeadsWhereTheBudgetDoesNotHoldTheLines() {
        let sentence = FinderSelectionSummary.sentence(naming: Self.names({ "MWMWMWMWMWMWMWMWMWMWMWMWMWMWMWMW\($0).MOV" }, count: 7))
        #expect(sentence.hasPrefix("7 selected in Finder: "))
        #expect(Self.lines(of: sentence) > 3)
    }

    /// The control that says the instrument can count past three: the pre-fix sentence for five
    /// screenshot names, which the reviewer measured at four lines, measures four here too.
    @Test
    func theInstrumentCountsThePreFixSentenceAtFourLines() {
        let preFix = "Selected in Finder: " + Self.names({ "Screenshot 2026-09-11 at 09.14.0\($0).png" }, count: 5).joined(separator: ", ") + ", and 2 more."
        #expect(Self.lines(of: preFix) == 4)
    }
}
