import Foundation

@MainActor
public protocol DocumentConverting {
    var isAvailable: Bool { get }
    var modeName: String { get }
    /// Whether conversion destinations use the `.mock.pdf` placeholder naming. Must agree with
    /// what `convert(_:log:)` actually writes — destination naming is derived from the injected
    /// converter, never from a separately-constructed default instance.
    var usesMockNaming: Bool { get }
    func convert(_ records: [DocxRecord], log: @escaping (String) -> Void) async throws -> [DocxRecord]
}

public enum DocumentConversionError: Error, LocalizedError, Equatable {
    case wordUnavailable
    case conversionFailed(String)
    case mockWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .wordUnavailable:
            return "Microsoft Word is unavailable. Set MAC_AGENT_MOCK_DOCX=1 to create clearly marked mock PDF placeholders."
        case .conversionFailed(let detail):
            return "DOCX conversion failed: \(detail)"
        case .mockWriteFailed(let detail):
            return "Mock DOCX conversion failed: \(detail)"
        }
    }
}

public struct MicrosoftWordDocumentConverter: DocumentConverting {
    private let fileManager: FileManager
    private let wordAppPath: String

    public init(
        fileManager: FileManager = .default,
        wordAppPath: String = "/Applications/Microsoft Word.app"
    ) {
        self.fileManager = fileManager
        self.wordAppPath = wordAppPath
    }

    public var isAvailable: Bool {
        fileManager.fileExists(atPath: wordAppPath)
    }

    public var modeName: String {
        "Microsoft Word AppleScript"
    }

    public var usesMockNaming: Bool {
        false
    }

    public func convert(_ records: [DocxRecord], log: @escaping (String) -> Void) async throws -> [DocxRecord] {
        guard isAvailable else {
            throw DocumentConversionError.wordUnavailable
        }

        let pending = records.filter { !$0.skippedBecausePDFExists }
        var converted: [DocxRecord] = []
        for (index, record) in pending.enumerated() {
            log("Converting \(index + 1)/\(pending.count): \(record.sourceURL.lastPathComponent) to \(record.destinationURL.lastPathComponent)")
            try await runAppleScript(source: record.sourceURL, destination: record.destinationURL)
            converted.append(record)
            log("Converted \(index + 1)/\(pending.count): \(record.destinationURL.lastPathComponent)")
        }
        return converted
    }

    private func runAppleScript(source: URL, destination: URL) async throws {
        let temporaryPDF = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("macagent-\(UUID().uuidString).pdf")
        defer {
            try? fileManager.removeItem(at: temporaryPDF)
        }

        let script = """
        tell application "Microsoft Word"
            set sourceFile to POSIX file "\(Self.escapeAppleScript(source.path))"
            set outputFile to "\(Self.escapeAppleScript(temporaryPDF.path))"
            open sourceFile add to recent files false
            delay 0.5
            set activeDoc to active document
            try
                save as activeDoc file name outputFile file format format PDF add to recent files false
                close activeDoc saving no
            on error errMsg number errNum
                try
                    close activeDoc saving no
                end try
                error errMsg number errNum
            end try
        end tell
        """

        let result = try await AsyncProcessRunner.run(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", script]
        )

        guard result.terminationStatus == 0 else {
            throw DocumentConversionError.conversionFailed(result.output)
        }

        guard fileManager.fileExists(atPath: temporaryPDF.path) else {
            throw DocumentConversionError.conversionFailed("Microsoft Word did not produce a temporary PDF.")
        }

        do {
            try fileManager.moveItem(at: temporaryPDF, to: destination)
            OutputFileNormalizer.normalizeUserWritablePDF(at: destination, fileManager: fileManager)
        } catch {
            throw DocumentConversionError.conversionFailed("Could not move exported PDF to \(destination.path): \(error.localizedDescription)")
        }
    }

    private static func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum OutputFileNormalizer {
    static func normalizeUserWritablePDF(at url: URL, fileManager: FileManager = .default) {
        try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        let userName = NSUserName()
        if !userName.isEmpty {
            try? fileManager.setAttributes([.ownerAccountName: userName], ofItemAtPath: url.path)
        }

        try? fileManager.setAttributes([.groupOwnerAccountName: "staff"], ofItemAtPath: url.path)
    }
}

public struct MockDocumentConverter: DocumentConverting {
    public init() {}

    public var isAvailable: Bool {
        ProcessInfo.processInfo.environment["MAC_AGENT_MOCK_DOCX"] == "1"
    }

    public var modeName: String {
        "Mock DOCX placeholder"
    }

    public var usesMockNaming: Bool {
        true
    }

    public func convert(_ records: [DocxRecord], log: @escaping (String) -> Void) async throws -> [DocxRecord] {
        guard isAvailable else {
            throw DocumentConversionError.wordUnavailable
        }

        let pending = records.filter { !$0.skippedBecausePDFExists }
        var converted: [DocxRecord] = []
        for (index, record) in pending.enumerated() {
            log("Writing mock placeholder \(index + 1)/\(pending.count): \(record.destinationURL.lastPathComponent)")
            let markdown = """
            Mock PDF placeholder
            Source DOCX: \(record.sourceURL.path)
            Created by Sonny because Microsoft Word was unavailable and MAC_AGENT_MOCK_DOCX=1 was set.
            """
            do {
                try markdown.data(using: .utf8)?.write(to: record.destinationURL, options: .atomic)
            } catch {
                throw DocumentConversionError.mockWriteFailed(error.localizedDescription)
            }
            converted.append(record)
            log("Wrote mock placeholder \(index + 1)/\(pending.count): \(record.destinationURL.lastPathComponent)")
        }
        return converted
    }
}

public struct AutoDocumentConverter: DocumentConverting {
    private let word: MicrosoftWordDocumentConverter
    private let mock: MockDocumentConverter

    public init(
        word: MicrosoftWordDocumentConverter = MicrosoftWordDocumentConverter(),
        mock: MockDocumentConverter = MockDocumentConverter()
    ) {
        self.word = word
        self.mock = mock
    }

    public var isAvailable: Bool {
        word.isAvailable || mock.isAvailable
    }

    public var modeName: String {
        word.isAvailable ? word.modeName : mock.modeName
    }

    public var usesMockNaming: Bool {
        word.isAvailable ? word.usesMockNaming : mock.usesMockNaming
    }

    public func convert(_ records: [DocxRecord], log: @escaping (String) -> Void) async throws -> [DocxRecord] {
        if word.isAvailable {
            return try await word.convert(records, log: log)
        }
        return try await mock.convert(records, log: log)
    }
}
