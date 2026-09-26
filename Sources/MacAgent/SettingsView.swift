import AppKit
import MacAgentCore
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case preferences
    case security
    case notifications
    case data

    var id: Self { self }

    var title: String {
        switch self {
        case .preferences: "Preferences"
        case .security: "Security & Access"
        case .notifications: "Notifications"
        case .data: "Data"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SonnyAppModel
    @ObservedObject var screenAccessModel: ScreenAccessOnboardingModel
    @Binding var isPresented: Bool
    @State private var selection: SettingsSection = .preferences
    @Environment(\.sonnyDensity) private var density

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
            Rectangle().fill(SonnyTheme.border).frame(width: 1).frame(maxHeight: .infinity)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    SonnyDialogCloseButton(accessibilityLabel: "Close Settings") { isPresented = false }
                }
                .padding(.horizontal, SonnySpacing.md)
                .padding(.top, SonnySpacing.md)
                ScrollView {
                    Group {
                        switch selection {
                        case .preferences: PreferencesPage()
                        case .security: SecurityPage(model: model, screenAccessModel: screenAccessModel)
                        case .notifications: NotificationsPage()
                        case .data: DataPage(model: model)
                        }
                    }
                    .padding(.horizontal, SonnySpacing.xxxl)
                    .padding(.top, SonnySpacing.sm)
                    .padding(.bottom, SonnySpacing.xxxl)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SonnyTheme.ink)
        }
        .sonnyDialogFrame(.wide)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: SonnySpacing.xs + 2) {
                Image(systemName: "gearshape").font(SonnyType.icon(SonnyMetrics.iconRow, weight: .medium))
                Text("Settings").font(SonnyType.headline)
            }
            .foregroundStyle(SonnyTheme.text)
            .padding(.horizontal, SonnySpacing.sm)
            .frame(height: SonnyMetrics.controlLarge)
            .padding(.bottom, SonnySpacing.sm)
            ForEach(SettingsSection.allCases) { section in
                let selected = selection == section
                Button { selection = section } label: {
                    Text(section.title)
                        .font(selected ? SonnyType.bodyEmphasis : SonnyType.body)
                        .foregroundStyle(selected ? SonnyTheme.text : SonnyTheme.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SonnySpacing.sm)
                        .frame(height: density.navRowHeight)
                        .background(RoundedRectangle(cornerRadius: SonnyRadius.control).fill(selected ? SonnyTheme.fillSelected : .clear))
                        .contentShape(RoundedRectangle(cornerRadius: SonnyRadius.control))
                }
                .buttonStyle(.plain)
                .sonnyPointerCursor()
                .sonnyHoverHighlight()
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, SonnySpacing.md)
        .padding(.vertical, SonnySpacing.lg)
        .frame(width: 200, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.sidebar)
    }
}

private struct PreferencesPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: "Preferences", subtitle: "How Sonny looks")
                .padding(.bottom, SonnySpacing.xl)
            SettingsDivider()
            SettingsSectionBlock(title: "Appearance") {
                SettingsAdaptiveControlRow {
                    SettingsControlLabel(title: "Interface theme", detail: "Light, dark or the system's")
                } trailing: {
                    SettingsThemeDropdown()
                }
                SettingsDivider()
                SettingsAdaptiveControlRow {
                    SettingsControlLabel(title: "Density", detail: "How much fits on a page")
                } trailing: {
                    SettingsDensityPicker()
                }
            }
            .padding(.top, SonnySpacing.xxl)
        }
        .frame(maxWidth: 700, alignment: .topLeading)
    }
}

private struct SecurityPage: View {
    @ObservedObject var model: SonnyAppModel
    @ObservedObject var screenAccessModel: ScreenAccessOnboardingModel
    @State private var isScreenAccessPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: "Security & Access", subtitle: "What Sonny may do without asking")
                .padding(.bottom, SonnySpacing.xl)
            SettingsDivider()

            SettingsSectionBlock(title: "Mode") {
                VStack(alignment: .leading, spacing: SonnySpacing.md) {
                    SonnyModeSegmentedControl(selection: $model.mode)
                    Text(model.mode.settingsDescription)
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, SonnySpacing.lg)
            }
            .padding(.top, SonnySpacing.xxl)
            .padding(.bottom, SonnySpacing.lg)
            SettingsDivider()

            SettingsSectionBlock(title: "Clipboard History") {
                SettingsToggleRow(
                    title: "Keep clipboard history",
                    detail: "Copied text, kept on this Mac",
                    isOn: Binding(get: { model.clipboardHistoryOn }, set: { model.setClipboardHistory($0) })
                )
            }
            .padding(.top, SonnySpacing.xxl)
            .padding(.bottom, SonnySpacing.lg)
            SettingsDivider()

            SettingsSectionBlock(title: "Screen Access") {
                SettingsAdaptiveControlRow {
                    SettingsControlLabel(
                        title: "Screen Recording and Accessibility",
                        detail: screenAccessModel.allGranted ? "Both are allowed" : "Sonny needs both to work in other apps"
                    )
                } trailing: {
                    Button("Set up") { isScreenAccessPresented = true }
                        .buttonStyle(SonnyButtonStyle(tone: .secondary, width: 96))
                }
                SettingsDivider()
                VStack(alignment: .leading, spacing: SonnySpacing.md) {
                    PermissionReadinessRows(items: model.permissions)
                    Button {
                        screenAccessModel.refresh()
                        model.refreshPermissions()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SonnyButtonStyle(tone: .tertiary, size: .small))
                }
                .padding(.vertical, SonnySpacing.lg)
            }
            .padding(.top, SonnySpacing.xxl)
            .padding(.bottom, SonnySpacing.lg)
            SettingsDivider()

            SettingsSectionBlock(title: "Allowed apps") {
                if model.approvedApps.isEmpty {
                    Text("No apps allowed yet")
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.muted)
                        .padding(.vertical, SonnySpacing.md)
                }
                ForEach(model.approvedApps, id: \.bundleIdentifier) { app in
                    SettingsAdaptiveControlRow {
                        SettingsControlLabel(title: app.displayName, detail: app.bundleIdentifier)
                    } trailing: {
                        Button("Remove") { model.forget(app) }
                            .buttonStyle(SonnyButtonStyle(tone: .secondary))
                    }
                    SettingsDivider()
                }
                Menu("Allow an app…") {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "App") { model.approve(app) }
                    }
                }
                .fixedSize()
                .padding(.vertical, SonnySpacing.md)
            }
            .padding(.top, SonnySpacing.xxl)
        }
        .frame(maxWidth: 700, alignment: .topLeading)
        .sheet(isPresented: $isScreenAccessPresented) {
            ScreenAccessOnboardingView(model: screenAccessModel, isPresented: $isScreenAccessPresented)
        }
    }

    /// Running apps with a window, not already allowed, and not ones Sonny never works in.
    private var runningApps: [NSRunningApplication] {
        let allowed = Set(model.approvedApps.map(\.bundleIdentifier))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .filter { app in
                guard let id = app.bundleIdentifier, !allowed.contains(id) else { return false }
                return ScreenControlPolicy.verdict(bundleIdentifier: id, displayName: app.localizedName ?? id).isEligible
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

private struct NotificationsPage: View {
    @EnvironmentObject private var preferences: SonnyNotificationPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: "Notifications", subtitle: "When Sonny tells you, while you're elsewhere")
                .padding(.bottom, SonnySpacing.xl)
            SettingsDivider()
            SettingsSectionBlock(title: "Notify me when") {
                ForEach(Array(SonnyNotificationKind.allCases.enumerated()), id: \.offset) { index, kind in
                    SettingsToggleRow(
                        title: kind.title,
                        detail: kind.settingsDetail,
                        isOn: Binding(get: { preferences.isEnabled(kind) }, set: { preferences.setEnabled($0, for: kind) })
                    )
                    if index < SonnyNotificationKind.allCases.count - 1 { SettingsDivider() }
                }
            }
            .padding(.top, SonnySpacing.xxl)
        }
        .frame(maxWidth: 700, alignment: .topLeading)
    }
}

private struct DataPage: View {
    @ObservedObject var model: SonnyAppModel
    @State private var isConfirming = false
    @State private var done: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: "Data", subtitle: "What Sonny keeps on this Mac")
                .padding(.bottom, SonnySpacing.xl)
            SettingsDivider()
            SettingsSectionBlock(title: "Task history") {
                SettingsAdaptiveControlRow {
                    SettingsControlLabel(
                        title: "Delete task history",
                        detail: historyDetail
                    )
                } trailing: {
                    Button("Delete", role: .destructive) { isConfirming = true }
                        .buttonStyle(SonnyButtonStyle(tone: .danger, width: 96))
                        .disabled(!model.desk.hasHistoryToDelete)
                }
                if let done {
                    Label(done, systemImage: "checkmark.circle")
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.success)
                }
            }
            .padding(.top, SonnySpacing.xxl)
        }
        .frame(maxWidth: 700, alignment: .topLeading)
        .confirmationDialog("Delete every task in history?", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.desk.deleteAllHistory()
                    done = "Deleted."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They're removed from this Mac.")
        }
    }

    private var historyDetail: String {
        if model.desk.unreadable.contains(.history) { return "Sonny couldn't read your task history." }
        return model.desk.history.isEmpty ? "No tasks kept" : "\(model.desk.history.count) finished tasks kept"
    }
}
