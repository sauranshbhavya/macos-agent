import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-451. `restoringFocus` notes the app in front before an open, lets the open run, and brings
/// that app back once the open moved it — on a throw too — and does nothing when nothing moved.
@Suite
struct FocusRestorerTests {
    private static let xcode = RunningApp(displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", processIdentifier: 1)
    private static let safari = RunningApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 2)

    /// A restorer over a scripted screen: `frontmost` answers the script in order, and every
    /// bring-back is recorded.
    private final class ScriptedRestorer: FocusRestoring, @unchecked Sendable {
        private var frontmostAnswers: [RunningApp?]
        private(set) var broughtToFront: [RunningApp] = []
        var activationSucceeds = true

        init(frontmost: [RunningApp?]) {
            self.frontmostAnswers = frontmost
        }

        func frontmost() async -> RunningApp? {
            frontmostAnswers.isEmpty ? nil : frontmostAnswers.removeFirst()
        }

        func bringToFront(_ app: RunningApp) async -> Bool {
            broughtToFront.append(app)
            return activationSucceeds
        }
    }

    @Test
    func anOpenThatMovedTheFrontmostAppBringsItBack() async throws {
        let restorer = ScriptedRestorer(frontmost: [Self.xcode, Self.safari])
        var restored: [RunningApp] = []

        let result = try await restorer.restoringFocus(onRestore: { restored.append($0) }) { "opened" }

        #expect(result == "opened")
        #expect(restorer.broughtToFront == [Self.xcode])
        #expect(restored == [Self.xcode])
    }

    @Test
    func anOpenThatMovedNothingRestoresNothing() async throws {
        let restorer = ScriptedRestorer(frontmost: [Self.safari, Self.safari])

        _ = try await restorer.restoringFocus { "opened" }

        #expect(restorer.broughtToFront.isEmpty)
    }

    @Test
    func nothingInFrontBeforehandRestoresNothing() async throws {
        let restorer = ScriptedRestorer(frontmost: [nil, Self.safari])

        _ = try await restorer.restoringFocus { "opened" }

        #expect(restorer.broughtToFront.isEmpty)
    }

    @Test
    func anOpenThatThrowsStillBringsTheAppBackAndRethrows() async {
        struct OpenFailed: Error {}
        let restorer = ScriptedRestorer(frontmost: [Self.xcode, Self.safari])

        await #expect(throws: OpenFailed.self) {
            try await restorer.restoringFocus { throw OpenFailed() }
        }

        #expect(restorer.broughtToFront == [Self.xcode])
    }

    @Test
    func aRefusedActivationReportsNoRestore() async throws {
        let restorer = ScriptedRestorer(frontmost: [Self.xcode, Self.safari])
        restorer.activationSucceeds = false
        var restored: [RunningApp] = []

        _ = try await restorer.restoringFocus(onRestore: { restored.append($0) }) { "opened" }

        #expect(restorer.broughtToFront == [Self.xcode])
        #expect(restored.isEmpty)
    }

    @Test
    func theInertRestorerReadsNothingAndMovesNothing() async {
        let inert = FocusRestorer.inert()

        #expect(await inert.frontmost() == nil)
        #expect(await inert.bringToFront(Self.xcode) == false)
    }
}
