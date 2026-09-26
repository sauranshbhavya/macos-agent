import Testing
@testable import MacAgent
@testable import MacAgentCore

/// The Command Center sidebar: V1's six pages minus the two the V2 plan removed (Workspaces, and
/// Skills now that packs live on the gateway). Insights and Memory were never meant to go.
@MainActor
@Suite
struct CommandCenterPagesTests {
    /// The order is V1's, so every page keeps the ⌘-number it had there, minus the removed ones.
    @Test
    func theSidebarIsV1sPagesInV1sOrderMinusTheOnesThePlanRemoved() {
        let pages = CommandCenterDestination.allCases
        #expect(pages.map(\.title) == ["Tasks", "Insights", "Routines", "Memory"])
        // V1's own glyphs for the two pages that came back.
        #expect(pages.map(\.systemImage) == ["checklist", "chart.bar.xaxis", "clock.arrow.circlepath", "brain"])
    }

    /// Insights' recent activity opens a task by leaving it for the Tasks page, which takes it once
    /// when it appears, so a later visit to Tasks doesn't reopen it.
    @Test
    func aTaskLeftForTheTasksPageIsTakenOnce() {
        let commands = CommandCenterCommands()
        let task = TaskID()
        commands.taskToOpen = task
        #expect(commands.takeTaskToOpen() == task)
        #expect(commands.takeTaskToOpen() == nil)
        #expect(commands.taskToOpen == nil)
    }
}
