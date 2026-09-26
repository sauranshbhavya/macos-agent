import AppKit
import MacAgentCore
import SwiftUI

/// Memory: everything Sonny keeps on this Mac, one row per kind, grouped into what the person saved
/// and what was recorded as Sonny worked. Each row can be viewed and deleted.
struct MemoryPage: View {
    @ObservedObject var model: SonnyAppModel
    @StateObject private var memory: MemoryModel
    /// Selects another sidebar page, for the rows whose entries live there.
    let openPage: (CommandCenterDestination) -> Void
    let openSettings: () -> Void
    @State private var entriesCategory: MemoryCategory?
    @State private var deletionCategory: MemoryCategory?
    @Environment(\.sonnyDensity) private var density

    init(
        model: SonnyAppModel,
        openPage: @escaping (CommandCenterDestination) -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.model = model
        _memory = StateObject(wrappedValue: MemoryModel(app: model))
        self.openPage = openPage
        self.openSettings = openSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.lg) {
            CommandCenterPageHeader(title: "Memory")
            preferencesPanel
            collectionPanel
        }
        .commandCenterPageFrame()
        .onAppear { memory.refresh() }
        // A task that ends may have saved a snippet or noted a file, and something copied in another
        // app lands while Sonny is in the background.
        .onReceive(model.desk.$history.dropFirst()) { _ in memory.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            memory.refresh()
        }
        .sheet(item: $entriesCategory) { category in
            MemoryEntriesSheet(
                memory: memory,
                model: model,
                category: category,
                isPresented: Binding(get: { entriesCategory != nil }, set: { if !$0 { entriesCategory = nil } })
            )
        }
        .confirmationDialog(
            deletionCategory.map { "Delete \($0.title.lowercased())?" } ?? "",
            isPresented: Binding(get: { deletionCategory != nil }, set: { if !$0 { deletionCategory = nil } }),
            titleVisibility: .visible
        ) {
            if let deletionCategory {
                Button("Delete", role: .destructive) {
                    Task { await memory.deleteAll(in: deletionCategory) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let deletionCategory {
                Text(MemoryDeletionCopy.message(for: deletionCategory))
            }
        }
    }

    /// Preferences are the existing Settings, surfaced here rather than kept a second time.
    private var preferencesPanel: some View {
        SettingsAdaptiveControlRow {
            SettingsControlLabel(title: "Preferences", detail: "Preferences, notifications, security and data.")
        } trailing: {
            Button("Open settings", action: openSettings)
                .buttonStyle(SonnyButtonStyle(tone: .secondary, size: .small))
        }
        .padding(.horizontal, SonnySpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sonnyCard()
    }

    private var collectionPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("All memory")
                    .font(SonnyType.headline)
                    .foregroundStyle(SonnyTheme.text)
                Spacer()
            }
            .padding(.horizontal, SonnySpacing.xl)
            .frame(height: density.listRowHeight)
            .sonnyDivider(SonnyTheme.border)

            ScrollView {
                LazyVStack(spacing: density.rowGap) {
                    ForEach(MemorySection.all) { section in
                        MemoryGroupHeader(title: section.title, count: section.categories.count)
                        ForEach(Array(section.categories.enumerated()), id: \.element) { index, category in
                            MemoryRow(
                                presentation: memory.row(for: category),
                                isLast: index == section.categories.count - 1,
                                view: { open(category) },
                                delete: { deletionCategory = category },
                                setRecording: { memory.setRecording($0, for: category) }
                            )
                        }
                    }
                }
            }

            if let status = memory.deletionStatus {
                SettingsDivider()
                MemoryStatusLine(status: status)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SonnySpacing.lg)
                    .padding(.vertical, SonnySpacing.md)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .commandCenterPanel()
    }

    private func open(_ category: MemoryCategory) {
        switch MemoryRowDestination.of(category) {
        case .page(let destination): openPage(destination)
        case .entriesSheet: entriesCategory = category
        }
    }
}

/// Where a Memory row's View leads: a type whose entries already have a page goes to that page,
/// and the rest open the entries sheet.
enum MemoryRowDestination: Equatable {
    case page(CommandCenterDestination)
    case entriesSheet

    static func of(_ category: MemoryCategory) -> MemoryRowDestination {
        switch category {
        case .routines: .page(.routines)
        case .taskHistory: .page(.tasks)
        case .recentArtifacts, .clipboardHistory, .snippets, .approvedApps: .entriesSheet
        }
    }
}

/// A group's band: its title and how many rows it holds.
private struct MemoryGroupHeader: View {
    let title: String
    let count: Int
    @Environment(\.sonnyDensity) private var density

    var body: some View {
        HStack(spacing: SonnySpacing.sm) {
            Text(title)
                .font(SonnyType.headline)
                .foregroundStyle(SonnyTheme.text)
            SonnyBadge(text: "\(count)", tone: .neutral)
        }
        .padding(.horizontal, SonnySpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: density.listRowHeight)
        .background(SonnyTheme.surfaceRaised)
        .sonnyDivider()
    }
}

private struct MemoryRow: View {
    let presentation: MemoryRowPresentation
    let isLast: Bool
    let view: () -> Void
    let delete: () -> Void
    let setRecording: (Bool) -> Void
    @Environment(\.sonnyDensity) private var density

    var body: some View {
        HStack(spacing: SonnySpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: SonnyRadius.control)
                    .fill(SonnyTheme.accentSubtle)
                Image(systemName: presentation.systemImage)
                    .font(SonnyType.icon(SonnyMetrics.iconRow, weight: .medium))
                    .foregroundStyle(SonnyTheme.accent)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: SonnySpacing.xs) {
                Text(presentation.title)
                    .font(SonnyType.bodyEmphasis)
                    .foregroundStyle(SonnyTheme.text)
                    .lineLimit(1)
                Text(presentation.detailText)
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: SonnySpacing.md)

            if let isRecording = presentation.isRecording {
                SonnySettingsToggle(isOn: Binding(get: { isRecording }, set: { setRecording($0) }))
                    .accessibilityLabel("Remember \(presentation.title)")
            }

            // View leads and Delete follows a divider: look before you remove. Delete stays live
            // while recording is off, since deleting what is stored is what someone who turned it
            // off wants next.
            SonnyOverflowMenu(accessibilityLabel: presentation.moreActionsAccessibilityLabel) {
                Button("View", action: view)
                    .accessibilityLabel("View \(presentation.title)")
                Divider()
                Button("Delete", role: .destructive, action: delete)
                    .disabled(!presentation.canDelete)
                    .accessibilityLabel("Delete \(presentation.title)")
            }
        }
        .padding(.horizontal, SonnySpacing.xl)
        .frame(height: density.scaled(44))
        .sonnyDivider(isLast ? Color.clear : SonnyTheme.cardBorder)
    }
}

/// A Delete's result under the list: a tick when it worked, a warning when it didn't.
struct MemoryStatusLine: View {
    let status: MemoryStatus

    var body: some View {
        Label(status.text, systemImage: status.isSuccess ? "checkmark.circle" : "exclamationmark.triangle")
            .font(SonnyType.micro)
            .foregroundStyle(status.isSuccess ? SonnyTheme.success : SonnyTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }
}
