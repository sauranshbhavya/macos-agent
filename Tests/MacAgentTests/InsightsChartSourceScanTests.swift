import Testing
@testable import MacAgent

/// The weekly chart's hover pill and the bento row it sits in (phase 12 of ui-ux-claude), pinned by
/// source scan since Insights has no view test: the wiring from the column to the presentation's
/// wording, the headroom the pill needs above the bars, the inward lean at the ends of the week,
/// and both cards of the row being flexible in height.
@MainActor
@Suite
struct InsightsChartSourceScanTests {
    @Test
    func theChartWiresItsCountWordingReservesHeadroomAndLeansTheEndPillsInward() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let chart = try MacAgentSource.braceBlock(of: source, openedBy: "private struct WeeklyCompletionChart: View {")

        #expect(chart.components(separatedBy: ".accessibilityValue(WeeklyCompletionChartPresentation.countLabel(for:").count - 1 == 1)
        #expect(chart.contains(".padding(.top, SonnyMetrics.controlRegular)"))
        #expect(chart.contains(".overlay(alignment: pillAlignment(for: index))"))
        #expect(chart.contains("if index == 0 { return .topLeading }"))
        #expect(chart.contains("if index == days.count - 1 { return .topTrailing }"))
        #expect(chart.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"))
    }

    /// The breakdown panel is flexible too, so the row's height is the taller card's whichever it is.
    @Test
    func theBreakdownPanelIsFlexibleInHeightLikeTheChart() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let panel = try MacAgentSource.braceBlock(of: source, openedBy: "private struct WorkspaceBreakdownPanel: View {")
        #expect(panel.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"))
    }
}
