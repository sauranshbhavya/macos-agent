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
// Fully separate from System A (SonnyTheme/SonnyType/SonnyRadius in ContentView.swift) and also
// separate from RoutineDetailView's own System B token set — per this project's explicit decision,
// RoutineDetailView keeps its own hand-written copy rather than sharing this one. Per
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

    static let textFull = Color.white
    static let textMuted = Color.white.opacity(0.55)

    /// §3.1/§3.2's note: the authored Figma radius is genuinely 34, but on a fixed 40pt-tall bar
    /// that exceeds half the height, so callers use `Capsule()` there rather than this literal value.
    static let panelRadius: CGFloat = 34
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
    static let icon = Font.system(size: 12, weight: .regular, design: .default)
}

/// Reusable liquid-glass background matching §3.1/§3.2's recipe as closely as SwiftUI's drawing
/// primitives allow. Two parts are approximations rather than literal ports: the blend-mode-layered
/// gradient fill (approximated with `.blendMode` on stacked translucent layers) and the inset
/// "inner glass highlight" shadows (CSS `inset` shadows have no SwiftUI counterpart; approximated
/// with edge-fading gradient overlays). Same technique RoutineDetailView already uses successfully,
/// kept as an independent copy per this project's decision not to share that implementation.
private struct WidgetGlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    let highlightBandHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Real blur/vibrancy first — everything after this is a tint wash layered on
                    // top of genuine blurred content, not a substitute for it.
                    WidgetVisualEffectBackground()
                    WidgetTheme.panelBase
                        .blendMode(.lighten)
                    WidgetTheme.panelBase.opacity(0.5)
                        .blendMode(.luminosity)
                    WidgetTheme.panelBase.opacity(0.5)
                        .blendMode(.luminosity)
                }
                .compositingGroup()
                .clipShape(shape)
            )
            .overlay(
                VStack(spacing: 0) {
                    LinearGradient(colors: [Color.white.opacity(0.06), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: highlightBandHeight)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [.clear, Color.black.opacity(0.1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: highlightBandHeight)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            )
            // Border-driven elevation, not shadow-driven — per Wispr Flow's own design system
            // ("border-driven design without box-shadow for card elevation"), and directly
            // motivated by this exact shape: §3.2's literal CSS shadow recipe (0 18px 48px
            // rgba(0,0,0,.45)) kept rendering as a smudge in SwiftUI across two separate tuning
            // passes (padding, opacity, compositingGroup ordering), never as a clean soft shadow.
            // A visibly-real border reads as intentional "glass edge" definition on its own,
            // without fighting SwiftUI's shadow model for something it isn't good at reproducing.
            .overlay(shape.stroke(WidgetTheme.hairline.opacity(0.9), lineWidth: 1.25))
            // Flattens content+background+overlay into one properly-clipped layer before the
            // small residual shadow below — without this, shadows compute against the
            // pre-composited tree (blend-mode layers stacked with unclipped `content`) instead of
            // the final clipped silhouette.
            .compositingGroup()
            // A small, tight shadow only — just enough to lift the shape off very light desktop
            // backgrounds, not the primary definition (the border above is). Needs minimal bleed
            // room, unlike the old radius-20 version.
            .shadow(color: Color.black.opacity(0.22), radius: 6, x: 0, y: 3)
    }
}

extension View {
    /// For the taller step-log / result / permission panels.
    func widgetGlassPanel() -> some View {
        modifier(
            WidgetGlassBackground(shape: RoundedRectangle(cornerRadius: WidgetTheme.panelRadius), highlightBandHeight: 32)
        )
    }

    /// For the fixed 40pt-tall command pill — `Capsule()` per §3.1/§3.2's SwiftUI-clamping note.
    func widgetGlassPill() -> some View {
        modifier(WidgetGlassBackground(shape: Capsule(), highlightBandHeight: 14))
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
            .overlay(shape.stroke(WidgetTheme.hairline.opacity(0.6), lineWidth: 0.5))
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
