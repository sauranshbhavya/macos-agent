import AppKit
import Foundation
import OSLog

/// Everything V2 keeps on this Mac, in one folder: `Application Support/Sonny/V2` (V2 plan decision
/// 1). Nothing here reads V1's stores; the first launch of V2 starts empty.
///
/// The typed operations still run V1 adapter bodies, which take V1's store types, so those types are
/// reused here at new locations inside the V2 folder.
@MainActor
public final class KernelStores {
    public let folder: URL
    /// One ledger per unfinished task, for exactly-once after a relaunch.
    public let ledgers: FileTaskLedgerStore
    public let history: FinishedTaskStore
    public let routines: RoutineGoalStore
    public let snippets: SnippetStore
    public let recentFiles: RecentArtifactStore
    public let shortcutRuns: ShortcutRunHistoryStore
    /// Holds the pages `start_watching` watches.
    public let watchers: ResumableTaskStore
    public let clipboard: ClipboardHistoryStore
    public let clipboardSettings: ClipboardHistorySettingsStore
    public let approvedApps: ApprovedAppStore

    public init(folder: URL, encryption: LocalStorageEncryption = .shared) {
        func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
        self.folder = folder
        ledgers = FileTaskLedgerStore(directory: folder.appendingPathComponent("ledgers", isDirectory: true), encryption: encryption)
        history = FinishedTaskStore(fileURL: file("history.json"), encryption: encryption)
        routines = RoutineGoalStore(fileURL: file("routines.json"), encryption: encryption)
        snippets = SnippetStore(fileURL: file("snippets.json"), encryption: encryption)
        recentFiles = RecentArtifactStore(fileURL: file("recent-files.json"), encryption: encryption)
        shortcutRuns = ShortcutRunHistoryStore(fileURL: file("shortcut-runs.json"), encryption: encryption)
        watchers = ResumableTaskStore(fileURL: file("watchers.json"), encryption: encryption)
        clipboard = ClipboardHistoryStore(fileURL: file("clipboard.json"), encryption: encryption)
        clipboardSettings = ClipboardHistorySettingsStore(fileURL: file("clipboard-settings.json"), encryption: encryption)
        approvedApps = ApprovedAppStore(fileURL: file("approved-apps.json"), encryption: encryption)
    }

    public static func applicationSupportFolder() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("Sonny/V2", isDirectory: true)
    }

    /// Removes what V1 kept beside the V2 folder (its history, routines, workspaces, memory and
    /// settings files), once. Nothing is migrated (V2 plan decision 1). The Keychain items V1 used
    /// are all still V2's own: the storage key, the account and the entitlement claim.
    ///
    /// It counts as done only once everything is gone, so an item it couldn't remove is tried again
    /// on the next launch. That is safe because V2 writes nothing beside its own folder.
    ///
    /// Returns the names it removed.
    @discardableResult
    public static func removeV1Data(v2Folder: URL, fileManager: FileManager = .default) -> [String] {
        let done = v2Folder.appendingPathComponent(".v1-data-removed")
        guard !fileManager.fileExists(atPath: done.path) else { return [] }
        let sonnyFolder = v2Folder.deletingLastPathComponent()
        let items = (try? fileManager.contentsOfDirectory(atPath: sonnyFolder.path)) ?? []
        var removed: [String] = []
        var failed = 0
        for item in items.sorted() where item != v2Folder.lastPathComponent {
            do {
                try fileManager.removeItem(at: sonnyFolder.appendingPathComponent(item))
                removed.append(item)
            } catch {
                failed += 1
                logger.warning("Could not remove V1 data \(item, privacy: .public): \(error.localizedDescription, privacy: .public). Trying again next launch.")
            }
        }
        try? fileManager.createDirectory(at: v2Folder, withIntermediateDirectories: true)
        if failed == 0 {
            fileManager.createFile(atPath: done.path, contents: Data())
        }
        return removed
    }

    private static let logger = Logger(subsystem: "com.sonny.macagent", category: "kernel-stores")

    /// An app's standing for screen control, asked from the screen controller's own actor: an
    /// app the person allowed is allowed, and everything else keeps the built-in standing.
    public nonisolated static func standing(
        approvedApps: ApprovedAppStore
    ) -> @Sendable (String) -> AppStanding {
        { bundleID in
            let builtIn = ScreenController.defaultStanding(bundleID)
            guard builtIn == .notAllowed else { return builtIn }
            let allowed = (try? approvedApps.loadAll()) ?? []
            return allowed.contains { $0.matches(bundleIdentifier: bundleID) } ? .allowed : .notAllowed
        }
    }

    /// Recognises the zero-model commands from the person's own snippets, recent files and
    /// shortcuts.
    public func instantResolver() -> InstantCommandResolver {
        InstantCommandResolver(snippetStore: snippets, recentArtifactStore: recentFiles)
    }

    /// What the adapter bodies behind the typed operations run with.
    public func capabilityContext(
        eventKit: any EventKitAccessing,
        focusRestorer: any FocusRestoring,
        permissions: PermissionReadinessService
    ) -> CapabilityExecutionContext {
        let whitelist = PathWhitelist()
        return CapabilityExecutionContext(
            whitelist: whitelist,
            inventory: FileInventory(),
            zipArchiver: ProcessZipArchiver(),
            documentConverter: AutoDocumentConverter(),
            browserOpener: WorkspaceBrowserOpener(),
            appCatalog: .default,
            installedAppResolver: InstalledAppResolver.shared,
            appSearchURLCatalog: .default,
            appOpener: WorkspaceAppOpener(),
            focusRestorer: focusRestorer,
            fileOpener: WorkspaceFileOpener(),
            mediaOpener: NativeMediaOpener(),
            spotifyPlaybackProvider: UnavailableSpotifyPlaybackProvider(),
            appleMusicPlaybackProvider: UnavailableAppleMusicPlaybackProvider(),
            finderContextReader: AppleScriptFinderContextReader(),
            permissionReadinessService: permissions,
            webPageLoader: PublicWebPageLoader.live(),
            clipboardHistoryStore: clipboard,
            snippetStore: snippets,
            runningAppSwitcher: WorkspaceRunningAppSwitcher.forThisMac(),
            recentArtifactStore: recentFiles,
            shortcutCatalog: ProcessShortcutCatalog(),
            shortcutInvoker: ProcessShortcutInvoker(),
            shortcutRunHistoryStore: shortcutRuns,
            resumableTaskStore: watchers,
            eventKit: eventKit
        )
    }
}
