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

    public init(fileManager: FileManager = .default, fileURLs: [URL]? = nil) {
        self.fileManager = fileManager
        self.fileURLs = fileURLs ?? Self.defaultStoreFileURLs(fileManager: fileManager)
    }

    /// Attempts every store even when one fails. Stopping at the first error would leave the
    /// remaining files — real user data this action promised to erase — silently untouched and
    /// unreported, which is the opposite of what a privacy wipe must do.
    public func deleteAllLocalData() throws -> LocalDataDeletionResult {
        var deletedFileCount = 0
        var missingFileCount = 0
        var failedFilePaths: [String] = []
        var failureDescriptions: [String] = []

        for fileURL in unique(fileURLs) {
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
            RoutineStore(fileManager: fileManager).fileURL,
            WorkspaceStore(fileManager: fileManager).fileURL,
            ClipboardHistoryStore(fileManager: fileManager).fileURL,
            ClipboardHistorySettingsStore(fileManager: fileManager).fileURL,
            SnippetStore(fileManager: fileManager).fileURL,
            RecentArtifactStore(fileManager: fileManager).fileURL,
            ShortcutRunHistoryStore(fileManager: fileManager).fileURL,
            TaskHistoryStore(fileManager: fileManager).fileURL
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
