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
            // **The one user-facing sentence in the tree that still named an environment variable,
            // reworded on the founder's ratification of 2026-08-28** (SONNY-136). It read
            // "Microsoft Word is unavailable. Set MAC_AGENT_MOCK_DOCX=1 to create clearly marked
            // mock PDF placeholders." — an instruction that is right for a developer running the
            // suite and wrong for everyone else: this is thrown from a live path any user without
            // Word reaches, and exporting that flag does not give them a converted document, it
            // gives them a placeholder saying the conversion did not happen.
            //
            // **The flag itself is untouched and is not this ticket's**, which is why the change is
            // one string literal in this file and nothing else: `MAC_AGENT_MOCK_DOCX` is named on
            // SONNY-136's never-touch list, the read at `AutoDocumentConverter`'s `enabled:`
            // parameter stays, and the mock path behaves exactly as before. The ratification's own
            // discharge condition was "this file, one string literal".
            return "Microsoft Word isn't available, so Sonny can't convert this document."
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
    private let fileManager: FileManager
    private let enabled: Bool

    /// `enabled` and `fileManager` are seams, defaulted to exactly what this read before: the live
    /// environment and `FileManager.default`. They exist so the refuse-to-overwrite behavior below
    /// can be tested — `isAvailable` gated it behind a process-wide environment variable, and a test
    /// that has to `setenv` to reach a code path either runs serialized forever or leaks into every
    /// other test in the process. Same shape `TavilySearchProvider` and `OpenAITranscriber` use for
    /// their own environment reads, and `MicrosoftWordDocumentConverter` for its `fileManager`.
    ///
    /// The environment is now read once, when the converter is constructed, rather than on every
    /// `isAvailable` access. Nothing changes it mid-process, and reading it once makes a run
    /// self-consistent instead of able to flip halfway through.
    public init(
        fileManager: FileManager = .default,
        enabled: Bool = ProcessInfo.processInfo.environment["MAC_AGENT_MOCK_DOCX"] == "1"
    ) {
        self.fileManager = fileManager
        self.enabled = enabled
    }

    public var isAvailable: Bool {
        enabled
    }

    public var modeName: String {
        "Mock DOCX placeholder"
    }

    public var usesMockNaming: Bool {
        true
    }

    /// Writes a placeholder per pending record, **refusing an occupied destination** exactly as the
    /// real converter does.
    ///
    /// `Data.write(to:options:.atomic)` silently replaces an existing file, while
    /// `MicrosoftWordDocumentConverter` finishes with `moveItem`, which throws. That divergence is
    /// what made SONNY-28 read as "silent data loss" when the loss was only reachable with no Word
    /// installed and `MAC_AGENT_MOCK_DOCX=1`; a mock whose failure mode differs from the real thing
    /// at the one moment that matters is worse than no mock.
    ///
    /// This is the backstop for the collisions `FileInventory.docxFiles` cannot see, and there are
    /// two classes of them rather than the one an earlier version of this comment claimed. It said
    /// destination collisions inside one run "can no longer arise at all", which is not true and is
    /// the same absolute phrasing that was corrected in two other places and missed here (PR #41
    /// cycle-3, R2). What `docxFiles` rules out is same-scan collisions **as `DestinationKey`
    /// compares them**; what still reaches this guard is (a) a file that appeared between the scan and
    /// the write, and (b) a pair some volume folds together and `DestinationKey` does not.
    ///
    /// **(b) is narrower since SONNY-79 and is no longer the eszett class.** `DestinationKey.folded`
    /// now folds the way the volumes measured do — `Straße.pdf` against `STRASSE.pdf` renames rather
    /// than aborting — so what remains under (b) is a volume whose folding differs from Foundation's
    /// `.caseInsensitive` fold, which is not ruled out and is not enumerated. For whatever remains,
    /// this refusal is still the whole of the protection, and it is still why such a residual costs a
    /// partway-aborted batch and not a lost file.
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
            guard !fileManager.fileExists(atPath: record.destinationURL.path) else {
                throw DocumentConversionError.mockWriteFailed(
                    "Could not write mock PDF to \(record.destinationURL.path): a file already exists there."
                )
            }
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
