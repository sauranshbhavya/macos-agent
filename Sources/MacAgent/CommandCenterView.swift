import MacAgentCore
import SwiftUI

enum CommandCenterDestination: String, CaseIterable, Identifiable {
    case tasks
    case routines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .routines: "Routines"
        }
    }

    var systemImage: String {
        switch self {
        case .tasks: "checklist"
        case .routines: "clock.arrow.circlepath"
        }
    }
}

/// The main window: the green sidebar (Bhavya's 336959ca) and the Tasks and Routines pages, with
/// Settings, the account, first run, shortcuts and About as sheets.
struct CommandCenterView: View {
    @ObservedObject var model: SonnyAppModel
    @ObservedObject var accountModel: SonnyAccountModel
    @ObservedObject var screenAccessModel: ScreenAccessOnboardingModel
    @ObservedObject var firstRunCoordinator: FirstRunCoordinator
    @EnvironmentObject private var commands: CommandCenterCommands
    @EnvironmentObject private var densityModel: SonnyDensityModel
    @EnvironmentObject private var commandKeyHints: CommandKeyHintModel
    @State private var selection: CommandCenterDestination = .tasks
    @State private var isSettingsPresented = false
    @State private var isSignInPresented = false
    @State private var isShortcutsPresented = false
    @State private var isAboutPresented = false
    @State private var isAccountMenuPresented = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(SonnyTheme.border).frame(width: 1)
            Group {
                switch selection {
                case .tasks: TasksPage(model: model)
                case .routines: RoutinesPage(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(action: { isSettingsPresented = true }) { EmptyView() }
                .keyboardShortcut(",", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            Button(action: { isShortcutsPresented = true }) { EmptyView() }
                .keyboardShortcut("/", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(SonnyTheme.ink)
        .foregroundStyle(SonnyTheme.text)
        .tint(SonnyTheme.accent)
        .environment(\.sonnyDensity, densityModel.density)
        .onAppear { model.refreshPermissions() }
        .onChange(of: commands.settingsRequests) { _, _ in isSettingsPresented = true }
        .onChange(of: commands.aboutRequests) { _, _ in isAboutPresented = true }
        .onChange(of: commands.shortcutsRequests) { _, _ in isShortcutsPresented = true }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(model: model, screenAccessModel: screenAccessModel, isPresented: $isSettingsPresented)
        }
        .sheet(isPresented: $isShortcutsPresented) {
            KeyboardShortcutsSheet(isPresented: $isShortcutsPresented)
        }
        .sheet(isPresented: $isAboutPresented) {
            AboutSonnySheet(isPresented: $isAboutPresented)
        }
        .sheet(isPresented: $isSignInPresented) {
            SignInDialogView(
                model: accountModel,
                isPresented: $isSignInPresented,
                creditBalance: model.credits,
                refreshCreditBalance: { await model.refreshCredits() },
                creditAutoTopUp: CreditAutoTopUpControl(
                    isBusy: model.isSettingAutoTopUp,
                    failure: model.autoTopUpFailure,
                    set: { await model.setAutoTopUp($0) }
                )
            )
        }
        .sheet(isPresented: Binding(
            get: { firstRunCoordinator.presentedStep != nil },
            set: { if !$0 { firstRunCoordinator.withdrawUnanswered() } }
        )) {
            FirstRunSequenceView(
                coordinator: firstRunCoordinator,
                accountModel: accountModel,
                screenAccessModel: screenAccessModel
            )
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.lg) {
            HStack(spacing: SonnySpacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: SonnyRadius.control)
                        .fill(SonnyTheme.sidebarBrandGoldSubtle)
                    SonnyBrandMark(size: 22)
                        .foregroundStyle(SonnyTheme.sidebarBrandGold)
                }
                .frame(width: SonnyMetrics.controlLarge, height: SonnyMetrics.controlLarge)
                Text("Sonny")
                    .font(SonnyType.sidebarWordmark)
                    .foregroundStyle(SonnyTheme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SonnySpacing.sm)

            Button(action: model.showWidget) {
                HStack(spacing: SonnySpacing.sm) {
                    Image(systemName: "plus")
                        .font(SonnyType.icon(SonnyMetrics.iconButton, weight: .semibold))
                    Text("Ask Sonny")
                    Spacer(minLength: 0)
                    if commandKeyHints.isShowingHints {
                        CommandKeyHintBadge(chord: "⌘N")
                    } else {
                        Text("⌘N")
                            .font(SonnyType.mono)
                            .foregroundStyle(SonnyTheme.sidebarTextOnAccent.opacity(0.7))
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SonnyButtonStyle(tone: .sidebarPrimary))
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityLabel("Ask Sonny")

            VStack(spacing: 2) {
                ForEach(Array(CommandCenterDestination.allCases.enumerated()), id: \.element) { index, destination in
                    sidebarButton(destination, ordinal: index + 1)
                }
            }

            Spacer()

            profileRow
        }
        .padding(.horizontal, SonnySpacing.md)
        .padding(.vertical, SonnySpacing.lg)
        .frame(width: SonnyMetrics.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.sidebar)
        .tint(SonnyTheme.sidebarAccent)
    }

    private func sidebarButton(_ destination: CommandCenterDestination, ordinal: Int) -> some View {
        let selected = selection == destination
        let live = model.controller.tasks.filter { !$0.phase.isTerminal }.count
        return Button { selection = destination } label: {
            HStack(spacing: SonnySpacing.sm) {
                Image(systemName: destination.systemImage)
                    .font(SonnyType.icon(SonnyMetrics.iconSidebar, weight: .medium))
                    .foregroundStyle(selected ? SonnyTheme.text : SonnyTheme.muted)
                    .frame(width: 20)
                Text(destination.title)
                    .font(selected ? SonnyType.bodyEmphasis : SonnyType.body)
                    .foregroundStyle(SonnyTheme.text)
                Spacer(minLength: SonnySpacing.sm)
                if commandKeyHints.isShowingHints {
                    CommandKeyHintBadge(chord: "⌘\(ordinal)")
                } else if destination == .tasks, live > 0 {
                    Text("\(live)")
                        .font(SonnyType.microEmphasis.monospacedDigit())
                        .foregroundStyle(SonnyTheme.sidebarAccent)
                        .padding(.horizontal, SonnySpacing.sm - 2)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(SonnyTheme.sidebarAccentSubtle, in: RoundedRectangle(cornerRadius: SonnyRadius.control))
                        .accessibilityLabel(live == 1 ? "One task running" : "\(live) tasks running")
                }
            }
            .padding(.horizontal, SonnySpacing.sm)
            .frame(height: densityModel.density.navRowHeight)
            .background(RoundedRectangle(cornerRadius: SonnyRadius.control).fill(selected ? SonnyTheme.fillSelected : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: SonnyRadius.control))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(ordinal)")), modifiers: .command)
        .sonnyPointerCursor()
        .sonnyHoverHighlight()
        .accessibilityLabel(destination.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var profileRow: some View {
        Button { isAccountMenuPresented = true } label: {
            HStack(spacing: SonnySpacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: SonnyRadius.control)
                        .fill(SonnyTheme.sidebarAccentSubtle)
                    Text(profileName.prefix(1).uppercased())
                        .font(SonnyType.microEmphasis)
                        .foregroundStyle(SonnyTheme.sidebarAccent)
                }
                .frame(width: 22, height: 22)
                Text(profileName)
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(SonnyType.icon(SonnyMetrics.iconChevron, weight: .semibold))
                    .foregroundStyle(SonnyTheme.textTertiary)
            }
            .padding(.horizontal, SonnySpacing.sm)
            .frame(height: densityModel.density.listRowHeight)
            .contentShape(RoundedRectangle(cornerRadius: SonnyRadius.control))
        }
        .buttonStyle(.plain)
        .sonnyPointerCursor()
        .sonnyHoverHighlight()
        .accessibilityLabel("Account: \(profileName)")
        .popover(isPresented: $isAccountMenuPresented, arrowEdge: .top) {
            accountMenuContent
        }
    }

    private var accountMenuContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            menuRow(accountModel.isSignedIn ? "Account" : SignInCopy.signInLabel, "person.crop.circle") { isSignInPresented = true }
            menuRow("Settings", "gearshape") { isSettingsPresented = true }
            Rectangle().fill(SonnyTheme.border).frame(height: 1).padding(.vertical, SonnySpacing.xs)
            menuRow("Keyboard shortcuts", "keyboard") { isShortcutsPresented = true }
            menuRow("About Sonny", "info.circle") { isAboutPresented = true }
        }
        .padding(SonnySpacing.xs + 2)
        .frame(width: 220)
        .background(SonnyTheme.surfaceRaised2)
    }

    private func menuRow(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            isAccountMenuPresented = false
            action()
        } label: {
            HStack(spacing: SonnySpacing.sm) {
                Image(systemName: systemImage)
                    .font(SonnyType.icon(SonnyMetrics.iconRow, weight: .medium))
                    .foregroundStyle(SonnyTheme.muted)
                    .frame(width: 18)
                Text(title).font(SonnyType.body)
                Spacer(minLength: SonnySpacing.sm)
            }
            .foregroundStyle(SonnyTheme.text)
            .padding(.horizontal, SonnySpacing.sm)
            .frame(height: densityModel.density.compactRowHeight)
            .contentShape(RoundedRectangle(cornerRadius: SonnyRadius.control))
        }
        .buttonStyle(.plain)
        .sonnyPointerCursor()
        .sonnyHoverHighlight()
    }

    private var profileName: String {
        if let address = accountModel.signedInAddress { return address }
        let fullName = NSFullUserName()
        return fullName.isEmpty ? "Account" : fullName
    }
}
