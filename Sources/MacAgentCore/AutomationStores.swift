import Foundation

public struct StoredRoutine: Codable, Equatable, Sendable {
    public var name: String
    public var steps: [AgentStep]

    public init(name: String, steps: [AgentStep]) {
        self.name = name
        self.steps = steps
    }

    public var plan: AgentPlan {
        AgentPlan(
            summary: "Run routine \(name).",
            requiresConfirmation: true,
            steps: steps
        )
    }
}

public struct StoredWorkspace: Codable, Equatable, Sendable {
    public var name: String
    public var apps: [String]
    public var urls: [String]

    public init(name: String, apps: [String], urls: [String]) {
        self.name = name
        self.apps = apps
        self.urls = urls
    }
}

public enum AutomationStoreError: Error, LocalizedError, Equatable {
    case missingName(String)
    case missingRoutine(String)
    case missingWorkspace(String)
    case emptyRoutine
    case emptyWorkspace
    case unsafeRoutineStep(String)

    public var errorDescription: String? {
        switch self {
        case .missingName(let kind):
            return "\(kind) needs a name."
        case .missingRoutine(let name):
            return "No routine named \(name) is saved."
        case .missingWorkspace(let name):
            return "No workspace named \(name) is saved."
        case .emptyRoutine:
            return "A routine needs at least one saved step."
        case .emptyWorkspace:
            return "A workspace needs at least one app or URL."
        case .unsafeRoutineStep(let operation):
            return "Routines cannot contain \(operation) steps."
        }
    }
}

public struct RoutineStore: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    private let encryption: LocalStorageEncryption

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared
    ) {
        self.fileManager = fileManager
        self.encryption = encryption
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = ClipboardHistoryStore.defaultDirectory(fileManager: fileManager)
                .appendingPathComponent("routines.json")
        }
    }

    public func save(_ routine: StoredRoutine) throws {
        var routines = try loadAll()
        routines[normalized(routine.name)] = routine
        try write(routines)
    }

    public func routine(named rawName: String) throws -> StoredRoutine {
        let name = try normalizedName(rawName, kind: "Routine")
        guard let routine = try loadAll()[name] else {
            throw AutomationStoreError.missingRoutine(rawName)
        }
        return routine
    }

    public func loadAll() throws -> [String: StoredRoutine] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode([String: StoredRoutine].self, from: data)
        if decoded.wasLegacyPlaintext {
            try write(decoded.value)
        }
        return decoded.value
    }

    private func write(_ routines: [String: StoredRoutine]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(routines, encoder: .prettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

public struct WorkspaceStore: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    private let encryption: LocalStorageEncryption

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared
    ) {
        self.fileManager = fileManager
        self.encryption = encryption
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = ClipboardHistoryStore.defaultDirectory(fileManager: fileManager)
                .appendingPathComponent("workspaces.json")
        }
    }

    public func save(_ workspace: StoredWorkspace) throws {
        var workspaces = try loadAll()
        workspaces[normalized(workspace.name)] = workspace
        try write(workspaces)
    }

    public func workspace(named rawName: String) throws -> StoredWorkspace {
        let name = try normalizedName(rawName, kind: "Workspace")
        guard let workspace = try loadAll()[name] else {
            throw AutomationStoreError.missingWorkspace(rawName)
        }
        return workspace
    }

    public func loadAll() throws -> [String: StoredWorkspace] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode([String: StoredWorkspace].self, from: data)
        if decoded.wasLegacyPlaintext {
            try write(decoded.value)
        }
        return decoded.value
    }

    private func write(_ workspaces: [String: StoredWorkspace]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(workspaces, encoder: .prettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

private func normalizedName(_ rawName: String?, kind: String) throws -> String {
    guard let rawName else {
        throw AutomationStoreError.missingName(kind)
    }
    let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw AutomationStoreError.missingName(kind)
    }
    return normalized(trimmed)
}

private func normalized(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
