import SwiftUI

/// The "more actions" menu a row keeps its secondary and destructive actions in: an ellipsis in a
/// circle, drawn as a small quiet control. A destructive item takes `role: .destructive` and still
/// confirms before it acts.
struct SonnyOverflowMenu<Content: View>: View {
    let accessibilityLabel: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(SonnyType.icon(SonnyMetrics.iconRow, weight: .medium))
                .foregroundStyle(SonnyTheme.muted)
                .frame(width: SonnyMetrics.controlSmall, height: SonnyMetrics.controlSmall)
                .contentShape(RoundedRectangle(cornerRadius: SonnyRadius.control))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .sonnyPointerCursor()
        .sonnyHoverHighlight(cornerRadius: SonnyRadius.control)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}
