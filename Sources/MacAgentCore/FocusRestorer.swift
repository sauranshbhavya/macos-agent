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
/// per open step for an answer the inert restorer gives without moving. Measured on this branch
/// before its rebase onto `main`, at two heads the rebase replaced: with the read declared `async`
/// and nonisolated, the first test of each of `ResumableTaskRunTests.swift`'s three serialized
/// suites — the three that start when every suite in the run is contending for the main actor —
/// crossed their 30 s idle backstop in two consecutive full runs and passed in 0.1 s each alone; on
/// the main actor the same runs cost nothing.
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
    /// **`carry` hands the app on instead of bringing it back** (PR #238's F5). When the run's next
    /// unit is a screen-control session on the app this open brings forward, restoring here would
    /// put the user's app in front for the moment before the session takes the front again — Notes,
    /// then the user's app, then Notes. So a completed open holds what was in front in `carry`, and
    /// the session gives it back when it ends. An open that throws still restores at once: there is
    /// no session to hand it to.
    ///
    /// Main-actor isolated like the adapters that call it, so an adapter's non-`Sendable` `log` and
    /// context are captured by both closures without crossing an executor.
    @MainActor
    func restoringFocus<T>(
        onRestore: (RunningApp) -> Void = { _ in },
        handingOnTo carry: FocusCarry? = nil,
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
        if let carry {
            if let before {
                carry.hold(before)
            }
            return result
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

/// The app the user was in, handed from an open step to the screen-control session that runs right
/// after it in the same run (PR #238's F5).
///
/// One per chain run, made by `AgentActionExecutor.executeChain` and reached through
/// `CapabilityExecutionContext.focusHandoff`. It holds the first app it is given and hands it out
/// once, so a later open in the same run cannot replace the app the user was really in.
@MainActor
public final class FocusCarry {
    private var held: NotedFrontmost?

    public init() {}

    /// Keeps `noted` for the session to give back, unless something is already held.
    public func hold(_ noted: NotedFrontmost) {
        if held == nil {
            held = noted
        }
    }

    /// What was held, once; `nil` afterwards.
    public func take() -> NotedFrontmost? {
        defer { held = nil }
        return held
    }
}

/// What the rest of a run says about the front, for one unit of it (PR #238's F5).
public struct FocusHandoff: Sendable {
    /// The bundle identifier of the app the run's next unit takes control of itself — a
    /// screen-control session's pinned target — or `nil` when the next unit brings no app forward.
    public let nextUnitControls: String?
    public let carry: FocusCarry

    public init(nextUnitControls: String?, carry: FocusCarry) {
        self.nextUnitControls = nextUnitControls
        self.carry = carry
    }

    /// The carry to hand the user's app to when an open brings `bundleIdentifiers` forward and the
    /// next unit controls one of them; `nil` when the open should give the user's app back itself.
    public func carry(forOpening bundleIdentifiers: [String]) -> FocusCarry? {
        guard let nextUnitControls,
              bundleIdentifiers.contains(where: { $0.caseInsensitiveCompare(nextUnitControls) == .orderedSame }) else {
            return nil
        }
        return carry
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
        composed(
            frontmostApplication: { NSWorkspace.shared.frontmostApplication },
            runningApplications: { NSRunningApplication.runningApplications(withBundleIdentifier: $0) },
            activation: { bundleURL, held in
                await RunningAppActivation.activate(bundleURL: bundleURL, amongHeld: held)
            }
        )
    }

    public typealias FrontmostApplication = @Sendable @MainActor () -> NSRunningApplication?
    public typealias RunningApplications = @Sendable @MainActor (String) -> [NSRunningApplication]
    public typealias LaunchServicesActivation = @Sendable @MainActor (URL, [NSRunningApplication]) async -> RunningAppActivationOutcome

    /// The shipping composition over its three AppKit calls, so a test runs this exact wiring with
    /// real `NSRunningApplication` values (PR #238's F12) — `forThisMac()` names the real calls and
    /// nothing else.
    ///
    /// **The running instances are read once, when the app in front is noted**, and the activation is
    /// handed those same instances rather than a fresh read: a set re-read at restore time would
    /// include a copy started after the user's own had quit, and that launch would read as a switch.
    static func composed(
        frontmostApplication: @escaping FrontmostApplication,
        runningApplications: @escaping RunningApplications,
        activation: @escaping LaunchServicesActivation
    ) -> FocusRestorer {
        FocusRestorer(
            frontmost: {
                guard let app = frontmostApplication(),
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
                    heldInstances: runningApplications(bundleIdentifier)
                )
            },
            stillRunning: { noted in
                anyStillRunning(noted.heldInstances, at: noted.app.bundleURL)
            },
            activation: { noted in
                guard let bundleURL = noted.app.bundleURL else {
                    return .refused
                }
                return await activation(bundleURL, noted.heldInstances)
            }
        )
    }

    /// Whether any of `instances` is still running **from `bundleURL`**, the bundle the restore
    /// will ask Launch Services to open. Empty is `false`: nothing noted is nothing to bring back.
    ///
    /// **Only a copy at the same bundle counts** (PR #238's F7). Two apps can share a bundle
    /// identifier — Xcode and Xcode-beta both answer `com.apple.dt.Xcode` — and the restore opens
    /// the noted app's own bundle. With the user in Xcode-beta, Xcode-beta quit and Xcode still
    /// running, a check over every instance would pass and Launch Services would be asked to open
    /// Xcode-beta.app, which starts it. A noted app with no bundle URL is never brought back at all,
    /// so it has nothing to be live at.
    public static func anyStillRunning(_ instances: [NSRunningApplication], at bundleURL: URL?) -> Bool {
        guard let bundleURL else {
            return false
        }
        return instances.contains { !$0.isTerminated && $0.bundleURL?.standardizedFileURL == bundleURL.standardizedFileURL }
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
