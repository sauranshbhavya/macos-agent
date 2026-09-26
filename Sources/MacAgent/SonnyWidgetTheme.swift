import AppKit
import SwiftUI

/// Real macOS vibrancy/blur — an `NSVisualEffectView` with `blendingMode: .behindWindow`, which
/// samples and blurs whatever is actually behind the window in real time (desktop wallpaper,
/// other windows). This is the actual mechanism behind every native "glass" surface on macOS
/// (Notification Center, Control Center, HUDs, Spotlight) — the previous implementation had no
/// real blur at all, only flat semi-transparent color layers with `.blendMode` tricks, which is
/// why it read as a dark smudge instead of glass: there was nothing real behind it to blend with.
/// `.hudWindow` is Apple's own always-dark vibrant material (the volume/brightness HUD's own
/// material) — the closest built-in match to a dark liquid-glass surface that doesn't adapt to
/// system light/dark mode, matching this design language being deliberately dark-only.
private struct WidgetVisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .hudWindow
        nsView.blendingMode = .behindWindow
        nsView.state = .active
        nsView.appearance = NSAppearance(named: .vibrantDark)
    }
}

// MARK: - System B tokens (floating widget only)
//
// Fully separate from System A (SonnyTheme/SonnyType/SonnyRadius in ContentView.swift). This is the
// only System B token set since 2026-09-08: RoutineDetailView's private copy went with the routine
// detail sheet's move onto System A (docs/sonny-ui-modernization-2026-09-08.md). Per
// docs/sonny-design-system-reference.md §3, do not extend SonnyTheme/SonnyType to serve this file,
// and do not reuse WidgetTheme/WidgetType outside the floating widget itself.

enum WidgetTheme {
    static let panelBase = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255)
    static let hairline = Color(red: 0xA6 / 255, green: 0xA6 / 255, blue: 0xA6 / 255)

    /// §3.1: per-action accents, not one universal accent — do not reuse SonnyTheme.accent here.
    static let primaryAction = Color(red: 0x00 / 255, green: 0x91 / 255, blue: 0xFF / 255)
    static let secondaryCircular = Color(red: 0xFF / 255, green: 0x92 / 255, blue: 0x30 / 255)
    static let allowAction = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let errorGlyph = Color(red: 0xFF / 255, green: 0x74 / 255, blue: 0x74 / 255)
    static let taskFailureRetry = Color(red: 0xFF / 255, green: 0x38 / 255, blue: 0x3C / 255)
    static let neutralButtonFill = Color(red: 0x99 / 255, green: 0x99 / 255, blue: 0x99 / 255).opacity(0.17)
    /// The voice-countdown's last-thirty-seconds colour (phase 11, the voice lane). Mirrors
    /// `SonnyTheme.warning`'s dark reading (`0xE8B84A`) — System B has no warning accent of its own
    /// and this is the one token this file adds for that reason, per the phase's own brief; every
    /// other System B colour is untouched.
    static let attention = Color(red: 0xE8 / 255, green: 0xB8 / 255, blue: 0x4A / 255)

    static let textFull = Color.white
    static let textMuted = Color.white.opacity(0.72)
    static let helperText = Color.white.opacity(0.78)
    /// The compact capsule's glyph and the file-preview chip's "Open" label — a step brighter than
    /// `textMuted`, short of full `textFull` (2026-09-08 modernization pass).
    static let textStrong = Color.white.opacity(0.92)
    /// The composer's wand glyph while the field is disabled — dimmer than `textMuted`, the
    /// composer withdrawing its invitation rather than merely muting it.
    static let textFaint = Color.white.opacity(0.28)
    static let privateModeOutline = Color.white.opacity(0.38)

    /// §3.1/§3.2's note: the authored Figma radius is genuinely 34, but on the fixed-height bar that
    /// exceeds half the height, so callers use `Capsule()` there rather than this literal value.
    static let panelRadius: CGFloat = 34

    /// The panel/pill's fixed width — one token so every frame that must match it (the panel, the
    /// composer pill, the mic hover hint row, a notice strip) reads the same source rather than
    /// repeating the literal (2026-09-08 modernization pass).
    static let panelWidth: CGFloat = 520
    static let composerHeight: CGFloat = 44
    static let composerEdgeInset: CGFloat = 8
    static let startButtonHeight: CGFloat = composerHeight - (composerEdgeInset * 2)
    static let satelliteControlSize: CGFloat = 40
    static let compactSize: CGFloat = 44
    static let composerMarkSize: CGFloat = 18
    /// The floor every circular/capsule control in the widget's panels grows to. Was a bare 23pt at
    /// seventeen call sites; 28 matches System A's own `SonnyMetrics.controlRegular` floor without
    /// importing that token, since System B may not reach into System A's set.
    static let controlSize: CGFloat = 28
    /// The corner radius on the Safe-mode capture-review thumbnail.
    static let thumbnailRadius: CGFloat = 8
    /// The corner radius on `WidgetNoticeStrip`.
    static let noticeRadius: CGFloat = 16
}

enum WidgetType {
    /// §3.1 calls out a recurring non-standard weight value, 510 — Apple's own "Medium" optical-
    /// weight instance in SF Pro's variable-font axis, distinct from the generic CSS 500. SwiftUI's
    /// `Font.Weight` has no matching custom numeric axis value to set directly, so `.medium`
    /// (SwiftUI's own closest built-in token) is used wherever §3.1 specifies 510.
    static let mediumWeight: Font.Weight = .medium

    /// SF Pro / SF Pro Display come from `design: .default` — that's already San Francisco on
    /// Apple platforms, so no custom font name needs registering (unlike System A's Inter, which
    /// is a bundled, non-system font loaded via `Font.custom`).
    static let pillQuery = Font.system(size: 13, weight: .regular, design: .default)
    static let body = Font.system(size: 12, weight: mediumWeight, design: .default)
    static let caption = Font.system(size: 13, weight: .regular, design: .default)
    static let captionMedium = Font.system(size: 13, weight: mediumWeight, design: .default)
    static let captionSmall = Font.system(size: 10, weight: mediumWeight, design: .default)
    static let headlineChip = Font.system(size: 10, weight: .bold, design: .default)
    /// Every standalone glyph in a row or a panel header, including the two warning triangles that
    /// sat at 11pt until 2026-09-08 and now share this 12 (a one-point change, made so one token
    /// covers the role).
    static let icon = Font.system(size: 12, weight: .regular, design: .default)
    /// The small glyph slot shared by the step-status and item-job icons — 10/11pt semibold literals
    /// consolidated onto one size (2026-09-08 modernization pass).
    static let iconSmall = Font.system(size: 10, weight: .semibold, design: .default)
    /// The compact capsule's glyph.
    static let iconLarge = Font.system(size: 14, weight: .medium, design: .default)
}

/// Native Liquid Glass on macOS 26 and later, with the real AppKit vibrancy material retained only
/// as the compatibility path for this package's macOS 14 deployment target.
private struct WidgetGlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(WidgetVisualEffectBackground().clipShape(shape))
                .overlay(shape.stroke(WidgetTheme.hairline.opacity(0.9), lineWidth: 1.25))
                .compositingGroup()
                .shadow(color: Color.black.opacity(0.22), radius: 6, x: 0, y: 3)
        }
    }
}

extension View {
    /// For the taller step-log / result / permission panels.
    func widgetGlassPanel() -> some View {
        modifier(WidgetGlassBackground(shape: RoundedRectangle(cornerRadius: WidgetTheme.panelRadius)))
    }

    /// For the fixed-height command pill — `Capsule()` per §3.1/§3.2's SwiftUI-clamping note.
    func widgetGlassPill() -> some View {
        modifier(WidgetGlassBackground(shape: Capsule()))
    }

    func widgetGlassCircle() -> some View {
        modifier(WidgetGlassBackground(shape: Circle()))
    }
}

/// Tinted-button chrome shared by the mic/retry/allow/deny/close/Start/Open buttons — circular for
/// icon-only buttons, capsule for the text+chevron "Start"/"Open" pills. `tint` is nil for the
/// untinted "Deny"-style variant (§3.1's neutral `rgba(153,153,153,.17)` fill, lighter shadow).
private struct WidgetTintedButtonBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    if let tint {
                        Color.white.opacity(0.94)
                        tint.blendMode(.plusDarker)
                    } else {
                        WidgetTheme.neutralButtonFill
                    }
                }
                .compositingGroup()
                .clipShape(shape)
            )
            .overlay(
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), .clear],
                            startPoint: .top,
                            endPoint: .center
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            // **Drawn, never clicked** (PR #237's third delta review, B). The gradient overlay above
            // already ignored hit testing and this hairline did not, so a stroke 0.5 pt wide, sitting
            // on top of every tinted widget button, took the clicks that landed on it and handed them
            // to nothing — SONNY-443's mic tracker at the scale of an outline. On the session's Stop
            // it was a dead ring exactly where a founder aims at the edge of a red circle. Ignoring
            // hit testing changes where clicks land and nothing that is drawn.
            .overlay(shape.stroke(WidgetTheme.hairline.opacity(0.6), lineWidth: 0.5).allowsHitTesting(false))
            .shadow(
                color: Color.black.opacity(tint == nil ? 0.04 : 0.45),
                radius: tint == nil ? 8 : 12,
                x: 0,
                y: tint == nil ? 4 : 6
            )
    }
}

extension View {
    func widgetCircularBackground(tint: Color? = nil) -> some View {
        modifier(WidgetTintedButtonBackground(shape: Circle(), tint: tint))
    }

    func widgetCapsuleBackground(tint: Color?) -> some View {
        modifier(WidgetTintedButtonBackground(shape: Capsule(), tint: tint))
    }
}

/// §3.3's 8-blade indeterminate spinner is, blade-for-blade, macOS's own native spinning progress
/// indicator — using the system one is both simpler and more literally accurate than hand-drawing
/// 8 rotating/fading blades.
struct WidgetSpinner: View {
    var tint: Color = .white

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.mini)
            .tint(tint)
            .frame(width: 12, height: 12)
    }
}
