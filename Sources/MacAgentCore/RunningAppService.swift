import AppKit
import Foundation

public struct RunningApp: Equatable, Sendable {
    public var displayName: String
    public var bundleIdentifier: String
    public var processIdentifier: Int32
    /// Where the running app's bundle is, as Launch Services will be asked to activate it
    /// (SONNY-440). `nil` for a process with no bundle, which is not something a switch can bring
    /// forward; defaulted so every fixture that builds one of these by name still compiles.
    public var bundleURL: URL?

    public init(displayName: String, bundleIdentifier: String, processIdentifier: Int32, bundleURL: URL? = nil) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.bundleURL = bundleURL
    }
}

public enum RunningAppSwitchError: Error, Equatable, LocalizedError {
    case missingQuery
    case noMatchingRunningApp(String)
    case failedToActivate(String)

    public var errorDescription: String? {
        switch self {
        case .missingQuery:
            return "Switching apps requires a running app name."
        case .noMatchingRunningApp(let query):
            return "No running app matched \(query)."
        case .failedToActivate(let app):
            return "Could not switch to \(app)."
        }
    }
}

@MainActor
public protocol RunningAppSwitching: AnyObject {
    func runningApps() -> [RunningApp]
    func activate(bundleIdentifier: String) async throws
}

/// How this process brings another app to the front, and why it is Launch Services rather than
/// `NSRunningApplication.activate` (SONNY-440).
///
/// **`activate(options:)` answers false from a background app, and Sonny is a background app while
/// a command runs.** The founders typed `switch to Chrome` into the widget with Chrome running and
/// read "Could not switch to Google Chrome." — the switcher had resolved the right app and the
/// deprecated call had refused it. Since macOS 14 activation is cooperative: a process may
/// activate another only while it is itself the active app or has been yielded activation, and
/// the widget is a non-activating panel by design (`FloatingWidgetPanel`), so a command typed
/// there runs with whatever app the user was in still active. The same call sat in
/// `SystemScreenActionSynthesizer.activateApp`, where it passed the founders' screen-control rows
/// only because Command Center happened to be the active app at the time; it takes this route too.
///
/// Launch Services has no such rule. `NSWorkspace.openApplication(at:configuration:)` with
/// `activates` on brings a running app forward the way `open -a` does, from any process — the
/// route `WorkspaceAppOpener` already takes for `open Safari`, which the founders' row 21 proved
/// works from the background. For an app that is already running Launch Services sends it a reopen
/// and activates it; it starts no second instance (`createsNewApplicationInstance` stays false), so
/// "switching launches nothing" still holds: every caller checks the app is running before it
/// reaches this, and an app that is not running fails by name without this ever being asked.
@MainActor
public enum RunningAppActivation {
    /// Brings the app at `bundleURL` to the front. Answers false when Launch Services refused.
    public static func activate(bundleURL: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}

/// The shipping switcher: the workspace's live process list, activated through Launch Services.
///
/// **Its two collaborators are injected**, so the decision it makes — running: activate; refused:
/// fail by the app's name; not running: fail by name and never activate — is held by
/// `RunningAppSwitcherTests` with plain values, and `forThisMac()` is the one place the real two are
/// named. Neither has a default, for `DefaultAppRelauncher`'s reason: a defaulted activation would
/// let a fixture bring a real app forward on the developer's Mac by saying nothing.
@MainActor
public final class WorkspaceRunningAppSwitcher: RunningAppSwitching {
    public typealias RunningApplications = @MainActor () -> [RunningApp]
    public typealias Activation = @MainActor (RunningApp) async -> Bool

    private let runningApplications: RunningApplications
    private let activation: Activation

    public init(
        runningApplications: @escaping RunningApplications,
        activation: @escaping Activation
    ) {
        self.runningApplications = runningApplications
        self.activation = activation
    }

    /// The wiring the shipping app runs: regular apps from `NSWorkspace`, and Launch Services.
    public static func forThisMac() -> WorkspaceRunningAppSwitcher {
        WorkspaceRunningAppSwitcher(
            runningApplications: {
                NSWorkspace.shared.runningApplications.compactMap { app in
                    guard app.activationPolicy == .regular,
                          let displayName = app.localizedName,
                          let bundleIdentifier = app.bundleIdentifier else {
                        return nil
                    }
                    return RunningApp(
                        displayName: displayName,
                        bundleIdentifier: bundleIdentifier,
                        processIdentifier: app.processIdentifier,
                        bundleURL: app.bundleURL
                    )
                }
            },
            activation: { app in
                guard let bundleURL = app.bundleURL else {
                    return false
                }
                return await RunningAppActivation.activate(bundleURL: bundleURL)
            }
        )
    }

    public func runningApps() -> [RunningApp] {
        runningApplications()
    }

    public func activate(bundleIdentifier: String) async throws {
        guard let app = runningApplications().first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw RunningAppSwitchError.noMatchingRunningApp(bundleIdentifier)
        }
        guard await activation(app) else {
            throw RunningAppSwitchError.failedToActivate(app.displayName)
        }
    }
}

public enum RunningAppMatcher {
    public static func bestMatch(query rawQuery: String?, in apps: [RunningApp]) throws -> RunningApp {
        guard let rawQuery else {
            throw RunningAppSwitchError.missingQuery
        }
        let query = normalize(rawQuery)
        guard !query.isEmpty else {
            throw RunningAppSwitchError.missingQuery
        }

        if let exact = apps.first(where: { normalize($0.displayName) == query || normalize($0.bundleIdentifier) == query }) {
            return exact
        }

        if let prefix = apps.first(where: {
            normalize($0.displayName).hasPrefix(query) || normalize($0.bundleIdentifier).hasPrefix(query)
        }) {
            return prefix
        }

        if let contains = apps.first(where: {
            normalize($0.displayName).contains(query) || normalize($0.bundleIdentifier).contains(query)
        }) {
            return contains
        }

        throw RunningAppSwitchError.noMatchingRunningApp(rawQuery)
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
    }
}
