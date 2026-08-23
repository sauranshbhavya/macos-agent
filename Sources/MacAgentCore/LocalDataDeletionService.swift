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

    /// **Settings' whole wipe: every store file, and every file set aside from one.**
    ///
    /// Attempts every store even when one fails. Stopping at the first error would leave the
    /// remaining files — real user data this action promised to erase — silently untouched and
    /// unreported, which is the opposite of what a privacy wipe must do.
    ///
    /// **The set-aside files go too, and that is load-bearing rather than tidy** (SONNY-239).
    /// `LocalDataQuarantine` renames an unreadable file instead of unlinking it, so a store the user
    /// cleared from the Memory page leaves its bytes on disk under a suffixed name. Those bytes are
    /// the user's — folder paths, commands, routines — and a wipe that deleted only the exact
    /// thirteen names would leave them behind while reporting that everything was erased. Sonny
    /// cannot read them, which is not the same as their holding nothing.
    ///
    /// **This is the one door that sweeps, and `deleteStoreFilesOnly()` is the reason that sentence
    /// is now enforceable rather than aspirational** (PR #110 review, F2). Command Center's per-row
    /// Delete used to call *this* method, so an ordinary press on a readable row destroyed a file an
    /// earlier press had promised to keep — measured against the real types: set one aside, rewrite
    /// the store, press Delete, and the result was `deletedFileCount == 2` with the kept file gone.
    public func deleteAllLocalData() throws -> LocalDataDeletionResult {
        try delete(sweepingSetAsideFiles: true)
    }

    /// **Command Center's per-row Delete: the store files themselves, and nothing set aside from
    /// them.**
    ///
    /// The founder's decision of 2026-08-23 is that Sonny never destroys a file it cannot read,
    /// because a decrypt failure proves only that the bytes were written under a different key and
    /// SONNY-253's key migration can hand that key back. A per-row Delete is scoped to "forget this
    /// kind of memory", and a set-aside file is not part of that kind's memory — the row does not
    /// count it, the sheet does not list it, and the confirmation the user accepted when it was set
    /// aside said in so many words that Sonny keeps it.
    ///
    /// **The asymmetry with `deleteAllLocalData` is deliberate and is the smaller of two broken
    /// promises.** Leaving it means "Delete routines" leaves unreadable routine bytes on disk, which
    /// is real — but it is *disclosed* (the user was told the file is kept) and *recoverable*
    /// (Settings → Delete Local Data removes it, and that is the control the product already frames
    /// as the destructive one). Sweeping it here would destroy data the product promised to keep,
    /// undisclosed and with no undo. Disclosed-and-recoverable beats silent-and-final.
    public func deleteStoreFilesOnly() throws -> LocalDataDeletionResult {
        try delete(sweepingSetAsideFiles: false)
    }

    private func delete(sweepingSetAsideFiles: Bool) throws -> LocalDataDeletionResult {
        var deletedFileCount = 0
        var missingFileCount = 0
        var failedFilePaths: [String] = []
        var failureDescriptions: [String] = []

        for fileURL in unique(fileURLs) {
            // Before the existence check below, not inside it: a store whose own file was already
            // moved aside has nothing at its own path and everything at the suffixed one, which is
            // precisely the state this sweep exists for.
            if sweepingSetAsideFiles {
                for setAside in quarantine.quarantinedSiblings(of: fileURL) {
                    do {
                        try fileManager.removeItem(at: setAside)
                        deletedFileCount += 1
                    } catch {
                        failedFilePaths.append(setAside.path)
                        failureDescriptions.append(error.localizedDescription)
                    }
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
