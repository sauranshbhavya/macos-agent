import Foundation

public enum CapabilityRiskTier: Int, Codable, CaseIterable, Equatable, Sendable {
    case tier0 = 0
    case tier1 = 1
    case tier2 = 2
    case tier3 = 3
    case tier4 = 4

    public var displayName: String {
        "Tier \(rawValue)"
    }
}

public enum CapabilityExecutorLocation: String, Codable, Equatable, Sendable {
    case localMac = "local_mac"
}

public enum CapabilityPermissionEnforcement: String, Codable, Equatable, Sendable {
    case descriptiveOnly = "descriptive_only"
}

public enum CapabilityPermissionRequirement: String, Codable, CaseIterable, Equatable, Sendable {
    case desktopDocumentsAccess = "desktop_documents_access"
    case browserOpening = "browser_opening"
    case appOpening = "app_opening"
    case networkAccess = "network_access"
    case finderAutomation = "finder_automation"
    case wordAutomation = "word_automation"
    case shortcutsAutomation = "shortcuts_automation"

    public var displayName: String {
        switch self {
        case .desktopDocumentsAccess:
            return "Desktop/Documents access"
        case .browserOpening:
            return "Browser opening"
        case .appOpening:
            return "App opening"
        case .networkAccess:
            return "Network access"
        case .finderAutomation:
            return "Finder automation"
        case .wordAutomation:
            return "Microsoft Word automation"
        case .shortcutsAutomation:
            return "Shortcuts automation"
        }
    }

    public var description: String {
        switch self {
        case .desktopDocumentsAccess:
            return "macOS may require access to user-selected Desktop or Documents paths."
        case .browserOpening:
            return "Sonny may ask macOS to open a URL in the default browser."
        case .appOpening:
            return "Sonny may ask macOS to open an allowlisted app."
        case .networkAccess:
            return "Sonny may make a fixed network request for this capability."
        case .finderAutomation:
            return "Sonny may use a fixed Finder AppleScript template."
        case .wordAutomation:
            return "Sonny may use a fixed Microsoft Word AppleScript template."
        case .shortcutsAutomation:
            return "Sonny may invoke a named Apple Shortcut through the fixed Shortcuts CLI template."
        }
    }
}

public struct CapabilityPermissionMetadata: Codable, Equatable, Sendable {
    public var requirement: CapabilityPermissionRequirement
    public var enforcement: CapabilityPermissionEnforcement

    public init(
        requirement: CapabilityPermissionRequirement,
        enforcement: CapabilityPermissionEnforcement = .descriptiveOnly
    ) {
        self.requirement = requirement
        self.enforcement = enforcement
    }
}

public struct CapabilityMetadata: Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var description: String
    public var version: String
    public var operations: [AgentOperation]
    public var plannerTools: [AgentTool]
    public var requiredPermissions: [CapabilityPermissionMetadata]
    public var defaultRiskTier: CapabilityRiskTier
    public var executorLocation: CapabilityExecutorLocation

    public init(
        id: String,
        displayName: String,
        description: String,
        version: String = "1.0",
        operations: [AgentOperation],
        plannerTools: [AgentTool],
        requiredPermissions: [CapabilityPermissionMetadata] = [],
        defaultRiskTier: CapabilityRiskTier,
        executorLocation: CapabilityExecutorLocation = .localMac
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.version = version
        self.operations = operations
        self.plannerTools = plannerTools
        self.requiredPermissions = requiredPermissions
        self.defaultRiskTier = defaultRiskTier
        self.executorLocation = executorLocation
    }
}

public struct CapabilityExecutionContext {
    public typealias AssessNestedPlan = @MainActor (AgentPlan) throws -> CapabilityRiskAssessment
    public typealias PreviewNestedPlan = @MainActor (AgentPlan) throws -> [ActionPreview]
    /// Runs a nested plan, optionally binding a browser for every URL it opens on the injected
    /// browser-opener seam. `nil` means the
    /// nested plan keeps the system default, which is what every caller except a routine passes.
    public typealias ExecuteNestedPlan = @MainActor (AgentPlan, MacApp?, @escaping (AgentPhase, String) -> Void) async throws -> AgentRunResult

    public var whitelist: PathWhitelist
    public var inventory: FileInventory
    public var zipArchiver: any ZipArchiving
    public var documentConverter: any DocumentConverting
    public var browserOpener: any BrowserOpening
    public var hackerNewsFetcher: any HackerNewsFetching
    public var appCatalog: MacAppCatalog
    public var appSearchURLCatalog: AppSearchURLCatalog
    public var appOpener: any AppOpening
    public var fileOpener: any FileOpening
    public var mediaOpener: any MediaOpening
    public var spotifyPlaybackProvider: any SpotifyPlaybackProviding
    public var appleMusicPlaybackProvider: any AppleMusicPlaybackProviding
    public var finderContextReader: any FinderContextReading
    public var permissionReadinessService: PermissionReadinessService
    public var routineStore: RoutineStore
    public var workspaceStore: WorkspaceStore
    public var webPageLoader: PublicWebPageLoader
    public var webSearchProvider: any WebSearchProviding
    public var webResearchSynthesizer: any WebResearchSynthesizing
    public var clipboardHistoryStore: ClipboardHistoryStore
    public var snippetStore: SnippetStore
    public var runningAppSwitcher: any RunningAppSwitching
    public var recentArtifactStore: RecentArtifactStore
    public var shortcutCatalog: any ShortcutCatalogProviding
    public var shortcutInvoker: any ShortcutInvoking
    public var shortcutRunHistoryStore: ShortcutRunHistoryStore
    public var fileManager: FileManager
    public var now: () -> Date
    /// Live push-to-talk hotkey registration state. Read through a closure for the same reason
    /// as `now` — the real value lives in the UI layer and changes after launch, so a snapshot
    /// or a hardcoded `true` would misreport an actual Control-Option-Space conflict.
    public var hotKeyReady: () -> Bool
    /// The browser this execution should prefer for every URL it opens *on the injected
    /// browser-opener seam*, or `nil` for the system default. `.playMedia` is on a different seam
    /// and does not consult this (SONNY-51).
    ///
    /// Set only for the nested execution of a routine that names a browser-capable app among its
    /// own steps (SONNY-24), mirroring what a workspace already does with its apps list. It is
    /// `nil` for every top-level run, so a plain "open github.com" keeps going to the system
    /// default browser — the ordinary path must not inherit a routine's preference.
    public var preferredBrowser: MacApp?
    public var assessNestedPlan: AssessNestedPlan
    public var previewNestedPlan: PreviewNestedPlan
    public var executeNestedPlan: ExecuteNestedPlan

    public init(
        whitelist: PathWhitelist,
        inventory: FileInventory,
        zipArchiver: any ZipArchiving,
        documentConverter: any DocumentConverting,
        browserOpener: any BrowserOpening,
        hackerNewsFetcher: any HackerNewsFetching,
        appCatalog: MacAppCatalog,
        appSearchURLCatalog: AppSearchURLCatalog,
        appOpener: any AppOpening,
        fileOpener: any FileOpening,
        mediaOpener: any MediaOpening,
        spotifyPlaybackProvider: any SpotifyPlaybackProviding,
        appleMusicPlaybackProvider: any AppleMusicPlaybackProviding,
        finderContextReader: any FinderContextReading,
        permissionReadinessService: PermissionReadinessService,
        routineStore: RoutineStore,
        workspaceStore: WorkspaceStore,
        webPageLoader: PublicWebPageLoader,
        webSearchProvider: any WebSearchProviding,
        webResearchSynthesizer: any WebResearchSynthesizing,
        clipboardHistoryStore: ClipboardHistoryStore,
        snippetStore: SnippetStore,
        runningAppSwitcher: any RunningAppSwitching,
        recentArtifactStore: RecentArtifactStore,
        shortcutCatalog: any ShortcutCatalogProviding,
        shortcutInvoker: any ShortcutInvoking,
        shortcutRunHistoryStore: ShortcutRunHistoryStore,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        hotKeyReady: @escaping () -> Bool = { true },
        preferredBrowser: MacApp? = nil,
        assessNestedPlan: @escaping AssessNestedPlan,
        previewNestedPlan: @escaping PreviewNestedPlan,
        executeNestedPlan: @escaping ExecuteNestedPlan
    ) {
        self.whitelist = whitelist
        self.inventory = inventory
        self.zipArchiver = zipArchiver
        self.documentConverter = documentConverter
        self.browserOpener = browserOpener
        self.hackerNewsFetcher = hackerNewsFetcher
        self.appCatalog = appCatalog
        self.appSearchURLCatalog = appSearchURLCatalog
        self.appOpener = appOpener
        self.fileOpener = fileOpener
        self.mediaOpener = mediaOpener
        self.spotifyPlaybackProvider = spotifyPlaybackProvider
        self.appleMusicPlaybackProvider = appleMusicPlaybackProvider
        self.finderContextReader = finderContextReader
        self.permissionReadinessService = permissionReadinessService
        self.routineStore = routineStore
        self.workspaceStore = workspaceStore
        self.webPageLoader = webPageLoader
        self.webSearchProvider = webSearchProvider
        self.webResearchSynthesizer = webResearchSynthesizer
        self.clipboardHistoryStore = clipboardHistoryStore
        self.snippetStore = snippetStore
        self.runningAppSwitcher = runningAppSwitcher
        self.recentArtifactStore = recentArtifactStore
        self.shortcutCatalog = shortcutCatalog
        self.shortcutInvoker = shortcutInvoker
        self.shortcutRunHistoryStore = shortcutRunHistoryStore
        self.fileManager = fileManager
        self.now = now
        self.hotKeyReady = hotKeyReady
        self.preferredBrowser = preferredBrowser
        self.assessNestedPlan = assessNestedPlan
        self.previewNestedPlan = previewNestedPlan
        self.executeNestedPlan = executeNestedPlan
    }
}

public protocol CapabilityAdapter: Sendable {
    var metadata: CapabilityMetadata { get }

    @MainActor
    func resolveDefaultOutputs(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AgentPlan

    @MainActor
    func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview]

    @MainActor
    func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment

    @MainActor
    func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult
}

public extension CapabilityAdapter {
    @MainActor
    func resolveDefaultOutputs(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AgentPlan {
        plan
    }

    @MainActor
    func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        throw CapabilityRegistryError.notExecutable(metadata.id)
    }

    @MainActor
    func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        CapabilityRiskAssessment(defaultTier: metadata.defaultRiskTier)
    }

    @MainActor
    func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        throw CapabilityRegistryError.notExecutable(metadata.id)
    }
}

public struct MetadataOnlyCapabilityAdapter: CapabilityAdapter {
    public var metadata: CapabilityMetadata

    public init(metadata: CapabilityMetadata) {
        self.metadata = metadata
    }
}

public enum CapabilityRegistryError: Error, Equatable, LocalizedError {
    case duplicateCapabilityID(String)
    case duplicateOperation(AgentOperation, String, String)
    case unsupportedOperation(AgentOperation)
    case notExecutable(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateCapabilityID(let id):
            return "Capability ID \(id) is registered more than once."
        case .duplicateOperation(let operation, let firstID, let secondID):
            return "\(operation.rawValue) is registered by both \(firstID) and \(secondID)."
        case .unsupportedOperation(let operation):
            return "\(operation.rawValue) is not registered as an executable capability."
        case .notExecutable(let id):
            return "\(id) has metadata but no executor yet."
        }
    }
}

public struct CapabilityRegistry: Sendable {
    public var adapters: [any CapabilityAdapter]
    private var operationIndex: [AgentOperation: any CapabilityAdapter]

    public init(adapters: [any CapabilityAdapter]) throws {
        var seenIDs: Set<String> = []
        var operationIndex: [AgentOperation: any CapabilityAdapter] = [:]

        for adapter in adapters {
            let metadata = adapter.metadata
            if !seenIDs.insert(metadata.id).inserted {
                throw CapabilityRegistryError.duplicateCapabilityID(metadata.id)
            }

            for operation in metadata.operations {
                if let existing = operationIndex[operation] {
                    throw CapabilityRegistryError.duplicateOperation(
                        operation,
                        existing.metadata.id,
                        metadata.id
                    )
                }
                operationIndex[operation] = adapter
            }
        }

        self.adapters = adapters
        self.operationIndex = operationIndex
    }

    public static let `default`: CapabilityRegistry = {
        do {
            return try CapabilityRegistry(adapters: DefaultCapabilityAdapters.all())
        } catch {
            preconditionFailure("Default capability registry is invalid: \(error)")
        }
    }()

    public var metadata: [CapabilityMetadata] {
        adapters.map(\.metadata)
    }

    public var tools: [AgentTool] {
        adapters.flatMap(\.metadata.plannerTools)
    }

    public func adapter(for operation: AgentOperation) throws -> any CapabilityAdapter {
        guard let adapter = operationIndex[operation] else {
            throw CapabilityRegistryError.unsupportedOperation(operation)
        }
        return adapter
    }
}
