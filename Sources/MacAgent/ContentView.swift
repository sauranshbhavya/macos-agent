import AppKit
import MacAgentCore
import SwiftUI

struct AgentCommandComposerView: View {
    @ObservedObject var viewModel: AgentViewModel
    let autoFocus: Bool
    let focusRequest: Int
    @FocusState private var commandFocused: Bool

    init(viewModel: AgentViewModel, autoFocus: Bool = false, focusRequest: Int = 0) {
        self.viewModel = viewModel
        self.autoFocus = autoFocus
        self.focusRequest = focusRequest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Single-row pill (icon, input, primary action, voice) matches the wireframe's
            // compact composer. Dry run / hotkey hint / reset have no wireframe equivalent —
            // they're real Sonny controls with nowhere to go in that row, so they stay as a
            // secondary row below rather than being dropped.
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(SonnyTheme.accent.opacity(0.16))
                    Image(systemName: "wand.and.stars")
                        .font(SonnyType.icon(13, weight: .medium))
                        .foregroundStyle(SonnyTheme.accent)
                }
                .frame(width: 28, height: 28)

                TextField("Open Safari, zip files, convert docs...", text: $viewModel.command)
                    .textFieldStyle(.plain)
                    .font(SonnyType.command)
                    .disabled(viewModel.isRunning)
                    .focused($commandFocused)
                    .submitLabel(.go)
                    .onSubmit {
                        viewModel.start()
                    }

                if viewModel.canCancel {
                    Button {
                        viewModel.cancelCurrentRun()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(SonnyButtonStyle(tone: .secondary, width: 86))
                } else {
                    Button {
                        viewModel.start()
                    } label: {
                        Label(viewModel.primaryButtonTitle, systemImage: viewModel.primaryButtonIcon)
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!viewModel.canSubmit)
                    .buttonStyle(SonnyButtonStyle(tone: .primary, width: 92))
                }

                Button {
                    viewModel.toggleVoiceRecording()
                } label: {
                    Image(systemName: viewModel.voiceButtonIcon)
                }
                .disabled(!viewModel.canUseVoice && !viewModel.isRecordingVoice)
                .buttonStyle(SonnyVoiceCircleButtonStyle(isActive: viewModel.isRecordingVoice))
                .help("Click to speak, or hold Control-Option-Space")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(SonnyTheme.input)
            .overlay(
                Capsule().stroke(
                    commandFocused ? SonnyTheme.accent.opacity(0.72) : SonnyTheme.border,
                    lineWidth: 1
                )
            )
            .clipShape(Capsule())

            if let recentTask = viewModel.recentTaskAffordanceText {
                RecentTaskAffordance(text: recentTask)
            }

            if !viewModel.voiceTranscript.isEmpty {
                Label("Voice command received", systemImage: "waveform")
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.muted)
            }

            HStack(spacing: 8) {
                DryRunToggle(isOn: $viewModel.dryRun)
                    .disabled(viewModel.isRunning || viewModel.isAwaitingApproval)

                HotKeyHint(title: viewModel.voiceHotKeyReady ? "Ctrl-Opt-Space" : "Unavailable")

                Spacer(minLength: 12)

                if !viewModel.canCancel {
                    Button {
                        viewModel.reset()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(viewModel.isRunning)
                    .buttonStyle(SonnyButtonStyle(tone: .secondary, width: 80))
                }
            }
        }
        .onAppear {
            if autoFocus {
                commandFocused = true
            }
        }
        .onChange(of: focusRequest) { _, _ in
            commandFocused = true
        }
    }
}

private struct RecentTaskAffordance: View {
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(SonnyType.icon(13))
                .foregroundStyle(SonnyTheme.accent)
                .frame(width: 16)

            Text("Recent task")
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.text)

            Text(text)
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SonnyTheme.surfaceRaised.opacity(0.84))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SonnyTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct HotKeyHint: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "keyboard")
            .font(SonnyType.micro)
            .foregroundStyle(SonnyTheme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.84)
            .frame(width: 112, height: 34)
            .background(SonnyTheme.surfaceRaised.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct DryRunToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Dry run")
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .frame(width: 44, alignment: .leading)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .frame(width: 54)
        }
        .frame(width: 106, height: 34, alignment: .leading)
    }
}

/// Shared between the Command Center's `SettingsSecurityAccessPage` and `SettingsDataPage` — both
/// surfaces call the same `viewModel.deleteLocalData()` action with identical copy, only the
/// surrounding row layout differs per surface.
struct LocalDataDeletionStatusMessage: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: message.hasPrefix("Deleted") ? "checkmark.circle" : "exclamationmark.triangle")
                .font(SonnyType.micro)
                .foregroundStyle(message.hasPrefix("Deleted") ? SonnyTheme.accent : SonnyTheme.warning)
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
            Text("This deletes saved routines, workspaces, clipboard history, snippets, recent artifacts, Shortcut run history, task history, and clipboard settings. Generated files and API keys are not deleted.")
        }
    }
}

struct PermissionReadinessRows: View {
    let items: [PermissionReadinessItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(for: item.state))
                        .font(SonnyType.caption)
                        .foregroundStyle(color(for: item.state))
                        .frame(width: 16)
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
            return SonnyTheme.accent
        case .needsAction:
            return SonnyTheme.warning
        case .unknown:
            return SonnyTheme.muted
        }
    }
}

enum SonnyType {
    static let brand = inter(42, weight: .semibold)
    static let hero = inter(28, weight: .semibold)
    static let panelTitle = inter(23, weight: .semibold)
    /// Command Center page titles ("Tasks", "Insights", "Routines", "Workspaces") — 23px/500 per
    /// the wireframes. Deliberately separate from `panelTitle` (23px/600, a different existing
    /// consumer: the sidebar "Sonny" wordmark) so this fix doesn't silently change that unrelated
    /// element's weight too. NOT used for Settings, which isn't a sidebar destination at all
    /// (2026-07-18: Settings moved into its own dialog, see `SettingsDialogView`).
    static let pageTitle = inter(23, weight: .medium)
    /// Sidebar "Sonny" wordmark — 13px/600 per the wireframes, deliberately separate from
    /// `panelTitle` (23px/600, the popover's own former `PanelHeader` title) so fixing the
    /// wordmark's size doesn't silently change that unrelated surface too.
    static let sidebarWordmark = inter(13, weight: .semibold)
    /// Settings dialog's content-pane title ("Preferences", "Usage", ...) — 24px/500.
    static let settingsContentTitle = inter(24, weight: .medium)
    /// Settings subsection labels ("Display", "Theme") — 18px/500, one real step louder than the
    /// 13px row titles beneath them. Collapsing these to the same size as row titles was a real,
    /// verified hierarchy loss (`10-MainAppSettings.svg`'s own `font-size` attribute), not a
    /// close-enough token reuse.
    static let settingsSectionLabel = inter(18, weight: .medium)
    static let heroStat = inter(22, weight: .medium)
    static let tagline = inter(12)
    static let eyebrow = inter(11, weight: .medium)
    static let command = inter(15)
    static let body = inter(13)
    static let bodyEmphasis = inter(13, weight: .medium)
    static let itemTitle = inter(12, weight: .medium)
    static let caption = inter(12)
    static let micro = inter(11)
    static let microEmphasis = inter(11, weight: .medium)
    static let avatar = inter(14, weight: .medium)
    static let panelIcon = Font.system(size: 14)

    static func icon(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    private static func inter(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom("Inter", size: size).weight(weight)
    }
}

enum SonnyTheme {
    static let ink = Color(red: 9 / 255, green: 9 / 255, blue: 9 / 255)
    static let collectionSurface = Color(red: 15 / 255, green: 16 / 255, blue: 17 / 255)
    static let surfaceRaised = Color(red: 22 / 255, green: 23 / 255, blue: 26 / 255)
    static let border = Color(red: 37 / 255, green: 38 / 255, blue: 43 / 255)
    static let cardBorder = Color(red: 26 / 255, green: 27 / 255, blue: 32 / 255)
    static let text = Color(red: 1, green: 1, blue: 1)
    static let muted = Color(red: 149 / 255, green: 150 / 255, blue: 153 / 255)
    static let accent = Color(red: 92 / 255, green: 132 / 255, blue: 254 / 255)
    /// Sidebar nav-item label color — slightly warmer than pure white, uniform across every
    /// main-app screen's shared sidebar (the wireframes show no selected/unselected text-color
    /// distinction on nav rows at all).
    static let sidebarNavText = Color(red: 226 / 255, green: 227 / 255, blue: 229 / 255)

    // Compatibility alias keeps established surfaces on the same rebranded token.
    static let cream = text

    static let glassShade = ink.opacity(0.88)
    static let panelTint = collectionSurface.opacity(0.88)
    static let input = collectionSurface
    static let warning = Color(red: 242 / 255, green: 190 / 255, blue: 0 / 255)
    static let success = Color(red: 63 / 255, green: 185 / 255, blue: 80 / 255)
    static let chartBarMuted = Color(red: 36 / 255, green: 46 / 255, blue: 82 / 255)
    static let danger = Color(red: 0.973, green: 0.169, blue: 0.376)
    /// Task-history status-dot colors. The wireframe's own "Done" dot is Linear's brand purple
    /// (#5E6AD2), resolved in docs/sonny-design-system-reference.md §2.4 as un-cleaned template
    /// residue — `accent` (#5C84FE) is canonical everywhere, so `taskDone` aliases it rather than
    /// reproducing the wireframe's literal (wrong) value.
    static let taskDone = accent
    static let taskCanceled = Color(red: 0x95 / 255, green: 0xA2 / 255, blue: 0xB3 / 255)
    static let info = text.opacity(0.92)
}

enum SonnyRadius {
    static let container: CGFloat = 4
    static let themeSwatch: CGFloat = 5
    static let routineIcon: CGFloat = 6
    static let panelCard: CGFloat = 6
    static let workspaceCard: CGFloat = 8
    static let sidebarIcon: CGFloat = 10
    static let pill: CGFloat = 20
}

extension View {
    /// The sidebar top icon button's own two-pass drop shadow — one of only two shadow
    /// exceptions in System A besides the Settings toggle knob (`sonnySidebarIconShadow`'s
    /// counterpart being `sonnyLogoGlow` below). CSS: `drop-shadow(0px 1px 2px rgba(0,0,0,.04))
    /// drop-shadow(0px 2px 4px rgba(0,0,0,.04))`.
    func sonnySidebarIconShadow() -> some View {
        self
            .shadow(color: .black.opacity(0.04), radius: 1, x: 0, y: 1)
            .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 2)
    }

    /// The sidebar logo's ambient glow. CSS: `drop-shadow(0px 0px 19.8px rgba(255,255,255,.11))`.
    func sonnyLogoGlow() -> some View {
        self.shadow(color: .white.opacity(0.11), radius: 9.9, x: 0, y: 0)
    }
}

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

/// Universal hover feedback (2026-07-18): a subtle white tint overlaid on top of whatever the
/// control already renders, so it works the same way whether the control has a solid background
/// fill (buttons like `CommandCenterRowActionStyle`) or none (sidebar nav rows, which are only
/// filled when selected) — one primitive instead of hand-tuning a different "brighter" color per
/// component. Respects `isEnabled` the same way `sonnyPointerCursor()` does, so disabled controls
/// (e.g. the account menu's "Get help") correctly show no hover feedback at all.
private struct SonnyHoverHighlightModifier: ViewModifier {
    @Environment(\.isEnabled) private var isControlEnabled
    @State private var isHovering = false
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(isHovering && isControlEnabled ? 0.06 : 0))
                    .allowsHitTesting(false)
            )
            .onHover { isHovering = $0 }
    }
}

extension View {
    func sonnyPointerCursor() -> some View {
        modifier(SonnyPointerCursorModifier())
    }

    func sonnyHoverHighlight(cornerRadius: CGFloat = SonnyRadius.container) -> some View {
        modifier(SonnyHoverHighlightModifier(cornerRadius: cornerRadius))
    }
}

struct SonnyButtonStyle: ButtonStyle {
    let tone: Tone
    var width: CGFloat? = nil

    enum Tone {
        case primary
        case secondary
        case danger
    }

    init(tone: Tone, width: CGFloat? = nil) {
        self.tone = tone
        self.width = width
    }

    func makeBody(configuration: Configuration) -> some View {
        if let width {
            label(configuration)
                .frame(width: width, height: 34)
                .background(background.opacity(configuration.isPressed ? 0.72 : 1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .sonnyPointerCursor()
                .sonnyHoverHighlight(cornerRadius: 8)
        } else {
            label(configuration)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(background.opacity(configuration.isPressed ? 0.72 : 1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .sonnyPointerCursor()
                .sonnyHoverHighlight(cornerRadius: 8)
        }
    }

    private func label(_ configuration: Configuration) -> some View {
        configuration.label
            .font(SonnyType.caption)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.86)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var foreground: Color {
        switch tone {
        case .primary:
            return SonnyTheme.ink
        case .secondary:
            return SonnyTheme.text
        case .danger:
            return SonnyTheme.text
        }
    }

    private var background: Color {
        switch tone {
        case .primary:
            return SonnyTheme.accent
        case .secondary:
            return SonnyTheme.surfaceRaised
        case .danger:
            return SonnyTheme.danger.opacity(0.58)
        }
    }

    private var border: Color {
        switch tone {
        case .primary:
            return SonnyTheme.accent.opacity(0.88)
        case .secondary:
            return SonnyTheme.border
        case .danger:
            return SonnyTheme.danger.opacity(0.7)
        }
    }
}

private struct SonnyVoiceCircleButtonStyle: ButtonStyle {
    let isActive: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SonnyType.icon(13, weight: .medium))
            .foregroundStyle(SonnyTheme.ink)
            .frame(width: 30, height: 30)
            .background(isActive ? SonnyTheme.danger : SonnyTheme.accent)
            .clipShape(Circle())
            .opacity(configuration.isPressed ? 0.72 : (isEnabled ? 1 : 0.4))
            .sonnyPointerCursor()
            .sonnyHoverHighlight(cornerRadius: 15)
    }
}
