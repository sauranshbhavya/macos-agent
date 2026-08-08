import Foundation

public struct AgentPlan: Codable, Equatable, Sendable {
    public var summary: String
    public var requiresConfirmation: Bool
    public var steps: [AgentStep]

    public init(summary: String, requiresConfirmation: Bool, steps: [AgentStep]) {
        self.summary = summary
        self.requiresConfirmation = requiresConfirmation
        self.steps = steps
    }
}

public struct AgentStep: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var operation: AgentOperation
    public var description: String
    public var inputPath: String?
    public var outputPath: String?
    public var count: Int?
    public var targetURL: String?
    public var appName: String?
    public var question: String?
    public var mediaProvider: MediaProvider?
    public var mediaTitle: String?
    public var mediaArtist: String?
    public var contextSource: FinderContextSource?
    public var routineName: String?
    public var routineSteps: [AgentStep]?
    public var workspaceName: String?
    /// Apps a workspace should contain. `create_workspace` reads it as the workspace's whole app
    /// list; `edit_workspace` reads it as the apps to *add*. Reused rather than paired with a
    /// `workspaceAppsToAdd` twin for the same reason the operation already decides what `appName`
    /// and `searchQuery` mean elsewhere: the field carries a value, the operation carries the verb.
    public var workspaceApps: [String]?
    /// URLs a workspace should contain — the whole list for `create_workspace`, the URLs to add for
    /// `edit_workspace`. Same reuse as `workspaceApps`.
    public var workspaceURLs: [String]?
    /// Folders to add to a workspace's restriction scope (`edit_workspace`). There is no
    /// `create_workspace` half on purpose: creation names apps and URLs, and file locations are
    /// configured afterwards by the edit path.
    public var workspaceFileLocations: [String]?
    public var workspaceAppsToRemove: [String]?
    public var workspaceURLsToRemove: [String]?
    public var workspaceFileLocationsToRemove: [String]?
    public var sourceURLs: [String]?
    public var searchQuery: String?
    public var draftTitle: String?
    public var draftContent: String?
    public var shortcutName: String?
    public var shortcutInput: String?
    /// The running app a `switch_running_app` step will actually activate, pinned exactly once by
    /// `RunningAppSwitchCapabilityAdapter.resolveDefaultOutputs` — the resolve phase every executor
    /// gate (`prepare`, `assessRisk`, `execute`) runs before doing anything else (SONNY-58). Nil
    /// until that phase runs; never emitted by the planner (the operation is schema-excluded) or
    /// the instant resolver. Once set, the pin is the identity: scope classifies it, the preview
    /// names it, and execution activates it or fails — nothing re-resolves the query.
    public var resolvedAppName: String?
    /// The pinned app's bundle identifier — the half of the pin execution activates by and scope
    /// matching compares first. Written together with `resolvedAppName`, never separately.
    public var resolvedBundleIdentifier: String?

    public init(
        id: String,
        operation: AgentOperation,
        description: String,
        inputPath: String? = nil,
        outputPath: String? = nil,
        count: Int? = nil,
        targetURL: String? = nil,
        appName: String? = nil,
        question: String? = nil,
        mediaProvider: MediaProvider? = nil,
        mediaTitle: String? = nil,
        mediaArtist: String? = nil,
        contextSource: FinderContextSource? = nil,
        routineName: String? = nil,
        routineSteps: [AgentStep]? = nil,
        workspaceName: String? = nil,
        workspaceApps: [String]? = nil,
        workspaceURLs: [String]? = nil,
        workspaceFileLocations: [String]? = nil,
        workspaceAppsToRemove: [String]? = nil,
        workspaceURLsToRemove: [String]? = nil,
        workspaceFileLocationsToRemove: [String]? = nil,
        sourceURLs: [String]? = nil,
        searchQuery: String? = nil,
        draftTitle: String? = nil,
        draftContent: String? = nil,
        shortcutName: String? = nil,
        shortcutInput: String? = nil,
        resolvedAppName: String? = nil,
        resolvedBundleIdentifier: String? = nil
    ) {
        self.id = id
        self.operation = operation
        self.description = description
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.count = count
        self.targetURL = targetURL
        self.appName = appName
        self.question = question
        self.mediaProvider = mediaProvider
        self.mediaTitle = mediaTitle
        self.mediaArtist = mediaArtist
        self.contextSource = contextSource
        self.routineName = routineName
        self.routineSteps = routineSteps
        self.workspaceName = workspaceName
        self.workspaceApps = workspaceApps
        self.workspaceURLs = workspaceURLs
        self.workspaceFileLocations = workspaceFileLocations
        self.workspaceAppsToRemove = workspaceAppsToRemove
        self.workspaceURLsToRemove = workspaceURLsToRemove
        self.workspaceFileLocationsToRemove = workspaceFileLocationsToRemove
        self.sourceURLs = sourceURLs
        self.searchQuery = searchQuery
        self.draftTitle = draftTitle
        self.draftContent = draftContent
        self.shortcutName = shortcutName
        self.shortcutInput = shortcutInput
        self.resolvedAppName = resolvedAppName
        self.resolvedBundleIdentifier = resolvedBundleIdentifier
    }
}

public enum AgentOperation: String, Codable, CaseIterable, Sendable {
    case scanSelectLargestFiles = "scan_select_largest_files"
    case createZip = "create_zip"
    case scanDocx = "scan_docx"
    case convertDocxToPDF = "convert_docx_to_pdf"
    case openHackerNews = "open_hacker_news"
    case fetchHNHeadlines = "fetch_hn_headlines"
    case writeMarkdown = "write_markdown"
    case webToMarkdown = "web_to_markdown"
    case openApp = "open_app"
    case openAppSearchURL = "open_app_search_url"
    case openURL = "open_url"
    case playMedia = "play_media"
    case getFinderSelection = "get_finder_selection"
    case revealInFinder = "reveal_in_finder"
    case showPermissionReadiness = "show_permission_readiness"
    case saveRoutine = "save_routine"
    case runRoutine = "run_routine"
    case createWorkspace = "create_workspace"
    case editWorkspace = "edit_workspace"
    case openWorkspace = "open_workspace"
    case openGeneratedArtifact = "open_generated_artifact"
    case createLocalDraft = "create_local_draft"
    case calculateUtility = "calculate_utility"
    case lookupClipboardHistory = "lookup_clipboard_history"
    case expandSnippet = "expand_snippet"
    case saveSnippet = "save_snippet"
    case switchRunningApp = "switch_running_app"
    case lookupRecentArtifacts = "lookup_recent_artifacts"
    case invokeShortcut = "invoke_shortcut"
    case clarify
    case unsupported

    public static var plannerVisibleCases: [AgentOperation] {
        allCases.filter { operation in
            switch operation {
            case .calculateUtility,
                 .lookupClipboardHistory,
                 .expandSnippet,
                 .saveSnippet,
                 .switchRunningApp,
                 .lookupRecentArtifacts:
                return false
            default:
                return true
            }
        }
    }
}

public enum MediaProvider: String, Codable, CaseIterable, Sendable {
    case appleMusic = "apple_music"
    case spotify

    public var displayName: String {
        switch self {
        case .appleMusic:
            return "Apple Music"
        case .spotify:
            return "Spotify"
        }
    }
}

public enum AgentPlanDecodingError: Error, Equatable, LocalizedError {
    case invalidJSON
    case unexpectedTopLevelKey(String)
    case unexpectedStepKey(String)
    case missingOutputText
    case malformedPlan(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Planner returned invalid JSON."
        case .unexpectedTopLevelKey(let key):
            return "Planner returned an unexpected top-level key: \(key)."
        case .unexpectedStepKey(let key):
            return "Planner returned an unexpected step key: \(key)."
        case .missingOutputText:
            return "Planner response did not include output text."
        case .malformedPlan(let detail):
            return "Planner returned a plan Sonny could not read: \(detail)"
        }
    }
}

public enum AgentPlanDecoder {
    private static let topLevelKeys: Set<String> = [
        "summary",
        "requiresConfirmation",
        "steps"
    ]

    private static let stepKeys: Set<String> = [
        "id",
        "operation",
        "description",
        "inputPath",
        "outputPath",
        "count",
        "targetURL",
        "appName",
        "question",
        "mediaProvider",
        "mediaTitle",
        "mediaArtist",
        "contextSource",
        "routineName",
        "routineSteps",
        "workspaceName",
        "workspaceApps",
        "workspaceURLs",
        "workspaceFileLocations",
        "workspaceAppsToRemove",
        "workspaceURLsToRemove",
        "workspaceFileLocationsToRemove",
        "sourceURLs",
        "searchQuery",
        "draftTitle",
        "draftContent",
        "shortcutName",
        "shortcutInput"
    ]

    public static func decodeStrict(from data: Data) throws -> AgentPlan {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw AgentPlanDecodingError.invalidJSON
        }

        for key in dictionary.keys where !topLevelKeys.contains(key) {
            throw AgentPlanDecodingError.unexpectedTopLevelKey(key)
        }

        guard let steps = dictionary["steps"] as? [[String: Any]] else {
            throw AgentPlanDecodingError.invalidJSON
        }

        for step in steps {
            try validateStepKeys(step)
        }

        // The key allowlist above only inspects key *names*. An unknown operation value or a
        // wrong field type still reaches the decoder, and a raw DecodingError would surface to
        // the user as unreadable Foundation text.
        do {
            return try JSONDecoder().decode(AgentPlan.self, from: data)
        } catch let error as DecodingError {
            throw AgentPlanDecodingError.malformedPlan(Self.describe(error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        case .keyNotFound(let key, _):
            return "missing field \(key.stringValue)"
        case .typeMismatch(let type, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "\(path.isEmpty ? "value" : path) is not a \(type)"
        case .valueNotFound(let type, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "\(path.isEmpty ? "value" : path) is missing a \(type)"
        @unknown default:
            return error.localizedDescription
        }
    }

    public static func decodeStrict(from text: String) throws -> AgentPlan {
        guard let data = text.data(using: .utf8) else {
            throw AgentPlanDecodingError.invalidJSON
        }
        return try decodeStrict(from: data)
    }

    private static func validateStepKeys(_ step: [String: Any]) throws {
        for key in step.keys where !stepKeys.contains(key) {
            throw AgentPlanDecodingError.unexpectedStepKey(key)
        }

        guard let routineSteps = step["routineSteps"] as? [[String: Any]] else {
            return
        }

        for nestedStep in routineSteps {
            try validateStepKeys(nestedStep)
        }
    }
}

public enum AgentPlanSchema {
    private static let stepRequiredKeys = [
        "id",
        "operation",
        "description",
        "inputPath",
        "outputPath",
        "count",
        "targetURL",
        "appName",
        "question",
        "mediaProvider",
        "mediaTitle",
        "mediaArtist",
        "contextSource",
        "routineName",
        "routineSteps",
        "workspaceName",
        "workspaceApps",
        "workspaceURLs",
        "workspaceFileLocations",
        "workspaceAppsToRemove",
        "workspaceURLsToRemove",
        "workspaceFileLocationsToRemove",
        "sourceURLs",
        "searchQuery",
        "draftTitle",
        "draftContent",
        "shortcutName",
        "shortcutInput"
    ]

    public static func responseFormat() -> [String: Any] {
        [
            "type": "json_schema",
            "name": "agent_plan",
            "strict": true,
            "schema": [
                "type": "object",
                "additionalProperties": false,
                "required": ["summary", "requiresConfirmation", "steps"],
                "properties": [
                    "summary": [
                        "type": "string",
                        "description": "Short human-readable summary of the proposed action."
                    ],
                    "requiresConfirmation": [
                        "type": "boolean",
                        "description": "True when the action writes files, opens apps, or converts documents."
                    ],
                    "steps": [
                        "type": "array",
                        "minItems": 1,
                        "items": stepSchema(allowsRoutineSteps: true)
                    ]
                ]
            ]
        ]
    }

    private static func stepSchema(allowsRoutineSteps: Bool) -> [String: Any] {
        var properties = baseStepProperties()
        properties["routineSteps"] = allowsRoutineSteps
            ? [
                "type": ["array", "null"],
                "description": "Nested executable steps for save_routine, or null.",
                "items": stepSchema(allowsRoutineSteps: false)
            ]
            : [
                "type": "null",
                "description": "Nested routines are not allowed."
            ]

        return [
            "type": "object",
            "additionalProperties": false,
            "required": stepRequiredKeys,
            "properties": properties
        ]
    }

    private static func baseStepProperties() -> [String: Any] {
        [
            "id": ["type": "string"],
            "operation": [
                "type": "string",
                "enum": AgentOperation.plannerVisibleCases.map(\.rawValue)
            ],
            "description": ["type": "string"],
            "inputPath": [
                "type": ["string", "null"],
                "description": "Folder or file path supplied by the user, or null."
            ],
            "outputPath": [
                "type": ["string", "null"],
                "description": "Destination folder or file path, reveal target path, or null."
            ],
            "count": [
                "type": ["integer", "null"],
                "description": "Requested count, such as top 3 files or top 5 headlines."
            ],
            "targetURL": [
                "type": ["string", "null"],
                "description": "URL for browser/fetch actions or exact provider result URI for media actions, or null."
            ],
            "appName": [
                "type": ["string", "null"],
                "description": "Human app name for open_app actions, or null."
            ],
            "question": [
                "type": ["string", "null"],
                "description": "Clarifying question for clarify actions, or null."
            ],
            "mediaProvider": [
                "type": ["string", "null"],
                "enum": (MediaProvider.allCases.map(\.rawValue) as [Any]) + [NSNull()],
                "description": "Music provider for media-opening actions, or null."
            ],
            "mediaTitle": [
                "type": ["string", "null"],
                "description": "Song or album title for media-opening actions, or null."
            ],
            "mediaArtist": [
                "type": ["string", "null"],
                "description": "Artist name for media-opening actions when provided by the user, or null."
            ],
            "contextSource": [
                "type": ["string", "null"],
                "enum": ([FinderContextSource.finderSelection.rawValue] as [Any]) + [NSNull()],
                "description": "Use finder_selection when the user refers to selected Finder items, or null."
            ],
            "routineName": [
                "type": ["string", "null"],
                "description": "Routine name for save_routine or run_routine, or null."
            ],
            "workspaceName": [
                "type": ["string", "null"],
                "description": "Workspace name for create_workspace, edit_workspace or open_workspace, or null."
            ],
            "workspaceApps": [
                "type": ["array", "null"],
                "description": "App names for create_workspace, or app names to add for edit_workspace, or null.",
                "items": ["type": "string"]
            ],
            "workspaceURLs": [
                "type": ["array", "null"],
                "description": "HTTP/HTTPS URLs for create_workspace, or URLs to add for edit_workspace, or null.",
                "items": ["type": "string"]
            ],
            "workspaceFileLocations": [
                "type": ["array", "null"],
                "description": "Folder paths inside Desktop or Documents to add to a workspace for edit_workspace, or null.",
                "items": ["type": "string"]
            ],
            "workspaceAppsToRemove": [
                "type": ["array", "null"],
                "description": "App names to remove from a workspace for edit_workspace, or null.",
                "items": ["type": "string"]
            ],
            "workspaceURLsToRemove": [
                "type": ["array", "null"],
                "description": "URLs or site domains to remove from a workspace for edit_workspace, or null.",
                "items": ["type": "string"]
            ],
            "workspaceFileLocationsToRemove": [
                "type": ["array", "null"],
                "description": "Folder paths to remove from a workspace for edit_workspace, or null.",
                "items": ["type": "string"]
            ],
            "sourceURLs": [
                "type": ["array", "null"],
                "description": "HTTP/HTTPS source URLs for web_to_markdown comparison notes, or null.",
                "items": ["type": "string"]
            ],
            "searchQuery": [
                "type": ["string", "null"],
                "description": "Topic or web search query for web_to_markdown research notes, or null."
            ],
            "draftTitle": [
                "type": ["string", "null"],
                "description": "Title for create_local_draft Markdown drafts, or null."
            ],
            "draftContent": [
                "type": ["string", "null"],
                "description": "User-provided body content for create_local_draft Markdown drafts, or null."
            ],
            "shortcutName": [
                "type": ["string", "null"],
                "description": "Existing Apple Shortcut name for invoke_shortcut, or null."
            ],
            "shortcutInput": [
                "type": ["string", "null"],
                "description": "Simple text input to pass to invoke_shortcut through a temporary input file, or null."
            ]
        ]
    }
}
