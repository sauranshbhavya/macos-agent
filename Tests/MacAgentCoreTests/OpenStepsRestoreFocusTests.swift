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

    private struct ScreenOpener: AppOpening, BrowserOpening {
        let screen: Screen
        func open(bundleIdentifier: String) async throws {
            screen.opened(bundleIdentifier)
        }
        func open(_ url: URL, using browser: MacApp?) async throws {
            screen.opened("browser:\(url.host ?? url.absoluteString)")
        }
    }

    private struct ScreenRestorer: FocusRestoring {
        let screen: Screen
        func frontmost() -> RunningApp? { screen.frontmost }
        func bringToFront(_ app: RunningApp) async -> Bool {
            screen.broughtToFront(app)
            return true
        }
    }

    @MainActor
    private func makeContext(screen: Screen) -> CapabilityExecutionContext {
        VisionTestContext.make(
            installed: [Self.safari, Self.notes],
            appOpener: ScreenOpener(screen: screen),
            browserOpener: ScreenOpener(screen: screen),
            focusRestorer: ScreenRestorer(screen: screen)
        )
    }

    @Test
    @MainActor
    func anAppOpenBringsThePreviousAppBack() async throws {
        let screen = Screen(frontmost: Self.xcode)
        var trace: [String] = []
        let plan = AgentPlan(
            summary: "Open Safari.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")]
        )

        _ = try await OpenAppCapabilityAdapter().execute(plan: plan, context: makeContext(screen: screen)) { _, line in
            trace.append(line)
        }

        #expect(screen.events == ["opened com.apple.Safari", "front com.apple.dt.Xcode"])
        #expect(screen.frontmost?.bundleIdentifier == "com.apple.dt.Xcode")
        #expect(trace.contains("Brought Xcode back in front"))
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

        #expect(screen.events == ["opened browser:example.com", "front com.apple.dt.Xcode"])
    }

    /// The whole workspace opens under one restore: the user's app comes back once, at the end,
    /// rather than fighting each open for the front.
    @Test
    @MainActor
    func aWorkspaceOpenBringsThePreviousAppBackOnceAtTheEnd() async throws {
        let screen = Screen(frontmost: Self.xcode)
        let context = makeContext(screen: screen)
        try context.workspaceStore.save(StoredWorkspace(name: "Writing", apps: ["Safari", "Notes"], urls: ["https://example.com/"]))
        let plan = AgentPlan(
            summary: "Open workspace.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "open", operation: .openWorkspace, description: "Open workspace.", workspaceName: "Writing")]
        )

        _ = try await OpenWorkspaceCapabilityAdapter().execute(plan: plan, context: context) { _, _ in }

        #expect(screen.events == [
            "opened com.apple.Safari",
            "opened com.apple.Notes",
            "opened browser:example.com",
            "front com.apple.dt.Xcode"
        ])
    }

    /// An open whose app was already in front moves nothing, so nothing is brought back.
    @Test
    @MainActor
    func anOpenOfTheAppAlreadyInFrontRestoresNothing() async throws {
        let inFront = RunningApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 3)
        let screen = Screen(frontmost: inFront)
        let plan = AgentPlan(
            summary: "Open Safari.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")]
        )

        _ = try await OpenAppCapabilityAdapter().execute(plan: plan, context: makeContext(screen: screen)) { _, _ in }

        #expect(screen.events == ["opened com.apple.Safari"])
    }
}
