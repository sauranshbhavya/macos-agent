import SwiftUI

/// The run pill: the floating widget, minimised (SONNY-450).
///
/// System B, like the widget it stands in for — `WidgetTheme` glass through `widgetGlassPill()`,
/// SF Pro through `WidgetType`, the widget's own radii and shadows, and never a `SonnyTheme`
/// token (`.claude/rules/macagent-ui-conventions.md`'s two-system rule). One control: clicking
/// anywhere on the pill expands the widget, on whatever is parked, through
/// `AgentViewModel.expandWidgetFromPill()`. Nothing is answered here; the pill only says.
struct RunPillView: View {
    @ObservedObject var viewModel: AgentViewModel

    /// The widest the pill grows before its words truncate. `RunPillPresentation.wordLimit`
    /// already bounds the text; this is the belt for a wide glyph run.
    static let maxWidth: CGFloat = 320
    static let height: CGFloat = 36

    var body: some View {
        if let presentation = viewModel.runPillPresentation {
            Button(action: viewModel.expandWidgetFromPill) {
                HStack(spacing: 8) {
                    glyph(for: presentation)
                    Text(presentation.words)
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(WidgetTheme.textFull)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 14)
                .frame(height: Self.height)
                .frame(maxWidth: Self.maxWidth)
            }
            .buttonStyle(.plain)
            .widgetGlassPill()
            .accessibilityLabel(presentation.accessibilityLabel)
            .help(presentation.accessibilityLabel)
            // The same headroom the widget keeps around its glass, so the visible pill sits 16pt
            // in from the corner the window is flush with (`RunPillPlacement`).
            .padding(16)
            .fixedSize()
        }
    }

    /// The `WidgetTheme` colour for a presentation's tint: the widget's own action blue for a run
    /// in flight, its attention amber for a parked question, its allow green for a result and its
    /// error red for a failure — the same four the widget's panels use for the same four meanings.
    static func color(for tint: RunPillPresentation.Tint) -> Color {
        switch tint {
        case .action:
            return WidgetTheme.primaryAction
        case .attention:
            return WidgetTheme.attention
        case .allow:
            return WidgetTheme.allowAction
        case .error:
            return WidgetTheme.errorGlyph
        }
    }

    @ViewBuilder
    private func glyph(for presentation: RunPillPresentation) -> some View {
        if let glyph = presentation.glyph {
            Image(systemName: glyph)
                .font(WidgetType.iconLarge)
                .foregroundStyle(Self.color(for: presentation.tint))
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(Self.color(for: presentation.tint))
        }
    }
}
