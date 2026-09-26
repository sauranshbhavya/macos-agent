import Foundation
import Testing
import MacAgentTestSupport
@testable import MacAgentCore

/// SONNY-451. An `open_app`, `open_url` or `open_workspace` step brings the app the user was in
/// back in front once the open has completed, through the execution context's `focusRestorer`;
/// the order of calls is held here with fakes that share one scripted screen.
@Suite
struct OpenStepsRestoreFocusTests {
    private static let xcode = RunningApp(displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", processIdentifier: 1)
    private static let safari = InstalledApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari", applicationURL: URL(fileURLWithPath: "/Applications/Safari.app"))
    private static let notes = InstalledApp(displayName: "Notes", bundleIdentifier: "com.apple.Notes", applicationURL: URL(fileURLWithPath: "/System/Applications/Notes.app"))

    /// One screen the fakes share: an open makes its app frontmost, the restorer reads what is in
    /// front and records what it brought back, and the order of everything is one list.
    private final class Screen: @unchecked Sendable {
        var frontmost: RunningApp?
        private(set) var events: [String] = []

        init(frontmost: RunningApp?) {
            self.frontmost = frontmost
        }

        func opened(_ bundleIdentifier: String) {
            events.append("opened \(bundleIdentifier)")
            frontmost = RunningApp(displayName: bundleIdentifier, bundleIdentifier: bundleIdentifier, processIdentifier: 9)
        }

        func broughtToFront(_ app: RunningApp) {
            events.append("front \(app.bundleIdentifier)")
            frontmost = app
        }
    }

    /// Opens land on the screen as the app that actually comes forward. **A URL opens in a browser's
    /// own bundle identifier** — the one the plan chose, or Safari standing in for the default — so a
    /// browser that was already in front reads as in front after the open. This recorded
    /// `browser:<host>` until SONNY-451's rebase, a name no browser has, which made the founders'
    /// "a browser already in front included" impossible to express in this suite at all.
    private struct ScreenOpener: AppOpening, BrowserOpening {
        static let defaultBrowser = "com.apple.Safari"
        let screen: Screen
        func open(bundleIdentifier: String) async throws {
            screen.opened(bundleIdentifier)
        }
        func open(_ url: URL, using browser: MacApp?) async throws {
            screen.opened(browser?.bundleIdentifier ?? Self.defaultBrowser)
        }
    }

    private struct ScreenRestorer: FocusRestoring {
        let screen: Screen
        var outcome: RunningAppActivationOutcome = .switched
        func frontmost() -> NotedFrontmost? {
            screen.frontmost.map { NotedFrontmost(app: $0, heldInstances: []) }
        }
        func bringToFront(_ noted: NotedFrontmost) async -> RunningAppActivationOutcome {
            screen.broughtToFront(noted.app)
            return outcome
        }
    }

    @MainActor
    private func makeContext(screen: Screen, outcome: RunningAppActivationOutcome = .switched) -> CapabilityExecutionContext {
        CapabilityTestContext.make(
            installed: [Self.safari, Self.notes],
            appOpener: ScreenOpener(screen: screen),
            browserOpener: ScreenOpener(screen: screen),
            focusRestorer: ScreenRestorer(screen: screen, outcome: outcome)
        )
    }


    @Test
    @MainActor
    func anAppOpenBringsThePreviousAppBack() async throws {
        let screen = Screen(frontmost: Self.xcode)
        try await openApp("Safari", screen: screen)
        #expect(screen.events == ["opened com.apple.Safari", "front com.apple.dt.Xcode"])
        #expect(screen.frontmost?.bundleIdentifier == "com.apple.dt.Xcode")
    }

    /// The kernel's `open_app`, opening onto the scripted screen.
    @MainActor
    private func openApp(_ name: String, screen: Screen, outcome: RunningAppActivationOutcome = .switched) async throws {
        let capability = OpenAppCapability(
            resolver: FixedAppResolver([Self.safari, Self.notes]),
            opener: { app in screen.opened(app.bundleIdentifier) },
            focus: { ScreenRestorer(screen: screen, outcome: outcome) }
        )
        let prepared = try await capability.prepare(actionID: ActionID(), args: ["app": .string(name)])
        #expect(await capability.execute(prepared).status == .done)
    }


    @Test
    @MainActor
    func aURLOpenBringsThePreviousAppBack() async throws {
        let screen = Screen(frontmost: Self.xcode)
        let plan = AgentPlan(
            summary: "Open a page.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "open", operation: .openURL, description: "Open a page.", targetURL: "https://example.com/")]
        )

        _ = try await OpenSafeURLCapabilityAdapter().execute(plan: plan, context: makeContext(screen: screen)) { _, _ in }

        #expect(screen.events == ["opened com.apple.Safari", "front com.apple.dt.Xcode"])
    }

    /// **A browser that was already in front is included, and the open moves nothing** (founder
    /// decision, 2026-09-12). The user is in Safari and opens a page, which Safari takes: the front
    /// is still the user's own app, so the restore is asked nothing and Safari stays where it was.
    @Test
    @MainActor
    func aURLOpenInTheBrowserAlreadyInFrontRestoresNothing() async throws {
        let inBrowser = RunningApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 4)
        let screen = Screen(frontmost: inBrowser)
        var trace: [String] = []
        let plan = AgentPlan(
            summary: "Open a page.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "open", operation: .openURL, description: "Open a page.", targetURL: "https://example.com/")]
        )

        _ = try await OpenSafeURLCapabilityAdapter().execute(plan: plan, context: makeContext(screen: screen)) { _, line in
            trace.append(line)
        }

        #expect(screen.events == ["opened com.apple.Safari"])
        #expect(screen.frontmost?.bundleIdentifier == "com.apple.Safari")
        #expect(!trace.contains { $0.hasPrefix("Brought ") })
    }

    /// **A launch is not reported in the trace as the user's app coming back.** The restore is
    /// attempted, Launch Services answers that it started a copy rather than switching to the one
    /// the user had, and the run's trace says nothing was brought back.


    /// The whole workspace opens under one restore: the user's app comes back once, at the end,
    /// rather than fighting each open for the front.


    /// An open whose app was already in front moves nothing, so nothing is brought back.

    /// An open whose app was already in front moves nothing, so nothing is brought back.
    @Test
    @MainActor
    func anOpenOfTheAppAlreadyInFrontRestoresNothing() async throws {
        let screen = Screen(frontmost: RunningApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 3))
        try await openApp("Safari", screen: screen)
        #expect(screen.events == ["opened com.apple.Safari"])
    }
}
