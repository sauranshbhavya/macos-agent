import Foundation

public struct AgentTool: Equatable, Sendable {
    public var operation: AgentOperation
    public var name: String
    public var description: String
    public var requiredFields: [String]
    public var sideEffects: [String]
    public var dryRunBehavior: String
    public var examples: [String]

    public init(
        operation: AgentOperation,
        name: String,
        description: String,
        requiredFields: [String],
        sideEffects: [String],
        dryRunBehavior: String,
        examples: [String] = []
    ) {
        self.operation = operation
        self.name = name
        self.description = description
        self.requiredFields = requiredFields
        self.sideEffects = sideEffects
        self.dryRunBehavior = dryRunBehavior
        self.examples = examples
    }
}

public struct ToolRegistry: Equatable, Sendable {
    public var tools: [AgentTool]

    public init(tools: [AgentTool] = Self.default.tools) {
        self.tools = tools
    }

    /// Tools are metadata: no registry's revealer is called to produce them, so this takes the one
    /// that cannot reach the desktop (SONNY-395). Both registries answer the same tools.
    public static let `default` = ToolRegistry(tools: CapabilityRegistry.revealingNowhere.tools)

    public var plannerDescription: String {
        tools.map { tool in
            let required = tool.requiredFields.isEmpty ? "none" : tool.requiredFields.joined(separator: ", ")
            let effects = tool.sideEffects.isEmpty ? "none" : tool.sideEffects.joined(separator: ", ")
            let examples = tool.examples.isEmpty ? "" : "\n  examples: \(tool.examples.joined(separator: " | "))"
            return """
            - \(tool.operation.rawValue): \(tool.name)
              description: \(tool.description)
              required fields: \(required)
              side effects: \(effects)
              dry run: \(tool.dryRunBehavior)\(examples)
            """
        }
        .joined(separator: "\n")
    }
}
