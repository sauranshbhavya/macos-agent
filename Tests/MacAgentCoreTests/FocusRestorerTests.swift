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

    // MARK: - forThisMac()'s composition, with real `NSRunningApplication` values (PR #238's F12)

    /// The Dock's instance — a real `NSRunningApplication` with a bundle identifier and a bundle URL
    /// that runs for as long as anyone is logged in — and the `#require` makes a machine without one
    /// fail here by name rather than assert something false.
    ///
    /// **Not `NSRunningApplication.current`**, which the first version of these tests used: inside
    /// the test helper process it is a placeholder — measured: process identifier −1, no bundle
    /// identifier, and `isTerminated` true.
    private static func dock() throws -> NSRunningApplication {
        try #require(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
            "no Dock is running, so this machine has no live instance to measure against"
        )
    }

    /// **The instances handed to the activation are the ones read when the app was noted, and the
    /// running list is read exactly once** — the founders' rule of 2026-09-12, through the shipping
    /// composition itself rather than a closure this test writes. A composition that re-read the
    /// running instances when it activated would hand over this later, empty read and read twice.
    ///
    /// The earlier test under this rule passed its own activation closure, so `forThisMac()` could
    /// re-read at restore time and it stayed green (PR #238's F12).
    @Test
    @MainActor
    func theShippingCompositionHandsTheActivationTheInstancesItNotedAndReadsThemOnce() async throws {
        let dock = try Self.dock()
        var fronts: [NSRunningApplication?] = [dock, nil]
        var runningReads = 0
        var handed: (url: URL, held: [NSRunningApplication])?
        let restorer = FocusRestorer.composed(
            frontmostApplication: { fronts.isEmpty ? nil : fronts.removeFirst() },
            runningApplications: { _ in
                runningReads += 1
                return runningReads == 1 ? [dock] : []
            },
            activation: { url, held in
                handed = (url, held)
                return .switched
            }
        )
        var restored: [RunningApp] = []

        _ = await restorer.restoringFocus(onRestore: { restored.append($0) }) { "opened" }

        let activation = try #require(handed, "the noted app was not asked back")
        #expect(runningReads == 1, "the running instances were read again after the app was noted")
        #expect(activation.held.count == 1)
        #expect(activation.held.first === dock)
        #expect(activation.url == dock.bundleURL)
        #expect(restored.map(\.bundleIdentifier) == ["com.apple.dock"])
    }

    /// The liveness read the shipping restorer uses: the Dock's instance is running from the Dock's
    /// own bundle, and nothing else counts.
    ///
    /// **Only a copy at the noted bundle is live** (PR #238's F7): Xcode and Xcode-beta share a
    /// bundle identifier, and a check over every instance would let a restore open Xcode-beta.app —
    /// starting it — because Xcode was still running. The same instance read against another bundle
    /// is the case that must answer `false`.
    @Test
    @MainActor
    func theLivenessReadCountsOnlyInstancesStillRunningFromTheNotedBundle() throws {
        let dock = try Self.dock()
        let dockBundle = try #require(dock.bundleURL)

        #expect(FocusRestorer.anyStillRunning([dock], at: dockBundle))
        #expect(!FocusRestorer.anyStillRunning([dock], at: URL(fileURLWithPath: "/Applications/Xcode-beta.app")))
        #expect(!FocusRestorer.anyStillRunning([], at: dockBundle))
        #expect(!FocusRestorer.anyStillRunning([dock], at: nil))
    }

    // MARK: - Handing the user's app on to the next unit (PR #238's F5)

    /// **An open handing on brings nothing back and holds what was in front**, so a session that
    /// takes the front right after it gives that app back once, at its end.
    @Test
    @MainActor
    func anOpenHandingOnBringsNothingBackAndHoldsTheAppThatWasInFront() async throws {
        let restorer = ScriptedRestorer(frontmost: [Self.xcode, Self.safari])
        let carry = FocusCarry()
        var restored: [RunningApp] = []

        _ = await restorer.restoringFocus(onRestore: { restored.append($0) }, handingOnTo: carry) { "opened" }

        #expect(restorer.broughtToFront.isEmpty)
        #expect(restored.isEmpty)
        #expect(carry.take()?.app == Self.xcode)
        #expect(carry.take() == nil, "a held app is handed out once")
    }

    /// An open that throws has no session to hand the app to, so it restores at once.
    @Test
    @MainActor
    func anOpenHandingOnThatThrowsStillBringsTheAppBack() async {
        struct OpenFailed: Error {}
        let restorer = ScriptedRestorer(frontmost: [Self.xcode, Self.safari])
        let carry = FocusCarry()

        await #expect(throws: OpenFailed.self) {
            try await restorer.restoringFocus(handingOnTo: carry) { throw OpenFailed() }
        }

        #expect(restorer.broughtToFront == [Self.xcode])
        #expect(carry.take() == nil)
    }

    /// The carry holds the first app it is given, so a second open in the same run cannot replace the
    /// app the user was really in.
    @Test
    @MainActor
    func theCarryKeepsTheFirstAppItIsGiven() {
        let carry = FocusCarry()
        carry.hold(Self.noted(Self.xcode))
        carry.hold(Self.noted(Self.safari))

        #expect(carry.take()?.app == Self.xcode)
    }

    /// A hand-off applies only to an open of the app the next unit controls, by bundle identifier and
    /// whatever its case.
    @Test
    @MainActor
    func aHandoffAppliesOnlyToAnOpenOfTheAppTheNextUnitControls() {
        let carry = FocusCarry()
        let toNotes = FocusHandoff(nextUnitControls: "com.apple.Notes", carry: carry)

        #expect(toNotes.carry(forOpening: ["com.apple.notes"]) === carry)
        #expect(toNotes.carry(forOpening: ["com.apple.Safari", "com.apple.Notes"]) === carry)
        #expect(toNotes.carry(forOpening: ["com.apple.Safari"]) == nil)
        #expect(toNotes.carry(forOpening: []) == nil)
        #expect(FocusHandoff(nextUnitControls: nil, carry: carry).carry(forOpening: ["com.apple.Notes"]) == nil)
    }

    @Test
    @MainActor
    func theInertRestorerReadsNothingAndMovesNothing() async {
        let inert = FocusRestorer.inert()

        #expect(inert.frontmost() == nil)
        #expect(await inert.bringToFront(Self.noted(Self.xcode, held: [NSRunningApplication.current])) == .refused)
    }
}
