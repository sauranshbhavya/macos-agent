import Foundation
import Testing
@testable import MacAgentCore

@Suite
struct ToolRegistryTests {
    @Test
    func defaultRegistryDescribesNewAgentTools() {
        let registry = ToolRegistry.default
        let operations = registry.tools.map(\.operation)

        #expect(operations.contains(.openApp))
        #expect(operations.contains(.openURL))
        #expect(operations.contains(.webToMarkdown))
        #expect(operations.contains(.playMedia))
        #expect(operations.contains(.invokeShortcut))
        #expect(operations.contains(.switchRunningApp))
        #expect(operations.contains(.clarify))
        #expect(registry.plannerDescription.contains("open_app"))
        #expect(registry.plannerDescription.contains("open_url"))
        #expect(registry.plannerDescription.contains("web_to_markdown"))
        #expect(registry.plannerDescription.contains("play_media"))
        #expect(registry.plannerDescription.contains("invoke_shortcut"))
        // SONNY-68: the one operation that moved out of the instant-resolver-only set. It is
        // described to the planner so a switch phrasing the resolver declines has a truthful
        // operation to land on instead of the nearest-sounding one.
        #expect(registry.plannerDescription.contains("switch_running_app"))
        #expect(registry.plannerDescription.contains("Play Jimmy Cooks by Drake on Apple Music"))
        #expect(registry.plannerDescription.contains("Spotify"))
        #expect(registry.plannerDescription.contains("Apple Music"))
        #expect(!registry.plannerDescription.contains("calculate_utility"))
        #expect(!registry.plannerDescription.contains("lookup_clipboard_history"))
        #expect(!registry.plannerDescription.contains("expand_snippet"))
        #expect(!registry.plannerDescription.contains("save_snippet"))
        #expect(!registry.plannerDescription.contains("lookup_recent_artifacts"))
    }

    @Test
    func plannerPromptIsGeneratedFromToolRegistry() {
        let registry = ToolRegistry(
            tools: [
                AgentTool(
                    operation: .openApp,
                    name: "Open test app",
                    description: "Open a test app.",
                    requiredFields: ["appName"],
                    sideEffects: ["open app"],
                    dryRunBehavior: "Preview the app.",
                    examples: ["Open Test"]
                )
            ]
        )

        let prompt = OpenAIPlanner.systemPrompt(toolRegistry: registry)

        #expect(prompt.contains("open_app"))
        #expect(prompt.contains("Open test app"))
        #expect(prompt.contains("Do not invent tools"))
    }
}
