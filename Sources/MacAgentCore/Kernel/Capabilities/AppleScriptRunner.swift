import Foundation

public enum AppleScriptRunError: Error, Sendable, Equatable {
    /// macOS refused the Apple Event: the user hasn't allowed Sonny to control that app.
    case notAuthorized
    /// The script ran past its deadline. Whatever it was doing may or may not have happened.
    case timedOut
    case failed(String)
}

/// Runs one reviewed AppleScript template. User data only ever travels as `arguments` (the script's
/// `argv`), never spliced into the script's text, so nothing a person or a model writes can change
/// what the script does (V2 plan: "scripts come only from reviewed templates").
///
/// `argv` starts with one fixed marker, so a person's text that happens to begin with a dash is
/// never read by osascript as an option; templates read their arguments from item 2 on.
public protocol AppleScriptRunning: Sendable {
    func run(_ script: String, arguments: [String], timeout: TimeInterval) async throws -> String
}

public struct OsascriptRunner: AppleScriptRunning {
    public static let argumentMarker = "sonny-arguments"

    public init() {}

    public func run(_ script: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, OsascriptRunner.argumentMarker] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Drained while the script runs: a reply larger than the pipe's buffer would otherwise
        // block the script from exiting.
        let outputData = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let errorData = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }

        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        process.waitUntilExit()
                        continuation.resume()
                    }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard finished else {
            process.terminate()
            throw AppleScriptRunError.timedOut
        }
        let text = String(decoding: await outputData.value, as: UTF8.self)
        let problem = String(decoding: await errorData.value, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            if problem.contains("-1743") || problem.localizedCaseInsensitiveContains("Not authorized to send Apple events") {
                throw AppleScriptRunError.notAuthorized
            }
            throw AppleScriptRunError.failed(problem.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text.trimmingCharacters(in: .newlines)
    }
}
