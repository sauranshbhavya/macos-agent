import AppKit
import MacAgentCore
import SwiftUI

// MARK: - System A: the Command Center design layer
//
// Everything Command Center and its dialogs draw with lives here: the palette (`SonnyTheme`), the
// type scale (`SonnyType`), the radius rule (`SonnyRadius`), spacing and metrics (`SonnySpacing`,
// `SonnyMetrics`), motion (`SonnyMotion`) and the shared controls (`SonnyButtonStyle`,
// `SonnyBadge`, the surface modifiers). System A is flat and opaque with no shadows. The floating
// widget is System B and keeps its own tokens in `SonnyWidgetTheme.swift`; neither file imports
// the other's. `docs/sonny-ui-modernization-2026-09-08.md` records the decisions behind the values.
//
// Three rules the rest of the target follows:
// 1. No literal colour, font size or radius in a view. Every one routes through a token here, so a
//    change to the system is a change to one file.
// 2. Every interactive control has hover, pressed, focus and disabled states, from the shared
//    modifiers below rather than hand-rolled per view.
// 3. Motion reads `accessibilityReduceMotion` through `sonnyAnimation`, never bare `withAnimation`.

/// The one-line result under a delete control, shared by the Command Center surfaces that have
/// one: Settings' Data page, where it reports the whole wipe and, since SONNY-266, the narrower
/// control beside it on the same slot, and the Memory page, where it reports a per-row Delete off
/// its own channel. Success is read off the "Deleted" prefix, so any outcome copy that means
/// success starts with that word and any that does not, does not. (This comment named
/// `SettingsSecurityAccessPage` as a second host until SONNY-266; the wipe moved off that page on
/// 2026-07-18 and the Memory page took the second seat with SONNY-208.)
struct LocalDataDeletionStatusMessage: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: message.hasPrefix("Deleted") ? "checkmark.circle" : "exclamationmark.triangle")
                .font(SonnyType.micro)
                .foregroundStyle(message.hasPrefix("Deleted") ? SonnyTheme.success : SonnyTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    func localDataDeletionConfirmationDialog(isPresented: Binding<Bool>, viewModel: AgentViewModel) -> some View {
        confirmationDialog(
            "Delete Sonny Local Data?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Local Data", role: .destructive) {
                viewModel.deleteLocalData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // **The list is `LocalDataDeletionCopy`'s, shared with Settings' own detail line**
            // (SONNY-233). This literal named nine of the thirteen the wipe deleted then — one
            // fewer than the line on the page behind it, so the two surfaces describing one
            // irreversible press disagreed with each other as well as with the wipe. What stays
            // written here is the part that is this dialog's alone: what the press does *not* take.
            // **Two sentences: what the press reaches, and what it leaves alone** (SONNY-404,
            // founder decision 2026-09-04 restated 2026-09-05). The account is named in the second
            // because "delete my data" and "delete my account" are two promises and only one of
            // them is this button. This said "from this Mac" for one round, under a reversal that
            // was a coordinator's error.
            //
            // **A third sentence stood here and is gone** (PR #207's R5): "If Sonny can't reach them
            // now, it deletes their copy the next time it can." That is how-it-works copy in a
            // pre-press confirmation, which the standing rule forbids, and the founder's condition
            // is about what the press says *afterwards* — which `LocalDataDeletionCopy.outcome`
            // covers in all three of its states, including the signed-out one that tells the user
            // what to do.
            Text("This deletes \(LocalDataDeletionCopy.everythingItTakes) from this Mac and from Sonny's servers. Generated files, API keys and your account are not deleted.")
        }
    }
}

struct PermissionReadinessRows: View {
    let items: [PermissionReadinessItem]

    var body: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.sm) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: SonnySpacing.sm) {
                    Image(systemName: icon(for: item.state))
                        .font(SonnyType.icon(SonnyMetrics.iconRow, weight: .medium))
                        .foregroundStyle(color(for: item.state))
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(SonnyType.caption)
                            .foregroundStyle(SonnyTheme.text)
                            .lineLimit(1)
                        Text(item.detail)
                            .font(SonnyType.micro)
                            .foregroundStyle(SonnyTheme.muted)
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func icon(for state: PermissionReadinessState) -> String {
        switch state {
        case .ready:
            return "checkmark.circle"
        case .needsAction:
            return "exclamationmark.triangle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private func color(for state: PermissionReadinessState) -> Color {
        switch state {
        case .ready:
            return SonnyTheme.success
        case .needsAction:
            return SonnyTheme.warning
        case .unknown:
            return SonnyTheme.textTertiary
        }
    }
}

// MARK: - Type scale

/// The system font (SF Pro) at a fixed scale. SF switches between its Text and Display optical
/// sizes on its own at 20pt, so nothing here sets tracking by hand. Weight carries hierarchy;
/// size steps are 11 / 12 / 13 / 15 / 20 / 22 / 26 and nothing in between.
enum SonnyType {
    /// Command Center page titles ("Tasks", "Insights", "Routines", "Workspaces", "Memory").
    static let pageTitle = system(22, weight: .semibold)
    /// Settings dialog's content-pane title ("Preferences", "Usage", ...).
    static let settingsContentTitle = system(20, weight: .semibold)
    /// Settings subsection labels ("Display", "Theme"): one real step louder than the 13pt rows
    /// beneath them, which is the hierarchy the page reads by.
    static let settingsSectionLabel = system(15, weight: .semibold)
    /// Sidebar "Sonny" wordmark.
    static let sidebarWordmark = system(13, weight: .semibold)
    /// Insights hero numbers. Monospaced digits so a column of them lines up.
    static let heroStat = system(26, weight: .semibold).monospacedDigit()
    /// Card and row titles that carry hierarchy inside a panel.
    static let headline = system(13, weight: .semibold)
    static let bodyEmphasis = system(13, weight: .medium)
    static let body = system(13)
    static let itemTitle = system(12, weight: .medium)
    static let caption = system(12)
    static let microEmphasis = system(11, weight: .medium)
    static let micro = system(11)
    /// A small label above a block. Sentence case, no tracking, at most one per page.
    static let eyebrow = system(11, weight: .medium)
    static let avatar = system(13, weight: .medium)
    /// Shortcuts, identifiers and anything else that must line up character for character.
    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)

    static func icon(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    private static func system(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

// MARK: - Palette

/// One cool-neutral ramp with a dark and a light reading of every step. Surfaces are opaque and
/// step up in luminance by level (in light they step down, since paper is the brightest thing);
/// text, hairlines and fills are the foreground colour at an opacity, so they compose the same on
/// every level. Every token is an `NSColor` with a dynamic provider, so it resolves against the
/// appearance of the window it is drawn in: `SonnyAppearanceModel` sets that at the application,
/// and the floating widget pins its own panel dark. The brand accent is the one saturated colour;
/// its light reading is a step darker so white text on it keeps its contrast on paper.
enum SonnyTheme {
    // Surfaces, level 0 to 4.
    /// Sidebar and the Settings dialog's own sidebar.
    static let sidebar = dynamic(dark: 0x0F1012, light: 0xECEDF0)
    /// The window canvas.
    static let ink = dynamic(dark: 0x141518, light: 0xF5F6F8)
    /// The bordered content panel inside each page.
    static let collectionSurface = dynamic(dark: 0x191A1E, light: 0xFFFFFF)
    /// Cards, secondary buttons, inputs, popovers.
    static let surfaceRaised = dynamic(dark: 0x1F2126, light: 0xF2F3F6)
    /// Menus and a hovered card.
    static let surfaceRaised2 = dynamic(dark: 0x262930, light: 0xE8EAEE)

    // Text.
    static let text = onSurface(dark: 0.92, light: 0.88)
    /// Secondary text: subtitles, descriptions, metadata that still has to be read.
    static let muted = onSurface(dark: 0.60, light: 0.58)
    /// Tertiary text: timestamps, placeholders, counts.
    static let textTertiary = onSurface(dark: 0.38, light: 0.42)
    /// Text on the accent fill.
    static let textOnAccent = Color.white

    // Hairlines and fills.
    /// Panel borders and the dividers between sections.
    static let border = onSurface(dark: 0.09, light: 0.10)
    /// Card and button borders, and the dividers between rows.
    static let cardBorder = onSurface(dark: 0.06, light: 0.07)
    static let fillHover = onSurface(dark: 0.05, light: 0.04)
    static let fillPressed = onSurface(dark: 0.09, light: 0.08)
    static let fillSelected = onSurface(dark: 0.10, light: 0.08)

    // Accent and semantics.
    static let accent = dynamic(dark: 0x5C84FE, light: 0x3B67E9)
    static let accentSubtle = accent.opacity(0.14)
    static let accentBorder = accent.opacity(0.40)
    static let success = dynamic(dark: 0x4CC38A, light: 0x1E9E5F)
    static let warning = dynamic(dark: 0xE8B84A, light: 0xA8760A)
    static let danger = dynamic(dark: 0xE5484D, light: 0xD2353B)
    /// Every non-peak bar in the Insights chart.
    static let chartBarMuted = accent.opacity(0.22)

    /// The foreground colour at an opacity: white on dark, black on light. For a view that needs a
    /// step the named tokens do not have (the mode control's wireframe-literal track and dividers).
    static func onSurface(dark: Double, light: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isSonnyLight
                ? NSColor.black.withAlphaComponent(light)
                : NSColor.white.withAlphaComponent(dark)
        })
    }

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isSonnyLight ? NSColor(sonnyHex: light) : NSColor(sonnyHex: dark)
        })
    }
}

private extension NSAppearance {
    /// Dark unless the appearance resolves to Aqua: the widget's vibrant-dark panel and every
    /// dark variant answer false here without being named one by one.
    var isSonnyLight: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .aqua
    }
}

private extension NSColor {
    convenience init(sonnyHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Radius, spacing, metrics

/// Three radii and a capsule. Controls, rows, badges and inputs share one; cards and panels share
/// one; sheets share one. A view never writes a radius literal.
enum SonnyRadius {
    static let control: CGFloat = 6
    static let card: CGFloat = 10
    static let sheet: CGFloat = 12
    static let pill: CGFloat = 999
}

/// A 4pt grid.
enum SonnySpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
    /// Inset from a page's edge to its title and its panel.
    static let pageInset: CGFloat = 24
}

enum SonnyMetrics {
    static let sidebarWidth: CGFloat = 220
    static let navRowHeight: CGFloat = 30
    static let listRowHeight: CGFloat = 36
    static let compactRowHeight: CGFloat = 28
    static let toolbarHeight: CGFloat = 36
    /// The floor a pointer can hit reliably; nothing interactive is shorter.
    static let controlSmall: CGFloat = 24
    static let controlRegular: CGFloat = 28
    static let controlLarge: CGFloat = 32
    static let iconSidebar: CGFloat = 14
    static let iconRow: CGFloat = 13
    static let iconButton: CGFloat = 11
    static let iconEmptyState: CGFloat = 24
    /// The disclosure chevron beside a row or in a menu row: smaller than a button glyph on purpose.
    static let iconChevron: CGFloat = 9
    /// The sidebar with its labels hidden: the mark, the icons and the avatar, each with a tooltip.
    static let sidebarWidthCollapsed: CGFloat = 56
    /// A collapsed sidebar row's selection fill, centred on its icon.
    static let sidebarCollapsedRowWidth: CGFloat = 36
}

// MARK: - Motion

/// One curve family. `quick` is for a fill changing under the pointer, `standard` for a row or a
/// section appearing, `emphasized` for a sheet or a panel. All of it is off under Reduce Motion
/// through `sonnyAnimation`.
enum SonnyMotion {
    static let quick = Animation.smooth(duration: 0.15)
    static let standard = Animation.smooth(duration: 0.22)
    static let emphasized = Animation.snappy(duration: 0.3)
}

private struct SonnyAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that reads Reduce Motion, so a view never has to.
    func sonnyAnimation<Value: Equatable>(_ animation: Animation = SonnyMotion.standard, value: Value) -> some View {
        modifier(SonnyAnimationModifier(animation: animation, value: value))
    }
}

// MARK: - Surfaces

private struct SonnySurfaceModifier: ViewModifier {
    let fill: Color
    let stroke: Color
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(stroke, lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    /// The bordered content panel each page draws its lists inside.
    func sonnyPanel() -> some View {
        modifier(SonnySurfaceModifier(fill: SonnyTheme.collectionSurface, stroke: SonnyTheme.border, radius: SonnyRadius.card))
    }

    /// A raised card inside a panel: a stat, a workspace, a memory row.
    func sonnyCard(isHovered: Bool = false) -> some View {
        modifier(SonnySurfaceModifier(
            fill: isHovered ? SonnyTheme.surfaceRaised2 : SonnyTheme.surfaceRaised,
            stroke: SonnyTheme.cardBorder,
            radius: SonnyRadius.card
        ))
    }

    /// A one-pixel rule under a row or between sections.
    func sonnyDivider(_ color: Color = SonnyTheme.cardBorder) -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(color)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Text fields

/// One text-field chrome for every field in System A: the task search, a clarification answer,
/// the workspace scope entry, sign-in. A raised fill, a hairline that turns accent while the field
/// has focus, and the same two heights buttons use so a field and a button share a row cleanly.
enum SonnyTextFieldSize {
    case small
    case regular

    var height: CGFloat {
        switch self {
        case .small: return SonnyMetrics.controlSmall
        case .regular: return SonnyMetrics.controlRegular
        }
    }
}

private struct SonnyTextFieldModifier: ViewModifier {
    @FocusState private var isFocused: Bool
    let size: SonnyTextFieldSize

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(size == .small ? SonnyType.caption : SonnyType.body)
            .foregroundStyle(SonnyTheme.text)
            .focused($isFocused)
            .padding(.horizontal, SonnySpacing.sm)
            .frame(height: size.height)
            .background(SonnyTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: SonnyRadius.control))
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.control)
                    .strokeBorder(isFocused ? SonnyTheme.accent : SonnyTheme.cardBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .animation(SonnyMotion.quick, value: isFocused)
    }
}

extension View {
    func sonnyTextField(size: SonnyTextFieldSize = .regular) -> some View {
        modifier(SonnyTextFieldModifier(size: size))
    }
}

// MARK: - Dialogs

/// Every sheet's close control: one glyph, one hit target, one hover shape. The label names the
/// sheet ("Close Settings") so VoiceOver says which one is closing.
struct SonnyDialogCloseButton: View {
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(SonnyType.icon(SonnyMetrics.iconButton, weight: .semibold))
                .foregroundStyle(SonnyTheme.muted)
                .frame(width: SonnyMetrics.controlRegular, height: SonnyMetrics.controlRegular)
                .contentShape(RoundedRectangle(cornerRadius: SonnyRadius.control))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .sonnyPointerCursor()
        .sonnyHoverHighlight(cornerRadius: SonnyRadius.control)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The "more actions" menu a card or a row keeps its secondary and destructive actions in (founder
/// ask, 2026-09-09): an ellipsis in a circle, the Mac convention, drawn as a small tertiary control
/// so the row's one primary action stays the only thing that reads as a button. Callers pass menu
/// content as they would to `Menu`; a destructive item takes `role: .destructive` and still confirms
/// before it acts, as every delete in Command Center does. The menu style is `.button` with a plain
/// button style rather than the deprecated borderless menu style, which the warnings count would
/// flag; the indicator is hidden because the glyph already says what it is.
struct SonnyOverflowMenu<Content: View>: View {
    let accessibilityLabel: String
    @ViewBuilder let content: () -> Content

    init(accessibilityLabel: String = "More actions", @ViewBuilder content: @escaping () -> Content) {
        self.accessibilityLabel = accessibilityLabel
        self.content = content
    }

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

/// The title row a sheet opens with: the title at the leading edge, the close control at the
/// trailing edge, and one inset shared with `sonnyDialogFrame`.
struct SonnyDialogHeader: View {
    let title: String
    var subtitle: String? = nil
    let closeLabel: String
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: SonnySpacing.md) {
            VStack(alignment: .leading, spacing: SonnySpacing.xs) {
                Text(title)
                    .font(SonnyType.settingsContentTitle)
                    .foregroundStyle(SonnyTheme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: SonnySpacing.md)
            SonnyDialogCloseButton(accessibilityLabel: closeLabel, action: close)
        }
        .padding(.horizontal, SonnySpacing.xxl)
        .padding(.top, SonnySpacing.xl)
        .padding(.bottom, SonnySpacing.lg)
    }
}

/// A sheet's size and chrome: the canvas colour, the sheet radius, a hairline. Three sizes cover
/// every sheet the app has; a sheet that needs a fourth number is a sheet asking to be redesigned.
enum SonnyDialogSize {
    /// A confirmation, a short form, the profile placeholder.
    case compact
    /// Sign-in, routine detail, workspace detail, scope entry.
    case regular
    /// Settings.
    case wide

    var size: CGSize {
        switch self {
        case .compact: return CGSize(width: 480, height: 360)
        case .regular: return CGSize(width: 560, height: 520)
        case .wide: return CGSize(width: 860, height: 600)
        }
    }
}

private struct SonnyDialogFrameModifier: ViewModifier {
    let size: SonnyDialogSize

    func body(content: Content) -> some View {
        content
            .frame(width: size.size.width, height: size.size.height)
            .background(SonnyTheme.ink)
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.sheet))
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.sheet)
                    .strokeBorder(SonnyTheme.border, lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }
}

private struct SonnyDialogChromeModifier: ViewModifier {
    let width: CGFloat
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(width: width, height: height)
            .background(SonnyTheme.ink)
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.sheet))
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.sheet)
                    .strokeBorder(SonnyTheme.border, lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    func sonnyDialogFrame(_ size: SonnyDialogSize) -> some View {
        modifier(SonnyDialogFrameModifier(size: size))
    }

    /// The same chrome at a size the caller computes from its content, for the one sheet whose
    /// height is a measured function of what it shows (the task detail, `TaskDetailPresentation`).
    /// Width still comes from a named size so it lines up with its siblings.
    func sonnyDialogFrame(width: CGFloat, height: CGFloat) -> some View {
        modifier(SonnyDialogChromeModifier(width: width, height: height))
    }
}

// MARK: - Badge

/// A count or a state word in a small tinted chip: the sidebar's active-task count, a routine's
/// step count, a status on a row.
struct SonnyBadge: View {
    enum Tone {
        case neutral
        case accent
        case success
        case warning
        case danger
    }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(SonnyType.microEmphasis.monospacedDigit())
            .foregroundStyle(foreground)
            .padding(.horizontal, SonnySpacing.sm - 2)
            .frame(minWidth: 18, minHeight: 18)
            .background(background, in: RoundedRectangle(cornerRadius: SonnyRadius.control))
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return SonnyTheme.muted
        case .accent: return SonnyTheme.accent
        case .success: return SonnyTheme.success
        case .warning: return SonnyTheme.warning
        case .danger: return SonnyTheme.danger
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: return SonnyTheme.fillSelected
        case .accent: return SonnyTheme.accentSubtle
        case .success: return SonnyTheme.success.opacity(0.14)
        case .warning: return SonnyTheme.warning.opacity(0.14)
        case .danger: return SonnyTheme.danger.opacity(0.14)
        }
    }
}

// MARK: - Pointer and hover

private struct SonnyPointerCursorsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var sonnyPointerCursorsEnabled: Bool {
        get { self[SonnyPointerCursorsEnabledKey.self] }
        set { self[SonnyPointerCursorsEnabledKey.self] = newValue }
    }
}

private struct SonnyPointerCursorModifier: ViewModifier {
    @Environment(\.sonnyPointerCursorsEnabled) private var isEnabled
    @Environment(\.isEnabled) private var isControlEnabled
    @State private var didPushCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                if isEnabled, isControlEnabled, isHovering, !didPushCursor {
                    NSCursor.pointingHand.push()
                    didPushCursor = true
                } else if didPushCursor, (!isHovering || !isEnabled || !isControlEnabled) {
                    NSCursor.pop()
                    didPushCursor = false
                }
            }
            .onChange(of: isEnabled) { _, newValue in
                if !newValue, didPushCursor {
                    NSCursor.pop()
                    didPushCursor = false
                }
            }
            .onChange(of: isControlEnabled) { _, newValue in
                if !newValue, didPushCursor {
                    NSCursor.pop()
                    didPushCursor = false
                }
            }
            .onDisappear {
                if didPushCursor {
                    NSCursor.pop()
                    didPushCursor = false
                }
            }
    }
}

/// Universal hover feedback: `SonnyTheme.fillHover` laid over whatever the control already draws,
/// so a filled button and a bare row get the same lift from one primitive. Respects `isEnabled`
/// the way `sonnyPointerCursor()` does, so a disabled control shows nothing on hover. The fade is
/// a fill, not a movement, so it is not gated on Reduce Motion.
private struct SonnyHoverHighlightModifier: ViewModifier {
    @Environment(\.isEnabled) private var isControlEnabled
    @State private var isHovering = false
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHovering && isControlEnabled ? SonnyTheme.fillHover : Color.clear)
                    .allowsHitTesting(false)
            )
            .animation(SonnyMotion.quick, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    func sonnyPointerCursor() -> some View {
        modifier(SonnyPointerCursorModifier())
    }

    func sonnyHoverHighlight(cornerRadius: CGFloat = SonnyRadius.control) -> some View {
        modifier(SonnyHoverHighlightModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Buttons

/// The one button system. Four tones say what a press means; three sizes say where the button
/// sits. Hover, pressed, keyboard focus and disabled come with it, so a view never adds them.
struct SonnyButtonStyle: ButtonStyle {
    enum Tone {
        /// The one action a surface is for. Accent fill.
        case primary
        /// Everything else that has a border: row actions, toolbar actions, sheet buttons.
        case secondary
        /// A quiet action that only shows a fill under the pointer: "Clear", a header's "+".
        case tertiary
        /// Delete and its relatives.
        case danger
    }

    enum Size {
        /// Row actions inside a list or a card.
        case small
        /// Toolbar and sheet actions.
        case regular
        /// The main action on an onboarding or sign-in step.
        case large

        var height: CGFloat {
            switch self {
            case .small: return SonnyMetrics.controlSmall
            case .regular: return SonnyMetrics.controlRegular
            case .large: return SonnyMetrics.controlLarge
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .small: return SonnySpacing.sm
            case .regular: return SonnySpacing.md
            case .large: return SonnySpacing.lg
            }
        }

        var font: Font {
            switch self {
            case .small: return SonnyType.itemTitle
            case .regular: return SonnyType.bodyEmphasis
            case .large: return SonnyType.headline
            }
        }
    }

    @Environment(\.isEnabled) private var isEnabled
    let tone: Tone
    var size: Size = .regular
    var width: CGFloat? = nil

    init(tone: Tone, size: Size = .regular, width: CGFloat? = nil) {
        self.tone = tone
        self.size = size
        self.width = width
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: SonnyRadius.control)
        configuration.label
            .font(size.font)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(width == nil ? 1 : 0.9)
            .padding(.horizontal, size.horizontalPadding)
            .frame(width: width, height: size.height)
            .background(background, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1).allowsHitTesting(false))
            .overlay(shape.fill(configuration.isPressed ? pressedOverlay : Color.clear).allowsHitTesting(false))
            .contentShape(shape)
            .contentShape(.focusEffect, shape)
            .sonnyPointerCursor()
            .sonnyHoverHighlight(cornerRadius: SonnyRadius.control)
            .opacity(isEnabled ? 1 : 0.4)
    }

    private var foreground: Color {
        switch tone {
        case .primary: return SonnyTheme.textOnAccent
        case .secondary, .tertiary: return SonnyTheme.text
        case .danger: return SonnyTheme.danger
        }
    }

    private var background: Color {
        switch tone {
        case .primary: return SonnyTheme.accent
        case .secondary: return SonnyTheme.surfaceRaised
        case .tertiary: return .clear
        case .danger: return SonnyTheme.danger.opacity(0.12)
        }
    }

    private var border: Color {
        switch tone {
        case .primary: return .clear
        case .secondary: return SonnyTheme.cardBorder
        case .tertiary: return .clear
        case .danger: return SonnyTheme.danger.opacity(0.35)
        }
    }

    private var pressedOverlay: Color {
        switch tone {
        case .primary: return Color.black.opacity(0.18)
        case .secondary, .tertiary: return SonnyTheme.fillPressed
        case .danger: return SonnyTheme.danger.opacity(0.12)
        }
    }
}
