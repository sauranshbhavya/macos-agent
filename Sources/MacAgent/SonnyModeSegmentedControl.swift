import MacAgentCore
import SwiftUI

/// The Safe | Normal | Power mode control, built to the founder's wireframe
/// (`docs/wireframes/15-SegmentedControl.svg`, 2026-08-14) literally: a 308×36 stadium whose
/// track is two layered white fills (2% on the pill shape + 7% full-bleed, clipped), a
/// full-height capsule for the selected segment in `#0091FF` with a 3.9% white overlay, 1×20
/// hairline dividers at 25% white between unselected neighbors only (the export shows no divider
/// beside the selection), and 13px labels at 85% white — pure white on the selected segment.
/// Type is System A's body token; the blue is this wireframe's own literal, not a System B token
/// import. The whites are the wireframe's dark reading; through `SonnyTheme.onSurface` they read
/// as blacks at the same opacities on the light appearance, which keeps the control's own
/// contrast without a second drawing of it.
struct SonnyModeSegmentedControl: View {
    @Binding var selection: AgentInteractionMode

    private static let controlWidth: CGFloat = 308
    private static let controlHeight: CGFloat = 36
    private static let dividerHeight: CGFloat = 20
    /// `#0091FF` from the SVG's selected-segment path. It coincides with System B's
    /// primary-action blue, but its source here is the founder's control wireframe — do not
    /// swap in `WidgetTheme`, whose tokens never leave the widget.
    private static let selectedFill = Color(red: 0x00 / 255, green: 0x91 / 255, blue: 0xFF / 255)

    private var modes: [AgentInteractionMode] { AgentInteractionMode.allCases }

    private var segmentWidth: CGFloat {
        Self.controlWidth / CGFloat(modes.count)
    }

    private var selectedIndex: Int {
        modes.firstIndex(of: selection) ?? 0
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(Self.selectedFill)
                .overlay(Capsule().fill(Color.white.opacity(0.0392157)))
                // The overlay stays white in both appearances: it sits on the blue capsule.
                .frame(width: segmentWidth, height: Self.controlHeight)
                .offset(x: CGFloat(selectedIndex) * segmentWidth)

            // Dividers sit between unselected neighbors only — the wireframe hides the
            // hairline wherever the selected capsule provides the edge.
            ForEach(1..<modes.count, id: \.self) { boundary in
                if selectedIndex != boundary, selectedIndex != boundary - 1 {
                    Rectangle()
                        .fill(SonnyTheme.onSurface(dark: 0.25, light: 0.25))
                        .frame(width: 1, height: Self.dividerHeight)
                        .offset(
                            x: CGFloat(boundary) * segmentWidth - 0.5,
                            y: (Self.controlHeight - Self.dividerHeight) / 2
                        )
                }
            }

            HStack(spacing: 0) {
                ForEach(modes, id: \.self) { mode in
                    Button {
                        selection = mode
                    } label: {
                        Text(mode.displayName)
                            .font(SonnyType.body)
                            .foregroundStyle(mode == selection ? SonnyTheme.textOnAccent : SonnyTheme.onSurface(dark: 0.85, light: 0.85))
                            .frame(width: segmentWidth, height: Self.controlHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .sonnyPointerCursor()
                    .accessibilityLabel("\(mode.displayName) mode")
                    .accessibilityAddTraits(mode == selection ? [.isSelected] : [])
                }
            }
        }
        .frame(width: Self.controlWidth, height: Self.controlHeight)
        .background(
            ZStack {
                Capsule().fill(SonnyTheme.onSurface(dark: 0.02, light: 0.02))
                Rectangle().fill(SonnyTheme.onSurface(dark: 0.07, light: 0.07))
            }
        )
        .clipShape(Capsule())
    }
}
