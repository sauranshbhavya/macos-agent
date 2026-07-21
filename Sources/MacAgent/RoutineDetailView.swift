import MacAgentCore
import SwiftUI

// MARK: - System B tokens (routine detail view only)
//
// This is a fully separate token set from System A (SonnyTheme/SonnyType/SonnyRadius in
// ContentView.swift) — per docs/sonny-design-system-reference.md §3 and
// docs/sonny-founder-design-decisions.md's Routines section, the routine detail view is styled
// like the floating widget's liquid-glass material embedded inside the main app window, not a
// variant of System A. Do not extend SonnyTheme/SonnyType/SonnyRadius to serve this view, and do
// not reuse these System B tokens outside this deliberate System-B-inside-System-A case.

enum RoutineDetailTheme {
    static let basePanel = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255)
    static let hairline = Color(red: 0xA6 / 255, green: 0xA6 / 255, blue: 0xA6 / 255)
    static let text = Color.white
    static let mutedText = Color.white.opacity(0.55)

    /// §3's exact radius/shadow-offset recipe only covers two specific components — the floating
    /// widget's own panels (34px radius, 18px shadow offset) and the system notification banner
    /// (20px radius, 8px offset). Neither is literally "the routine detail view," which isn't in
    /// that doc at all. `docs/sonny-founder-design-decisions.md`'s own language is "styled like the
    /// floating widget" specifically, not the notification, so the floating widget's values are
    /// used here as the more defensible default — an explicit, stated choice, not a silent
    /// assumption. Worth a visual check alongside the actual floating widget once branch 11 exists.
    static let panelRadius: CGFloat = 34
    static let shadowOffset: CGFloat = 18
}

enum RoutineDetailType {
    /// §3.1 calls out a recurring non-standard weight value, 510 — Apple's own "Medium" optical-
    /// weight instance in SF Pro's variable-font axis, distinct from the generic CSS 500. SwiftUI's
    /// `Font.Weight` has no matching custom numeric axis value to set directly, so `.medium`
    /// (SwiftUI's own closest built-in token) is used wherever §3.1 specifies 510.
    static let mediumWeight: Font.Weight = .medium

    /// SF Pro / SF Pro Display come from `design: .default` — that's already San Francisco on
    /// Apple platforms, so no custom font name needs registering (unlike System A's Inter, which
    /// is a bundled, non-system font loaded via `Font.custom`).
    static let title = Font.system(size: 20, weight: .semibold, design: .default)
    static let sectionLabel = Font.system(size: 13, weight: mediumWeight, design: .default)
    static let body = Font.system(size: 13, weight: .regular, design: .default)
    static let micro = Font.system(size: 11, weight: .regular, design: .default)
}

/// Reusable liquid-glass panel background matching §3.1/§3.2's recipe as closely as SwiftUI's
/// drawing primitives allow. Two parts are approximations rather than literal ports, since CSS and
/// SwiftUI have no exact equivalents for them: the blend-mode-layered gradient fill (approximated
/// with `.blendMode` on stacked translucent layers) and the inset "inner glass highlight" shadows
/// (CSS `inset` shadows have no SwiftUI counterpart; approximated with edge-fading gradient
/// overlays). Worth a visual check, not guaranteed pixel-identical to the CSS export.
private struct LiquidGlassPanelBackground: ViewModifier {
    let cornerRadius: CGFloat
    let shadowOffset: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                // §3.1's exact recipe: the opaque base layer carries `lighten`; both translucent
                // `rgba(26,26,26,.5)` layers carry `luminosity`. `.compositingGroup()` isolates
                // this stack so the blend modes composite against each other, not whatever's
                // drawn behind the sheet.
                ZStack {
                    RoutineDetailTheme.basePanel
                        .blendMode(.lighten)
                    RoutineDetailTheme.basePanel.opacity(0.5)
                        .blendMode(.luminosity)
                    RoutineDetailTheme.basePanel.opacity(0.5)
                        .blendMode(.luminosity)
                }
                .compositingGroup()
            )
            .overlay(
                // Approximates the inset "inner glass highlight" (`inset 0 40px 10px -40px #1A1A1A`
                // on both top and bottom edges) via edge-fading gradients, since SwiftUI has no
                // inset-shadow primitive.
                VStack(spacing: 0) {
                    LinearGradient(colors: [Color.white.opacity(0.05), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 40)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [.clear, Color.black.opacity(0.08)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 40)
                }
                .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(RoutineDetailTheme.hairline, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            // The 3-pass hairline rim from §3.2 (±1.25px offset passes plus the 0.5px outline
            // stroke already applied above as an overlay, the more precise translation for a
            // zero-blur/zero-offset CSS shadow pass). §3.2's outline color is fully opaque —
            // SwiftUI's blur-based `.shadow` still softens what CSS's spread-based passes render
            // sharp, but the color itself shouldn't be additionally dimmed on top of that.
            .shadow(color: RoutineDetailTheme.hairline, radius: 0.5, x: 1.25, y: 0)
            .shadow(color: RoutineDetailTheme.hairline, radius: 0.5, x: -1.25, y: 0)
            // The outer drop shadow: `0px <offset>px 48px rgba(0,0,0,.45)`.
            .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: shadowOffset)
    }
}

private extension View {
    func liquidGlassPanel(cornerRadius: CGFloat, shadowOffset: CGFloat) -> some View {
        modifier(LiquidGlassPanelBackground(cornerRadius: cornerRadius, shadowOffset: shadowOffset))
    }
}

// MARK: - Routine detail view

/// Per `docs/sonny-founder-design-decisions.md`'s Routines section: clicking into a routine opens
/// a detail view styled like the floating widget (liquid glass), embedded inside the main app
/// window rather than the literal floating widget window — presented here via `.sheet(item:)`.
struct RoutineDetailView: View {
    let routine: StoredRoutine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(RoutineDetailTheme.hairline.opacity(0.2))
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(routine.steps) { step in
                        RoutineDetailStepRow(step: step)
                    }

                    // Deliberately no Run button here — branch 10 hasn't decided whether Run stays
                    // on the Routines list row or moves into this view. This trailing spacer just
                    // leaves room for one to be added later without the layout needing rework.
                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .frame(width: 420, height: 480)
        .liquidGlassPanel(cornerRadius: RoutineDetailTheme.panelRadius, shadowOffset: RoutineDetailTheme.shadowOffset)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(routine.name)
                .font(RoutineDetailType.title)
                .foregroundStyle(RoutineDetailTheme.text)
                .lineLimit(1)

            Text("\(routine.steps.count) saved step\(routine.steps.count == 1 ? "" : "s")")
                .font(RoutineDetailType.micro)
                .foregroundStyle(RoutineDetailTheme.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }
}

private struct RoutineDetailStepRow: View {
    let step: AgentStep

    /// Icon slot matching the floating widget's own row grammar (§3.3.2: "icon slot... + label
    /// text") — `docs/sonny-founder-design-decisions.md` asks for "one consistent... experience"
    /// across both surfaces, not a plain numbered list wearing glass chrome. Resolves the step's
    /// real app icon the same way `WorkspaceAppIconStack` already does; falls back to a step
    /// glyph when the step has no app (or it isn't installed).
    private var resolvedIcon: NSImage? {
        guard let appName = step.appName else { return nil }
        return WorkspaceAppIconResolver.shared.icon(forAppName: appName)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                if let resolvedIcon {
                    Image(nsImage: resolvedIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: AgentActivityPresentation.eventIcon(.act))
                        .font(RoutineDetailType.sectionLabel)
                        .foregroundStyle(RoutineDetailTheme.mutedText)
                }
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(AgentActivityPresentation.operationTitle(step))
                    .font(RoutineDetailType.body)
                    .foregroundStyle(RoutineDetailTheme.text)

                if !step.description.isEmpty {
                    Text(step.description)
                        .font(RoutineDetailType.micro)
                        .foregroundStyle(RoutineDetailTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
    }
}
