import AppKit
import Foundation

public struct LocalActionDescriptor: Equatable, Sendable {
    public var capabilityID: String
    public var displayName: String
    public var description: String
    public var supportedActions: [AgentOperation]
    public var requiredPermissions: [CapabilityPermissionMetadata]
    public var defaultRiskTier: CapabilityRiskTier
    public var fallbackBehavior: String

    public init(
        capabilityID: String,
        displayName: String,
        description: String,
        supportedActions: [AgentOperation],
        requiredPermissions: [CapabilityPermissionMetadata],
        defaultRiskTier: CapabilityRiskTier,
        fallbackBehavior: String
    ) {
        self.capabilityID = capabilityID
        self.displayName = displayName
        self.description = description
        self.supportedActions = supportedActions
        self.requiredPermissions = requiredPermissions
        self.defaultRiskTier = defaultRiskTier
        self.fallbackBehavior = fallbackBehavior
    }
}

public enum AppWebsiteActionDescriptors {
    public static let openApp = LocalActionDescriptor(
        capabilityID: "local.apps.open-allowlisted-app",
        displayName: "Open allowlisted Mac app",
        description: "Open an app from the local allowlist by human app name.",
        supportedActions: [.openApp],
        requiredPermissions: [CapabilityPermissionMetadata(requirement: .appOpening)],
        defaultRiskTier: .tier1,
        fallbackBehavior: "Fail clearly when the requested app name is not in the allowlisted catalog or is not installed."
    )

    public static let openAppSearchURL = LocalActionDescriptor(
        capabilityID: "local.browser.open-app-search-url",
        displayName: "Open allowlisted search URL",
        description: "Open a fixed allowlisted app or website search URL template.",
        supportedActions: [.openAppSearchURL],
        requiredPermissions: [CapabilityPermissionMetadata(requirement: .browserOpening)],
        defaultRiskTier: .tier1,
        fallbackBehavior: "Fail clearly when the requested search target is not allowlisted."
    )

    public static let openURL = LocalActionDescriptor(
        capabilityID: "local.browser.open-url",
        displayName: "Open safe web URL",
        description: "Open a validated http or https URL in the default browser.",
        supportedActions: [.openURL],
        requiredPermissions: [CapabilityPermissionMetadata(requirement: .browserOpening)],
        defaultRiskTier: .tier1,
        fallbackBehavior: "Reject missing URLs, invalid URLs, and non-http/https schemes."
    )

    public static let openGeneratedArtifact = LocalActionDescriptor(
        capabilityID: "local.files.open-generated-artifact",
        displayName: "Open generated artifact",
        description: "Open an existing whitelisted generated file with the default local app.",
        supportedActions: [.openGeneratedArtifact],
        requiredPermissions: [CapabilityPermissionMetadata(requirement: .desktopDocumentsAccess)],
        defaultRiskTier: .tier1,
        fallbackBehavior: "Require an existing whitelisted file path, or resolve the previous generated artifact in a chain."
    )

    public static let createLocalDraft = LocalActionDescriptor(
        capabilityID: "local.files.create-local-draft",
        displayName: "Create local draft",
        description: "Create a local Markdown draft artifact in a whitelisted output path.",
        supportedActions: [.createLocalDraft],
        requiredPermissions: [CapabilityPermissionMetadata(requirement: .desktopDocumentsAccess)],
        defaultRiskTier: .tier2,
        fallbackBehavior: "Create only a local file; escalate before replacing an existing draft."
    )

    public static let openWorkspace = LocalActionDescriptor(
        capabilityID: "local.workspaces.open",
        displayName: "Open saved workspace",
        description: "Open the supported apps and safe URLs saved in a named workspace.",
        supportedActions: [.openWorkspace],
        requiredPermissions: [
            CapabilityPermissionMetadata(requirement: .appOpening),
            CapabilityPermissionMetadata(requirement: .browserOpening)
        ],
        defaultRiskTier: .tier1,
        // A workspace app outside `MacAppCatalog` is no longer a failure: scope listing was
        // decoupled from the launch catalog (SONNY-44), so such an entry is skipped and the open
        // succeeds. The other two failures are unchanged — a missing workspace has nothing to open,
        // and `SafeURL` is a capability bound rather than a user-declared boundary.
        fallbackBehavior: "Skip any saved app Sonny cannot launch and open the rest. Fail clearly when the workspace is missing or contains an unsafe URL."
    )

    public static let all: [LocalActionDescriptor] = [
        openApp,
        openAppSearchURL,
        openURL,
        openGeneratedArtifact,
        createLocalDraft,
        openWorkspace
    ]
}

public enum AppSearchURLCatalogError: Error, LocalizedError, Equatable {
    case missingSearchTarget
    case missingSearchQuery
    case searchTargetNotAllowed(String)
    case couldNotBuildURL(String)

    public var errorDescription: String? {
        switch self {
        case .missingSearchTarget:
            return "Opening a search URL requires an allowlisted search target."
        case .missingSearchQuery:
            return "Opening a search URL requires a search query."
        case .searchTargetNotAllowed(let target):
            return "\(target) is not an allowlisted search URL target."
        case .couldNotBuildURL(let target):
            return "Could not build the allowlisted search URL for \(target)."
        }
    }
}

public struct AppSearchURLTemplate: Equatable, Sendable {
    public var displayName: String
    public var aliases: [String]
    public var buildURL: @Sendable (String) -> URL?

    public init(displayName: String, aliases: [String] = [], buildURL: @escaping @Sendable (String) -> URL?) {
        self.displayName = displayName
        self.aliases = aliases
        self.buildURL = buildURL
    }

    public static func == (lhs: AppSearchURLTemplate, rhs: AppSearchURLTemplate) -> Bool {
        lhs.displayName == rhs.displayName && lhs.aliases == rhs.aliases
    }
}

public struct AppSearchURLCatalog: Equatable, Sendable {
    public var templates: [AppSearchURLTemplate]

    public init(templates: [AppSearchURLTemplate] = Self.default.templates) {
        self.templates = templates
    }

    public static let `default` = AppSearchURLCatalog(templates: [
        AppSearchURLTemplate(displayName: "Google", aliases: ["Web", "Safari", "Chrome"]) { query in
            searchURL(host: "www.google.com", path: "/search", queryItems: [URLQueryItem(name: "q", value: query)])
        },
        AppSearchURLTemplate(displayName: "GitHub", aliases: []) { query in
            searchURL(host: "github.com", path: "/search", queryItems: [URLQueryItem(name: "q", value: query)])
        },
        AppSearchURLTemplate(displayName: "YouTube", aliases: []) { query in
            searchURL(host: "www.youtube.com", path: "/results", queryItems: [URLQueryItem(name: "search_query", value: query)])
        },
        AppSearchURLTemplate(displayName: "Apple Music", aliases: ["Music"]) { query in
            searchURL(host: "music.apple.com", path: "/us/search", queryItems: [URLQueryItem(name: "term", value: query)])
        },
        AppSearchURLTemplate(displayName: "Spotify", aliases: []) { query in
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
            return URL(string: "https://open.spotify.com/search/\(encoded)")
        }
    ])

    public var displayList: String {
        templates.map(\.displayName).joined(separator: ", ")
    }

    public func resolve(target rawTarget: String?, query rawQuery: String?) throws -> AppSearchURL {
        guard let rawTarget, !rawTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppSearchURLCatalogError.missingSearchTarget
        }
        guard let query = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw AppSearchURLCatalogError.missingSearchQuery
        }

        let normalizedTarget = Self.normalize(rawTarget)
        guard let template = templates.first(where: { template in
            Self.normalize(template.displayName) == normalizedTarget ||
                template.aliases.contains(where: { Self.normalize($0) == normalizedTarget })
        }) else {
            throw AppSearchURLCatalogError.searchTargetNotAllowed(rawTarget)
        }

        guard let url = template.buildURL(query) else {
            throw AppSearchURLCatalogError.couldNotBuildURL(template.displayName)
        }
        return AppSearchURL(targetName: template.displayName, query: query, url: url)
    }

    private static func searchURL(host: String, path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = queryItems
        return components.url
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }
}

public struct AppSearchURL: Equatable, Sendable {
    public var targetName: String
    public var query: String
    public var url: URL
}

@MainActor
public protocol FileOpening {
    func openFile(_ url: URL) async throws
}

public enum FileOpeningError: Error, LocalizedError, Equatable {
    case failedToOpen(String)

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let path):
            return "Could not open file at \(path)."
        }
    }
}

public struct WorkspaceFileOpener: FileOpening {
    public init() {}

    @MainActor
    public func openFile(_ url: URL) async throws {
        guard NSWorkspace.shared.open(url) else {
            throw FileOpeningError.failedToOpen(url.path)
        }
    }
}
