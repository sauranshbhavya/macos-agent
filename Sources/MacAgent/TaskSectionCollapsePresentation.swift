import Foundation
import MacAgentCore

/// Which of the Tasks page's status sections the user has collapsed.
///
/// Stored as the *collapsed* set rather than the expanded one on purpose: the default is
/// "everything expanded", and only a collapsed-set representation makes an absent/empty value mean
/// exactly that — including for a section that did not exist when the value was written (the page's
/// sections come and go with the history, since `TaskHistoryGrouping.groupedByOutcome` drops empty
/// ones). An expanded-set representation would have to enumerate every section that could ever
/// exist to say the same thing, and would silently collapse any new one.
///
/// A section's identity is its title, because that is already this codebase's section identity —
/// `TaskHistorySection.id` is literally `title`. The live "In Progress" group is not one of
/// `TaskHistoryGrouping`'s outcome sections (it renders from view-model state, not records), so its
/// identifier is spelled out below; it follows the same rule.
struct TaskSectionCollapseState: Equatable {
    static let inProgressSectionID = "In Progress"

    private(set) var collapsedSectionIDs: Set<String>

    init(collapsedSectionIDs: Set<String> = []) {
        self.collapsedSectionIDs = collapsedSectionIDs
    }

    func isExpanded(_ sectionID: String) -> Bool {
        !collapsedSectionIDs.contains(sectionID)
    }

    mutating func setExpanded(_ isExpanded: Bool, for sectionID: String) {
        if isExpanded {
            collapsedSectionIDs.remove(sectionID)
        } else {
            collapsedSectionIDs.insert(sectionID)
        }
    }

    mutating func toggle(_ sectionID: String) {
        setExpanded(!isExpanded(sectionID), for: sectionID)
    }
}

/// Plain `UserDefaults` persistence for `TaskSectionCollapseState` — which section is folded away
/// is a cosmetic display preference with no privacy sensitivity, so it uses the same mechanism as
/// `usePointerCursors`/`displayFullNames` rather than one of the encrypted local stores
/// (`.claude/rules/macagent-ui-conventions.md`, "Preferences").
///
/// It does not live on `AgentViewModel` alongside those two because nothing outside this page reads
/// it: the widget, the other Command Center pages, and every capability adapter are all indifferent
/// to it, so putting it in the shared view model would add published state that only one view ever
/// observes. That is a deliberate departure from the two-preference precedent, not an oversight —
/// the rule that mattered (plain `UserDefaults`, not an encrypted store) is the one being followed.
struct TaskSectionCollapseStore {
    static let defaultsKey = "com.sonny.preferences.tasksCollapsedSections"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// `object(forKey:) as? [String]` rather than `stringArray(forKey:)` for the same reason the
    /// preference rule bans `.bool(forKey:)`: a value of an unexpected type must fall back to the
    /// real default (everything expanded), not to whatever the typed accessor coerces it into.
    func load() -> TaskSectionCollapseState {
        let stored = userDefaults.object(forKey: Self.defaultsKey) as? [String] ?? []
        return TaskSectionCollapseState(collapsedSectionIDs: Set(stored))
    }

    /// Sorted so the persisted representation is stable — a `Set`'s iteration order is not, and an
    /// unstable one would rewrite the defaults file on every save with no actual change.
    func save(_ state: TaskSectionCollapseState) {
        userDefaults.set(state.collapsedSectionIDs.sorted(), forKey: Self.defaultsKey)
    }
}

/// One status section as the Tasks page renders it.
///
/// `count` is deliberately independent of `isExpanded`: a collapsed "Done" still reports how many
/// tasks are in it, so a run that finishes while the section is folded away is visible without
/// expanding it. `visibleRecords` is the collapsed half — empty while collapsed, the full list
/// while expanded — so the view never has to decide either question inline.
struct TaskSectionPresentation: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int
    let isExpanded: Bool
    let visibleRecords: [CompletedTaskRecord]

    init(section: TaskHistorySection, isExpanded: Bool) {
        id = section.id
        title = section.title
        count = section.records.count
        self.isExpanded = isExpanded
        visibleRecords = isExpanded ? section.records : []
    }

    static func sections(
        for historySections: [TaskHistorySection],
        collapse: TaskSectionCollapseState
    ) -> [TaskSectionPresentation] {
        historySections.map {
            TaskSectionPresentation(section: $0, isExpanded: collapse.isExpanded($0.id))
        }
    }
}
