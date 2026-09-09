import Foundation
import MacAgentCore

/// How many rows the Tasks page shows at once — Gmail's "first 50 / 100 / 500" idiom, for the
/// founders' ask of 2026-09-09: "there should be a feature where users can filter or sort the given
/// list by how many items they want to see... Having to show everything from the past 30 days is
/// going to make the tasks page very cluttered."
///
/// A plain value type, kept free of `SwiftUI`, so the capping rule and the footer's wording are
/// testable without a view — the same reason `TaskSectionCollapsePresentation` and
/// `TasksSelectionPresentation` exist as value types beside their views.
enum TaskListPageSize: Int, CaseIterable, Identifiable {
    case ten = 10
    case twentyFive = 25
    case fifty = 50
    case oneHundred = 100
    case all = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .ten: return "10"
        case .twentyFive: return "25"
        case .fifty: return "50"
        case .oneHundred: return "100"
        case .all: return "All"
        }
    }

    /// `nil` for `.all` — the one case with nothing to cap.
    var limit: Int? {
        self == .all ? nil : rawValue
    }

    static let defaultSize: TaskListPageSize = .twentyFive

    /// The first `limit` of `records`, in the order the caller already has them — this codebase's
    /// lists are newest first, and nothing here reorders. `.all` returns `records` untouched.
    static func visible(_ records: [CompletedTaskRecord], size: TaskListPageSize) -> [CompletedTaskRecord] {
        guard let limit = size.limit else { return records }
        return Array(records.prefix(limit))
    }

    /// The footer's wording — "25 of 69 shown" — or `nil` when nothing is hidden (the size is `.all`,
    /// or the list is already shorter than the smallest size), so the caller can drop the row
    /// entirely rather than show a footer that says nothing.
    static func footer(shown: Int, total: Int) -> String? {
        guard shown < total else { return nil }
        return "\(shown) of \(total) shown"
    }
}

/// Plain `UserDefaults` persistence for `TaskListPageSize`, on `TaskSectionCollapseStore`'s pattern:
/// a cosmetic display preference with no privacy sensitivity, so it lives beside `.standard` rather
/// than in one of the encrypted local stores (`.claude/rules/macagent-ui-conventions.md`,
/// "Preferences").
struct TaskListPageSizeStore {
    static let defaultsKey = "com.sonny.preferences.tasksPageSize"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// `object(forKey:) as? Int` rather than `integer(forKey:)`, for the same reason the preference
    /// rule bans `.bool(forKey:)`: a missing value or one of the wrong type must fall back to the
    /// real default, not to whatever the typed accessor coerces it into (`integer(forKey:)` reads a
    /// missing key as `0`, which happens to collide with `.all`'s own raw value — exactly the kind
    /// of silent wrong answer that rule exists to rule out). A stored value with no matching case
    /// (a size this build no longer offers) reads as the default the same way.
    func load() -> TaskListPageSize {
        guard let stored = userDefaults.object(forKey: Self.defaultsKey) as? Int,
              let size = TaskListPageSize(rawValue: stored) else {
            return .defaultSize
        }
        return size
    }

    func save(_ size: TaskListPageSize) {
        userDefaults.set(size.rawValue, forKey: Self.defaultsKey)
    }
}
