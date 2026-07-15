import Foundation

public struct CreateLocalDraftCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let descriptor = AppWebsiteActionDescriptors.createLocalDraft

    public static let metadata = CapabilityMetadata(
        id: descriptor.capabilityID,
        displayName: descriptor.displayName,
        description: descriptor.description,
        operations: descriptor.supportedActions,
        plannerTools: [
            AgentTool(
                operation: .createLocalDraft,
                name: "Create local draft",
                description: "Create a local Markdown draft artifact in a whitelisted output path. This does not automate Notes, Mail, Calendar, or any other app UI.",
                requiredFields: ["draftContent"],
                sideEffects: ["write file"],
                dryRunBehavior: "Show the draft file path without writing it.",
                examples: ["Create a local draft called Follow-up with this text"]
            )
        ],
        requiredPermissions: descriptor.requiredPermissions,
        defaultRiskTier: descriptor.defaultRiskTier
    )

    public func resolveDefaultOutputs(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AgentPlan {
        var resolved = plan
        guard let index = resolved.steps.firstIndex(where: { $0.operation == .createLocalDraft }) else {
            return resolved
        }
        resolved.steps[index].outputPath = try draftSpec(in: resolved, context: context).outputURL.path
        return resolved
    }

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try draftSpec(in: plan, context: context)
        return [
            ActionPreview(
                title: "Create local draft",
                details: [
                    "Title: \(spec.title)",
                    "Save Markdown to \(spec.outputURL.path)"
                ],
                writes: [spec.outputURL.path]
            )
        ]
    }

    public func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        let spec = try draftSpec(in: plan, context: context)
        let escalations = context.fileManager.fileExists(atPath: spec.outputURL.path)
            ? [
                CapabilityRiskEscalation(
                    fromTier: metadata.defaultRiskTier,
                    toTier: .tier3,
                    reason: "Draft output already exists at \(spec.outputURL.path)."
                )
            ]
            : []
        return CapabilityRiskAssessment(defaultTier: metadata.defaultRiskTier, escalations: escalations)
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let resolved = try resolveDefaultOutputs(in: plan, context: context)
        let previews = try preview(plan: resolved, context: context)
        let spec = try draftSpec(in: resolved, context: context)
        log(.act, "Writing local draft \(spec.outputURL.path)")
        try Data(markdown(for: spec).utf8).write(to: spec.outputURL, options: .atomic)
        log(.summarize, "Saved local draft")
        return AgentRunResult(
            plan: resolved,
            previews: previews,
            summary: "Created local draft at \(spec.outputURL.path).",
            suggestions: [
                RunSuggestion(title: "Open Draft", kind: .openFile, value: spec.outputURL.path),
                RunSuggestion(title: "Reveal Draft in Finder", kind: .revealInFinder, value: spec.outputURL.path)
            ]
        )
    }

    private struct DraftSpec {
        var title: String
        var content: String
        var outputURL: URL
    }

    private func draftSpec(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> DraftSpec {
        guard let step = plan.steps.first(where: { $0.operation == .createLocalDraft }) else {
            throw AgentExecutionError.invalidPlan("create_local_draft step is missing.")
        }
        guard let content = step.draftContent?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw AgentExecutionError.invalidPlan("create_local_draft needs draftContent.")
        }

        let title = [
            step.draftTitle,
            plan.summary,
            step.description
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? "Local Draft"

        return DraftSpec(
            title: title,
            content: content,
            outputURL: try outputURL(for: step.outputPath, title: title, context: context)
        )
    }

    private func outputURL(for rawOutput: String?, title: String, context: CapabilityExecutionContext) throws -> URL {
        try context.whitelist.resolveOutputPath(
            rawPath: rawOutput,
            defaultName: "draft-\(slug(title))-\(Timestamp.fileSafe(context.now()))",
            extension: "md",
            fileManager: context.fileManager
        )
    }

    private func markdown(for spec: DraftSpec) -> String {
        """
        # \(escape(spec.title))

        \(spec.content)
        """
    }

    private func slug(_ value: String) -> String {
        let cleaned = value
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : "-"
            }
        let collapsed = String(cleaned).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "local" : collapsed
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
    }
}
