import Foundation

public struct LocalDataDeletionResult: Equatable, Sendable {
    public var deletedFileCount: Int
    public var missingFileCount: Int
    /// Paths that still hold data because deletion failed, newest failure last.
    public var failedFilePaths: [String]

    public init(
        deletedFileCount: Int,
        missingFileCount: Int,
        failedFilePaths: [String] = []
    ) {
        self.deletedFileCount = deletedFileCount
        self.missingFileCount = missingFileCount
        self.failedFilePaths = failedFilePaths
    }
}

public struct LocalDataDeletionError: Error, LocalizedError, Equatable {
    public var result: LocalDataDeletionResult
    public var underlyingDescriptions: [String]

    public init(result: LocalDataDeletionResult, underlyingDescriptions: [String]) {
        self.result = result
        self.underlyingDescriptions = underlyingDescriptions
    }

    public var errorDescription: String? {
        let fileNames = result.failedFilePaths
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .joined(separator: ", ")
        let deleted = "Deleted \(result.deletedFileCount) local data file\(result.deletedFileCount == 1 ? "" : "s")"
        let remaining = "\(result.failedFilePaths.count) could not be deleted and still hold data: \(fileNames)"
        let detail = underlyingDescriptions.first.map { " (\($0))" } ?? ""
        return "\(deleted), but \(remaining).\(detail)"
    }
}

public struct LocalDataDeletionService: @unchecked Sendable {
    private let fileManager: FileManager
    private let fileURLs: [URL]
    private let quarantine: LocalDataQuarantine

    public init(fileManager: FileManager = .default, fileURLs: [URL]? = nil) {
        self.fileManager = fileManager
        self.fileURLs = fileURLs ?? Self.defaultStoreFileURLs(fileManager: fileManager)
        self.quarantine = LocalDataQuarantine(fileManager: fileManager)
    }

    /// Attempts every store even when one fails. Stopping at the first error would leave the
    /// remaining files — real user data this action promised to erase — silently untouched and
    /// unreported, which is the opposite of what a privacy wipe must do.
    ///
    /// **Each store's set-aside files go too, and that is load-bearing rather than tidy**
    /// (SONNY-239). `LocalDataQuarantine` renames an unreadable file instead of unlinking it, so a
    /// store the user cleared from the Memory page leaves its bytes on disk under a suffixed name.
    /// Those bytes are the user's — folder paths, commands, routines — and a wipe that deleted only
    /// the exact thirteen names would leave them behind while reporting that everything was erased.
    /// Sonny cannot read them, which is not the same as their holding nothing.
    public func deleteAllLocalData() throws -> LocalDataDeletionResult {
        var deletedFileCount = 0
        var missingFileCount = 0
        var failedFilePaths: [String] = []
        var failureDescriptions: [String] = []

        for fileURL in unique(fileURLs) {
            // Before the existence check below, not inside it: a store whose own file was already
            // moved aside has nothing at its own path and everything at the suffixed one, which is
            // precisely the state this sweep exists for.
            for setAside in quarantine.quarantinedSiblings(of: fileURL) {
                do {
                    try fileManager.removeItem(at: setAside)
                    deletedFileCount += 1
                } catch {
                    failedFilePaths.append(setAside.path)
                    failureDescriptions.append(error.localizedDescription)
                }
            }

            guard fileManager.fileExists(atPath: fileURL.path) else {
                missingFileCount += 1
                continue
            }

            do {
                try fileManager.removeItem(at: fileURL)
                deletedFileCount += 1
            } catch {
                failedFilePaths.append(fileURL.path)
                failureDescriptions.append(error.localizedDescription)
            }
        }

        let result = LocalDataDeletionResult(
            deletedFileCount: deletedFileCount,
            missingFileCount: missingFileCount,
            failedFilePaths: failedFilePaths
        )

        guard failedFilePaths.isEmpty else {
            throw LocalDataDeletionError(result: result, underlyingDescriptions: failureDescriptions)
        }
        return result
    }

    public static func defaultStoreFileURLs(fileManager: FileManager = .default) -> [URL] {
        [
            // Row I's action journal. A wipe that left a record of every click Sonny made inside the
            // user's apps would be the loudest possible failure of a privacy wipe.
            VisionSessionJournalStore(fileManager: fileManager).fileURL,
            RoutineStore(fileManager: fileManager).fileURL,
            WorkspaceStore(fileManager: fileManager).fileURL,
            ClipboardHistoryStore(fileManager: fileManager).fileURL,
            ClipboardHistorySettingsStore(fileManager: fileManager).fileURL,
            SnippetStore(fileManager: fileManager).fileURL,
            RecentArtifactStore(fileManager: fileManager).fileURL,
            ShortcutRunHistoryStore(fileManager: fileManager).fileURL,
            TaskHistoryStore(fileManager: fileManager).fileURL,
            // Row E's plan details. Deleted with the same wipe as the rows they hang off — a wipe
            // that left the plan of every task Sonny ran would be the same failure as leaving the
            // rows themselves.
            TaskPlanDetailStore(fileManager: fileManager).fileURL,
            // Row J's per-app grants. A durable record of which apps the user let Sonny drive is
            // theirs to erase along with everything else — and leaving it behind would also leave
            // the wipe's own promise half-true.
            ApprovedAppStore(fileManager: fileManager).fileURL,
            // Row 13's common output locations (SONNY-209). A short list of folder paths, which
            // sounds harmless and is not: where somebody's work goes is a map of what they work on,
            // and folder names are theirs. Erased with the rest for the same reason as everything
            // above it.
            OutputLocationStore(fileManager: fileManager).fileURL,
            // Row 13's unfinished runs (SONNY-210). It holds a whole plan — the steps, the paths
            // they name, the draft text they carry — for a task the user started and did not
            // finish, which is as much of their content as any row in task history and is left
            // behind by a wipe that forgot it.
            ResumableTaskStore(fileManager: fileManager).fileURL
        ]
    }

    private func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result
    }
}
