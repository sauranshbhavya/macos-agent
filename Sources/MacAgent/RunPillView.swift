import SwiftUI

/// The run pill: the floating widget, minimised (SONNY-450).
///
/// System B, like the widget it stands in for — `WidgetTheme` glass, SF Pro through `WidgetType`,
/// the widget's own radii and shadows, and never a `SonnyTheme` token
/// (`.claude/rules/macagent-ui-conventions.md`'s two-system rule). Nothing is answered here; the
/// pill says, and — while Sonny is controlling an app — stops.
///
/// **Two shapes, and the difference is where the clicks go** (founder decision 2026-09-12 on PR
/// #237's F1). The ordinary pill is one control on the 40 pt pill's `Capsule` glass: clicking
/// anywhere on it expands the widget on whatever is parked, through
/// `AgentViewModel.expandWidgetFromPill()`. The controlling pill is the HUD relocated to the corner,
/// on the panel's rounded-rectangle glass because it is several rows tall, and it carries Pause and
/// Stop — so it is *not* wrapped in an outer button. A `Button` containing other buttons is the
/// click sink this repository has already paid for once: SONNY-443 shipped a hover tracker over the
/// mic that claimed every point in its bounds, and the founders' clicks on the button beneath went
/// nowhere while it still looked live. Here the identity row is its own button and each control is
/// its own button beside it.
///
/// **What checks that, and what it can see.** `RunPillControlsReceiveClicksTests` sends real mouse
/// events through a real `RunPillPanel` at every point of a grid and records which action each one
/// fires, so it tells the controls apart from the glass around them and from each other; its control
/// is SONNY-443's overlay, under which nothing fires at all. This suite's first version asked
/// `NSView.hitTest` instead, which answers the hosting view at every point of a SwiftUI window,
/// empty corner included — it could only ever say that no AppKit layer covered the window (PR #237's
/// delta review, N6). What neither can see is the window server's own handling of a first click on a
/// panel that cannot become key, which is a manual row's.
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
    static let verticalPadding: CGFloat = 12
    static let rowSpacing: CGFloat = 10
    /// The transparent headroom around the glass, the same the widget keeps, so the visible pill
    /// sits this far in from the corner the window is flush with (`RunPillPlacement`).
    static let windowMargin: CGFloat = 16
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
                RunPillGlyph(presentation: presentation)
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
        .padding(Self.windowMargin)
        .fixedSize()
    }

    // MARK: - The HUD, in the corner

    /// The controlling pill, wired to the view model. Every action it can take is one of the
    /// view model's three doors — expand, pause, emergency stop — and they are bound here and
    /// nowhere else, which is where `RunPillControlBindingTests` reads each one at its own site.
    @ViewBuilder
    private func controllingPill(
        _ presentation: RunPillPresentation,
        _ controlling: RunPillPresentation.Controlling
    ) -> some View {
        RunPillControllingContent(
            presentation: presentation,
            controlling: controlling,
            onExpand: viewModel.expandWidgetFromPill,
            onPause: viewModel.pauseVisionSession,
            onStop: viewModel.emergencyStopVisionSession
        )
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

}

/// The controlling pill's content: every clause of `WidgetControllingPanel`'s stated requirement, in
/// the corner — that Sonny is controlling something, which app, what it is doing right now, how far
/// in, Pause, Stop, and the line naming the key that works when the pointer is not the user's to aim.
///
/// **Its actions are handed in, the way `WidgetControllingPanel(progress:onPause:onStop:)` takes
/// them**, for the same reason: what a control *does* is the caller's, and a view that reaches into
/// the model for it cannot be asked which action a click at a given point fires. PR #237's delta
/// review showed that question matters here — swapping the actions behind Pause and Stop passed the
/// whole suite, and on a screen-control session a Stop that pauses is the worst wiring in the
/// product. `RunPillControlsReceiveClicksTests` hosts this view with recording actions and clicks it.
///
/// **The panel's glass shape, not the pill's** (PR #237's delta review, N3). This content is several
/// rows tall, and the 40 pt command pill's `Capsule` at that height has a corner radius of half the
/// height — so its edge cut through the cursor glyph at the top-left and the first key of the hotkey
/// line at the bottom-left. `widgetGlassPanel()` is the rounded rectangle the widget's own multi-row
/// panels use, and `RunPillControllingGlassTests` measures that every corner of the content sits
/// inside it.
///
/// What this does not carry is named in the changelog entry as a deliberate omission, citing the
/// founders' decision of 2026-09-12.
struct RunPillControllingContent: View {
    let presentation: RunPillPresentation
    let controlling: RunPillPresentation.Controlling
    let onExpand: () -> Void
    let onPause: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RunPillView.rowSpacing) {
            // The identity row expands the widget, and is the only part of this pill that does.
            Button(action: onExpand) {
                HStack(spacing: 8) {
                    RunPillGlyph(presentation: presentation)
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
                .lineLimit(RunPillView.actionLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(controlling.stepLine)
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.textMuted)
                    .lineLimit(1)

                Spacer(minLength: 8)

                WidgetSessionPauseButton(appDisplayName: controlling.appDisplayName, action: onPause)
                WidgetSessionStopButton(appDisplayName: controlling.appDisplayName, action: onStop)
            }

            // Said once and quietly, as the panel says it, from the one owner both read.
            Text(ScreenControlSessionPresentation.hotkeyLine)
                .font(WidgetType.captionSmall)
                .foregroundStyle(WidgetTheme.textMuted)
        }
        .padding(.horizontal, RunPillView.horizontalPadding)
        .padding(.vertical, RunPillView.verticalPadding)
        .frame(width: RunPillView.controllingWidth, alignment: .leading)
        .widgetGlassPanel()
        .padding(RunPillView.windowMargin)
        .fixedSize()
    }
}

/// The pill's glyph: an SF Symbol in its tint, or a spinner while an ordinary run is in flight.
struct RunPillGlyph: View {
    let presentation: RunPillPresentation

    var body: some View {
        if let glyph = presentation.glyph {
            Image(systemName: glyph)
                .font(WidgetType.iconLarge)
                .foregroundStyle(RunPillView.color(for: presentation.tint))
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(RunPillView.color(for: presentation.tint))
        }
    }
}
