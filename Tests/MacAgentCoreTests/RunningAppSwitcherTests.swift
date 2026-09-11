import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-440. `WorkspaceRunningAppSwitcher` used to call `NSRunningApplication.activate(options:)`,
/// which since macOS 14 answers false from any process that is not the active app — and Sonny is
/// not the active app while a command typed into its non-activating widget runs. The founders read
/// "Could not switch to Google Chrome." with Chrome running. The switcher now takes its process
/// list and its activation as seams, so the decision it makes — running: activate through Launch
/// Services; refused: fail by name; not running: fail by name and never activate — is held here
/// with plain values, and `forThisMac()` is the only place the real two are named.
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
            answering: answering ? { .activated(processIdentifier: $0.processIdentifier) } : { _ in .refused },
            log: log
        )
    }

    /// The activation answers whatever `answering` makes of the app it was handed — the resolved
    /// process, a fresh one, or a refusal.
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

    /// **The process Launch Services activated is compared with the one the switcher resolved**
    /// (PR #227's F1, the founders' decision of 2026-09-11). An app that quit between the running
    /// check and the open passes the check and is started by the open; the completion's process
    /// identifier is then a fresh one, and the switch is reported as the launch it was, in Sonny's
    /// own sentence, rather than as "Switched to". The activation was asked exactly once either
    /// way — nothing here retries or undoes the launch.
    @Test
    func anActivationThatAnsweredWithAnotherProcessIsReportedAsALaunchNotASwitch() async {
        let log = ActivationLog()
        let subject = Self.switcher(
            running: [Self.chrome],
            answering: { _ in .activated(processIdentifier: Self.chrome.processIdentifier + 1) },
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

    /// The other outcome: the process that answered is the one resolved, and the switch is a switch.
    @Test
    func anActivationThatAnsweredWithTheResolvedProcessIsASwitch() async throws {
        let log = ActivationLog()
        let subject = Self.switcher(
            running: [Self.finder, Self.chrome],
            answering: { .activated(processIdentifier: $0.processIdentifier) },
            log: log
        )

        try await subject.activate(bundleIdentifier: "com.google.Chrome")

        #expect(log.activated == [Self.chrome])
    }

    @Test
    func theRunningListIsTheSeamsListUnchanged() {
        let log = ActivationLog()
        let subject = Self.switcher(running: [Self.chrome, Self.finder], answering: true, log: log)

        #expect(subject.runningApps() == [Self.chrome, Self.finder])
    }
}
