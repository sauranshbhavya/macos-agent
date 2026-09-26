import MacAgentCore
import SwiftUI

/// Insights' "Recently completed" card.
struct TaskHistoryListPanel: View {
    let tasks: [FinishedTask]
    let title: String
    let emptyTitle: String
    let emptyMessage: String
    let openTask: (TaskID) -> Void
    @Environment(\.sonnyDensity) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.xs) {
            Text(title)
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)

            if tasks.isEmpty {
                CollectionEmptyState(
                    systemImage: "checkmark.circle",
                    title: emptyTitle,
                    message: emptyMessage,
                    minHeight: 96
                )
            } else {
                VStack(spacing: density.rowGap) {
                    ForEach(tasks) { task in
                        InsightsRecentActivityRow(task: task) { openTask(task.id) }
                    }
                }
            }
        }
        .padding(SonnySpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sonnyCard()
    }
}

/// A recently completed task, and the way into it: the row selects the task on the Tasks page.
/// Every row here is the same outcome, so it carries no status dot.
private struct InsightsRecentActivityRow: View {
    let task: FinishedTask
    let open: () -> Void
    @Environment(\.sonnyDensity) private var density

    var body: some View {
        Button(action: open) {
            HStack(spacing: SonnySpacing.sm) {
                Text(task.goal.isEmpty ? "Untitled task" : task.goal.sentenceCapitalized.truncatedForRowDisplay())
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: SonnySpacing.md)

                Text(timestamp)
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Image(systemName: "chevron.right")
                    .font(SonnyType.icon(SonnyMetrics.iconChevron, weight: .semibold))
                    .foregroundStyle(SonnyTheme.textTertiary)
            }
            .padding(.horizontal, SonnySpacing.sm)
            .frame(height: density.scaled(32))
            .contentShape(RoundedRectangle(cornerRadius: SonnyRadius.control))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -SonnySpacing.sm)
        .sonnyPointerCursor()
        .sonnyHoverHighlight(cornerRadius: SonnyRadius.control)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.goal), \(timestamp)")
        .accessibilityHint("Opens the task")
    }

    private var timestamp: String {
        TaskHistoryDateFormatter.relativeTimestamp(for: task.finishedAt, now: Date())
    }
}
