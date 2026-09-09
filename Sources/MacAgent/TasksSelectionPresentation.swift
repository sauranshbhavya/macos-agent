import Foundation
import MacAgentCore

/// The pure selection logic behind the Tasks page's list-and-pane layout (row 11, the founders' ask
/// of 2026-09-09: "the finished task is viewed in a pane beside the list, Mail-style"). Kept free of
/// `SwiftUI` so `Tests/MacAgentTests/TasksSelectionPresentationTests.swift` can drive it directly —
/// the same reason `TaskSectionCollapsePresentation` and `JumpToPalettePresentation` exist as plain
/// value types in this target.
enum TasksSelectionPresentation {
    /// The task after `current` in the flattened list of every *expanded* section's visible rows,
    /// in section order — the same list ↑/↓ walks. `current` being `nil`, or naming a row that is
    /// no longer visible (deleted, or folded inside a section the user just collapsed), answers the
    /// first row instead of nothing — which is also what "select the first visible record" on first
    /// appearance reduces to, so the caller needs no separate case for it.
    ///
    /// Stops at the last row rather than wrapping back to the first, the same choice
    /// `JumpToPaletteSheet.moveSelection` makes for its own list.
    static func next(after current: String?, in sections: [TaskSectionPresentation]) -> String? {
        let ids = visibleIDs(sections)
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        return ids[min(index + 1, ids.count - 1)]
    }

    /// The mirror of `next(after:in:)`, moving backward and stopping at the first row.
    static func previous(before current: String?, in sections: [TaskSectionPresentation]) -> String? {
        let ids = visibleIDs(sections)
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        return ids[max(index - 1, 0)]
    }

    /// What the pane's selection becomes once the history reloads: kept when the selected task
    /// still exists, cleared otherwise. A deleted task is not a special case of its own — it is
    /// simply a refresh whose result no longer contains that id, and this rule already covers it.
    static func selectionAfterRefresh(current: String?, records: [CompletedTaskRecord]) -> String? {
        guard let current, records.contains(where: { $0.taskRowIdentity == current }) else {
            return nil
        }
        return current
    }

    /// Which status section a task belongs to, so a request naming a task can expand that section
    /// if the user had folded it away.
    ///
    /// **Takes `TaskHistorySection`, not `TaskSectionPresentation`** — deliberately, and it is the
    /// whole reason this function exists rather than a plain `first(where:)` at the call site. A
    /// collapsed `TaskSectionPresentation.visibleRecords` is empty by design (that is what makes a
    /// collapsed header still show its count without also showing its rows), so it cannot answer
    /// "where does this task live" for a task inside a section that is currently folded away.
    /// `TaskHistorySection.records` is the same records before that filter, so a task is findable
    /// here whether or not its section happens to be open right now.
    static func sectionContaining(taskID: String, sections: [TaskHistorySection]) -> String? {
        sections.first { section in section.records.contains { $0.taskRowIdentity == taskID } }?.id
    }

    private static func visibleIDs(_ sections: [TaskSectionPresentation]) -> [String] {
        sections.flatMap { $0.visibleRecords.map(\.taskRowIdentity) }
    }
}
