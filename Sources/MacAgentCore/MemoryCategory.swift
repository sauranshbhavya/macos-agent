import Foundation

/// A kind of thing Sonny remembers, as the person meets it on Command Center's Memory page.
///
/// These are V2's own local stores (`KernelStores`), not a separate memory engine. V1 also had rows
/// for workspaces and skills, which the V2 plan removed, and for output locations and unfinished
/// tasks, which V2 doesn't keep as lists.
public enum MemoryCategory: String, CaseIterable, Identifiable, Sendable {
    case routines
    case taskHistory
    case recentArtifacts
    case clipboardHistory
    case snippets
    case approvedApps

    /// Which of the page's two groups a row sits in.
    public enum Kind: Sendable {
        /// Things the person asked Sonny to keep.
        case savedByYou
        /// Records of what happened.
        case recorded
    }

    public var id: String { rawValue }

    /// The row's name, in the words the rest of the app uses for these stores.
    public var title: String {
        switch self {
        case .routines: "Routines"
        case .taskHistory: "Task history"
        case .recentArtifacts: "Recent artifacts"
        case .clipboardHistory: "Clipboard history"
        case .snippets: "Snippets"
        case .approvedApps: "Allowed apps"
        }
    }

    /// The row's count with the thing it counts named — "1 snippet", "184 tasks". A bare "N saved"
    /// named no unit, so nothing told a count of entries apart from a number inside one of them.
    public func countedEntries(_ count: Int) -> String {
        "\(count) \(count == 1 ? singularNoun : pluralNoun)"
    }

    /// What one entry under this row is called. Lower-case: it is read mid-sentence, after a number.
    public var singularNoun: String {
        switch self {
        case .routines: "routine"
        case .taskHistory: "task"
        case .recentArtifacts: "artifact"
        // The noun the row's own delete confirmation uses ("every copied item Sonny has recorded").
        case .clipboardHistory: "copied item"
        case .snippets: "snippet"
        case .approvedApps: "app"
        }
    }

    /// Spelled out rather than derived: an "-s" rule is a guess about English.
    public var pluralNoun: String {
        switch self {
        case .routines: "routines"
        case .taskHistory: "tasks"
        case .recentArtifacts: "artifacts"
        case .clipboardHistory: "copied items"
        case .snippets: "snippets"
        case .approvedApps: "apps"
        }
    }

    /// V1's grouping: the person saves routines and snippets and allows apps; history, recent files
    /// and copied text are recorded as Sonny works.
    public var kind: Kind {
        switch self {
        case .routines, .snippets, .approvedApps: .savedByYou
        case .taskHistory, .recentArtifacts, .clipboardHistory: .recorded
        }
    }
}

/// The Memory page's two groups, in order, each listing its rows in `MemoryCategory.allCases` order
/// so a category added later lands in its group without a second ordering to keep.
public struct MemorySection: Identifiable, Equatable, Sendable {
    public static let all: [MemorySection] = [
        MemorySection(kind: .savedByYou, title: "Saved by you"),
        MemorySection(kind: .recorded, title: "Recorded as Sonny works")
    ]

    public let kind: MemoryCategory.Kind
    public let title: String

    public var id: String { title }

    public var categories: [MemoryCategory] {
        MemoryCategory.allCases.filter { $0.kind == kind }
    }
}
