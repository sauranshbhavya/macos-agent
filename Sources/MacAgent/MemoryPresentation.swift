import Foundation
import MacAgentCore

/// One row of the Memory page: what it counts, when the newest entry landed, and whether it has a
/// switch. Values rather than expressions in the view, so a test can read them.
struct MemoryRowPresentation: Equatable {
    let category: MemoryCategory
    let title: String
    let systemImage: String
    let count: Int
    /// The row's "Remember" switch, for the one type V2 keeps a switch for: clipboard history, the
    /// same setting as Settings' "Keep clipboard history". Nil for every other row, which has none.
    let isRecording: Bool?
    /// "12 copied items · newest Today, 3:04 PM", or just the count when there is no date to show.
    let detailText: String

    /// An empty row has nothing to delete.
    var canDelete: Bool { count > 0 }

    /// Names its subject rather than reading as a bare "More actions".
    var moreActionsAccessibilityLabel: String { "More actions for \(title)" }

    init(category: MemoryCategory, count: Int, isRecording: Bool?, newestEntryDate: Date?, now: Date) {
        self.category = category
        self.title = category.title
        self.systemImage = Self.systemImage(for: category)
        self.count = count
        self.isRecording = isRecording
        let counted = category.countedEntries(count)
        if let newestEntryDate {
            detailText = "\(counted) · newest \(TaskHistoryDateFormatter.relativeTimestamp(for: newestEntryDate, now: now))"
        } else {
            detailText = counted
        }
    }

    /// A row whose entries have a page of their own shares that page's glyph.
    static func systemImage(for category: MemoryCategory) -> String {
        switch category {
        case .routines: CommandCenterDestination.routines.systemImage
        case .taskHistory: CommandCenterDestination.tasks.systemImage
        case .recentArtifacts: "doc"
        case .clipboardHistory: "doc.on.clipboard"
        case .snippets: "text.quote"
        case .approvedApps: "app.badge.checkmark"
        }
    }
}

/// One remembered item, as the entries sheet lists it.
struct MemoryEntryPresentation: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String

    var moreActionsAccessibilityLabel: String { "More actions for \(title)" }

    static func snippet(_ snippet: StoredSnippet) -> Self {
        Self(id: snippet.id.uuidString, title: snippet.trigger, detail: singleLine(snippet.expansion))
    }

    static func recentFile(_ artifact: RecentArtifact, now: Date) -> Self {
        Self(
            id: artifact.id.uuidString,
            title: artifact.title,
            detail: "\(TaskHistoryDateFormatter.relativeTimestamp(for: artifact.recordedAt, now: now)) · \(artifact.path)"
        )
    }

    static func copiedItem(_ item: ClipboardHistoryItem, now: Date) -> Self {
        Self(
            id: item.id.uuidString,
            title: singleLine(item.text),
            detail: TaskHistoryDateFormatter.relativeTimestamp(for: item.copiedAt, now: now)
        )
    }

    /// Keyed by the bundle identifier, which is what a grant is matched and forgotten by. The
    /// identifier shows beside the name so two builds calling themselves the same stay apart.
    static func approvedApp(_ app: ApprovedApp, now: Date) -> Self {
        let name = app.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            id: app.bundleIdentifier,
            title: name.isEmpty ? app.bundleIdentifier : app.displayName,
            detail: "\(app.bundleIdentifier) · allowed \(TaskHistoryDateFormatter.relativeTimestamp(for: app.approvedAt, now: now))"
        )
    }

    /// Collapses newlines so a multi-line copied item or snippet takes one row.
    static func singleLine(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .truncatedForRowDisplay(maxLength: 90)
    }
}

/// What a Delete on the Memory page did, or why it didn't.
struct MemoryStatus: Equatable {
    let text: String
    let isSuccess: Bool
}

/// The Memory page's confirmations, empty states and results, per category. A confirmation says
/// what goes and what stays, like every other destructive confirmation in the app.
enum MemoryDeletionCopy {
    static func message(for category: MemoryCategory) -> String {
        switch category {
        case .routines:
            "This deletes every saved routine and its schedule. Task history is not deleted."
        case .taskHistory:
            "This deletes every task Sonny has recorded, what each one planned, and the records of what Sonny did on screen. Files those tasks created are not deleted."
        case .recentArtifacts:
            "This deletes Sonny's list of files it recently worked with. The files themselves are not deleted."
        case .clipboardHistory:
            "This deletes every copied item Sonny has recorded. Your clipboard itself is not affected."
        case .snippets:
            "This deletes every saved snippet and its trigger."
        case .approvedApps:
            "This deletes every app you have allowed Sonny to control. Sonny asks again the next time it needs one of them."
        }
    }

    /// What removing one entry takes. Shorter than `message(for:)`, because the row names the entry.
    static func entryMessage(for category: MemoryCategory) -> String {
        switch category {
        case .recentArtifacts:
            "This removes Sonny's note about the file. The file itself is not deleted."
        case .clipboardHistory:
            "This removes the copied item from Sonny's history."
        case .snippets:
            "This deletes the snippet and its trigger."
        case .approvedApps:
            "Sonny asks again the next time it needs to control this app."
        case .routines, .taskHistory:
            // Unreachable: the sheet opens only for the types above; these are removed on their own pages.
            ""
        }
    }

    static func emptyTitle(for category: MemoryCategory) -> String {
        "No \(category.title.lowercased()) yet"
    }

    /// Paired with the command that ends the empty state.
    static func emptyMessage(for category: MemoryCategory) -> String {
        switch category {
        case .recentArtifacts:
            "Ask Sonny to create or convert a file, then it will appear here."
        case .clipboardHistory:
            "Copy something while clipboard history is on, and it will appear here."
        case .snippets:
            "Ask Sonny to save a snippet, then it will appear here."
        case .approvedApps:
            "Allow Sonny to control an app during a screen task, and it will appear here."
        case .routines, .taskHistory:
            // Unreachable: these rows open their own pages, which have their own empty states.
            ""
        }
    }

    /// No file count and no "starts over": the title is a plural noun phrase.
    static func outcome(for category: MemoryCategory) -> MemoryStatus {
        MemoryStatus(text: "Deleted \(category.title.lowercased()).", isSuccess: true)
    }

    static func failure(for category: MemoryCategory) -> MemoryStatus {
        MemoryStatus(text: "Could not delete \(category.title.lowercased()).", isSuccess: false)
    }

    static func entryFailure(for category: MemoryCategory) -> MemoryStatus {
        MemoryStatus(text: "Could not delete this \(category.singularNoun).", isSuccess: false)
    }

    /// A running task may be about to write the file this deletes.
    static let busy = MemoryStatus(text: "Finish or stop the current task before deleting memory.", isSuccess: false)
}
