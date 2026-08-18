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
            mockDestinations: spec.usesMockDestinations,
            claimedEarlierInThisRun: context.claimedEarlierInThisRun
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
        var details = [
            "Converter: \(context.documentConverter.modeName)",
            "Found \(records.count) .docx files",
            "Skipping \(skipped.count) existing PDFs"
        ]
        if let note = Self.renamedOutputNote(for: records) {
            details.append(note)
        }
        return ActionPreview(
            title: "Convert \(pending.count) DOCX files",
            details: details,
            writes: pending.map(\.destinationURL.path),
            conversions: pending.map { "\($0.sourceURL.path) -> \($0.destinationURL.path)" },
            convertedSources: pending.map(\.sourceURL.path)
        )
    }

    /// What to tell the user when two source documents share a basename and an output folder.
    ///
    /// **Deliberately not a `CapabilityRiskEscalation`, and this adapter deliberately has no
    /// `assessRisk` override.** SONNY-28's review asked for that decision explicitly, so here it is
    /// with its reasoning. Every sibling escalation — zip, draft, Markdown, workspace, routine,
    /// snippet — fires because the capability is about to *overwrite* its single output. This
    /// capability never overwrites: a destination that already exists is skipped
    /// (`skippedBecausePDFExists`), and a destination another document of the same run claims is
    /// renamed onto a free name. With nothing overwritten there is nothing to raise a tier for, so
    /// the asymmetry with the siblings is an invariant rather than a gap. The precedent for the
    /// shape is `CreateWorkspaceCapabilityAdapter`'s scope-only-apps note: both approval panels
    /// label an escalation as *what raised this above its default tier*, so a same-tier entry there
    /// would render an informational line in warning colour under a heading that would then be false.
    ///
    /// It rides the run summary because that is the one free-text channel that reaches a person
    /// (`WidgetResultPanel`, via `AgentRunResult.summary`). The preview copy is added for symmetry
    /// with the adapter's other details; `ActionPreview` has no renderer today, so the summary is
    /// what the user actually reads.
    private static func renamedOutputNote(for records: [DocxRecord]) -> String? {
        let renamed = records.filter(\.renamedToAvoidCollision)
        guard !renamed.isEmpty else {
            return nil
        }
        let names = renamed.prefix(3).map(\.destinationURL.lastPathComponent).joined(separator: ", ")
        let remainder = renamed.count > 3 ? ", and \(renamed.count - 3) more" : ""
        return "Renamed \(renamed.count) output\(renamed.count == 1 ? "" : "s") "
            + "because another document would produce the same PDF name: \(names)\(remainder)."
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
        var summary: String
        var converted: [DocxRecord] = []
        if pending.isEmpty {
            log(.summarize, "No DOCX files needed conversion")
            summary = "No DOCX files needed conversion in \(spec.folder.path). Skipped \(skipped) existing PDF outputs."
        } else {
            log(.act, "Starting \(pending.count) conversion(s) with \(context.documentConverter.modeName)")
            converted = try await context.documentConverter.convert(records) { message in
                log(.act, message)
            }
            log(.summarize, "Converted \(converted.count) files")
            summary = "Converted \(converted.count) DOCX files from \(spec.folder.path). Skipped \(skipped) existing PDF outputs."
        }

        // Built from what really converted rather than from every scanned record: a renamed record
        // the converter did not reach is not a file the user will find under a new name.
        if let note = Self.renamedOutputNote(for: converted) {
            summary += " " + note
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
