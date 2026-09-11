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
    /// Launch Services answered with an app that is none of the instances the running list held:
    /// the app had quit between the running check and the open, and was started rather than
    /// brought forward (SONNY-440, PR #227's F1). Sonny cannot undo the launch, so it says what
    /// happened.
    case launchedInsteadOfSwitching(String)

    public var errorDescription: String? {
        switch self {
        case .missingQuery:
            return "Switching apps requires a running app name."
        case .noMatchingRunningApp(let query):
            return "No running app matched \(query)."
        case .failedToActivate(let app):
            return "Could not switch to \(app)."
        case .launchedInsteadOfSwitching(let app):
            return "\(app) had quit, so Sonny opened it instead of switching to it."
        }
    }
}

/// What Launch Services answered when asked to bring an app forward: an instance the running list
/// already held, an app it started, or a refusal.
///
/// **A switch is told from a launch by app identity, never by process identifier** (PR #227's
/// delta review, N1; the founders' decision of 2026-09-11). The first round compared the pid
/// Launch Services returned with the pid the switcher resolved, which is the comparison the SDK
/// header says not to make: `NSRunningApplication.h` on `processIdentifier` reads "Do not rely on
/// this for comparing processes. Use `-isEqual:` instead", and "an application's pid may change if
/// it is automatically terminated". Safari opts into automatic termination, so the founders' own
/// row — Safari with every window closed — could have read "Safari had quit" for an app that
/// never quit; and two instances started from one bundle, or Launch Services substituting another
/// running copy of the same app, each answer a different pid without any launch. So the answer is
/// compared with `isEqual:` against every instance the running list held for that bundle
/// identifier, read immediately before the open: any match is a switch, and no match is a launch.
public enum RunningAppActivationOutcome: Equatable, Sendable {
    /// The app Launch Services activated is one the running list already held.
    case switched
    /// The app Launch Services activated is none of them: it was started.
    case launched
    case refused
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
/// call had refused it (the call itself carries no deprecation marker in the SDK this tree builds
/// against; what macOS 14 deprecated is the ignoring-other-apps *option*, which neither old call
/// passed — PR #227's F4). Since macOS 14 activation is cooperative: a process may
/// activate another only while it is itself the active app or has been yielded activation, and
/// the widget is a non-activating panel by design (`FloatingWidgetPanel`), so a command typed
/// there runs with whatever app the user was in still active. The same call sat in
/// `SystemScreenActionSynthesizer.activateApp`, where it passed the founders' screen-control rows
/// only because Command Center happened to be the active app at the time; it takes this route too.
///
/// Launch Services has no such rule. `NSWorkspace.openApplication(at:configuration:)` with
/// `activates` on brings a running app forward the way `open -a` does, from any process — the
/// route `WorkspaceAppOpener` already takes for `open Safari`, which the founders' row 21 proved
/// works from the background for an app that was *not* running. That the same call brings an
/// already-running app forward from the background is the premise of this fix, and it is
/// unmeasured until the founders' first manual row passes. For an app that is already running
/// Launch Services sends it a reopen and activates it — which for an app with no window open
/// creates one, as a Dock click does — and it starts no second instance
/// (`createsNewApplicationInstance` stays false).
///
/// **"Switching launches nothing" is a check followed by an act, and there is a window between
/// them** (PR #227's F1). Every caller checks the app is running before it reaches this, but the
/// running list refreshes only when the main run loop runs in a common mode, an app mid-quit stays
/// listed until it exits, and the open itself is a separate hop — so an app that quit after the
/// check passes it, and Launch Services, asked to open a bundle with no process behind it,
/// starts one. The window cannot be closed on this route; a process-bound activation through
/// Accessibility could close it and would tie switching to that grant, which is recorded on
/// SONNY-440 as the alternative not built. What this route can do is notice: the completion hands
/// back the `NSRunningApplication` it activated, and that app either is one of the instances the
/// running list held for the bundle identifier — compared with `isEqual:`, the way the SDK header
/// says, and never by process identifier (`RunningAppActivationOutcome`) — or is a fresh launch.
/// `activate(bundleURL:amongHeld:)` answers which, and the switcher reports a launch as one rather
/// than as a switch.
@MainActor
public enum RunningAppActivation {
    /// Brings the app at `bundleURL` to the front, answering whether the app Launch Services
    /// activated is one of `held` — the instances the running list holds for that bundle identifier,
    /// read by the caller immediately before this — or a launch, or `.refused` when it refused.
    public static func activate(bundleURL: URL, amongHeld held: [NSRunningApplication]) async -> RunningAppActivationOutcome {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { (continuation: CheckedContinuation<RunningAppActivationOutcome, Never>) in
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { application, error in
                guard error == nil, let application else {
                    continuation.resume(returning: .refused)
                    return
                }
                continuation.resume(returning: outcome(activated: application, amongHeld: held))
            }
        }
    }

    /// The comparison itself, apart from the open, so a test can hold it with real
    /// `NSRunningApplication` objects: `isEqual:` against every held instance, as the header says.
    /// `nonisolated` because Launch Services runs the completion above on a queue of its own, and
    /// the comparison touches nothing of this actor's.
    nonisolated public static func outcome(activated: NSRunningApplication, amongHeld held: [NSRunningApplication]) -> RunningAppActivationOutcome {
        held.contains { $0.isEqual(activated) } ? .switched : .launched
    }
}

/// The shipping switcher: the workspace's live process list, activated through Launch Services.
///
/// **Its two collaborators are injected**, so the decision it makes — running: activate; refused:
/// fail by the app's name; not running: fail by name and never activate; launched rather than
/// switched: say so — is held by `RunningAppSwitcherTests` with plain values, and `forThisMac()`
/// is the one place the real two are named. Neither has a default, for `DefaultAppRelauncher`'s reason: a defaulted activation would
/// let a fixture bring a real app forward on the developer's Mac by saying nothing.
@MainActor
public final class WorkspaceRunningAppSwitcher: RunningAppSwitching {
    public typealias RunningApplications = @MainActor () -> [RunningApp]
    public typealias Activation = @MainActor (RunningApp) async -> RunningAppActivationOutcome

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
                    return .refused
                }
                // Every instance the running list holds for this bundle identifier, read
                // immediately before the open: the answer is compared against all of them, so a
                // second instance or a substituted copy counts as the switch it is.
                let held = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier)
                return await RunningAppActivation.activate(bundleURL: bundleURL, amongHeld: held)
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
        switch await activation(app) {
        case .refused:
            throw RunningAppSwitchError.failedToActivate(app.displayName)
        case .launched:
            // The app Launch Services activated is none the running list held: the app quit in
            // the window between the running check and the open and this is a fresh launch (PR
            // #227's F1). A launch is reported as one: "Switched to" would be a sentence about a
            // switch that did not happen.
            throw RunningAppSwitchError.launchedInsteadOfSwitching(app.displayName)
        case .switched:
            break
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
