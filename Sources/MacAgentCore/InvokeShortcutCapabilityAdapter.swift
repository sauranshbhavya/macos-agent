import Foundation

public struct InvokeShortcutCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.shortcuts.invoke",
        displayName: "Invoke Shortcut",
        description: "Invoke an existing named Apple Shortcut through the fixed Shortcuts CLI template.",
        operations: [.invokeShortcut],
        plannerTools: [
            AgentTool(
                operation: .invokeShortcut,
                name: "Invoke Shortcut",
                description: "Run an existing named Apple Shortcut. Use shortcutInput only for simple text input explicitly supplied by the user.",
                requiredFields: ["shortcutName"],
                sideEffects: ["run Shortcut"],
                dryRunBehavior: "Show the Shortcut name and input without running it.",
                examples: ["Run my Morning Routine shortcut", "Run shortcut Resize Image with input ~/Desktop/photo.png"]
            )
        ],
        requiredPermissions: [
            CapabilityPermissionMetadata(requirement: .shortcutsAutomation)
        ],
        defaultRiskTier: .tier2
    )

    public func resolveDefaultOutputs(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AgentPlan {
        do {
            _ = try spec(in: plan, context: context)
            return plan
        } catch ShortcutsBridgeError.missingShortcutName {
            return clarifyPlan(question: "Which Shortcut should I run?")
        } catch ShortcutsBridgeError.unknownShortcut(let name, let available) {
            let suffix = available.isEmpty ? "" : " Available Shortcuts include: \(available.prefix(5).joined(separator: ", "))."
            return clarifyPlan(question: "I could not find a Shortcut named \(name). Which Shortcut should I run?\(suffix)")
        }
    }

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try spec(in: plan, context: context)
        var details = [
            "Shortcut: \(spec.name)",
            "Risk: \(try context.shortcutRunHistoryStore.hasCleanObservedSuccess(for: spec.name) ? "Sonny-observed successful invocation" : "No Sonny-observed successful invocation yet")"
        ]
        if let input = spec.input {
            details.append("Input: \(input)")
        }
        return [
            ActionPreview(
                title: "Invoke Shortcut",
                details: details,
                opens: ["Shortcut: \(spec.name)"]
            )
        ]
    }

    public func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        let spec = try spec(in: plan, context: context)
        let hasCleanHistory = try context.shortcutRunHistoryStore.hasCleanObservedSuccess(for: spec.name)
        return CapabilityRiskAssessment(defaultTier: hasCleanHistory ? .tier1 : metadata.defaultRiskTier)
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let spec = try spec(in: plan, context: context)
        let previews = try preview(plan: plan, context: context)
        log(.act, "Running Shortcut \(spec.name)")

        let result: ProcessResult
        do {
            result = try await context.shortcutInvoker.invokeShortcut(name: spec.name, input: spec.input)
        } catch {
            try? context.shortcutRunHistoryStore.recordFailure(shortcutName: spec.name, at: context.now())
            log(.summarize, "Shortcut failed")
            throw error
        }

        guard result.terminationStatus == 0 else {
            try? context.shortcutRunHistoryStore.recordFailure(shortcutName: spec.name, at: context.now())
            log(.summarize, "Shortcut failed")
            throw ShortcutsBridgeError.invocationFailed(spec.name, result.terminationStatus, result.output)
        }

        try? context.shortcutRunHistoryStore.recordSuccess(shortcutName: spec.name, at: context.now())
        if !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log(.observe, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        log(.summarize, "Shortcut completed")
        return AgentRunResult(
            plan: plan,
            previews: previews,
            summary: "Ran Shortcut \(spec.name)."
        )
    }

    private struct ShortcutSpec {
        var name: String
        var input: String?
    }

    private func spec(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> ShortcutSpec {
        guard let step = plan.steps.first(where: { $0.operation == .invokeShortcut }) else {
            throw AgentExecutionError.invalidPlan("invoke_shortcut step is missing.")
        }
        let name = try context.shortcutCatalog.resolveShortcutName(step.shortcutName)
        let input = step.shortcutInput?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShortcutSpec(name: name, input: input?.isEmpty == true ? nil : input)
    }

    private func clarifyPlan(question: String) -> AgentPlan {
        AgentPlan(
            summary: "Clarification needed.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify-shortcut",
                    operation: .clarify,
                    description: "Ask which Shortcut to run.",
                    question: question
                )
            ]
        )
    }
}
