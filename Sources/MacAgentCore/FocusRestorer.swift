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
/// **Two collaborators, injected, for `WorkspaceRunningAppSwitcher`'s reason**: the executor's
/// default is `inert()`, so a fixture that never heard of focus can neither read the developer's
/// frontmost app nor bring one forward; `forThisMac()` is what the shipping view model passes, and
/// a scan test pins that it does.
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
    /// The app in front right now, or `nil` when nothing is (or the restorer is inert).
    @MainActor
    func frontmost() -> RunningApp?
    /// Brings `app` back in front. `false` when Launch Services refused or the app is gone.
    @MainActor
    func bringToFront(_ app: RunningApp) async -> Bool
}

public extension FocusRestoring {
    /// Runs `work`, then puts the app that was in front before it back in front if the open moved
    /// it. **Restores on a throw as well**: an open that failed halfway may still have activated
    /// something, and the user's focus is not Sonny's to keep because a step failed.
    ///
    /// `onRestore` is told which app came back, so the run's trace can say so.
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
                onRestore(before)
            }
            throw error
        }
        if let before, await restored(before) {
            onRestore(before)
        }
        return result
    }

    /// Brings `before` back if the open moved the front; `true` when it did and the activation
    /// succeeded. Nothing moved — the opened app was already in front — is `false` with no call.
    @MainActor
    private func restored(_ before: RunningApp) async -> Bool {
        if let now = frontmost(), now.bundleIdentifier == before.bundleIdentifier {
            return false
        }
        return await bringToFront(before)
    }
}

/// The shipping restorer and the inert one, both over injected reads (SONNY-451).
public struct FocusRestorer: FocusRestoring {
    public typealias Frontmost = @Sendable @MainActor () -> RunningApp?
    public typealias Activation = @Sendable @MainActor (RunningApp) async -> Bool

    private let frontmostRead: Frontmost
    private let activation: Activation

    public init(frontmost: @escaping Frontmost, activation: @escaping Activation) {
        self.frontmostRead = frontmost
        self.activation = activation
    }

    /// `NSWorkspace`'s frontmost app, and Launch Services to bring it back — the switcher's route.
    public static func forThisMac() -> FocusRestorer {
        FocusRestorer(
            frontmost: {
                guard let app = NSWorkspace.shared.frontmostApplication,
                      let bundleIdentifier = app.bundleIdentifier else {
                    return nil
                }
                return RunningApp(
                    displayName: app.localizedName ?? bundleIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: app.processIdentifier,
                    bundleURL: app.bundleURL
                )
            },
            activation: { app in
                guard let bundleURL = app.bundleURL else {
                    return false
                }
                return await RunningAppActivation.activate(bundleURL: bundleURL)
            }
        )
    }

    /// Reads nothing and moves nothing: the default a fixture gets by saying nothing.
    public static func inert() -> FocusRestorer {
        FocusRestorer(frontmost: { nil }, activation: { _ in false })
    }

    @MainActor
    public func frontmost() -> RunningApp? {
        frontmostRead()
    }

    @MainActor
    public func bringToFront(_ app: RunningApp) async -> Bool {
        await activation(app)
    }
}
