import AppKit
import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-451. `restoringFocus` notes the app in front before an open, lets the open run, and brings
/// that app back once the open moved it — on a throw too — and does nothing when nothing moved.
///
/// **Only a switch is a restore** (founder decision, 2026-09-12, taken when SONNY-440's activation
/// change broke this file's one call into Launch Services). The activation answers `.switched`,
/// `.launched` or `.refused`, and a restore reports the app back only for the first: a launch means
/// the user's app had quit and a new copy stood in for it, which is not their window coming back.
/// And because a launch is reported only after it has happened, `FocusRestorer` asks Launch Services
/// nothing at all when none of the instances it noted is still running — restoring focus must never
/// start an app.
@Suite
struct FocusRestorerTests {
    private static let xcode = RunningApp(displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", processIdentifier: 1)
    private static let safari = RunningApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 2)

    private static func noted(_ app: RunningApp, held: [NSRunningApplication] = []) -> NotedFrontmost {
        NotedFrontmost(app: app, heldInstances: held)
    }

    /// A restorer over a scripted screen: `frontmost` answers the script in order, every bring-back
    /// is recorded, and the activation answers `outcome`.
    private final class ScriptedRestorer: FocusRestoring, @unchecked Sendable {
        private var frontmostAnswers: [NotedFrontmost?]
        private(set) var broughtToFront: [RunningApp] = []
        var outcome: RunningAppActivationOutcome = .switched

        init(frontmost: [RunningApp?]) {
            self.frontmostAnswers = frontmost.map { $0.map { FocusRestorerTests.noted($0) } }
        }

        func frontmost() -> NotedFrontmost? {
            frontmostAnswers.isEmpty ? nil : frontmostAnswers.removeFirst()
        }

        func bringToFront(_ noted: NotedFrontmost) async -> RunningAppActivationOutcome {
            broughtToFront.append(noted.app)
            return outcome
        }
    }

    // MARK: - restoringFocus

    @Test
    @MainActor
    func anOpenThatMovedTheFrontmostAppBringsItBack() async throws {
        let restorer = ScriptedRestorer(frontmost: [Self.xcode, Self.safari])
        var restored: [RunningApp] = []

        let result = await restorer.restoringFocus(onRestore: { restored.append($0) }) { "opened" }

        #expect(result == "opened")
        #expect(restorer.broughtToFront == [Self.xcode])
        #expect(restored == [Self.xcode])
    }

    /// **The first of the two outcomes: a switch is a restore**, and the run's trace hears of it.
    @Test
    @MainActor
    func aSwitchIsReportedAsARestore() async throws {
        let restorer = ScriptedRestorer(frontmost: [Self.xcode, Self.safari])
        restorer.outcome = .switched
        var restored: [RunningApp] = []

        _ = await restorer.restoringFocus(onRestore: { restored.append($0) }) { "opened" }

        #expect(restored == [Self.xcode])
    }

    /// **The second: a launch is not a restore.** Launch Services brought forward something that was
    /// not one of the noted instances — the user's app had quit and a new copy was started — so the
    /// trace must not say the user's app came back.
    @Test
    @MainActor
    func aLaunchIsNotReportedAsARestore() async throws {
        let restorer = ScriptedRestorer(frontmost: [Self.xcode, Self.safari])
        restorer.outcome = .launched
        var restored: [RunningApp] = []

        _ = await restorer.restoringFocus(onRestore: { restored.append($0) }) { "opened" }

        #expect(restorer.broughtToFront == [Self.xcode], "the restore was attempted")
        #expect(restored.isEmpty, "a launch was reported as the user's app coming back")
    }

    @Test
    @MainActor
    func aRefusedActivationReportsNoRestore() async throws {
        let restorer = ScriptedRestorer(frontmost: [Self.xcode, Self.safari])
        restorer.outcome = .refused
        var restored: [RunningApp] = []

        _ = await restorer.restoringFocus(onRestore: { restored.append($0) }) { "opened" }

        #expect(restorer.broughtToFront == [Self.xcode])
        #expect(restored.isEmpty)
    }

    @Test
    @MainActor
    func anOpenThatMovedNothingRestoresNothing() async throws {
        let restorer = ScriptedRestorer(frontmost: [Self.safari, Self.safari])

        _ = await restorer.restoringFocus { "opened" }

        #expect(restorer.broughtToFront.isEmpty)
    }

    @Test
    @MainActor
    func nothingInFrontBeforehandRestoresNothing() async throws {
        let restorer = ScriptedRestorer(frontmost: [nil, Self.safari])

        _ = await restorer.restoringFocus { "opened" }

        #expect(restorer.broughtToFront.isEmpty)
    }

    @Test
    @MainActor
    func anOpenThatThrowsStillBringsTheAppBackAndRethrows() async {
        struct OpenFailed: Error {}
        let restorer = ScriptedRestorer(frontmost: [Self.xcode, Self.safari])

        await #expect(throws: OpenFailed.self) {
            try await restorer.restoringFocus { throw OpenFailed() }
        }

        #expect(restorer.broughtToFront == [Self.xcode])
    }

    // MARK: - FocusRestorer, the shipping shape

    /// A `FocusRestorer` whose three reads are scripted, recording what the activation was handed.
    @MainActor
    private final class Probe {
        var stillRunning = true
        var outcome: RunningAppActivationOutcome = .switched
        private(set) var activatedWith: [NotedFrontmost] = []

        func restorer(frontmost: [NotedFrontmost?]) -> FocusRestorer {
            var answers = frontmost
            return FocusRestorer(
                frontmost: { answers.isEmpty ? nil : answers.removeFirst() },
                stillRunning: { [unowned self] _ in self.stillRunning },
                activation: { [unowned self] noted in
                    self.activatedWith.append(noted)
                    return self.outcome
                }
            )
        }
    }

    /// **Restoring focus never starts an app that has quit.** When none of the noted instances is
    /// still running, Launch Services is not asked at all — asking would start the app, and a launch
    /// is reported only once it has already happened.
    @Test
    @MainActor
    func anAppThatHasQuitIsNeverAskedToComeBack() async throws {
        let probe = Probe()
        probe.stillRunning = false
        let restorer = probe.restorer(frontmost: [Self.noted(Self.xcode), Self.noted(Self.safari)])
        var restored: [RunningApp] = []

        _ = await restorer.restoringFocus(onRestore: { restored.append($0) }) { "opened" }

        #expect(probe.activatedWith.isEmpty, "Launch Services was asked to bring back an app that had quit")
        #expect(restored.isEmpty)
    }

    /// The control for the test above: the same restore with the app still running does ask, and a
    /// switch comes back as a restore — so the refusal above is the liveness check's doing.
    @Test
    @MainActor
    func anAppStillRunningIsAskedAndASwitchIsARestore() async throws {
        let probe = Probe()
        probe.outcome = .switched
        let restorer = probe.restorer(frontmost: [Self.noted(Self.xcode), Self.noted(Self.safari)])
        var restored: [RunningApp] = []

        _ = await restorer.restoringFocus(onRestore: { restored.append($0) }) { "opened" }

        #expect(probe.activatedWith.map(\.app) == [Self.xcode])
        #expect(restored == [Self.xcode])
    }

    /// Through the shipping shape end to end, a launch is not a restore either.
    @Test
    @MainActor
    func throughTheShippingShapeALaunchIsNotARestore() async throws {
        let probe = Probe()
        probe.outcome = .launched
        let restorer = probe.restorer(frontmost: [Self.noted(Self.xcode), Self.noted(Self.safari)])
        var restored: [RunningApp] = []

        _ = await restorer.restoringFocus(onRestore: { restored.append($0) }) { "opened" }

        #expect(probe.activatedWith.map(\.app) == [Self.xcode], "the app was still running, so it was asked")
        #expect(restored.isEmpty)
    }

    /// **The instances handed to the activation are the ones noted with the app**, not a fresh read
    /// at restore time: a set re-read then would include a copy started after the user's own quit,
    /// and a launch would read as a switch.
    @Test
    @MainActor
    func theActivationIsHandedTheInstancesNotedWithTheApp() async throws {
        let probe = Probe()
        let held = [NSRunningApplication.current]
        let restorer = probe.restorer(frontmost: [Self.noted(Self.xcode, held: held), Self.noted(Self.safari)])

        _ = await restorer.restoringFocus { "opened" }

        let handed = try #require(probe.activatedWith.first)
        #expect(handed.heldInstances.count == 1)
        #expect(handed.heldInstances.first === held.first)
    }

    /// The liveness read the shipping restorer uses: the Dock's instance is running, and an empty set
    /// is nothing to bring back.
    ///
    /// **Not `NSRunningApplication.current`, which the first version of this test used and which is
    /// wrong in exactly the way that matters.** Inside the test helper process it is a placeholder —
    /// measured: process identifier −1, no bundle identifier, and `isTerminated` true — so it read as
    /// an app that had quit, and the assertion that a live instance counts failed on its own sample.
    /// The Dock runs for as long as anyone is logged in, and the `#require` makes a machine without
    /// one fail here by name rather than assert something false.
    @Test
    @MainActor
    func theLivenessReadCountsOnlyInstancesThatAreStillRunning() throws {
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        try #require(!dock.isEmpty, "no Dock is running, so this machine has no live instance to measure against")

        #expect(FocusRestorer.anyStillRunning(dock))
        #expect(!FocusRestorer.anyStillRunning([]))
    }

    @Test
    @MainActor
    func theInertRestorerReadsNothingAndMovesNothing() async {
        let inert = FocusRestorer.inert()

        #expect(inert.frontmost() == nil)
        #expect(await inert.bringToFront(Self.noted(Self.xcode, held: [NSRunningApplication.current])) == .refused)
    }
}
