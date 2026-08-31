import Foundation

/// Turns a plan's `PlanItemJob` declaration into a concrete, ordered list of items, and expands the
/// plan into one copy of its steps per item (SONNY-235).
///
/// **This is the whole of what "for each of these" costs the rest of the system.** Everything after
/// this function has an ordinary plan: ordinary steps, cut into ordinary units by
/// `chainSegments(in:)`, previewed and assessed and approved and dispatched by code that has never
/// heard of an item. `PlanItemJob`'s own doc comment records why that is the shape.
public enum PlanItemJobResolver {
    /// Resolves and expands, or returns the plan untouched when there is nothing to do.
    ///
    /// **Idempotent, and that is a requirement rather than a nicety.** `AgentActionExecutor.prepare`
    /// runs again over a plan that has already been prepared — the resume path re-prepares the
    /// stored plan through `AgentRunner.prepare(plan:source:)`, and so does every pre-built dispatch.
    /// A second resolution would read the folder or the Finder selection *again*, at a later moment,
    /// and a job could then run over a different list from the one it was approved over. So a job
    /// that already carries its items passes straight through.
    public static func resolving(
        _ plan: AgentPlan,
        whitelist: PathWhitelist,
        finderContextReader: any FinderContextReading,
        fileManager: FileManager
    ) throws -> AgentPlan {
        guard let job = plan.itemJob else {
            return plan
        }
        guard !job.isResolved else {
            return plan
        }

        let items = try resolveItems(
            for: job,
            whitelist: whitelist,
            finderContextReader: finderContextReader,
            fileManager: fileManager
        )

        var resolvedJob = job
        resolvedJob.items = items
        return expanding(plan, over: resolvedJob)
    }

    /// The items this job names, in the order they will be worked through.
    ///
    /// Sorted by path, ascending, always. The order has to be stable across runs or a resumed job
    /// cannot line its stored progress up with a freshly resolved list — and it is the order the
    /// user sees in Finder, which is the second reason to prefer it over anything cleverer.
    public static func resolveItems(
        for job: PlanItemJob,
        whitelist: PathWhitelist,
        finderContextReader: any FinderContextReading,
        fileManager: FileManager
    ) throws -> [String] {
        try validateDeclaration(job)

        let candidates: [URL]
        let sourceDescription: String
        switch job.source {
        case .folder:
            let folderPath = job.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let folder = try whitelist.validateExistingDirectory(folderPath)
            candidates = try children(of: folder, fileManager: fileManager)
            sourceDescription = folder.path
        case .finderSelection:
            candidates = try FinderSelectionResolver.whitelistedSelection(
                whitelist: whitelist,
                finderContextReader: finderContextReader
            )
            sourceDescription = "the Finder selection"
        }

        let matching = candidates
            .filter { matches(job: job, url: $0, fileManager: fileManager) }
            .map { $0.standardizedFileURL.path }
            .sorted()

        guard !matching.isEmpty else {
            throw PlanItemJobError.noItems(emptyMessage(for: job, sourceDescription: sourceDescription))
        }
        guard matching.count <= PlanItemJob.maxItems else {
            throw PlanItemJobError.tooManyItems(count: matching.count, limit: PlanItemJob.maxItems)
        }

        // Every item is whitelisted on its own terms, not on its parent's. A folder inside the
        // whitelist can hold a child the whitelist would refuse — the resolver excludes symbolic
        // links below, and this is what catches anything else `validateInsideWhitelist` knows about
        // that a parent check cannot see.
        return try matching.map { try whitelist.validateInsideWhitelist($0).path }
    }

    /// One copy of the plan's steps per item, with the item written into the declared field.
    ///
    /// **Every step of the template gets the item, except one that takes the previous unit's output.**
    /// The template *is* the work done to one item, so there is no step of it that is about something
    /// else — with exactly one exception, and it is a rule this repository already owns rather than a
    /// special case: `ChainedArtifactCarry.consumesPreviousArtifact` is the predicate for a step whose
    /// input is whatever the unit before it produced. Such a step's input is not the item, by
    /// construction, and writing the item into it does not merely mis-fill the field — it *stops the
    /// step working at all*, because the predicate reads blank path fields and an item written there
    /// makes it false. A job of "convert the documents in each of these folders and open the result"
    /// failed outright before this exception, with `open_generated_artifact` refusing a folder.
    ///
    /// Filling in only steps whose field is empty was the alternative and does not work: the
    /// consuming step's field is empty in the template too, which is precisely what marks it.
    ///
    /// A unit of more than one step is covered without special handling: `[scan_docx, convert]` both
    /// take the folder in `inputPath`, and `DocxConversionCapabilityAdapter` reads
    /// `primary ?? secondary`, so the pair is one item's unit exactly as it is one plan's.
    ///
    /// Step ids are suffixed rather than regenerated, so a reader of a stored record can still see
    /// which template step an expanded one came from — and so `remainingPlan()`'s subtraction, which
    /// is by id, keeps working with no knowledge of jobs at all.
    public static func expanding(_ plan: AgentPlan, over job: PlanItemJob) -> AgentPlan {
        var expandedSteps: [AgentStep] = []
        expandedSteps.reserveCapacity(job.items.count * plan.steps.count)
        for (index, item) in job.items.enumerated() {
            for step in plan.steps {
                var copy = step
                copy.id = "\(step.id)#\(index + 1)"
                copy.itemIndex = index
                if !ChainedArtifactCarry.consumesPreviousArtifact(step) {
                    switch job.itemField {
                    case .inputPath:
                        copy.inputPath = item
                    case .shortcutInput:
                        copy.shortcutInput = item
                    }
                }
                expandedSteps.append(copy)
            }
        }

        var expanded = plan
        expanded.itemJob = job
        expanded.steps = expandedSteps
        return expanded
    }

    // MARK: - Declaration

    private static func validateDeclaration(_ job: PlanItemJob) throws {
        switch job.source {
        case .folder:
            let path = job.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !path.isEmpty else {
                throw PlanItemJobError.missingFolderPath
            }
        case .finderSelection:
            let path = job.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard path.isEmpty else {
                throw PlanItemJobError.folderPathOnNonFolderSource
            }
        }

        if job.itemKind == .folders, !normalizedExtensions(job).isEmpty {
            throw PlanItemJobError.fileExtensionsOnFolderItems
        }
    }

    private static func normalizedExtensions(_ job: PlanItemJob) -> Set<String> {
        Set(
            (job.fileExtensions ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
                .filter { !$0.isEmpty }
                .map { $0.lowercased() }
        )
    }

    // MARK: - Enumeration

    /// A folder's own contents, and **not** what is under them.
    ///
    /// Non-recursive on purpose, and it is the one place this resolver differs from
    /// `FileInventory.docxFiles`, which recurses because "convert the documents in this folder"
    /// plainly means all of them. "Each of these" points at what the user can see: a recursive walk
    /// of `~/Downloads` is a job over thousands of items nobody asked for, approved in one press
    /// because the founder's decision of 2026-08-31 asks once for the whole job. The count cap would
    /// then refuse it, which is a dead end rather than a wrong answer — but the honest fix is to
    /// enumerate what the sentence meant.
    ///
    /// Hidden entries and symbolic links are excluded: the first because nobody means `.DS_Store`
    /// when they say "all of these", and the second for `FileInventory.regularFiles`' reason — a link
    /// is a path whose target the enclosing folder's whitelist check has not vouched for.
    private static func children(of folder: URL, fileManager: FileManager) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        .filter { url in
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            return values?.isSymbolicLink != true
        }
    }

    private static func matches(job: PlanItemJob, url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        switch job.itemKind {
        case .folders:
            return isDirectory.boolValue
        case .files:
            guard !isDirectory.boolValue else {
                return false
            }
            let extensions = normalizedExtensions(job)
            guard !extensions.isEmpty else {
                return true
            }
            return extensions.contains(url.pathExtension.lowercased())
        }
    }

    private static func emptyMessage(for job: PlanItemJob, sourceDescription: String) -> String {
        let extensions = normalizedExtensions(job).sorted()
        let kind: String
        if job.itemKind == .files, !extensions.isEmpty {
            kind = extensions.map { ".\($0)" }.joined(separator: " or ") + " files"
        } else {
            kind = job.itemKind.pluralNoun
        }
        switch job.source {
        case .folder:
            return "There are no \(kind) in \(sourceDescription), so there is nothing to work through."
        case .finderSelection:
            return "Nothing in \(sourceDescription) is a \(job.itemKind == .files ? "file" : "folder"), so there is nothing to work through."
        }
    }
}
