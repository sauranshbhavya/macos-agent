import Foundation

public struct LargestFilesZipCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.files.largest-files-zip",
        displayName: "Largest files zip",
        description: "Select the largest regular files in a whitelisted folder and create a zip archive.",
        operations: [.scanSelectLargestFiles, .createZip],
        requiredPermissions: [
            CapabilityPermissionMetadata(requirement: .desktopDocumentsAccess)
        ],
        defaultRiskTier: .tier2
    )

    /// Resolves **the** zip step of the unit it is given — `firstIndex` is exact here, not a
    /// first-match approximation, because a unit holds at most one step per operation.
    ///
    /// A call handed a plan with two scan-and-zip pairs could not tell them apart — `spec(in:)`
    /// would answer with the first scan's folder for both — so each pair must arrive here on its
    /// own. `AdapterCapabilities` builds one pair per operation.
    public func resolveDefaultOutputs(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AgentPlan {
        var resolvedPlan = try FinderSelectionResolver.pinningSelectedDirectoryInput(
            in: plan,
            operations: [.scanSelectLargestFiles, .createZip],
            whitelist: context.whitelist,
            finderContextReader: context.finderContextReader
        )
        guard let zipIndex = resolvedPlan.steps.firstIndex(where: { $0.operation == .createZip }) else {
            return resolvedPlan
        }

        let outputPath = resolvedPlan.steps[zipIndex].outputPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if outputPath?.isEmpty != false {
            resolvedPlan.steps[zipIndex].outputPath = try spec(in: resolvedPlan, context: context).outputURL.path
        }
        return resolvedPlan
    }

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try spec(in: plan, context: context)
        let files = try context.inventory.largestFiles(in: spec.folder, count: spec.count)
        guard !files.isEmpty else {
            throw AgentExecutionError.noMatchingFiles("No regular files were found in \(spec.folder.path).")
        }
        return [preview(for: files, spec: spec)]
    }

    private func preview(for files: [FileRecord], spec: LargestFileSpec) -> ActionPreview {
        ActionPreview(
            title: "Zip \(files.count) largest files",
            details: files.map { "\($0.url.pathRelative(to: spec.folder)) (\($0.displaySize))" },
            writes: [spec.outputURL.path]
        )
    }

    public func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        let spec = try spec(in: plan, context: context)
        let escalations = context.fileManager.fileExists(atPath: spec.outputURL.path)
            ? [
                CapabilityRiskEscalation(
                    fromTier: metadata.defaultRiskTier,
                    toTier: .tier3,
                    reason: "Zip output already exists at \(spec.outputURL.path).",
                    // The write would overwrite an existing file.
                    consequence: .destructive
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
        let spec = try spec(in: plan, context: context)
        log(.act, "Scanning \(spec.folder.path) for regular files")
        let files = try context.inventory.largestFiles(in: spec.folder, count: spec.count)
        guard !files.isEmpty else {
            throw AgentExecutionError.noMatchingFiles("No regular files were found in \(spec.folder.path).")
        }

        let previews = [preview(for: files, spec: spec)]
        log(.observe, "Selected \(files.count) files")
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.byteCount }
        let totalSize = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        log(.act, "Creating \(spec.outputURL.path) from \(files.count) files (\(totalSize))")
        try await context.zipArchiver.createArchive(
            sourceFolder: spec.folder,
            files: files.map(\.url),
            outputURL: spec.outputURL
        )
        log(.summarize, "Created zip archive")

        let summary = "Created \(spec.outputURL.lastPathComponent) with \(files.count) largest files from \(spec.folder.path)."
        return AgentRunResult(plan: plan, previews: previews, summary: summary, suggestions: suggestions(for: spec))
    }

    private struct LargestFileSpec {
        var folder: URL
        var count: Int
        var outputURL: URL
    }

    private func spec(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> LargestFileSpec {
        let scanStep = plan.steps.first { $0.operation == .scanSelectLargestFiles }
        let zipStep = plan.steps.first { $0.operation == .createZip }
        guard let folderPath = try FinderSelectionResolver.selectedDirectoryPath(
            primary: scanStep?.inputPath,
            secondary: zipStep?.inputPath,
            contextSource: scanStep?.contextSource ?? zipStep?.contextSource,
            whitelist: context.whitelist,
            finderContextReader: context.finderContextReader
        ) else {
            throw AgentExecutionError.missingPath("largest file scan")
        }

        let folder = try context.whitelist.validateExistingDirectory(folderPath)
        let count = max(scanStep?.count ?? zipStep?.count ?? 3, 1)
        let outputURL: URL
        if let rawOutput = zipStep?.outputPath, !rawOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outputURL = try context.whitelist.validateOutputPath(rawOutput)
        } else {
            // Through the whitelist, not appended straight onto `folder` (SONNY-264). The folder was
            // validated; the leaf was not, and this destination's writer is the one in the tree that
            // follows a leaf symlink — `ProcessZipArchiver` hands the path to `/usr/bin/zip`, which
            // opens it. The user-named branch three lines above always validated; this one now does
            // the same thing by the same call.
            outputURL = try context.whitelist.validateOutputFile(
                named: "largest-files-\(Timestamp.fileSafe(context.now())).zip",
                in: folder
            )
        }

        return LargestFileSpec(folder: folder, count: count, outputURL: outputURL)
    }

    /// Open first, then Reveal, the order the draft and web-research adapters use (SONNY-445).
    /// The widget's result panel draws its file chip off the first `.openFile` suggestion and
    /// nothing else, so a result with only Reveal — which is what this emitted — showed the zip's
    /// path in a sentence and no chip, no icon, no size, no Open: the founders' pass, test 9.
    private func suggestions(for spec: LargestFileSpec) -> [RunSuggestion] {
        [
            RunSuggestion(
                title: "Open zip",
                kind: .openFile,
                value: spec.outputURL.path
            ),
            RunSuggestion(
                title: "Reveal zip in Finder",
                kind: .revealInFinder,
                value: spec.outputURL.path
            )
        ]
    }
}
