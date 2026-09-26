import Foundation
import MacAgentCore

/// What the Memory page reads and deletes, over V2's own stores. History and routines are the
/// desk's, and allowed apps and the clipboard switch are the app model's, so Memory, Tasks,
/// Routines and Settings all show one copy of each. Snippets, recent files and copied items are
/// shown only here, so this model reads them.
@MainActor
final class MemoryModel: ObservableObject {
    @Published private(set) var snippets: [StoredSnippet] = []
    @Published private(set) var recentFiles: [RecentArtifact] = []
    @Published private(set) var copiedItems: [ClipboardHistoryItem] = []
    /// What the last whole-row Delete did.
    @Published private(set) var deletionStatus: MemoryStatus?
    /// Why the last Delete in the entries sheet didn't happen.
    @Published private(set) var entryFailure: MemoryStatus?

    let app: SonnyAppModel
    private var stores: KernelStores { app.stores }

    init(app: SonnyAppModel) {
        self.app = app
    }

    func refresh(now: Date = Date()) {
        snippets = ((try? stores.snippets.loadAll()) ?? [:]).values
            .sorted { $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending }
        recentFiles = (try? stores.recentFiles.loadAll(now: now)) ?? []
        copiedItems = (try? stores.clipboard.loadAll(now: now)) ?? []
        app.refreshApprovedApps()
    }

    // MARK: What the rows say

    func count(for category: MemoryCategory) -> Int {
        switch category {
        case .routines: app.desk.routines.count
        case .taskHistory: app.desk.history.count
        case .recentArtifacts: recentFiles.count
        case .clipboardHistory: copiedItems.count
        case .snippets: snippets.count
        case .approvedApps: app.approvedApps.count
        }
    }

    /// Routines answer nil, as they did in V1: the row's "newest" means the last thing recorded,
    /// and V1 showed no date for a saved routine.
    func newestEntryDate(for category: MemoryCategory) -> Date? {
        switch category {
        case .routines: nil
        case .taskHistory: app.desk.history.map(\.finishedAt).max()
        case .recentArtifacts: recentFiles.map(\.recordedAt).max()
        case .clipboardHistory: copiedItems.map(\.copiedAt).max()
        case .snippets: snippets.map(\.updatedAt).max()
        case .approvedApps: app.approvedApps.map(\.approvedAt).max()
        }
    }

    /// Clipboard history is the one type with a switch of its own; the others have none in V2.
    func isRecording(_ category: MemoryCategory) -> Bool? {
        category == .clipboardHistory ? app.clipboardHistoryOn : nil
    }

    func setRecording(_ isOn: Bool, for category: MemoryCategory) {
        guard category == .clipboardHistory else { return }
        app.setClipboardHistory(isOn)
    }

    func row(for category: MemoryCategory, now: Date = Date()) -> MemoryRowPresentation {
        MemoryRowPresentation(
            category: category,
            count: count(for: category),
            isRecording: isRecording(category),
            newestEntryDate: newestEntryDate(for: category),
            now: now
        )
    }

    /// The entries sheet's rows. Read from the same lists the row counts, so the two agree. Routines
    /// and task history have pages of their own and answer none.
    func entries(for category: MemoryCategory, now: Date = Date()) -> [MemoryEntryPresentation] {
        switch category {
        case .snippets: snippets.map(MemoryEntryPresentation.snippet)
        case .recentArtifacts: recentFiles.map { MemoryEntryPresentation.recentFile($0, now: now) }
        case .clipboardHistory: copiedItems.map { MemoryEntryPresentation.copiedItem($0, now: now) }
        case .approvedApps: app.approvedApps.map { MemoryEntryPresentation.approvedApp($0, now: now) }
        case .routines, .taskHistory: []
        }
    }

    // MARK: Deleting

    /// Forgets everything of one kind and leaves every other kind alone. Refused while a task is
    /// running, because that task may be about to write the store this deletes.
    func deleteAll(in category: MemoryCategory) async {
        guard !app.isTaskRunning else {
            deletionStatus = MemoryDeletionCopy.busy
            return
        }
        do {
            switch category {
            case .routines:
                for routine in app.desk.routines {
                    await app.desk.deleteRoutine(routine)
                }
                guard app.desk.routines.isEmpty else { throw MemoryDeletionFailed() }
            case .taskHistory:
                // The same delete as the Tasks page's Delete all.
                await app.desk.deleteAllHistory()
            case .recentArtifacts:
                try removeFile(stores.recentFiles.fileURL)
            case .clipboardHistory:
                try removeFile(stores.clipboard.fileURL)
            case .snippets:
                try removeFile(stores.snippets.fileURL)
            case .approvedApps:
                try removeFile(stores.approvedApps.fileURL)
            }
            deletionStatus = MemoryDeletionCopy.outcome(for: category)
        } catch {
            deletionStatus = MemoryDeletionCopy.failure(for: category)
        }
        refresh()
    }

    /// Removes one entry from the entries sheet, found by the id the sheet rendered. Routines and
    /// task history are removed on their own pages, so asking for one here does nothing.
    func delete(_ entry: MemoryEntryPresentation, in category: MemoryCategory) {
        entryFailure = nil
        do {
            switch category {
            case .snippets:
                guard let snippet = snippets.first(where: { $0.id.uuidString == entry.id }) else { return }
                try stores.snippets.delete(trigger: snippet.trigger)
            case .recentArtifacts:
                guard let id = UUID(uuidString: entry.id) else { return }
                try stores.recentFiles.delete(id: id)
            case .clipboardHistory:
                guard let id = UUID(uuidString: entry.id) else { return }
                try stores.clipboard.delete(id: id)
            case .approvedApps:
                try stores.approvedApps.forget(bundleIdentifier: entry.id)
            case .routines, .taskHistory:
                return
            }
        } catch {
            entryFailure = MemoryDeletionCopy.entryFailure(for: category)
        }
        refresh()
    }

    func clearEntryFailure() {
        entryFailure = nil
    }

    private func removeFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

private struct MemoryDeletionFailed: Error {}
