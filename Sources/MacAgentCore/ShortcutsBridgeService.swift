import Foundation

public struct ShortcutRunHistoryRecord: Codable, Equatable, Sendable {
    public var shortcutName: String
    public var lastSuccessfulInvocationAt: Date?
    public var lastFailedInvocationAt: Date?

    public init(
        shortcutName: String,
        lastSuccessfulInvocationAt: Date? = nil,
        lastFailedInvocationAt: Date? = nil
    ) {
        self.shortcutName = shortcutName
        self.lastSuccessfulInvocationAt = lastSuccessfulInvocationAt
        self.lastFailedInvocationAt = lastFailedInvocationAt
    }

    public var hasCleanObservedSuccess: Bool {
        guard let lastSuccessfulInvocationAt else {
            return false
        }
        guard let lastFailedInvocationAt else {
            return true
        }
        return lastSuccessfulInvocationAt > lastFailedInvocationAt
    }
}

public struct ShortcutRunHistoryStore: @unchecked Sendable {
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
                .appendingPathComponent("shortcuts-run-history.json")
        }
    }

    public func hasCleanObservedSuccess(for shortcutName: String) throws -> Bool {
        try record(for: shortcutName)?.hasCleanObservedSuccess == true
    }

    public func recordSuccess(shortcutName: String, at date: Date = Date()) throws {
        var records = try loadAll()
        let key = normalizedShortcutName(shortcutName)
        records[key] = ShortcutRunHistoryRecord(
            shortcutName: shortcutName,
            lastSuccessfulInvocationAt: date,
            lastFailedInvocationAt: nil
        )
        try write(records)
    }

    public func recordFailure(shortcutName: String, at date: Date = Date()) throws {
        var records = try loadAll()
        let key = normalizedShortcutName(shortcutName)
        records[key] = ShortcutRunHistoryRecord(
            shortcutName: shortcutName,
            lastSuccessfulInvocationAt: nil,
            lastFailedInvocationAt: date
        )
        try write(records)
    }

    public func record(for shortcutName: String) throws -> ShortcutRunHistoryRecord? {
        try loadAll()[normalizedShortcutName(shortcutName)]
    }

    public func loadAll() throws -> [String: ShortcutRunHistoryRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            [String: ShortcutRunHistoryRecord].self,
            from: data,
            decoder: .shortcutHistoryISO8601
        )
        if decoded.wasLegacyPlaintext {
            try write(decoded.value)
        }
        return decoded.value
    }

    private func write(_ records: [String: ShortcutRunHistoryRecord]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(records, encoder: .shortcutHistoryPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

public enum ShortcutsBridgeError: Error, Equatable, LocalizedError {
    case missingShortcutName
    case unknownShortcut(String, [String])
    case listFailed(Int32, String)
    case invocationFailed(String, Int32, String)

    public var errorDescription: String? {
        switch self {
        case .missingShortcutName:
            return "Running a Shortcut requires a Shortcut name."
        case .unknownShortcut(let name, let available):
            if available.isEmpty {
                return "No Shortcut named \(name) was found."
            }
            return "No Shortcut named \(name) was found. Available Shortcuts: \(available.prefix(5).joined(separator: ", "))"
        case .listFailed(let code, let output):
            return "shortcuts list failed with exit code \(code): \(output)"
        case .invocationFailed(let name, let code, let output):
            return "Shortcut \(name) failed with exit code \(code): \(output)"
        }
    }
}

public protocol ShortcutCatalogProviding: Sendable {
    func shortcutNames() throws -> [String]
}

public protocol ShortcutProcessRunning: Sendable {
    func run(executablePath: String, arguments: [String]) async throws -> ProcessResult
}

public protocol ShortcutInvoking: Sendable {
    func invokeShortcut(name: String, input: String?) async throws -> ProcessResult
}

public struct ProcessShortcutCatalog: ShortcutCatalogProviding {
    public init() {}

    public func shortcutNames() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? "<unreadable process output>"
        guard process.terminationStatus == 0 else {
            throw ShortcutsBridgeError.listFailed(process.terminationStatus, output)
        }
        return output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

public struct AsyncShortcutProcessRunner: ShortcutProcessRunning {
    public init() {}

    public func run(executablePath: String, arguments: [String]) async throws -> ProcessResult {
        try await AsyncProcessRunner.run(executablePath: executablePath, arguments: arguments)
    }
}

public struct ProcessShortcutInvoker: ShortcutInvoking, @unchecked Sendable {
    private let processRunner: any ShortcutProcessRunning
    private let fileManager: FileManager

    public init(
        processRunner: any ShortcutProcessRunning = AsyncShortcutProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    public func invokeShortcut(name: String, input: String?) async throws -> ProcessResult {
        var arguments = ["run", name]
        var inputURL: URL?

        if let input = input?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty {
            let url = fileManager.temporaryDirectory
                .appendingPathComponent("sonny-shortcut-input-\(UUID().uuidString).txt")
            try Data(input.utf8).write(to: url, options: .atomic)
            inputURL = url
            arguments.append(contentsOf: ["--input-path", url.path])
        }

        defer {
            if let inputURL {
                try? fileManager.removeItem(at: inputURL)
            }
        }

        return try await processRunner.run(
            executablePath: "/usr/bin/shortcuts",
            arguments: arguments
        )
    }
}

public extension ShortcutCatalogProviding {
    func resolveShortcutName(_ rawName: String?) throws -> String {
        guard let rawName else {
            throw ShortcutsBridgeError.missingShortcutName
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw ShortcutsBridgeError.missingShortcutName
        }

        let names = try shortcutNames()
        if let exact = names.first(where: { normalizedShortcutName($0) == normalizedShortcutName(name) }) {
            return exact
        }
        throw ShortcutsBridgeError.unknownShortcut(name, names)
    }
}

public func normalizedShortcutName(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
}

private extension JSONEncoder {
    static var shortcutHistoryPrettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var shortcutHistoryISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
