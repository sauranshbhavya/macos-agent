import AppKit
import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-440. `WorkspaceRunningAppSwitcher` used to call `NSRunningApplication.activate(options:)`,
/// which since macOS 14 answers false from any process that is not the active app — and Sonny is
/// not the active app while a command typed into its non-activating widget runs. The founders read
/// "Could not switch to Google Chrome." with Chrome running. The switcher now takes its process
/// list and its activation as seams, so the decision it makes — running: activate through Launch
/// Services; refused: fail by name; not running: fail by name and never activate; launched rather
/// than switched: say so — is held here with plain values, and `forThisMac()` is the only place
/// the real two are named. The one thing held with real objects is the identity comparison that
/// tells a switch from a launch, at the bottom of this file.
@Suite
@MainActor
struct RunningAppSwitcherTests {
    private static let chrome = RunningApp(
        displayName: "Google Chrome",
        bundleIdentifier: "com.google.Chrome",
        processIdentifier: 4242,
        bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")
    )
    private static let finder = RunningApp(
        displayName: "Finder",
        bundleIdentifier: "com.apple.finder",
        processIdentifier: 99
    )

    private final class ActivationLog {
        var activated: [RunningApp] = []
    }

    private static func switcher(
        running: [RunningApp],
        answering: Bool,
        log: ActivationLog
    ) -> WorkspaceRunningAppSwitcher {
        switcher(
            running: running,
            answering: answering ? { _ in .switched } : { _ in .refused },
            log: log
        )
    }

    /// The activation answers whatever `answering` makes of the app it was handed — a switch, a
    /// launch, or a refusal.
    private static func switcher(
        running: [RunningApp],
        answering: @escaping (RunningApp) -> RunningAppActivationOutcome,
        log: ActivationLog
    ) -> WorkspaceRunningAppSwitcher {
        WorkspaceRunningAppSwitcher(
            runningApplications: { running },
            activation: { app in
                log.activated.append(app)
                return answering(app)
            }
        )
    }

    @Test
    func aRunningAppIsHandedToTheActivationAndTheSwitchSucceedsWhenItAnswersYes() async throws {
        let log = ActivationLog()
        let subject = Self.switcher(running: [Self.finder, Self.chrome], answering: true, log: log)

        try await subject.activate(bundleIdentifier: "com.google.Chrome")

        #expect(log.activated == [Self.chrome])
    }

    /// The founders' screenshot, from the other side: the app is running, the activation is refused,
    /// and the failure names the app rather than the bundle identifier.
    @Test
    func aRefusedActivationFailsByTheAppsName() async {
        let log = ActivationLog()
        let subject = Self.switcher(running: [Self.chrome], answering: false, log: log)

        await #expect(throws: RunningAppSwitchError.failedToActivate("Google Chrome")) {
            try await subject.activate(bundleIdentifier: "com.google.Chrome")
        }
        #expect(log.activated == [Self.chrome])
        #expect(
            RunningAppSwitchError.failedToActivate("Google Chrome").errorDescription
                == "Could not switch to Google Chrome."
        )
    }

    /// Switching launches nothing, by the tool's own description: an app that is not running fails
    /// before the activation is ever asked. What the switcher throws names the identifier it was
    /// handed; the display name the user reads comes from the adapter, which fails first with it
    /// (`RunningAppSwitchCapabilityAdapter.app(in:)`), so this test's claim is the refusal and the
    /// untouched log, not the wording (PR #227's F6).
    @Test
    func anAppThatIsNotRunningIsRefusedBeforeTheActivationIsAsked() async {
        let log = ActivationLog()
        let subject = Self.switcher(running: [Self.finder], answering: true, log: log)

        await #expect(throws: RunningAppSwitchError.noMatchingRunningApp("com.apple.Safari")) {
            try await subject.activate(bundleIdentifier: "com.apple.Safari")
        }
        #expect(log.activated.isEmpty)
    }

    /// **An activation the seam reports as a launch is reported as one** (PR #227's F1, the
    /// founders' decision of 2026-09-11; the seam's answer is decided by app identity since the
    /// delta review's N1). An app that quit between the running check and the open passes the check
    /// and is started by the open; the app Launch Services hands back is then none the list held,
    /// and the switch is reported as the launch it was, in Sonny's own sentence, rather than as
    /// "Switched to". The activation was asked exactly once either way — nothing here retries or
    /// undoes the launch.
    @Test
    func anActivationThatAnsweredWithAnotherProcessIsReportedAsALaunchNotASwitch() async {
        let log = ActivationLog()
        let subject = Self.switcher(
            running: [Self.chrome],
            answering: { _ in .launched },
            log: log
        )

        await #expect(throws: RunningAppSwitchError.launchedInsteadOfSwitching("Google Chrome")) {
            try await subject.activate(bundleIdentifier: "com.google.Chrome")
        }
        #expect(log.activated == [Self.chrome])
        #expect(
            RunningAppSwitchError.launchedInsteadOfSwitching("Google Chrome").errorDescription
                == "Google Chrome had quit, so Sonny opened it instead of switching to it."
        )
    }

    @Test
    func theRunningListIsTheSeamsListUnchanged() {
        let log = ActivationLog()
        let subject = Self.switcher(running: [Self.chrome, Self.finder], answering: true, log: log)

        #expect(subject.runningApps() == [Self.chrome, Self.finder])
    }

    // MARK: - The identity comparison, with real objects

    /// **A switch is told from a launch by `isEqual:` against every instance the list held, never by
    /// process identifier** (PR #227's delta review, N1; the founders' decision of 2026-09-11). The
    /// SDK header on `processIdentifier` says "Do not rely on this for comparing processes. Use
    /// `-isEqual:` instead" and that an app's pid may change if it is automatically terminated. These
    /// use apps already running on this Mac, which needs nothing launched — the test process itself
    /// is no use, since a bare test helper is not an app Launch Services knows and its
    /// `NSRunningApplication.current` answers a pid of -1. The same app reached through two different
    /// objects — one from the workspace's list and one made from its pid — is one app to `isEqual:`,
    /// so the comparison cannot be object identity; and an activation that matches none of the held
    /// instances is a launch, whether the list held nothing or held only some other app.
    @Test
    func anActivationEqualToAnInstanceTheListHeldIsASwitchEvenThroughAnotherObject() throws {
        let app = try #require(Self.twoRunningApps().first)
        let sameApp = try #require(NSRunningApplication(processIdentifier: app.processIdentifier))

        #expect(RunningAppActivation.outcome(activated: app, amongHeld: [app]) == .switched)
        #expect(RunningAppActivation.outcome(activated: sameApp, amongHeld: [app]) == .switched)
        #expect(RunningAppActivation.outcome(activated: app, amongHeld: [sameApp]) == .switched)
    }

    @Test
    func anActivationMatchingNoInstanceTheListHeldIsALaunch() throws {
        let apps = Self.twoRunningApps()
        let app = try #require(apps.first)
        let other = try #require(apps.dropFirst().first)

        #expect(RunningAppActivation.outcome(activated: app, amongHeld: []) == .launched)
        // Another running app is not this one, whatever its pid happens to be.
        #expect(RunningAppActivation.outcome(activated: app, amongHeld: [other]) == .launched)
        #expect(RunningAppActivation.outcome(activated: app, amongHeld: [other, app]) == .switched)
    }

    /// Two distinct apps Launch Services knows, from the workspace's own list: any two with a real
    /// pid and a bundle identifier. A signed-in Mac always has at least Finder and the login
    /// session's agents; a test that finds fewer than two fails on its `#require` rather than
    /// asserting on nothing.
    private static func twoRunningApps() -> [NSRunningApplication] {
        var seen: Set<String> = []
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier > 0, let bundle = app.bundleIdentifier, !seen.contains(bundle) else {
                return false
            }
            seen.insert(bundle)
            return true
        }.prefix(2).map { $0 }
    }
}
