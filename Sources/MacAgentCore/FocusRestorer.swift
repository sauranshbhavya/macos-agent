import AppKit
import Foundation

/// Puts the app the user was working in back in front after Sonny opens something (SONNY-451).
///
/// The founders' words: "figure out which window is currently active, and then once the new app
/// is opened auto activate the current window." An `open_app`, `open_workspace` or `open_url`
/// step brings its app forward through Launch Services, which makes it the active app — so a
/// command typed while working in Xcode leaves the user in Safari. The three adapters wrap their
/// open in `restoringFocus`, which notes what is in front before, lets the open run, and brings
/// that app back once it has completed; the bring-back is the same Launch Services activation the
/// switcher uses (SONNY-440), because it is the one route that works from a background app on
/// macOS 14.
///
/// **Its collaborators are injected, for `WorkspaceRunningAppSwitcher`'s reason**: the executor's
/// default is `inert()`, so a fixture that never heard of focus can neither read the developer's
/// frontmost app nor bring one forward; `forThisMac()` is what the shipping view model passes, and
/// a scan test pins that it does. `FocusRestorer`'s own doc says what each of the three is for.
///
/// **Both requirements are main-actor isolated, and the read is synchronous.** They are AppKit
/// calls (`NSWorkspace.frontmostApplication`, an `NSRunningApplication` activation), the adapters'
/// `execute` is already `@MainActor`, and a nonisolated `async` read would cost four executor hops
/// per open step for an answer the inert restorer gives without moving. Measured: with the read
/// declared `async` and nonisolated, the first test of each of `ResumableTaskRunTests.swift`'s
/// three serialized suites — the three that start when every suite in the run is contending for
/// the main actor — crossed their 30 s idle backstop in two consecutive full runs (`ebcf113e`,
/// `a8d40159`) and passed in 0.1 s each alone; on the main actor the same runs cost nothing.
public protocol FocusRestoring: Sendable {
    /// What is in front right now, noted with every instance the running list holds for it, or
    /// `nil` when nothing is (or the restorer is inert).
    @MainActor
    func frontmost() -> NotedFrontmost?
    /// Brings a noted app back in front, answering what Launch Services did — and only `.switched`
    /// is a restore. `.launched` means the app had quit and was started again; `.refused` means it
    /// was not brought back, including when the restorer declined to ask at all.
    @MainActor
    func bringToFront(_ noted: NotedFrontmost) async -> RunningAppActivationOutcome
}

/// The app that was in front when a restore noted it, and the instances of it that were running then.
///
/// **The instances are captured at the moment of noting, not re-read at the moment of restoring**
/// (founder decision, 2026-09-12, on SONNY-451's rebase over SONNY-440's activation change). The
/// activation compares the app Launch Services brings forward against a set of instances with
/// `isEqual:` and calls anything outside that set a launch (`RunningAppActivationOutcome`). Re-read
/// at restore time, that set would hold whatever happened to be running by then — including a copy
/// of the app started after the user's own had quit — and a fresh launch would read as a switch. Noted
/// with the app, the set is the user's app as it was, so a restore that brings back anything else is
/// seen for what it is.
public struct NotedFrontmost: Sendable {
    public let app: RunningApp
    public let heldInstances: [NSRunningApplication]

    public init(app: RunningApp, heldInstances: [NSRunningApplication]) {
        self.app = app
        self.heldInstances = heldInstances
    }
}

public extension FocusRestoring {
    /// Runs `work`, then puts the app that was in front before it back in front if the open moved
    /// it. **Restores on a throw as well**: an open that failed halfway may still have activated
    /// something, and the user's focus is not Sonny's to keep because a step failed.
    ///
    /// `onRestore` is told which app came back, so the run's trace can say so — and it is told only
    /// when the app really was switched back to. A launch is not a restore (see `restored(_:)`).
    ///
    /// Main-actor isolated like the adapters that call it, so an adapter's non-`Sendable` `log` and
    /// context are captured by both closures without crossing an executor.
    @MainActor
    func restoringFocus<T>(
        onRestore: (RunningApp) -> Void = { _ in },
        _ work: () async throws -> T
    ) async rethrows -> T {
        let before = frontmost()
        let result: T
        do {
            result = try await work()
        } catch {
            if let before, await restored(before) {
                onRestore(before.app)
            }
            throw error
        }
        if let before, await restored(before) {
            onRestore(before.app)
        }
        return result
    }

    /// Brings `before` back if the open moved the front; `true` only when Launch Services switched
    /// to one of the instances noted with it. Nothing moved — the opened app was already in front —
    /// is `false` with no call.
    ///
    /// **Only `.switched` counts** (founder decision, 2026-09-12). `.launched` means the user's app
    /// had quit while Sonny opened something and a new copy was started to stand in for it: that is
    /// not the user's window coming back, and the run's trace must not say it did.
    @MainActor
    private func restored(_ before: NotedFrontmost) async -> Bool {
        if let now = frontmost(), now.app.bundleIdentifier == before.app.bundleIdentifier {
            return false
        }
        return await bringToFront(before) == .switched
    }
}

/// The shipping restorer and the inert one, both over injected reads (SONNY-451).
///
/// **Three collaborators, and the third is what keeps a restore from starting an app.** A launch is
/// only *reported* by Launch Services after it has happened, so treating `.launched` as no restore
/// cannot by itself keep an app that quit from being started again — by the time the outcome says
/// so, it has been. So before asking Launch Services, the restorer checks that one of the noted
/// instances is still running, and asks nothing when none is. That is the check the switcher makes
/// before its own activation (`WorkspaceRunningAppSwitcher.activate`), for the same reason.
///
/// **What the check does not close, stated rather than implied.** An app that quits in the moment
/// between the check and the open still passes the check, and Launch Services, asked to open a bundle
/// with nothing behind it, starts one — the window `RunningAppActivation`'s doc says this route
/// cannot close. The outcome then reads `.launched`, and the trace says nothing was restored.
public struct FocusRestorer: FocusRestoring {
    public typealias Frontmost = @Sendable @MainActor () -> NotedFrontmost?
    public typealias StillRunning = @Sendable @MainActor (NotedFrontmost) -> Bool
    public typealias Activation = @Sendable @MainActor (NotedFrontmost) async -> RunningAppActivationOutcome

    private let frontmostRead: Frontmost
    private let stillRunning: StillRunning
    private let activation: Activation

    public init(frontmost: @escaping Frontmost, stillRunning: @escaping StillRunning, activation: @escaping Activation) {
        self.frontmostRead = frontmost
        self.stillRunning = stillRunning
        self.activation = activation
    }

    /// `NSWorkspace`'s frontmost app with every instance running for its bundle identifier, a
    /// liveness read over those instances, and Launch Services to bring it back — the switcher's route.
    public static func forThisMac() -> FocusRestorer {
        FocusRestorer(
            frontmost: {
                guard let app = NSWorkspace.shared.frontmostApplication,
                      let bundleIdentifier = app.bundleIdentifier else {
                    return nil
                }
                return NotedFrontmost(
                    app: RunningApp(
                        displayName: app.localizedName ?? bundleIdentifier,
                        bundleIdentifier: bundleIdentifier,
                        processIdentifier: app.processIdentifier,
                        bundleURL: app.bundleURL
                    ),
                    // Every instance for the bundle identifier, as the switcher reads them: a second
                    // instance, or Launch Services substituting another running copy, is still the
                    // user's app and counts as the switch it is.
                    heldInstances: NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                )
            },
            stillRunning: { noted in
                anyStillRunning(noted.heldInstances)
            },
            activation: { noted in
                guard let bundleURL = noted.app.bundleURL else {
                    return .refused
                }
                return await RunningAppActivation.activate(bundleURL: bundleURL, amongHeld: noted.heldInstances)
            }
        )
    }

    /// Whether any of `instances` is still running. Empty is `false`: nothing noted is nothing to
    /// bring back.
    public static func anyStillRunning(_ instances: [NSRunningApplication]) -> Bool {
        instances.contains { !$0.isTerminated }
    }

    /// Reads nothing and moves nothing: the default a fixture gets by saying nothing.
    public static func inert() -> FocusRestorer {
        FocusRestorer(frontmost: { nil }, stillRunning: { _ in false }, activation: { _ in .refused })
    }

    @MainActor
    public func frontmost() -> NotedFrontmost? {
        frontmostRead()
    }

    /// `.refused` without asking Launch Services when none of the noted instances is still running,
    /// because asking would start the app; otherwise whatever Launch Services did.
    @MainActor
    public func bringToFront(_ noted: NotedFrontmost) async -> RunningAppActivationOutcome {
        guard stillRunning(noted) else {
            return .refused
        }
        return await activation(noted)
    }
}
