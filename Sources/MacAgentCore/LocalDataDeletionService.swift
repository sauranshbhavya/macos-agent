import Foundation

public struct LocalDataDeletionResult: Equatable, Sendable {
    public var deletedFileCount: Int
    public var missingFileCount: Int

    public init(deletedFileCount: Int, missingFileCount: Int) {
        self.deletedFileCount = deletedFileCount
        self.missingFileCount = missingFileCount
    }
}

public struct LocalDataDeletionService: @unchecked Sendable {
    private let fileManager: FileManager
    private let fileURLs: [URL]

    public init(fileManager: FileManager = .default, fileURLs: [URL]? = nil) {
        self.fileManager = fileManager
        self.fileURLs = fileURLs ?? Self.defaultStoreFileURLs(fileManager: fileManager)
    }

    public func deleteAllLocalData() throws -> LocalDataDeletionResult {
        var deletedFileCount = 0
        var missingFileCount = 0

        for fileURL in unique(fileURLs) {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
                deletedFileCount += 1
            } else {
                missingFileCount += 1
            }
        }

        return LocalDataDeletionResult(
            deletedFileCount: deletedFileCount,
            missingFileCount: missingFileCount
        )
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
