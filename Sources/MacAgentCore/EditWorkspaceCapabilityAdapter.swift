import Foundation

/// Adds and removes the three things a workspace's restriction scope is made of.
///
/// Until this capability existed a workspace could only be *created*, so `fileLocations` had no way
/// of ever being set and one of the three founder-specified scope dimensions did nothing at all.
///
/// **Escalation is one-directional.** Adding never raises the tier — the user typed the command
/// asking for it, and taxing ordinary setup with an approval prompt would tax exactly the action
/// this feature depends on. Removing does, because removing is the only half that can weaken a
/// boundary the user is relying on. That asymmetry is a recorded row-B decision with a forward flag
/// on row C, not an oversight: once relaxation ships, an ungated add is a way to manufacture
/// relaxation-eligible territory in one un-escalated step.
public struct EditWorkspaceCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.workspaces.edit",
        displayName: "Edit workspace",
        description: "Add or remove apps, safe URLs, and Desktop/Documents folders on a saved workspace.",
        operations: [.editWorkspace],
        plannerTools: [
            AgentTool(
                operation: .editWorkspace,
                name: "Edit workspace",
                // Reaches the model verbatim (`ToolRegistry.plannerDescription` ->
                // `OpenAIPlanner.systemPrompt`), so the same rule `create_workspace`'s description
                // had to spell out applies here: a workspace's apps are its restriction scope, and
                // an app outside the supported list still belongs in that list.
                description: "Add or remove apps, safe http/https URLs, and folders on a workspace the user has already saved. A workspace's apps, URLs, and folders are also its restriction scope, so include every app the user names whether or not it is in the supported-apps list. Folders must be inside Desktop or Documents.",
                requiredFields: ["workspaceName"],
                sideEffects: ["write local workspace file"],
                dryRunBehavior: "Show the additions and removals without saving.",
                examples: [
                    "Add ~/Documents/ClientAlpha to my Client Alpha workspace",
                    "Remove Slack from my research workspace"
                ]
            )
        ],
        requiredPermissions: [],
        defaultRiskTier: .tier2
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let edit = try workspaceEdit(plan, context: context)
        var details: [String] = []
        for list in edit.lists {
            if !list.added.isEmpty {
                details.append("Add \(list.kind.pluralDisplayName): \(list.added.joined(separator: ", "))")
            }
            if !list.removed.isEmpty {
                details.append("Remove \(list.kind.pluralDisplayName): \(list.removed.joined(separator: ", "))")
            }
        }
        if details.isEmpty {
            details.append("No change: the workspace already matches this edit.")
        }
        for note in edit.unmatchedRemovalNotes {
            details.append(note)
        }
        return [
            ActionPreview(
                title: "Edit workspace \(edit.stored.name)",
                details: details,
                writes: [context.workspaceStore.fileURL.path]
            )
        ]
    }

    /// Escalates on removal, and says two different things depending on whether the removal leaves
    /// the dimension configured.
    ///
    /// The distinction is the whole point rather than a nicety. Removing one of several entries
    /// leaves the kind configured, so a non-matching resource still resolves `.outOfScope` and still
    /// prompts — what the user loses is that one entry. Removing the *last* entry empties the list,
    /// and `WorkspaceScope` reads an empty list as `.unconstrained`: the entire dimension stops
    /// escalating on anything, for every future task in this workspace. "Removing ~/Documents/Alpha"
    /// and "this workspace will no longer restrict file locations at all" are different consents,
    /// and only the second one is being given — so the emptying reason states the dimension and
    /// deliberately does not name the entry, which is the smaller thing the user would otherwise
    /// think they were agreeing to.
    ///
    /// One escalation per kind, not one merged reason, because a single edit can do both at once —
    /// drop one of two apps *and* the last file location. A merged reason would have to pick one of
    /// the two wordings and be wrong about the other.
    public func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        let edit = try workspaceEdit(plan, context: context)
        let escalations = edit.lists.compactMap { list -> CapabilityRiskEscalation? in
            guard !list.removed.isEmpty else {
                return nil
            }
            return CapabilityRiskEscalation(
                fromTier: metadata.defaultRiskTier,
                toTier: .tier3,
                reason: list.removalEmptiesTheKind
                    ? Self.dimensionNoLongerRestrictedReason(workspaceName: edit.stored.name, kind: list.kind)
                    : Self.entriesRemovedReason(
                        workspaceName: edit.stored.name,
                        kind: list.kind,
                        removed: list.removed
                    )
            )
        }
        return CapabilityRiskAssessment(defaultTier: metadata.defaultRiskTier, escalations: escalations)
    }

    /// The reason for a removal that leaves the kind configured. Names what is lost.
    ///
    /// Worded as a change to the workspace's *list* rather than as a claim about the resulting
    /// verdict, because the verdict claim is not always true: a workspace holding both `~/Documents`
    /// and `~/Documents/ClientAlpha` still has the second path in scope through the first after the
    /// second is removed. A reason that over-claims is worse than one that under-claims — the user is
    /// approving on the strength of it.
    private static func entriesRemovedReason(
        workspaceName: String,
        kind: ScopedResourceKind,
        removed: [String]
    ) -> String {
        let list = removed.joined(separator: ", ")
        switch kind {
        case .app, .webDomain:
            return "Removes \(list) from workspace \(workspaceName)'s \(kind.pluralDisplayName). "
                + "What is removed stops opening with the workspace and stops counting as part of it."
        case .fileLocation:
            return "Removes \(list) from workspace \(workspaceName)'s file locations. "
                + "What is removed stops counting as part of it."
        }
    }

    /// The reason for a removal that empties the kind. States the dimension, never the entry.
    private static func dimensionNoLongerRestrictedReason(workspaceName: String, kind: ScopedResourceKind) -> String {
        let plural = kind.pluralDisplayName
        return "Workspace \(workspaceName) will no longer restrict \(plural) at all: "
            + "this removes the last entry from its \(plural) list."
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let edit = try workspaceEdit(plan, context: context)
        log(.act, "Updating workspace \(edit.stored.name)")
        try context.workspaceStore.save(edit.updated)
        log(.summarize, "Workspace updated")
        return AgentRunResult(plan: plan, previews: previews, summary: edit.summary)
    }

    // MARK: - Building the edit

    /// One scope dimension's before and after under a requested edit.
    struct EditedList {
        let kind: ScopedResourceKind
        let before: [String]
        let after: [String]
        /// Entries this edit actually drops — derived as `before` minus `after` rather than read off
        /// the request. A request-derived list would call "remove Safari, add Safari" a loss and
        /// escalate for nothing, and would make the answer depend on whether removals or additions
        /// are applied first. What the user loses is a property of the outcome, so it is read from
        /// the outcome.
        let removed: [String]
        let added: [String]
        /// Removal requests that named nothing this workspace held. Reported rather than treated as
        /// an error: a mixed "add A, remove B" edit must not lose A because B was already gone, and
        /// a removal that quietly did nothing is the failure mode this branch exists to refuse.
        let unmatchedRemovals: [String]

        /// True when the removal empties the dimension. `WorkspaceScope` reads an empty list as
        /// `.unconstrained`, so this is the case where the workspace stops restricting the kind.
        var removalEmptiesTheKind: Bool {
            !removed.isEmpty && after.isEmpty
        }
    }

    struct WorkspaceEdit {
        let stored: StoredWorkspace
        let updated: StoredWorkspace
        /// Apps, URLs, file locations — in that fixed order, so the escalations and the summary read
        /// the same way every time.
        let lists: [EditedList]

        var unmatchedRemovalNotes: [String] {
            lists.compactMap { list in
                guard !list.unmatchedRemovals.isEmpty else {
                    return nil
                }
                return "Not in this workspace's \(list.kind.pluralDisplayName), so nothing was removed: "
                    + list.unmatchedRemovals.joined(separator: ", ")
            }
        }

        var summary: String {
            var sentences = ["Updated workspace \(stored.name)."]
            for list in lists {
                if !list.added.isEmpty {
                    sentences.append("Added \(list.added.count) \(list.kind.pluralDisplayName): \(list.added.joined(separator: ", ")).")
                }
                if !list.removed.isEmpty {
                    sentences.append("Removed \(list.removed.count) \(list.kind.pluralDisplayName): \(list.removed.joined(separator: ", ")).")
                }
                // Repeated in the result, not only in the approval prompt: the prompt is read once
                // under time pressure, and this is the sentence that explains why a later task in
                // this workspace stops prompting.
                if list.removalEmptiesTheKind {
                    sentences.append("\(stored.name) no longer restricts \(list.kind.pluralDisplayName) at all.")
                }
            }
            if sentences.count == 1 {
                sentences.append("Nothing changed — the workspace already matched this edit.")
            }
            sentences.append(contentsOf: unmatchedRemovalNotes.map { $0 + "." })
            return sentences.joined(separator: " ")
        }
    }

    private func workspaceEdit(
        _ plan: AgentPlan,
        context: CapabilityExecutionContext
    ) throws -> WorkspaceEdit {
        guard let step = plan.steps.first(where: { $0.operation == .editWorkspace }) else {
            throw AgentExecutionError.invalidPlan("edit_workspace step is missing.")
        }
        guard let rawName = step.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else {
            throw AutomationStoreError.missingName("Workspace")
        }

        // Plain `try`, never `try?`. SONNY-30 documents the sibling adapters' `try?` as a real
        // defect: it collapses a decrypt or decode failure into "no workspace by that name", which
        // here would turn a broken store into a silent create-from-nothing and, in `assessRisk`,
        // would suppress a correct tier-3 escalation. A load failure has to surface as a load
        // failure. `workspace(named:)` already throws `.missingWorkspace(name)` — which names the
        // workspace, as the contract requires — only when the load itself succeeded.
        let stored = try context.workspaceStore.workspace(named: rawName)

        let appAdditions = try Self.validatedAppAdditions(step.workspaceApps ?? [])
        let urlAdditions = try Self.validatedURLAdditions(step.workspaceURLs ?? [])
        let fileAdditions = try Self.validatedFileLocationAdditions(
            step.workspaceFileLocations ?? [],
            whitelist: context.whitelist
        )
        let appRemovals = Self.trimmedNonEmpty(step.workspaceAppsToRemove ?? [])
        let urlRemovals = Self.trimmedNonEmpty(step.workspaceURLsToRemove ?? [])
        // File-location removal requests are deliberately *not* whitelist-validated. A stored
        // location outside the whitelist is inert and useless, so removing it is the fix — refusing
        // to name it would make it the one edit a user could never make.
        let fileRemovals = Self.trimmedNonEmpty(step.workspaceFileLocationsToRemove ?? [])

        // Checked against what the step *asked for*, never against what the edit turns out to
        // change. "Add Safari" to a workspace that already lists Safari is a well-formed request
        // with nothing to do — a no-op with an honest summary — and reporting it as a malformed
        // plan would be a false accusation about the plan.
        let requested = [appAdditions, urlAdditions, fileAdditions, appRemovals, urlRemovals, fileRemovals]
        guard requested.contains(where: { !$0.isEmpty }) else {
            throw AgentExecutionError.invalidPlan(
                "edit_workspace step names no apps, URLs, or file locations to add or remove."
            )
        }

        let appEdit = Self.editedList(
            kind: .app,
            stored: stored.apps,
            additions: appAdditions,
            removalRequests: appRemovals,
            context: context
        )
        let urlEdit = Self.editedList(
            kind: .webDomain,
            stored: stored.urls,
            additions: urlAdditions,
            removalRequests: urlRemovals,
            context: context
        )
        let fileEdit = Self.editedList(
            kind: .fileLocation,
            stored: stored.effectiveFileLocations,
            additions: fileAdditions,
            removalRequests: fileRemovals,
            context: context
        )
        let lists = [appEdit, urlEdit, fileEdit]

        // The same rule creation enforces, applied to the outcome rather than the request: a
        // workspace with neither apps nor URLs cannot be opened at all. Checked before anything is
        // written, so the refusal costs the user nothing.
        guard !appEdit.after.isEmpty || !urlEdit.after.isEmpty else {
            throw AutomationStoreError.emptyWorkspace
        }

        return WorkspaceEdit(
            stored: stored,
            updated: StoredWorkspace(
                // The *stored* display name, not the one the user typed. `WorkspaceStore` keys on a
                // case- and diacritic-folded name, so saving "client alpha" back would silently
                // rename the workspace the user reads as "Client Alpha" — and renaming is an
                // explicit non-goal of this ticket.
                name: stored.name,
                apps: appEdit.after,
                urls: urlEdit.after,
                // Carried explicitly rather than left nil for `WorkspaceStore.save` to merge. The
                // merge would preserve it either way, but an edit that states its whole outcome
                // cannot be broken by a change one layer down.
                teamType: stored.teamType,
                // Always stated, never nil: nil means "not talking about file locations", and an
                // edit that empties the list means it.
                fileLocations: fileEdit.after
            ),
            lists: lists
        )
    }

    // MARK: - Validation of additions

    private static func trimmedNonEmpty(_ raw: [String]) -> [String] {
        raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Names are stored trimmed and otherwise as typed, matching `create_workspace` and the recorded
    /// storage rule in `docs/sonny-branch-b-plan.md` §7. A name the catalog cannot resolve is kept —
    /// it still matches, through the normalized-name fallback — but a blank one is rejected, because
    /// `WorkspaceScope` classifies a blank app name as inert: a boundary that quietly does nothing.
    private static func validatedAppAdditions(_ raw: [String]) throws -> [String] {
        var apps: [String] = []
        for rawApp in raw {
            let trimmed = rawApp.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MacAppCatalogError.missingAppName
            }
            apps.append(trimmed)
        }
        return apps
    }

    private static func validatedURLAdditions(_ raw: [String]) throws -> [String] {
        for url in raw {
            _ = try SafeURL.validateWebURL(url)
        }
        return trimmedNonEmpty(raw)
    }

    /// Validated at save time, exactly as `docs/sonny-branch-b-plan.md` §7 requires: a folder outside
    /// `~/Desktop`/`~/Documents` can never match anything, because `PathWhitelist` rejects the path
    /// long before scope is consulted — **workspace scope narrows the global whitelist and never
    /// widens it.** Accepting one would hand the user a boundary that quietly does nothing.
    ///
    /// `validateInsideWhitelist`, deliberately, and not `validateExistingDirectory`: `WorkspaceScope`
    /// admits a location on exactly this check, so requiring existence here would reject a
    /// not-yet-created folder that the evaluator would have honoured as a real boundary. One rule,
    /// and it is the evaluator's.
    ///
    /// The path is stored trimmed and as typed rather than canonicalized. `WorkspaceScope`
    /// canonicalizes every entry itself when it builds the scope, so storing the resolved form buys
    /// no matching accuracy and costs the user the `~/Documents/ClientAlpha` they typed, which is
    /// what B6's detail sheet will show them.
    private static func validatedFileLocationAdditions(
        _ raw: [String],
        whitelist: PathWhitelist
    ) throws -> [String] {
        var locations: [String] = []
        for rawPath in raw {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw PathValidationError.pathIsEmpty
            }
            _ = try whitelist.validateInsideWhitelist(trimmed)
            locations.append(trimmed)
        }
        return locations
    }

    // MARK: - Entry identity

    /// Identity of one stored entry: what makes two entries the same entry.
    ///
    /// Used to dedupe an addition against what is already listed, and to diff `before` against
    /// `after`.
    private static func entryKey(
        _ raw: String,
        kind: ScopedResourceKind,
        context: CapabilityExecutionContext
    ) -> String? {
        switch kind {
        case .webDomain:
            // Two URLs on one host are two different pages the workspace opens, so a workspace may
            // legitimately hold both and only the *same* URL is a duplicate. This is the one kind
            // where entry identity and removal identity differ — see `removalMatchKey`.
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            return (try? SafeURL.validateWebURL(trimmed))?.absoluteString ?? trimmed
        case .app, .fileLocation:
            return removalMatchKey(raw, kind: kind, context: context)
        }
    }

    /// What a removal request matches stored entries against.
    ///
    /// Deliberately **not** `WorkspaceScope.verdict(for:)`. That answers "does this resource fall
    /// inside the boundary", which is folder *containment* and a dot-suffix host match — right for a
    /// resource, wrong for an entry. Under it, "remove ~/Documents/ClientAlpha" would delete a stored
    /// `~/Documents`, and "remove api.github.com" would delete a stored `github.com`. Entry matching
    /// is *equality* of the same canonical form the evaluator compares through, which is why those
    /// canonical forms are reused verbatim instead of being re-derived here — two normalizers that
    /// disagree is the divergence this whole branch is shaped to avoid.
    private static func removalMatchKey(
        _ raw: String,
        kind: ScopedResourceKind,
        context: CapabilityExecutionContext
    ) -> String? {
        switch kind {
        case .app:
            return WorkspaceScope.appKey(for: raw, catalog: context.appCatalog)

        case .webDomain:
            // Hosts on both sides, not full URLs, and for two independent reasons. A removal that
            // took `https://github.com/a` out while `https://github.com/b` kept the host in scope
            // would change no boundary at all, and the tier-3 prompt describing it as a loss would
            // be false. And naming a site has to work at all: natural language is the only interface
            // this capability has until B6, and "remove github.com" is never byte-equal to a stored
            // full URL. A stored entry `SafeURL` rejects has no host, so it falls back to its own
            // text — otherwise an inert entry would be the one thing a user could never delete.
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = (try? SafeURL.validateWebURL(trimmed))?.host ?? trimmed
            return WorkspaceScope.normalizedHost(host)

        case .fileLocation:
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            // `PathWhitelist`'s own canonicalization, which is public for exactly this reason: tilde
            // expansion, `..` collapsing and symlink resolution agreeing with the evaluator instead
            // of a second implementation of the same arithmetic.
            return PathWhitelist.canonicalURL(trimmed).standardizedFileURL.path
        }
    }

    private static func editedList(
        kind: ScopedResourceKind,
        stored: [String],
        additions: [String],
        removalRequests: [String],
        context: CapabilityExecutionContext
    ) -> EditedList {
        let requestedRemovalKeys = Set(
            removalRequests.compactMap { removalMatchKey($0, kind: kind, context: context) }
        )
        // A stored entry with no removal key cannot be named by any request, so it survives. Only a
        // blank app name reaches that state, and creation already refuses to write one.
        var after = stored.filter { entry in
            guard let key = removalMatchKey(entry, kind: kind, context: context) else {
                return true
            }
            return !requestedRemovalKeys.contains(key)
        }

        var presentEntryKeys = Set(after.compactMap { entryKey($0, kind: kind, context: context) })
        var added: [String] = []
        for addition in additions {
            guard let key = entryKey(addition, kind: kind, context: context) else {
                continue
            }
            guard presentEntryKeys.insert(key).inserted else {
                continue
            }
            after.append(addition)
            added.append(addition)
        }

        let afterEntryKeys = Set(after.compactMap { entryKey($0, kind: kind, context: context) })
        let removed = stored.filter { entry in
            guard let key = entryKey(entry, kind: kind, context: context) else {
                return false
            }
            return !afterEntryKeys.contains(key)
        }

        let storedRemovalKeys = Set(stored.compactMap { removalMatchKey($0, kind: kind, context: context) })
        let unmatchedRemovals = removalRequests.filter { request in
            guard let key = removalMatchKey(request, kind: kind, context: context) else {
                return true
            }
            return !storedRemovalKeys.contains(key)
        }

        return EditedList(
            kind: kind,
            before: stored,
            after: after,
            removed: removed,
            added: added,
            unmatchedRemovals: unmatchedRemovals
        )
    }
}

/// How this capability names a scope dimension in user-facing copy.
///
/// Kept private to the edit path rather than added to `ScopedResourceKind` itself: the evaluator has
/// no user-facing surface, and B6's detail sheet should pick its own labels rather than inherit an
/// approval prompt's phrasing by accident.
private extension ScopedResourceKind {
    var pluralDisplayName: String {
        switch self {
        case .app:
            return "apps"
        case .webDomain:
            return "URLs"
        case .fileLocation:
            return "file locations"
        }
    }
}
