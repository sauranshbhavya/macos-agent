import SwiftUI

// The Command Center's shared building blocks, kept from the V1 window when it was rewritten over
// `TaskDesk`: sign-in, first run and Settings all draw with them.

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(SonnyTheme.cardBorder)
            .frame(height: 1)
    }
}

/// A label and its control side by side, stacking when the column is too narrow for both.
struct SettingsAdaptiveControlRow<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: SonnySpacing.lg) {
                leading
                    .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                trailing
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: SonnySpacing.md) {
                leading
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, SonnySpacing.md)
    }
}

struct SettingsControlLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.xs) {
            Text(title)
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsPageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.sm) {
            Text(title)
                .font(SonnyType.settingsContentTitle)
                .foregroundStyle(SonnyTheme.text)
            Text(subtitle)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
        }
        .padding(.bottom, SonnySpacing.xs)
    }
}

/// A titled group of rows. The caller puts `SettingsDivider` between rows.
struct SettingsSectionBlock<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.md) {
            Text(title)
                .font(SonnyType.settingsSectionLabel)
                .foregroundStyle(SonnyTheme.text)
            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsAdaptiveControlRow {
            SettingsControlLabel(title: title, detail: detail)
        } trailing: {
            SonnySettingsToggle(isOn: $isOn)
                .accessibilityLabel(title)
        }
    }
}

struct SonnySettingsToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(SonnyTheme.accent)
    }
}

/// The three appearances; the change shows as soon as the menu closes and is kept for next launch.
struct SettingsThemeDropdown: View {
    @EnvironmentObject private var appearanceModel: SonnyAppearanceModel

    var body: some View {
        Picker("Interface theme", selection: $appearanceModel.appearance) {
            ForEach(SonnyAppearance.allCases) { appearance in
                Text(appearance.title).tag(appearance)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .tint(SonnyTheme.accent)
        .frame(width: SonnyMetrics.settingsControlWidth)
        .accessibilityLabel("Interface theme, \(appearanceModel.appearance.title) selected")
    }
}

/// The two density stops as a segmented control.
struct SettingsDensityPicker: View {
    @EnvironmentObject private var densityModel: SonnyDensityModel

    var body: some View {
        Picker("", selection: Binding(get: { densityModel.density }, set: { densityModel.density = $0 })) {
            ForEach(SonnyDensity.allCases) { stop in
                Text(stop.title).tag(stop)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .tint(SonnyTheme.accent)
        .fixedSize()
        .frame(minWidth: SonnyMetrics.settingsControlWidth, alignment: .leading)
        .accessibilityLabel("Density")
        .accessibilityValue(densityModel.density.title)
    }
}

/// What a list shows when it has nothing in it, with the page's first action when it has one.
struct CollectionEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var minHeight: CGFloat = 180
    var action: Action? = nil

    struct Action {
        let title: String
        let run: () -> Void
    }

    var body: some View {
        VStack(spacing: SonnySpacing.sm) {
            Image(systemName: systemImage)
                .font(SonnyType.icon(SonnyMetrics.iconEmptyState, weight: .light))
                .foregroundStyle(SonnyTheme.textTertiary)
                .padding(.bottom, SonnySpacing.xs)
            Text(title)
                .font(SonnyType.headline)
                .foregroundStyle(SonnyTheme.text)
            Text(message)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(SonnyButtonStyle(tone: .secondary))
                    .padding(.top, SonnySpacing.sm)
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .padding(SonnySpacing.xxl)
        .accessibilityElement(children: .contain)
    }
}

struct CommandCenterPageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.xs) {
            Text(title)
                .font(SonnyType.pageTitle)
                .foregroundStyle(SonnyTheme.text)
            if let subtitle {
                Text(subtitle)
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.muted)
            }
        }
        .frame(minHeight: SonnyMetrics.controlLarge, alignment: .leading)
    }
}

extension View {
    /// One inset from the window edge on all four sides, the canvas colour behind.
    func commandCenterPageFrame() -> some View {
        padding(SonnySpacing.pageInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SonnyTheme.ink)
    }

    /// The bordered panel a page's scrolling content sits in.
    func commandCenterPanel() -> some View {
        clipShape(RoundedRectangle(cornerRadius: SonnyRadius.card))
            .sonnyPanel()
    }
}
