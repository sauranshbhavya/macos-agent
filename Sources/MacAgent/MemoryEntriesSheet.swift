import MacAgentCore
import SwiftUI

/// The entries of a memory type that has no page of its own, each one deletable. Routines and task
/// history open their own pages instead, whose editors this would be a worse copy of.
struct MemoryEntriesSheet: View {
    @ObservedObject var memory: MemoryModel
    /// Observed too, because allowed apps are the app model's list.
    @ObservedObject var model: SonnyAppModel
    let category: MemoryCategory
    @Binding var isPresented: Bool
    @State private var pendingDeletion: MemoryEntryPresentation?
    @Environment(\.sonnyDensity) private var density

    var body: some View {
        let entries = memory.entries(for: category)
        VStack(spacing: 0) {
            SonnyDialogHeader(title: category.title, closeLabel: "Close \(category.title)") {
                isPresented = false
            }

            SettingsDivider()

            if entries.isEmpty {
                CollectionEmptyState(
                    systemImage: "tray",
                    title: MemoryDeletionCopy.emptyTitle(for: category),
                    message: MemoryDeletionCopy.emptyMessage(for: category)
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: density.rowGap) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            MemoryEntryRow(entry: entry, isLast: index == entries.count - 1) {
                                pendingDeletion = entry
                            }
                        }
                    }
                }
            }

            if let failure = memory.entryFailure {
                SettingsDivider()
                MemoryStatusLine(status: failure)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SonnySpacing.xl)
                    .padding(.vertical, SonnySpacing.md)
            }
        }
        .onAppear { memory.clearEntryFailure() }
        // Confirmed, like every other per-row delete in Command Center: a misclick here can't be
        // undone.
        .confirmationDialog(
            pendingDeletion.map { "Delete \($0.title)?" } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingDeletion {
                Button("Delete", role: .destructive) {
                    memory.delete(pendingDeletion, in: category)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(MemoryDeletionCopy.entryMessage(for: category))
        }
        .sonnyDialogFrame(.regular)
    }
}

private struct MemoryEntryRow: View {
    let entry: MemoryEntryPresentation
    let isLast: Bool
    let delete: () -> Void
    @Environment(\.sonnyDensity) private var density

    var body: some View {
        HStack(spacing: SonnySpacing.md) {
            VStack(alignment: .leading, spacing: SonnySpacing.xs) {
                Text(entry.title)
                    .font(SonnyType.bodyEmphasis)
                    .foregroundStyle(SonnyTheme.text)
                    .lineLimit(1)
                Text(entry.detail)
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: SonnySpacing.md)

            SonnyOverflowMenu(accessibilityLabel: entry.moreActionsAccessibilityLabel) {
                Button("Delete", role: .destructive, action: delete)
                    .accessibilityLabel("Delete \(entry.title)")
            }
        }
        .padding(.horizontal, SonnySpacing.xl)
        .frame(height: density.scaled(52))
        .sonnyDivider(isLast ? Color.clear : SonnyTheme.cardBorder)
    }
}
