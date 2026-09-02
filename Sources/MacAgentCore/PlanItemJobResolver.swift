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
        // Asked first, so a template that is both forbidden and field-less says the thing the user
        // can act on ("ask for the watcher on its own") rather than "nothing in this task reads the
        // file it would put each item in", which is true and useless. A lone `[start_watching]`
        // template declaring `.inputPath` is exactly that pair.
        try validateTemplateOperations(plan.steps)
        try validateTemplateReadsTheItemField(job, steps: plan.steps)

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

        // Every item is whitelisted on its own terms rather than on its parent's.
        //
        // **Defensive, and measured to be so** (PR #185, F3; a mutant replacing this with `matching`
        // survived the whole suite at `08db3aa`). Two guards reach every escape first: `children(of:)`
        // excludes symbolic links, which is the only shape a child of a validated directory can take
        // whose canonical path leaves it; and the Finder source's items come through
        // `FinderSelectionResolver.whitelistedSelection`, which validates each URL before this
        // resolver sees it. This comment used to claim the line "catches anything else
        // `validateInsideWhitelist` knows about that a parent check cannot see", which nothing
        // demonstrates and which a reviewer was right to call out.
        //
        // Kept for R4's reason rather than removed: the three cover for each other, which is exactly
        // the arrangement in which deleting one later — believing another covers it — opens a hole
        // with a green suite. A new item source that does not validate, or a filter narrowed to let
        // some link through, would make this the only thing standing.
        return try matching.map { try whitelist.validateInsideWhitelist($0).path }
    }

    /// One copy of the plan's steps per item, with the item written into the declared field.
    ///
    /// **Every step of the template gets the item, except one that takes the previous unit's output —
    /// and that exception stops at the template's first step.** Both halves were paid for.
    ///
    /// The exception itself is a rule this repository already owns rather than a special case:
    /// `ChainedArtifactCarry.consumesPreviousArtifact` marks a step whose input is whatever the unit
    /// before it produced. Such a step's input is not the item, by construction, and writing the item
    /// into it does not merely mis-fill the field — it *stops the step working at all*, because the
    /// predicate reads blank path fields and an item written there makes it false. A job of "convert
    /// the documents in each of these folders and open the result" failed outright without it, with
    /// `open_generated_artifact` refusing a folder.
    ///
    /// **The first step is the half the exception got wrong on its own, and a battery's baseline
    /// caught it.** A consuming step *leading* the template has no previous unit inside its own item —
    /// the item is the first thing that happens to it — so it is the one place where the item really
    /// is its input. Exempting it too broke every job whose per-item work is "reveal each of these":
    /// each step arrived with no path at all and every item failed. `ChainedArtifactCarry.applying`
    /// reasons about "the leading step" for the same reason, and says why that is a segment by itself.
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
            for (position, step) in plan.steps.enumerated() {
                var copy = step
                copy.id = "\(step.id)#\(index + 1)"
                copy.itemIndex = index
                if writesTheItem(into: step, at: position, field: job.itemField) {
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

    /// Whether this template step gets the item written into it.
    ///
    /// **Two terms, and each was a defect on its own.**
    ///
    /// *It has to read the field.* Writing the item into a field the operation never reads is how a
    /// job touches none of its items and reports every one of them done (PR #185, F2). The narrower
    /// half of the same hole is a *leading* consuming step handed a field it does not read: it keeps
    /// both path fields blank, so it stays a live consumer of an artifact from outside its own item —
    /// which the resume door can now supply, since `ChainedArtifactCarry.applying` bakes the stored
    /// path onto a remainder's leading step and no in-loop reset can undo a value already in the plan.
    ///
    /// *A trailing consuming step is skipped even though it reads the field.* `open_generated_artifact`
    /// and `reveal_in_finder` read `outputPath ?? inputPath`, so an item written there is read — and
    /// that is precisely the problem: `ChainedArtifactCarry.consumesPreviousArtifact` tests for *blank*
    /// path fields, so filling one in stops the step consuming what the unit before it produced. The
    /// exemption stops at the template's first step, because a consuming step leading the template has
    /// no previous unit inside its own item.
    private static func writesTheItem(into step: AgentStep, at position: Int, field: PlanItemField) -> Bool {
        guard step.operation.itemFieldsRead.contains(field) else {
            return false
        }
        return position == 0 || !ChainedArtifactCarry.consumesPreviousArtifact(step)
    }

    // MARK: - Declaration

    /// **A job in which the item would be written into no step at all is refused before its items are
    /// even read** (PR #185, F2).
    ///
    /// One step is enough, and asking for more would refuse legitimate shapes: a template may
    /// perfectly well hold a step that is the same for every item, and a trailing step that takes what
    /// the unit before it produced reads the item through the chain rather than from the field. What
    /// cannot happen is *none* of them taking it, because then the item reaches nothing and every item
    /// is reported done.
    ///
    /// **Asked through `writesTheItem` rather than `itemFieldsRead` alone**, and the difference is a
    /// real shape rather than a nicety: `[create_local_draft, open_generated_artifact]` declaring
    /// `.inputPath` has a step that *reads* the field — the trailing `open_generated_artifact`, which
    /// reads `outputPath ?? inputPath` — and that step is precisely the one the expansion skips, so
    /// the item still reaches nothing. Reading the field is necessary and being written into is what
    /// the check has to be about.
    ///
    /// Checked against the template rather than the expansion, so the refusal arrives before the
    /// folder or the Finder selection is read — a declaration that cannot work should not first go
    /// looking at the user's files.
    /// **An operation a job may not repeat once per item is refused before the folder is read**
    /// (SONNY-382, PR #187 F1).
    ///
    /// `AgentOperation.jobTemplateRefusal` holds both the membership and the sentence; this is only
    /// the door that asks. Refuses on the first offending step, `StoredRoutine.validateStepSafety`'s
    /// reason: one sentence reaches the user, and the operation named in it is the one to change.
    ///
    /// **Checked on the template rather than on the expansion**, like the check below it, so nothing
    /// looks at the user's files on behalf of a job that cannot run. This is `resolving`'s job and
    /// not `expanding`'s deliberately: `expanding` is a pure rewrite that several tests drive
    /// directly, and a guard placed there would be one every caller could skip. `resolving` is the
    /// single door in `Sources/` — `git grep -n 'PlanItemJobResolver.resolving(' -- Sources | grep -vE ':[0-9]+: *[/][/]'`
    /// → 1 at `73391ba`, `AgentActionExecutor.prepare`; without the comment stage it answers 2, the
    /// second being this repository's own prose about it.
    private static func validateTemplateOperations(_ steps: [AgentStep]) throws {
        for step in steps {
            if let refusal = step.operation.jobTemplateRefusal {
                throw PlanItemJobError.forbiddenStepOperation(refusal)
            }
        }
    }

    private static func validateTemplateReadsTheItemField(_ job: PlanItemJob, steps: [AgentStep]) throws {
        let written = steps.enumerated().contains { position, step in
            writesTheItem(into: step, at: position, field: job.itemField)
        }
        guard !written else {
            return
        }
        throw PlanItemJobError.noStepReadsTheItemField(
            "Sonny cannot do this to each item: nothing in this task reads the \(job.itemField.displayNoun) it would put each item in."
        )
    }

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
