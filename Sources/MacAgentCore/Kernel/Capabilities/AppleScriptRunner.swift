import Foundation

public enum AppleScriptRunError: Error, Sendable, Equatable {
    /// macOS refused the Apple Event: the user hasn't allowed Sonny to control that app.
    case notAuthorized
    /// The script ran past its deadline and was stopped, or the app it was talking to didn't answer
    /// an Apple Event in time (-1712). Whatever it was doing may or may not have happened.
    case timedOut
    case failed(String)
}

/// Runs one reviewed AppleScript template. User data only ever travels as `arguments` (the script's
/// `argv`), never spliced into the script's text, so nothing a person or a model writes can change
/// what the script does (V2 plan: "scripts come only from reviewed templates").
///
/// `argv` starts with one fixed marker, so a person's text that happens to begin with a dash is
/// never read by osascript as an option; templates read their arguments from item 2 on.
///
/// A script still running at `timeout` is stopped and throws `timedOut`. One whose task is cancelled
/// is stopped and throws `CancellationError`; if it had started, what it did is unknown.
public protocol AppleScriptRunning: Sendable {
    func run(_ script: String, arguments: [String], timeout: TimeInterval) async throws -> String
}

public struct OsascriptRunner: AppleScriptRunning {
    public static let argumentMarker = "sonny-arguments"

    public init() {}

    public func run(_ script: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        // The deadline cancels the run, and cancelling the runner terminates the script, so the wait
        // ends at the deadline instead of whenever the script gives up by itself.
        let finished = try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
            group.addTask {
                try await AsyncProcessRunner.run(
                    executablePath: "/usr/bin/osascript",
                    arguments: ["-e", script, OsascriptRunner.argumentMarker] + arguments,
                    separatingErrorOutput: true
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        guard let result = finished else { throw AppleScriptRunError.timedOut }
        guard result.terminationStatus == 0 else {
            let problem = result.errorOutput
            if problem.contains("-1743") || problem.localizedCaseInsensitiveContains("Not authorized to send Apple events") {
                throw AppleScriptRunError.notAuthorized
            }
            if problem.contains("(-1712)") {
                throw AppleScriptRunError.timedOut
            }
            throw AppleScriptRunError.failed(problem.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.output.trimmingCharacters(in: .newlines)
    }
}
