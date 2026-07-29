import Foundation

public struct DocxConversionCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.documents.docx-to-pdf",
        displayName: "DOCX to PDF conversion",
        description: "Find DOCX files in a whitelisted folder and convert them to PDFs using a fixed converter.",
        operations: [.scanDocx, .convertDocxToPDF],
        plannerTools: [
            AgentTool(
                operation: .scanDocx,
                name: "Scan DOCX files",
                description: "Recursively find .docx files in a whitelisted folder.",
                requiredFields: ["inputPath"],
                sideEffects: [],
                dryRunBehavior: "List conversion targets and skipped existing PDFs.",
                examples: ["Find DOCX files in ~/Documents/MacAgentDocs"]
            ),
            AgentTool(
                operation: .convertDocxToPDF,
                name: "Convert DOCX to PDF",
                description: "Convert discovered DOCX files to PDFs using Microsoft Word or explicit mock mode.",
                requiredFields: ["inputPath"],
                sideEffects: ["write files", "control Microsoft Word"],
                dryRunBehavior: "Show conversion pairs without opening Word or writing PDFs.",
                examples: ["Convert all .docx to .pdf in ~/Documents/MacAgentDocs"]
            )
        ],
        requiredPermissions: [
            CapabilityPermissionMetadata(requirement: .desktopDocumentsAccess),
            CapabilityPermissionMetadata(requirement: .wordAutomation)
        ],
        defaultRiskTier: .tier2
    )

    public func resolveDefaultOutputs(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AgentPlan {
        try FinderSelectionResolver.pinningSelectedDirectoryInput(
            in: plan,
            operations: [.scanDocx, .convertDocxToPDF],
            whitelist: context.whitelist,
            finderContextReader: context.finderContextReader
        )
    }

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try spec(in: plan, context: context)
        let records = try records(for: spec, context: context)
        return [preview(for: records, context: context)]
    }

    private func records(for spec: DocxSpec, context: CapabilityExecutionContext) throws -> [DocxRecord] {
        let records = try context.inventory.docxFiles(
            in: spec.folder,
            outputFolder: spec.outputFolder,
            mockDestinations: spec.usesMockDestinations
        )
        guard !records.isEmpty else {
            throw AgentExecutionError.noMatchingFiles("No .docx files were found in \(spec.folder.path).")
        }
        return records
    }

    @MainActor
    private func preview(for records: [DocxRecord], context: CapabilityExecutionContext) -> ActionPreview {
        let pending = records.filter { !$0.skippedBecausePDFExists }
        let skipped = records.filter(\.skippedBecausePDFExists)
        return ActionPreview(
            title: "Convert \(pending.count) DOCX files",
            details: [
                "Converter: \(context.documentConverter.modeName)",
                "Found \(records.count) .docx files",
                "Skipping \(skipped.count) existing PDFs"
            ],
            writes: pending.map(\.destinationURL.path),
            conversions: pending.map { "\($0.sourceURL.path) -> \($0.destinationURL.path)" }
        )
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let spec = try spec(in: plan, context: context)
        log(.act, "Scanning \(spec.folder.path) for .docx files")
        let records = try records(for: spec, context: context)
        let previews = [preview(for: records, context: context)]

        let pending = records.filter { !$0.skippedBecausePDFExists }
        let skipped = records.count - pending.count
        log(.observe, "Found \(records.count) .docx files, skipping \(skipped) existing PDFs")
        let summary: String
        if pending.isEmpty {
            log(.summarize, "No DOCX files needed conversion")
            summary = "No DOCX files needed conversion in \(spec.folder.path). Skipped \(skipped) existing PDF outputs."
        } else {
            log(.act, "Starting \(pending.count) conversion(s) with \(context.documentConverter.modeName)")
            let converted = try await context.documentConverter.convert(records) { message in
                log(.act, message)
            }
            log(.summarize, "Converted \(converted.count) files")
            summary = "Converted \(converted.count) DOCX files from \(spec.folder.path). Skipped \(skipped) existing PDF outputs."
        }

        return AgentRunResult(plan: plan, previews: previews, summary: summary, suggestions: suggestions(for: spec))
    }

    private struct DocxSpec {
        var folder: URL
        var outputFolder: URL?
        var usesMockDestinations: Bool
    }

    @MainActor
    private func spec(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> DocxSpec {
        let scanStep = plan.steps.first { $0.operation == .scanDocx }
        let convertStep = plan.steps.first { $0.operation == .convertDocxToPDF }
        guard let folderPath = try FinderSelectionResolver.selectedDirectoryPath(
            primary: scanStep?.inputPath,
            secondary: convertStep?.inputPath,
            contextSource: scanStep?.contextSource ?? convertStep?.contextSource,
            whitelist: context.whitelist,
            finderContextReader: context.finderContextReader
        ) else {
            throw AgentExecutionError.missingPath("DOCX conversion")
        }

        let folder = try context.whitelist.validateExistingDirectory(folderPath)
        var outputFolder: URL?
        if let rawOutput = convertStep?.outputPath, !rawOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outputFolder = try context.whitelist.validateExistingDirectory(rawOutput)
        }

        return DocxSpec(
            folder: folder,
            outputFolder: outputFolder,
            usesMockDestinations: context.documentConverter.usesMockNaming
        )
    }

    private func suggestions(for spec: DocxSpec) -> [RunSuggestion] {
        [
            RunSuggestion(
                title: "Reveal PDFs in Finder",
                kind: .revealInFinder,
                value: spec.outputFolder?.path ?? spec.folder.path
            )
        ]
    }
}
