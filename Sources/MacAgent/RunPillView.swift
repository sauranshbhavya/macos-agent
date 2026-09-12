import SwiftUI

/// The run pill: the floating widget, minimised (SONNY-450).
///
/// System B, like the widget it stands in for — `WidgetTheme` glass through `widgetGlassPill()`,
/// SF Pro through `WidgetType`, the widget's own radii and shadows, and never a `SonnyTheme`
/// token (`.claude/rules/macagent-ui-conventions.md`'s two-system rule). Nothing is answered here;
/// the pill says, and — while Sonny is controlling an app — stops.
///
/// **Two shapes, and the difference is where the clicks go** (founder decision 2026-09-12 on PR
/// #237's F1). The ordinary pill is one control: clicking anywhere on it expands the widget on
/// whatever is parked, through `AgentViewModel.expandWidgetFromPill()`. The controlling pill is
/// the HUD relocated to the corner, so it carries Pause and Stop — and therefore it is *not*
/// wrapped in an outer button. A `Button` containing other buttons is the click sink this
/// repository has already paid for once: SONNY-443 shipped a hover tracker over the mic that
/// claimed every point in its bounds, and the founders' clicks on the button beneath went
/// nowhere while it still looked live. Here the informational column is its own button and each
/// control is its own button beside it, so no layer sits over a control.
/// `RunPillControlsReceiveClicksTests` asks AppKit's own hit-testing where a click at each
/// control's centre actually lands, against a control that reproduces the sink.
struct RunPillView: View {
    @ObservedObject var viewModel: AgentViewModel

    /// The widest the ordinary pill grows before its words truncate. `RunPillPresentation.wordLimit`
    /// already bounds the text; this is the belt for a wide glyph run.
    static let maxWidth: CGFloat = 320
    static let height: CGFloat = 36

    /// The controlling pill's fixed width. Fixed rather than fitted because the action line changes
    /// every iteration and a pill that resized under the user's eye each time Sonny moved the
    /// cursor would be its own distraction. `RunPillControllingLayoutTests` measures
    /// `RunPillPresentation.actionLimit` against this width with AppKit's own text layout.
    static let controllingWidth: CGFloat = 340
    static let horizontalPadding: CGFloat = 14
    /// How many lines the action line is allowed. The layout test asserts the budget fits it.
    static let actionLineLimit = 2

    var body: some View {
        if let presentation = viewModel.runPillPresentation {
            if let controlling = presentation.controlling {
                controllingPill(presentation, controlling)
            } else {
                compactPill(presentation)
            }
        }
    }

    // MARK: - The ordinary pill

    @ViewBuilder
    private func compactPill(_ presentation: RunPillPresentation) -> some View {
        Button(action: viewModel.expandWidgetFromPill) {
            HStack(spacing: 8) {
                glyph(for: presentation)
                Text(presentation.words)
                    .font(WidgetType.captionMedium)
                    .foregroundStyle(WidgetTheme.textFull)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, Self.horizontalPadding)
            .frame(height: Self.height)
            .frame(maxWidth: Self.maxWidth)
        }
        .buttonStyle(.plain)
        .widgetGlassPill()
        .accessibilityLabel(presentation.accessibilityLabel)
        .help(presentation.tooltip)
        // The same headroom the widget keeps around its glass, so the visible pill sits 16pt
        // in from the corner the window is flush with (`RunPillPlacement`).
        .padding(16)
        .fixedSize()
    }

    // MARK: - The HUD, in the corner

    /// Every clause of `WidgetControllingPanel`'s stated requirement, in the corner: that Sonny is
    /// controlling something, which app, what it is doing right now, how far in, Pause, Stop, and
    /// the line naming the key that works when the pointer is not the user's to aim.
    ///
    /// The rows are the panel's rows in the panel's order, at the pill's width. What is not here is
    /// named in the changelog entry as a deliberate omission rather than dropped quietly.
    @ViewBuilder
    private func controllingPill(
        _ presentation: RunPillPresentation,
        _ controlling: RunPillPresentation.Controlling
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // The identity row expands the widget, and is the only part of this pill that does.
            // A click here is the same summon the ordinary pill's click is.
            Button(action: viewModel.expandWidgetFromPill) {
                HStack(spacing: 8) {
                    glyph(for: presentation)
                    Text(presentation.words)
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(WidgetTheme.textFull)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(presentation.accessibilityLabel)
            .help(presentation.tooltip)

            Text(controlling.currentAction)
                .font(WidgetType.captionSmall)
                .foregroundStyle(WidgetTheme.textMuted)
                .lineLimit(Self.actionLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(controlling.stepLine)
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.textMuted)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button(action: viewModel.pauseVisionSession) {
                    Text(controlling.pauseLabel)
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(WidgetTheme.textFull)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: WidgetTheme.controlSize)
                .widgetCircularBackground()
                .accessibilityLabel(controlling.pauseAccessibilityLabel)

                Button(action: viewModel.emergencyStopVisionSession) {
                    Text(controlling.stopLabel)
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: WidgetTheme.controlSize)
                .widgetCircularBackground(tint: WidgetTheme.errorGlyph)
                .accessibilityLabel(controlling.stopAccessibilityLabel)
            }

            // Said once and quietly, as the panel says it: during a session the pointer is not the
            // user's to aim, so the keyboard is the one input path reliably theirs — and a control
            // nobody knows about is not a control.
            Text(controlling.hotkeyLine)
                .font(WidgetType.captionSmall)
                .foregroundStyle(WidgetTheme.textMuted)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 12)
        .frame(width: Self.controllingWidth, alignment: .leading)
        .widgetGlassPill()
        .padding(16)
        .fixedSize()
    }

    /// The `WidgetTheme` colour for a presentation's tint: the widget's own action blue for a run
    /// in flight, the identity line's amber while Sonny controls an app, its attention amber for a
    /// parked question, its allow green for a result and its error red for a failure — the same
    /// colours the widget's panels use for the same meanings.
    static func color(for tint: RunPillPresentation.Tint) -> Color {
        switch tint {
        case .action:
            return WidgetTheme.primaryAction
        case .controlling:
            return WidgetTheme.secondaryCircular
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
