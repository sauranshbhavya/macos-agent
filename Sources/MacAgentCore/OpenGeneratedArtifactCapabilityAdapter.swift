import Foundation

public struct OpenGeneratedArtifactCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let descriptor = AppWebsiteActionDescriptors.openGeneratedArtifact

    public static let metadata = CapabilityMetadata(
        id: descriptor.capabilityID,
        displayName: descriptor.displayName,
        description: descriptor.description,
        operations: descriptor.supportedActions,
        requiredPermissions: descriptor.requiredPermissions,
        defaultRiskTier: descriptor.defaultRiskTier
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let url = try artifactURL(in: plan, context: context, requiresExistingFile: false)
        return [
            ActionPreview(
                title: "Open generated artifact",
                details: ["Open \(url.path)"],
                opens: [url.path]
            )
        ]
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let url = try artifactURL(in: plan, context: context, requiresExistingFile: true)
        log(.act, "Opening generated artifact \(url.path)")
        try await context.fileOpener.openFile(url)
        log(.summarize, "Opened generated artifact")
        return AgentRunResult(plan: plan, previews: previews, summary: "Opened generated artifact \(url.path).")
    }

    private func artifactURL(
        in plan: AgentPlan,
        context: CapabilityExecutionContext,
        requiresExistingFile: Bool
    ) throws -> URL {
        guard let step = plan.steps.first(where: { $0.operation == .openGeneratedArtifact }) else {
            throw AgentExecutionError.invalidPlan("open_generated_artifact step is missing.")
        }

        guard let rawPath = step.outputPath ?? step.inputPath,
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentExecutionError.invalidPlan("open_generated_artifact needs outputPath or a previous chained artifact.")
        }

        let url = try context.whitelist.validateInsideWhitelist(rawPath)
        if requiresExistingFile {
            guard context.fileManager.fileExists(atPath: url.path) else {
                throw PathValidationError.notFound(url.path)
            }
        }
        if context.fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                throw AgentExecutionError.invalidPlan("open_generated_artifact needs a file path, not a folder.")
            }
        }
        return url
    }
}
