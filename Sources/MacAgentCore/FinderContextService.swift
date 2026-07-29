import Foundation

public enum FinderContextError: Error, LocalizedError, Equatable {
    case noSelection
    case noDirectorySelection
    case automationPermissionDenied(String)
    case appleScriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSelection:
            return "Finder has no selected items."
        case .noDirectorySelection:
            return "Select one folder in Finder first."
        case .automationPermissionDenied:
            return "Sonny is not allowed to control Finder. Grant Automation access in System Settings > Privacy & Security > Automation."
        case .appleScriptFailed(let detail):
            return "Could not read Finder selection: \(detail)"
        }
    }

    /// Classifies an `osascript` failure from its output text. The exit code is a generic 1 for
    /// every AppleScript error, so the `-1743` authorization marker (user has not granted
    /// Automation access) is only distinguishable from the stderr text itself.
    public static func from(output: String) -> FinderContextError {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.contains("-1743") || detail.localizedCaseInsensitiveContains("Not authorized to send Apple events") {
            return .automationPermissionDenied(detail)
        }
        return .appleScriptFailed(detail)
    }
}

public protocol FinderContextReading: Sendable {
    func selectedItems() throws -> [URL]
}

public struct AppleScriptFinderContextReader: FinderContextReading {
    public init() {}

    public func selectedItems() throws -> [URL] {
        let script = """
        tell application id "com.apple.finder"
            set selectedItems to selection
            if (count of selectedItems) is 0 then return ""
            set output to ""
            repeat with selectedItem in selectedItems
                set output to output & POSIX path of (selectedItem as alias) & linefeed
            end repeat
            return output
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = ProcessOutputCapture.drainThenWait(process: process, pipe: pipe)
        guard process.terminationStatus == 0 else {
            throw FinderContextError.from(output: output)
        }

        let urls = output
            .split(whereSeparator: \.isNewline)
            .map { URL(fileURLWithPath: String($0)) }

        guard !urls.isEmpty else {
            throw FinderContextError.noSelection
        }

        return urls
    }
}

public enum FinderContextSource: String, Codable, Sendable {
    case finderSelection = "finder_selection"
}
