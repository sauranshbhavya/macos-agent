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
        WorkspaceRunningAppSwitcher(
            runningApplications: { running },
            activation: { app in
                log.activated.append(app)
                return answering
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
    /// by name before the activation is ever asked.
    @Test
    func anAppThatIsNotRunningFailsByNameAndIsNeverActivated() async {
        let log = ActivationLog()
        let subject = Self.switcher(running: [Self.finder], answering: true, log: log)

        await #expect(throws: RunningAppSwitchError.noMatchingRunningApp("com.apple.Safari")) {
            try await subject.activate(bundleIdentifier: "com.apple.Safari")
        }
        #expect(log.activated.isEmpty)
    }

    @Test
    func theRunningListIsTheSeamsListUnchanged() {
        let log = ActivationLog()
        let subject = Self.switcher(running: [Self.chrome, Self.finder], answering: true, log: log)

        #expect(subject.runningApps() == [Self.chrome, Self.finder])
    }
}
