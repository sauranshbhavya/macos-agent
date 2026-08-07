import Foundation

public enum AgentExecutionError: Error, LocalizedError, Equatable {
    case emptyCommand
    case unsupported(String)
    case missingPath(String)
    case invalidPlan(String)
    case noMatchingFiles(String)
    case missingClarificationQuestion

    public var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "Enter a natural-language command first."
        case .unsupported(let detail):
            return detail
        case .missingPath(let operation):
            return "\(operation) needs a folder path."
        case .invalidPlan(let detail):
            return "The generated plan is invalid: \(detail)"
        case .noMatchingFiles(let detail):
            return detail
        case .missingClarificationQuestion:
            return "The planner asked for clarification but did not include a question."
        }
    }
}

public struct PreparedAgentRun: Equatable, Sendable {
    public var plan: AgentPlan
    public var previews: [ActionPreview]
    public var clarificationQuestion: String?

    public init(plan: AgentPlan, previews: [ActionPreview], clarificationQuestion: String? = nil) {
        self.plan = plan
        self.previews = previews
        self.clarificationQuestion = clarificationQuestion
    }

    public var sideEffects: [String] {
        previews.flatMap(\.sideEffects)
    }
}

@MainActor
public final class AgentActionExecutor {
    private let whitelist: PathWhitelist
    private let inventory: FileInventory
    private let zipArchiver: ZipArchiving
    private let documentConverter: DocumentConverting
    private let browserOpener: BrowserOpening
    private let hackerNewsFetcher: HackerNewsFetching
    private let appCatalog: MacAppCatalog
    private let appSearchURLCatalog: AppSearchURLCatalog
    private let appOpener: AppOpening
    private let fileOpener: FileOpening
    private let mediaOpener: MediaOpening
    private let spotifyPlaybackProvider: any SpotifyPlaybackProviding
    private let appleMusicPlaybackProvider: any AppleMusicPlaybackProviding
    private let finderContextReader: FinderContextReading
    private let permissionReadinessService: PermissionReadinessService
    private let routineStore: RoutineStore
    private let workspaceStore: WorkspaceStore
    private let webPageLoader: PublicWebPageLoader
    private let webSearchProvider: any WebSearchProviding
    private let webResearchSynthesizer: any WebResearchSynthesizing
    private let usageRecorder: any TaskUsageRecording
    private let clipboardHistoryStore: ClipboardHistoryStore
    private let snippetStore: SnippetStore
    private let runningAppSwitcher: any RunningAppSwitching
    private let recentArtifactStore: RecentArtifactStore
    private let shortcutCatalog: any ShortcutCatalogProviding
    private let shortcutInvoker: any ShortcutInvoking
    private let shortcutRunHistoryStore: ShortcutRunHistoryStore
    private let capabilityRegistry: CapabilityRegistry
    private let fileManager: FileManager
    private let now: () -> Date
    private let hotKeyReady: () -> Bool

    public init(
        whitelist: PathWhitelist = PathWhitelist(),
        inventory: FileInventory = FileInventory(),
        zipArchiver: ZipArchiving = ProcessZipArchiver(),
        documentConverter: DocumentConverting = AutoDocumentConverter(),
        browserOpener: BrowserOpening = WorkspaceBrowserOpener(),
        hackerNewsFetcher: HackerNewsFetching = HackerNewsAPIClient(),
        appCatalog: MacAppCatalog = .default,
        appSearchURLCatalog: AppSearchURLCatalog = .default,
        appOpener: AppOpening = WorkspaceAppOpener(),
        fileOpener: FileOpening = WorkspaceFileOpener(),
        mediaOpener: MediaOpening = NativeMediaOpener(),
        spotifyPlaybackProvider: (any SpotifyPlaybackProviding)? = nil,
        appleMusicPlaybackProvider: (any AppleMusicPlaybackProviding)? = nil,
        finderContextReader: FinderContextReading = AppleScriptFinderContextReader(),
        permissionReadinessService: PermissionReadinessService = PermissionReadinessService(),
        routineStore: RoutineStore = RoutineStore(),
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        webPageLoader: PublicWebPageLoader? = nil,
        webSearchProvider: (any WebSearchProviding)? = nil,
        webResearchSynthesizer: (any WebResearchSynthesizing)? = nil,
        usageRecorder: any TaskUsageRecording = NoopTaskUsageRecorder.shared,
        clipboardHistoryStore: ClipboardHistoryStore = ClipboardHistoryStore(),
        snippetStore: SnippetStore = SnippetStore(),
        runningAppSwitcher: any RunningAppSwitching = WorkspaceRunningAppSwitcher(),
        recentArtifactStore: RecentArtifactStore = RecentArtifactStore(),
        shortcutCatalog: any ShortcutCatalogProviding = ProcessShortcutCatalog(),
        shortcutInvoker: any ShortcutInvoking = ProcessShortcutInvoker(),
        shortcutRunHistoryStore: ShortcutRunHistoryStore = ShortcutRunHistoryStore(),
        capabilityRegistry: CapabilityRegistry = .default,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        hotKeyReady: @escaping () -> Bool = { true }
    ) {
        self.whitelist = whitelist
        self.inventory = inventory
        self.zipArchiver = zipArchiver
        self.documentConverter = documentConverter
        self.browserOpener = browserOpener
        self.hackerNewsFetcher = hackerNewsFetcher
        self.appCatalog = appCatalog
        self.appSearchURLCatalog = appSearchURLCatalog
        self.appOpener = appOpener
        self.fileOpener = fileOpener
        self.mediaOpener = mediaOpener
        self.spotifyPlaybackProvider = spotifyPlaybackProvider ?? UnavailableSpotifyPlaybackProvider()
        self.appleMusicPlaybackProvider = appleMusicPlaybackProvider ?? UnavailableAppleMusicPlaybackProvider()
        self.finderContextReader = finderContextReader
        self.permissionReadinessService = permissionReadinessService
        self.routineStore = routineStore
        self.workspaceStore = workspaceStore
        self.webPageLoader = webPageLoader ?? PublicWebPageLoader.live()
        self.webSearchProvider = webSearchProvider ?? UnavailableWebSearchProvider()
        self.usageRecorder = usageRecorder
        self.webResearchSynthesizer = webResearchSynthesizer ?? EnvironmentWebResearchSynthesizer(
            usageRecorder: usageRecorder
        )
        self.clipboardHistoryStore = clipboardHistoryStore
        self.snippetStore = snippetStore
        self.runningAppSwitcher = runningAppSwitcher
        self.recentArtifactStore = recentArtifactStore
        self.shortcutCatalog = shortcutCatalog
        self.shortcutInvoker = shortcutInvoker
        self.shortcutRunHistoryStore = shortcutRunHistoryStore
        self.capabilityRegistry = capabilityRegistry
        self.fileManager = fileManager
        self.now = now
        self.hotKeyReady = hotKeyReady
    }

    public func prepare(plan: AgentPlan) throws -> PreparedAgentRun {
        if let question = try clarificationQuestion(in: plan) {
            let preview = ActionPreview(
                title: "Clarification needed",
                details: [question]
            )
            return PreparedAgentRun(plan: plan, previews: [preview], clarificationQuestion: question)
        }

        let resolvedPlan = try resolveDefaultOutputs(in: plan)
        if let question = try clarificationQuestion(in: resolvedPlan) {
            let preview = ActionPreview(
                title: "Clarification needed",
                details: [question]
            )
            return PreparedAgentRun(plan: resolvedPlan, previews: [preview], clarificationQuestion: question)
        }

        do {
            let previews = try preview(plan: resolvedPlan)
            return PreparedAgentRun(plan: resolvedPlan, previews: previews)
        } catch let error as AutomationStoreError {
            // Only a not-found target converts, and only *after* preview has run, so an earlier
            // step's real error still wins: previewing in step order is what decides which
            // problem the user hears about first.
            guard let question = missingAutomationTargetQuestion(for: error) else {
                throw error
            }
            let clarifyPlan = Self.clarificationPlan(question: question)
            let preview = ActionPreview(
                title: "Clarification needed",
                details: [question]
            )
            return PreparedAgentRun(plan: clarifyPlan, previews: [preview], clarificationQuestion: question)
        }
    }

    /// Turns a planner-invented workspace/routine name into a clarification instead of a hard
    /// failure. Asked something vague like "focus on writing", the planner will confidently emit
    /// `open_workspace(workspaceName: "writing")`; letting that reach the adapter produced
    /// "No workspace named writing is saved." — a technical error about a concept the user never
    /// raised. Mirrors how the instant resolver already turns an unknown Shortcut name into a
    /// clarification rather than a failure (spec §4A.7).
    ///
    /// Deliberately narrow: **only** a name that matches nothing becomes a clarification. A
    /// missing/empty name, an unreadable store, a malformed plan, or an unsafe URL inside a
    /// workspace that does exist all still throw exactly as before.
    ///
    /// An *unresolvable app* inside an existing workspace used to be on that list and no longer is —
    /// SONNY-44 decoupled scope listing from `MacAppCatalog`, so such an entry is skipped at open
    /// time and the open succeeds. It is not a clarification either; it is simply not an error.
    ///
    /// Checks the *other* store first: "run hehe" when hehe is a saved workspace used to answer
    /// with a list of routine names while ignoring the exact-name workspace the user almost
    /// certainly meant. Exact (store-normalized) match only, no fuzzy matching, and an unreadable
    /// other store degrades to the same-kind list below rather than turning a good clarification
    /// into a thrown error.
    private func missingAutomationTargetQuestion(for error: AutomationStoreError) -> String? {
        switch error {
        case .missingWorkspace(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let routine = (try? routineStore.loadAll())?[normalized(trimmed)]?.name {
                return "I don't have a workspace called \"\(trimmed)\" saved, but you do have a routine called \"\(routine)\" — did you mean to run that?"
            }
            return missingTargetQuestion(
                name: name,
                kind: "workspace",
                savedNames: (try? workspaceStore.loadAll())?.values.map(\.name)
            )
        case .missingRoutine(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let workspace = (try? workspaceStore.loadAll())?[normalized(trimmed)]?.name {
                return "I don't have a routine called \"\(trimmed)\" saved, but you do have a workspace called \"\(workspace)\" — did you mean to open that?"
            }
            return missingTargetQuestion(
                name: name,
                kind: "routine",
                savedNames: (try? routineStore.loadAll())?.values.map(\.name)
            )
        case .missingName, .emptyRoutine, .emptyWorkspace, .unsafeRoutineStep, .invalidSchedule:
            // Every other automation-store failure keeps its own error. A missing name, an
            // empty definition, an unsafe nested step, or a malformed schedule are real problems,
            // not "did you mean".
            return nil
        }
    }

    private func missingTargetQuestion(name: String, kind: String, savedNames: [String]?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let savedNames else {
            // The store could not be read at all. That is a load failure with its own
            // surfacing — do not disguise it as "you never saved this".
            return nil
        }

        let sorted = savedNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !sorted.isEmpty else {
            return "I don't have a \(kind) called \"\(trimmed)\" saved — you haven't saved any \(kind)s yet. What would you like me to do instead?"
        }

        let shown = sorted.prefix(5).joined(separator: ", ")
        let remainder = sorted.count > 5 ? ", and \(sorted.count - 5) more" : ""
        return "I don't have a \(kind) called \"\(trimmed)\" saved — did you mean one of: \(shown)\(remainder)? Or would you like to do something else?"
    }

    /// Same shape the planner emits for a genuine clarification, so every downstream path
    /// (risk assessment, the widget's clarification panel, prior-task context) treats this
    /// identically to one rather than needing a second notion of "needs clarification".
    private static func clarificationPlan(question: String) -> AgentPlan {
        AgentPlan(
            summary: question,
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify-missing-automation-target",
                    operation: .clarify,
                    description: question,
                    question: question
                )
            ]
        )
    }

    /// Read-only risk assessment for a plan, optionally bound to a workspace.
    ///
    /// `scope` is non-optional and non-defaulted on purpose — see `TaskWorkspaceScope`. Every call
    /// site writes `.unscoped` deliberately or passes a real scope; none of them gets to be silent.
    ///
    /// Scope only ever **raises**. `effectiveTier` is computed as a maximum that now includes the
    /// scope escalations' `toTier`, so nothing here can lower a tier — which four other things
    /// depend on staying honest: the unattended gate (`approvedTier >= effectiveTier` against a
    /// fixed `.approved(.tier2)`), the stale-approval re-check in `AgentRunner.execute`, the
    /// `risk.assessed`/`risk.escalated` trace, and `UnattendedTrustAdvisory`, which reads
    /// `effectiveTier` alone. No relaxation of any kind lives here; that is row C's, and the
    /// `scopeVerdict` roll-up exists to give it a typed input rather than a re-derivation.
    public func assessRisk(plan: AgentPlan, scope: TaskWorkspaceScope) throws -> CapabilityRiskAssessment {
        let resolvedPlan = try resolveDefaultOutputs(in: plan)
        // The same scope goes into the nested-plan closure, so a `run_routine` step's stored steps
        // are evaluated under the boundary its caller is bound by. Without it, a routine is a
        // laundering hole: its steps would escape the workspace the task naming it is inside.
        let context = capabilityContext(scope: scope)

        var assessments: [CapabilityRiskAssessment] = []
        var metadata: [CapabilityMetadata] = []
        var seenCapabilityIDs: Set<String> = []

        for segment in try assessmentSegments(in: resolvedPlan) {
            for adapter in try capabilityAdapters(in: segment) {
                assessments.append(try adapter.assessRisk(plan: segment, context: context))
                // Deduplicated across the whole plan, in step order — segments preserve step
                // order, so this is the same metadata list (and therefore the same approval copy)
                // a single whole-plan `capabilityAdapters(in:)` call produced before segmenting.
                if seenCapabilityIDs.insert(adapter.metadata.id).inserted {
                    metadata.append(adapter.metadata)
                }
            }
        }

        let defaultTier = highestRiskTier(in: assessments.map(\.defaultTier))
        // Evaluated over the whole resolved plan rather than per segment: the evaluator walks
        // `plan.steps` itself, so a second step of the same operation is visible to it in a way it
        // is not to an adapter picking its step with `.first(where:)`. Resolved, so a default output
        // path pinned by `resolveDefaultOutputs` is the path actually compared.
        let findings = scopeFindings(in: resolvedPlan, scope: scope)
        let scopeEscalations = scopeEscalations(for: findings, scope: scope, fromTier: defaultTier)
        let effectiveTier = highestRiskTier(
            in: assessments.map(\.effectiveTier) + [defaultTier] + scopeEscalations.map(\.toTier)
        )
        return CapabilityRiskAssessment(
            defaultTier: defaultTier,
            effectiveTier: effectiveTier,
            approvalCopy: approvalCopy(for: resolvedPlan, metadata: metadata, tier: effectiveTier),
            // Adapter escalations first, scope after, then the existing dedup — a scope escalation
            // is an additional reason on the same prompt, never a replacement for one.
            escalations: unique(assessments.flatMap(\.escalations) + scopeEscalations),
            scopeVerdict: scopeVerdict(
                findings: findings,
                nested: assessments.compactMap(\.scopeVerdict),
                scope: scope
            )
        )
    }

    /// How many distinct out-of-scope resources the prompt names before it stops listing them.
    ///
    /// Three, matching `involvedResource(in:metadata:)`'s own `prefix(3)`. Both surfaces join every
    /// escalation reason into one paragraph, so an unbounded list turns an "allow anyway?" prompt
    /// into a wall the user scrolls past — and the decision a fifth hostname changes is none.
    private static let scopeEscalationLimit = 3

    /// Every resource the plan touches, with the bound workspace's verdict on each.
    ///
    /// Two sources, because one of them cannot come from the pure classifier. `PlanScopedResources`
    /// answers for every operation from the step alone; `open_workspace`'s real resources are the
    /// *stored* record's apps and URLs, which the classifier has no store to read. That half is
    /// discharged here, at the call site where `workspaceStore` is already in hand, which is what
    /// keeps the evaluator and its matching semantics untouched.
    private func scopeFindings(in plan: AgentPlan, scope: TaskWorkspaceScope) -> [WorkspaceScopeFinding] {
        guard let workspaceScope = scope.workspaceScope else {
            return []
        }
        var findings = WorkspaceScopeEvaluator.evaluate(
            plan: plan,
            scope: workspaceScope,
            searchURLCatalog: appSearchURLCatalog
        ).findings
        for step in plan.steps where step.operation == .openWorkspace {
            findings.append(contentsOf: openWorkspaceFindings(for: step, scope: workspaceScope))
        }
        return findings
    }

    /// The stored apps and URLs of the workspace an `open_workspace` step names.
    ///
    /// A plan bound to workspace A that opens workspace B launches B's apps and URLs, and until this
    /// existed nothing compared them against A — the same laundering hole `run_routine` has, through
    /// a different door. `PlanScopedResources` classifies `open_workspace` as no resources of its
    /// own deliberately, and that stays true: this adds the store-derived half without teaching the
    /// pure classifier about a store.
    ///
    /// A step naming the *bound* workspace needs no special case — its apps and URLs are the scope's
    /// own lists, so every resource resolves `.inScope` and no escalation is produced. An
    /// unresolvable name yields no resources rather than an escalation: the run fails at execution
    /// anyway, and a scope prompt for a workspace that does not exist would be a second, wrong
    /// explanation of the same problem.
    ///
    /// Note these are the *stored* record's fields, not the step's: `open_workspace` steps carry no
    /// `workspaceApps`/`workspaceURLs` at all — those belong to `create_workspace`.
    private func openWorkspaceFindings(for step: AgentStep, scope: WorkspaceScope) -> [WorkspaceScopeFinding] {
        guard let record = try? workspaceStore.workspace(named: step.workspaceName ?? "") else {
            return []
        }
        // Blank app names are dropped for the same reason the URL branch below drops what `SafeURL`
        // rejects, and the two must agree or the boundary contradicts itself: `WorkspaceScope.init`
        // records a blank app name as *inert*, while `verdict(for: .app(""))` answers `.outOfScope`
        // whenever the bound workspace lists any app. Mapping it through unfiltered therefore
        // produced an escalation reading " is not part of the Research workspace." — a sentence with
        // no subject — in the approval panel. `WorkspaceStore.save` validates nothing, and SONNY-40's
        // edit path and SONNY-41's detail sheet are both about to add record-writing surfaces, so a
        // record can genuinely carry one.
        var resources: [ScopedResource] = record.apps
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ScopedResource.app($0) }
        for rawURL in record.urls {
            // A stored URL `SafeURL` rejects, or one with no host, contributes nothing — the same
            // treatment `WorkspaceScope` gives an inert entry on its own side of the comparison.
            guard let host = (try? SafeURL.validateWebURL(rawURL))?.host else {
                continue
            }
            resources.append(.webDomain(host))
        }
        return resources.map { resource in
            WorkspaceScopeFinding(
                stepID: step.id,
                operation: step.operation,
                resource: resource,
                verdict: scope.verdict(for: resource)
            )
        }
    }

    /// One escalation per distinct out-of-scope resource, capped.
    ///
    /// Deduplicated on the `ScopedResource` itself rather than on its rendered string, so two
    /// genuinely different resources that happen to share a value stay two — and `Hashable`
    /// conformance makes that a set insert rather than the linear scan `unique(_:)` does for
    /// escalations.
    ///
    /// `fromTier` is the plan's own default tier rather than a hardcoded value, because that is what
    /// this escalation is actually raising *from*. Out-of-scope goes to tier 3 rather than a smaller
    /// bump: tier 2 and tier 3 render the same foreground panel (SONNY-10), so the visible cost is
    /// the sentence itself, "explicit approval" is the tier whose semantics match an "allow anyway?"
    /// prompt, and it makes the unattended behavior correct by default.
    private func scopeEscalations(
        for findings: [WorkspaceScopeFinding],
        scope: TaskWorkspaceScope,
        fromTier: CapabilityRiskTier
    ) -> [CapabilityRiskEscalation] {
        guard let workspaceScope = scope.workspaceScope else {
            return []
        }
        var seen: Set<ScopedResource> = []
        var ordered: [ScopedResource] = []
        for finding in findings where finding.verdict == .outOfScope {
            guard let resource = finding.resource, seen.insert(resource).inserted else {
                continue
            }
            ordered.append(resource)
        }
        return ordered.prefix(Self.scopeEscalationLimit).map { resource in
            CapabilityRiskEscalation(
                fromTier: fromTier,
                toTier: .tier3,
                reason: "\(resource.value) is not part of the \(workspaceScope.workspaceName) workspace."
            )
        }
    }

    /// The plan-level roll-up, folding in whatever nested assessments reported.
    ///
    /// `nil` when unscoped — "no workspace was bound" is a different statement from any verdict.
    ///
    /// The precedence below is `WorkspaceScopeEvaluator.planVerdict`'s, restated over verdicts
    /// rather than findings because a nested plan hands back a verdict and nothing else. Synthesizing
    /// findings from those verdicts to reuse `planVerdict` directly was rejected: `WorkspaceScopeFinding`
    /// documents `resource == nil` as meaning exactly `.opaque`, so a synthetic `.inScope` finding
    /// with no resource would violate the type's own invariant to save four lines.
    ///
    /// Folding nested verdicts in at all is what stops a routine laundering the roll-up: without it
    /// a plan whose routine writes outside the boundary reports `.inScope`, which is precisely the
    /// input row C would relax on.
    private func scopeVerdict(
        findings: [WorkspaceScopeFinding],
        nested: [ScopeVerdict],
        scope: TaskWorkspaceScope
    ) -> ScopeVerdict? {
        guard scope.workspaceScope != nil else {
            return nil
        }
        let verdicts = [WorkspaceScopeEvaluator.planVerdict(for: findings)] + nested
        if verdicts.contains(.outOfScope) {
            return .outOfScope
        }
        if verdicts.contains(.opaque) {
            return .opaque
        }
        if verdicts.contains(.inScope) {
            return .inScope
        }
        return .unconstrained
    }

    /// The units risk assessment walks: exactly the units `preview` and `execute` hand to an
    /// adapter. A chain is split with `segmentPlans(in:)` — the same segmentation
    /// `previewChain`/`executeChain` use, not a parallel one — and every other plan goes to its
    /// adapter whole, the way `previewCapability`/`executeCapability` do.
    ///
    /// Assessing a chain as one plan was the last plan-walking path in this executor that was not
    /// segmented, and every adapter picks its step with `.first(where:)`. So a chain of two
    /// `.createLocalDraft` steps executed both writes but assessed only the first: a second draft
    /// overwrote an existing file with no collision escalation and no tier-3 gate.
    ///
    /// Segments are assessed *without* the previous-artifact path `previewChain`/`executeChain`
    /// thread between segments, because the only two operations that consume it —
    /// `.revealInFinder` and `.openGeneratedArtifact` — take the default tier-based assessment and
    /// never read a path. Giving either one an `assessRisk` override means threading it here too.
    private func assessmentSegments(in plan: AgentPlan) throws -> [AgentPlan] {
        guard try workflow(in: plan) == .chain else {
            return [plan]
        }
        return try segmentPlans(in: plan)
    }

    public func preview(plan: AgentPlan) throws -> [ActionPreview] {
        switch try workflow(in: plan) {
        case .clarify:
            guard let question = try clarificationQuestion(in: plan) else {
                throw AgentExecutionError.missingClarificationQuestion
            }
            return [
                ActionPreview(
                    title: "Clarification needed",
                    details: [question]
                )
            ]
        case .largestFiles:
            return try previewCapability(for: .scanSelectLargestFiles, plan: plan)
        case .docx:
            return try previewCapability(for: .scanDocx, plan: plan)
        case .hackerNews:
            return try previewCapability(for: .openHackerNews, plan: plan)
        case .webResearch:
            return try previewCapability(for: .webToMarkdown, plan: plan)
        case .openApp:
            return try previewCapability(for: .openApp, plan: plan)
        case .openAppSearchURL:
            return try previewCapability(for: .openAppSearchURL, plan: plan)
        case .openURL:
            return try previewCapability(for: .openURL, plan: plan)
        case .openGeneratedArtifact:
            return try previewCapability(for: .openGeneratedArtifact, plan: plan)
        case .createLocalDraft:
            return try previewCapability(for: .createLocalDraft, plan: plan)
        case .calculator:
            return try previewCapability(for: .calculateUtility, plan: plan)
        case .clipboardHistory:
            return try previewCapability(for: .lookupClipboardHistory, plan: plan)
        case .snippetSave:
            return try previewCapability(for: .saveSnippet, plan: plan)
        case .snippetExpansion:
            return try previewCapability(for: .expandSnippet, plan: plan)
        case .runningAppSwitch:
            return try previewCapability(for: .switchRunningApp, plan: plan)
        case .recentArtifacts:
            return try previewCapability(for: .lookupRecentArtifacts, plan: plan)
        case .mediaOpen:
            return try previewCapability(for: .playMedia, plan: plan)
        case .finderSelection:
            return try previewCapability(for: .getFinderSelection, plan: plan)
        case .revealInFinder:
            return try previewCapability(for: .revealInFinder, plan: plan)
        case .permissionReadiness:
            return try previewCapability(for: .showPermissionReadiness, plan: plan)
        case .saveRoutine:
            return try previewCapability(for: .saveRoutine, plan: plan)
        case .runRoutine:
            return try previewCapability(for: .runRoutine, plan: plan)
        case .createWorkspace:
            return try previewCapability(for: .createWorkspace, plan: plan)
        case .editWorkspace:
            return try previewCapability(for: .editWorkspace, plan: plan)
        case .openWorkspace:
            return try previewCapability(for: .openWorkspace, plan: plan)
        case .invokeShortcut:
            return try previewCapability(for: .invokeShortcut, plan: plan)
        case .chain:
            return try previewChain(plan)
        }
    }

    /// Runs an already-approved plan.
    ///
    /// `preferredBrowser` binds every URL this plan opens *on the injected browser-opener seam*
    /// to one browser — not `.playMedia`, which opens on the media seam (SONNY-51). It is threaded as a
    /// parameter rather than held on the executor deliberately: `execute` suspends at every step,
    /// so executor-held state would be readable — and mutable — by any other main-actor task that
    /// interleaved, and a routine's browser could leak into a command the user ran meanwhile.
    /// Only `RunRoutineCapabilityAdapter` passes a non-nil value, through `executeNestedPlan`.
    public func execute(
        plan: AgentPlan,
        preferredBrowser: MacApp? = nil,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let resolvedPlan = try resolveDefaultOutputs(in: plan)
        let workflow = try workflow(in: resolvedPlan)

        switch workflow {
        case .clarify:
            throw AgentExecutionError.missingClarificationQuestion
        case .largestFiles:
            return try await executeCapability(for: .scanSelectLargestFiles, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .docx:
            return try await executeCapability(for: .scanDocx, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .hackerNews:
            return try await executeCapability(for: .openHackerNews, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .webResearch:
            return try await executeCapability(for: .webToMarkdown, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .openApp:
            return try await executeCapability(for: .openApp, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .openAppSearchURL:
            return try await executeCapability(for: .openAppSearchURL, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .openURL:
            return try await executeCapability(for: .openURL, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .openGeneratedArtifact:
            return try await executeCapability(for: .openGeneratedArtifact, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .createLocalDraft:
            return try await executeCapability(for: .createLocalDraft, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .calculator:
            return try await executeCapability(for: .calculateUtility, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .clipboardHistory:
            return try await executeCapability(for: .lookupClipboardHistory, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .snippetSave:
            return try await executeCapability(for: .saveSnippet, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .snippetExpansion:
            return try await executeCapability(for: .expandSnippet, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .runningAppSwitch:
            return try await executeCapability(for: .switchRunningApp, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .recentArtifacts:
            return try await executeCapability(for: .lookupRecentArtifacts, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .mediaOpen:
            return try await executeCapability(for: .playMedia, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .finderSelection:
            return try await executeCapability(for: .getFinderSelection, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .revealInFinder:
            return try await executeCapability(for: .revealInFinder, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .permissionReadiness:
            return try await executeCapability(for: .showPermissionReadiness, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .saveRoutine:
            return try await executeCapability(for: .saveRoutine, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .runRoutine:
            return try await executeCapability(for: .runRoutine, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .createWorkspace:
            return try await executeCapability(for: .createWorkspace, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .editWorkspace:
            return try await executeCapability(for: .editWorkspace, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .openWorkspace:
            return try await executeCapability(for: .openWorkspace, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .invokeShortcut:
            return try await executeCapability(for: .invokeShortcut, plan: resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        case .chain:
            return try await executeChain(resolvedPlan, preferredBrowser: preferredBrowser, log: log)
        }
    }

    private enum Workflow: Equatable {
        case clarify
        case largestFiles
        case docx
        case hackerNews
        case webResearch
        case openApp
        case openAppSearchURL
        case openURL
        case openGeneratedArtifact
        case createLocalDraft
        case calculator
        case clipboardHistory
        case snippetSave
        case snippetExpansion
        case runningAppSwitch
        case recentArtifacts
        case mediaOpen
        case finderSelection
        case revealInFinder
        case permissionReadiness
        case saveRoutine
        case runRoutine
        case createWorkspace
        case editWorkspace
        case openWorkspace
        case invokeShortcut
        case chain
    }

    private func workflow(in plan: AgentPlan) throws -> Workflow {
        try validateSupported(plan)

        let workflows = Set(try plan.steps.map { step in
            try workflow(for: step.operation)
        })

        guard workflows.count == 1, let workflow = workflows.first else {
            if workflows.contains(.clarify) {
                throw AgentExecutionError.invalidPlan("Clarification must be the only planned step.")
            }
            return .chain
        }

        if plan.steps.count > 1, shouldChainWhenRepeated(workflow) {
            return .chain
        }

        return workflow
    }

    private func shouldChainWhenRepeated(_ workflow: Workflow) -> Bool {
        switch workflow {
        case .openApp,
             .openAppSearchURL,
             .openURL,
             .openGeneratedArtifact,
             .createLocalDraft,
             .calculator,
             .clipboardHistory,
             .snippetSave,
             .snippetExpansion,
             .runningAppSwitch,
             .recentArtifacts,
             .mediaOpen,
             .finderSelection,
             .revealInFinder,
             .permissionReadiness,
             .saveRoutine,
             .runRoutine,
             .createWorkspace,
             .editWorkspace,
             .openWorkspace,
             .invokeShortcut:
            return true
        case .clarify,
             .largestFiles,
             .docx,
             .hackerNews,
             .webResearch,
             .chain:
            return false
        }
    }

    private func workflow(for operation: AgentOperation) throws -> Workflow {
        switch operation {
        case .clarify:
            return .clarify
        case .scanSelectLargestFiles, .createZip:
            return .largestFiles
        case .scanDocx, .convertDocxToPDF:
            return .docx
        case .openHackerNews, .fetchHNHeadlines, .writeMarkdown:
            return .hackerNews
        case .webToMarkdown:
            return .webResearch
        case .openApp:
            return .openApp
        case .openAppSearchURL:
            return .openAppSearchURL
        case .openURL:
            return .openURL
        case .openGeneratedArtifact:
            return .openGeneratedArtifact
        case .createLocalDraft:
            return .createLocalDraft
        case .calculateUtility:
            return .calculator
        case .lookupClipboardHistory:
            return .clipboardHistory
        case .saveSnippet:
            return .snippetSave
        case .expandSnippet:
            return .snippetExpansion
        case .switchRunningApp:
            return .runningAppSwitch
        case .lookupRecentArtifacts:
            return .recentArtifacts
        case .playMedia:
            return .mediaOpen
        case .getFinderSelection:
            return .finderSelection
        case .revealInFinder:
            return .revealInFinder
        case .showPermissionReadiness:
            return .permissionReadiness
        case .saveRoutine:
            return .saveRoutine
        case .runRoutine:
            return .runRoutine
        case .createWorkspace:
            return .createWorkspace
        case .editWorkspace:
            return .editWorkspace
        case .openWorkspace:
            return .openWorkspace
        case .invokeShortcut:
            return .invokeShortcut
        case .unsupported:
            throw AgentExecutionError.unsupported("Unsupported operation.")
        }
    }

    private func clarificationQuestion(in plan: AgentPlan) throws -> String? {
        guard try workflow(in: plan) == .clarify else {
            return nil
        }

        guard let question = plan.steps.first(where: { $0.operation == .clarify })?.question?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !question.isEmpty else {
            throw AgentExecutionError.missingClarificationQuestion
        }

        return question
    }

    private func resolveDefaultOutputs(in plan: AgentPlan) throws -> AgentPlan {
        _ = try workflow(in: plan)
        var resolvedPlan = plan

        if resolvedPlan.steps.contains(where: { [.scanSelectLargestFiles, .createZip].contains($0.operation) }) {
            resolvedPlan = try capabilityRegistry
                .adapter(for: .scanSelectLargestFiles)
                .resolveDefaultOutputs(in: resolvedPlan, context: capabilityContext(scope: .unscoped))
        }

        if resolvedPlan.steps.contains(where: { [.scanDocx, .convertDocxToPDF].contains($0.operation) }) {
            resolvedPlan = try capabilityRegistry
                .adapter(for: .scanDocx)
                .resolveDefaultOutputs(in: resolvedPlan, context: capabilityContext(scope: .unscoped))
        }

        if let markdownIndex = resolvedPlan.steps.firstIndex(where: { $0.operation == .writeMarkdown }) {
            resolvedPlan = try capabilityRegistry
                .adapter(for: resolvedPlan.steps[markdownIndex].operation)
                .resolveDefaultOutputs(in: resolvedPlan, context: capabilityContext(scope: .unscoped))
        }

        if resolvedPlan.steps.contains(where: { $0.operation == .webToMarkdown }) {
            resolvedPlan = try capabilityRegistry
                .adapter(for: .webToMarkdown)
                .resolveDefaultOutputs(in: resolvedPlan, context: capabilityContext(scope: .unscoped))
        }

        if resolvedPlan.steps.contains(where: { $0.operation == .createLocalDraft }) {
            resolvedPlan = try capabilityRegistry
                .adapter(for: .createLocalDraft)
                .resolveDefaultOutputs(in: resolvedPlan, context: capabilityContext(scope: .unscoped))
        }

        if resolvedPlan.steps.contains(where: { $0.operation == .invokeShortcut }) {
            resolvedPlan = try capabilityRegistry
                .adapter(for: .invokeShortcut)
                .resolveDefaultOutputs(in: resolvedPlan, context: capabilityContext(scope: .unscoped))
        }

        return resolvedPlan
    }

    private func validateSupported(_ plan: AgentPlan) throws {
        if let unsupported = plan.steps.first(where: { $0.operation == .unsupported }) {
            throw AgentExecutionError.unsupported(unsupported.description)
        }
    }

    private func previewCapability(for operation: AgentOperation, plan: AgentPlan) throws -> [ActionPreview] {
        try capabilityRegistry
            .adapter(for: operation)
            .preview(plan: plan, context: capabilityContext(scope: .unscoped))
    }

    private func executeCapability(
        for operation: AgentOperation,
        plan: AgentPlan,
        preferredBrowser: MacApp?,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        try await capabilityRegistry
            .adapter(for: operation)
            .execute(plan: plan, context: capabilityContext(preferredBrowser: preferredBrowser, scope: .unscoped), log: log)
    }

    private func capabilityAdapters(in plan: AgentPlan) throws -> [any CapabilityAdapter] {
        var seen: Set<String> = []
        var adapters: [any CapabilityAdapter] = []
        for step in plan.steps {
            let adapter = try capabilityRegistry.adapter(for: step.operation)
            guard seen.insert(adapter.metadata.id).inserted else {
                continue
            }
            adapters.append(adapter)
        }
        return adapters
    }

    private func highestRiskTier(in tiers: [CapabilityRiskTier]) -> CapabilityRiskTier {
        let rawValue = tiers
            .map(\.rawValue)
            .reduce(CapabilityRiskTier.tier0.rawValue, max)
        return CapabilityRiskTier(rawValue: rawValue) ?? .tier0
    }

    private func approvalCopy(
        for plan: AgentPlan,
        metadata: [CapabilityMetadata],
        tier: CapabilityRiskTier
    ) -> RiskApprovalCopy {
        RiskApprovalCopy(
            actionDescription: actionDescription(for: plan, metadata: metadata),
            riskReason: riskReason(for: tier),
            involvedResource: involvedResource(in: plan, metadata: metadata),
            dataLeavesDevice: dataLeavesDevice(in: plan),
            undoDescription: undoDescription(for: tier, plan: plan)
        )
    }

    private func actionDescription(for plan: AgentPlan, metadata: [CapabilityMetadata]) -> String {
        let summary = plan.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            return summary
        }

        let names = unique(metadata.map(\.displayName))
        return names.isEmpty ? "Run the prepared plan" : names.joined(separator: ", ")
    }

    private func riskReason(for tier: CapabilityRiskTier) -> String {
        switch tier {
        case .tier0:
            return "This only reads local context or status."
        case .tier1:
            return "This opens an app, URL, media result, or Finder location."
        case .tier2:
            return "This can create or change local files, routines, or workspaces."
        case .tier3:
            return "This may affect external services or overwrite/destructively change data."
        case .tier4:
            return "This is prohibited or unavailable in Sonny v1."
        }
    }

    private func involvedResource(in plan: AgentPlan, metadata: [CapabilityMetadata]) -> String {
        var resources: [String] = []

        for step in plan.steps {
            appendIfPresent(step.appName, to: &resources)
            appendIfPresent(step.targetURL, to: &resources)
            if let sourceURLs = step.sourceURLs {
                resources.append(contentsOf: sourceURLs)
            }
            appendIfPresent(searchQueryResource(for: step), to: &resources)
            appendIfPresent(step.outputPath, to: &resources)
            appendIfPresent(step.inputPath, to: &resources)
            appendIfPresent(step.routineName.map { "Routine: \($0)" }, to: &resources)
            appendIfPresent(step.workspaceName.map { "Workspace: \($0)" }, to: &resources)
            appendIfPresent(step.shortcutName.map { "Shortcut: \($0)" }, to: &resources)
            if let provider = step.mediaProvider, let title = step.mediaTitle {
                resources.append("\(provider.displayName): \(title)")
            }
            if step.operation == .openHackerNews || step.operation == .fetchHNHeadlines {
                resources.append("https://news.ycombinator.com")
            }
        }

        let cleaned = unique(resources.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        if !cleaned.isEmpty {
            return cleaned.prefix(3).joined(separator: ", ")
        }

        let names = unique(metadata.map(\.displayName))
        return names.isEmpty ? "Prepared Sonny action" : names.joined(separator: ", ")
    }

    /// Operations that leave the device on *every* execution, whatever their step's parameters
    /// say. An operation whose egress depends on saved content it merely names — a workspace, a
    /// routine — cannot be answered by the operation alone and does not belong here; see
    /// `stepLeavesDevice`.
    private static let dataEgressOperations: Set<AgentOperation> = [
        .openHackerNews,
        .fetchHNHeadlines,
        .webToMarkdown,
        .openAppSearchURL,
        .openURL,
        .playMedia,
        .invokeShortcut
    ]

    /// `AgentStep.searchQuery` is reused by several operations for a value that is not a search
    /// term at all — a snippet trigger, a calculator expression, an app name. Labeling those
    /// "Search: …" misdescribes the action in the approval prompt, which is the one place the
    /// user reads it (a snippet save showed "Allow access to Search: ;sig").
    private func searchQueryResource(for step: AgentStep) -> String? {
        guard let raw = step.searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        switch step.operation {
        case .saveSnippet, .expandSnippet:
            return "Snippet: \(raw)"
        case .calculateUtility:
            return "Calculation: \(raw)"
        case .switchRunningApp:
            return "App: \(raw)"
        default:
            return "Search: \(raw)"
        }
    }

    private func dataLeavesDevice(in plan: AgentPlan) -> Bool {
        plan.steps.contains { stepLeavesDevice($0) }
    }

    /// Whether one step sends anything off-device. Two operations name saved content rather than
    /// carrying it, so the operation alone cannot answer for either: the workspace or routine has
    /// to be loaded and looked at.
    private func stepLeavesDevice(_ step: AgentStep) -> Bool {
        if Self.dataEgressOperations.contains(step.operation) {
            return true
        }

        switch step.operation {
        case .openWorkspace:
            // A workspace is apps *and/or* URLs — `CreateWorkspaceCapabilityAdapter` accepts one
            // with apps only — and opening local apps sends nothing anywhere. Classifying every
            // workspace open as egress printed "Data leaves device: yes" on the approval panel of
            // any plan carrying an apps-only workspace open, a claim nothing in that plan made
            // true.
            //
            // Do not read this `try?` by analogy with the `.runRoutine` one below: that branch is
            // safe because `RunRoutineCapabilityAdapter.assessRisk` loads the routine with a plain
            // `try` first, and `OpenWorkspaceCapabilityAdapter` has no `assessRisk` override at
            // all, so there is no such guarantee here. What actually makes it safe is `prepare`,
            // which runs `preview` before anything reaches this copy: the adapter's `preview`
            // loads the workspace with a plain `try`, a name matching nothing becomes a
            // clarification plan, and an unreadable store still throws. Neither failure mode
            // survives to be silently answered "no" here on the `AgentRunner` path, the only path
            // that renders this line. (`UnattendedTrustAdvisory` is the one caller that skips
            // `prepare`, and it reads `effectiveTier` only, never `approvalCopy`.)
            guard let workspace = try? workspaceStore.workspace(named: step.workspaceName ?? "") else {
                return false
            }
            return !workspace.urls.isEmpty
        case .runRoutine:
            // A saved routine can wrap egress steps, so the outer .runRoutine step alone says
            // nothing. Stored routines cannot themselves contain .runRoutine *or* .openWorkspace
            // (both rejected at save time), so one level is enough and the nested scan needs no
            // second lookup of its own. A routine that fails to load surfaces through the
            // adapter's assessRisk before this copy is built.
            guard let routine = try? routineStore.routine(named: step.routineName ?? "") else {
                return false
            }
            return routine.steps.contains { Self.dataEgressOperations.contains($0.operation) }
        default:
            return false
        }
    }

    private func undoDescription(for tier: CapabilityRiskTier, plan: AgentPlan) -> String {
        switch tier {
        case .tier0:
            return "No undo needed; Sonny is only reading status or context."
        case .tier1:
            if plan.steps.contains(where: { $0.operation == .invokeShortcut }) {
                return "Depends on the Shortcut; undo in the affected app or service if needed."
            }
            return "Close the opened app, browser tab, media result, or Finder window."
        case .tier2:
            if plan.steps.contains(where: { $0.operation == .invokeShortcut }) {
                return "Depends on the Shortcut; undo in the affected app or service if needed."
            }
            if plan.steps.contains(where: { [.saveRoutine, .createWorkspace].contains($0.operation) }) {
                return "Edit or replace the saved routine/workspace manually."
            }
            if plan.steps.contains(where: { $0.operation == .saveSnippet }) {
                return "Edit or delete the saved snippet manually."
            }
            return "Delete generated local files manually if needed."
        case .tier3:
            return "May not be automatically undoable."
        case .tier4:
            return "Sonny will not perform this action."
        }
    }

    private func appendIfPresent(_ value: String?, to values: inout [String]) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        values.append(value)
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    /// Two segments that raise the identical escalation — two steps writing over the same existing
    /// file — say one thing, and the approval panel joins every reason into one sentence, so a
    /// repeat reads as a stutter. `CapabilityRiskEscalation` is Equatable but not Hashable and
    /// these arrays are single digits, so a linear scan beats teaching the type to hash.
    private func unique(_ escalations: [CapabilityRiskEscalation]) -> [CapabilityRiskEscalation] {
        var result: [CapabilityRiskEscalation] = []
        for escalation in escalations where !result.contains(escalation) {
            result.append(escalation)
        }
        return result
    }

    private func capabilityContext(
        preferredBrowser: MacApp? = nil,
        scope: TaskWorkspaceScope
    ) -> CapabilityExecutionContext {
        CapabilityExecutionContext(
            whitelist: whitelist,
            inventory: inventory,
            zipArchiver: zipArchiver,
            documentConverter: documentConverter,
            browserOpener: browserOpener,
            hackerNewsFetcher: hackerNewsFetcher,
            appCatalog: appCatalog,
            appSearchURLCatalog: appSearchURLCatalog,
            appOpener: appOpener,
            fileOpener: fileOpener,
            mediaOpener: mediaOpener,
            spotifyPlaybackProvider: spotifyPlaybackProvider,
            appleMusicPlaybackProvider: appleMusicPlaybackProvider,
            finderContextReader: finderContextReader,
            permissionReadinessService: permissionReadinessService,
            routineStore: routineStore,
            workspaceStore: workspaceStore,
            webPageLoader: webPageLoader,
            webSearchProvider: webSearchProvider,
            webResearchSynthesizer: webResearchSynthesizer,
            clipboardHistoryStore: clipboardHistoryStore,
            snippetStore: snippetStore,
            runningAppSwitcher: runningAppSwitcher,
            recentArtifactStore: recentArtifactStore,
            shortcutCatalog: shortcutCatalog,
            shortcutInvoker: shortcutInvoker,
            shortcutRunHistoryStore: shortcutRunHistoryStore,
            fileManager: fileManager,
            now: now,
            hotKeyReady: hotKeyReady,
            preferredBrowser: preferredBrowser,
            taskScope: scope,
            assessNestedPlan: { [weak self] plan, nestedScope in
                guard let self else {
                    throw AgentExecutionError.invalidPlan("Executor is unavailable for nested risk assessment.")
                }
                return try self.assessRisk(plan: plan, scope: nestedScope)
            },
            previewNestedPlan: { [weak self] plan in
                guard let self else {
                    throw AgentExecutionError.invalidPlan("Executor is unavailable for nested preview.")
                }
                return try self.preview(plan: plan)
            },
            executeNestedPlan: { [weak self] plan, nestedBrowser, log in
                guard let self else {
                    throw AgentExecutionError.invalidPlan("Executor is unavailable for nested execution.")
                }
                return try await self.execute(plan: plan, preferredBrowser: nestedBrowser, log: log)
            }
        )
    }

    private func previewChain(_ plan: AgentPlan) throws -> [ActionPreview] {
        var previews: [ActionPreview] = []
        var previousArtifactPath: String?

        for segment in try segmentPlans(in: plan) {
            let resolved = resolvePreviousArtifactPathIfNeeded(in: segment, previousArtifactPath: previousArtifactPath)
            let segmentPreviews = try preview(plan: resolved)
            previews.append(contentsOf: segmentPreviews)
            if let producedPath = segmentPreviews.flatMap(\.writes).last {
                previousArtifactPath = producedPath
            }
        }

        return previews
    }

    private func executeChain(
        _ plan: AgentPlan,
        preferredBrowser: MacApp?,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        var summaries: [String] = []
        var suggestions: [RunSuggestion] = []
        var previews: [ActionPreview] = []
        var previousArtifactPath: String?

        for segment in try segmentPlans(in: plan) {
            let resolved = resolvePreviousArtifactPathIfNeeded(in: segment, previousArtifactPath: previousArtifactPath)
            let result = try await execute(plan: resolved, preferredBrowser: preferredBrowser, log: log)
            summaries.append(result.summary)
            suggestions.append(contentsOf: result.suggestions)
            // Accumulate each segment's real result previews — re-running previewChain after
            // execution would re-resolve default output paths and misreport what was written.
            previews.append(contentsOf: result.previews)
            if let producedPath = result.previews.flatMap(\.writes).last {
                previousArtifactPath = producedPath
            } else if let suggestionPath = result.suggestions.last?.value {
                previousArtifactPath = suggestionPath
            }
        }

        let summary = summaries.joined(separator: " ")
        return AgentRunResult(plan: plan, previews: previews, summary: summary, suggestions: suggestions)
    }

    private func segmentPlans(in plan: AgentPlan) throws -> [AgentPlan] {
        var segments: [AgentPlan] = []
        var index = 0

        while index < plan.steps.count {
            let step = plan.steps[index]
            switch step.operation {
            case .scanSelectLargestFiles:
                var steps = [step]
                if index + 1 < plan.steps.count,
                   plan.steps[index + 1].operation == .createZip {
                    steps.append(plan.steps[index + 1])
                    index += 1
                }
                segments.append(segmentPlan(from: plan, steps: steps))
            case .scanDocx:
                var steps = [step]
                if index + 1 < plan.steps.count,
                   plan.steps[index + 1].operation == .convertDocxToPDF {
                    steps.append(plan.steps[index + 1])
                    index += 1
                }
                segments.append(segmentPlan(from: plan, steps: steps))
            case .openHackerNews:
                var steps = [step]
                while index + 1 < plan.steps.count,
                      [.fetchHNHeadlines, .writeMarkdown].contains(plan.steps[index + 1].operation) {
                    steps.append(plan.steps[index + 1])
                    index += 1
                }
                segments.append(segmentPlan(from: plan, steps: steps))
            default:
                segments.append(segmentPlan(from: plan, steps: [step]))
            }
            index += 1
        }

        return segments
    }

    private func segmentPlan(from plan: AgentPlan, steps: [AgentStep]) -> AgentPlan {
        AgentPlan(
            summary: plan.summary,
            requiresConfirmation: plan.requiresConfirmation,
            steps: steps
        )
    }

    private func resolvePreviousArtifactPathIfNeeded(in plan: AgentPlan, previousArtifactPath: String?) -> AgentPlan {
        guard plan.steps.count == 1,
              [.revealInFinder, .openGeneratedArtifact].contains(plan.steps[0].operation),
              plan.steps[0].outputPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              plan.steps[0].inputPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              let previousArtifactPath else {
            return plan
        }

        var resolved = plan
        resolved.steps[0].outputPath = previousArtifactPath
        return resolved
    }

}
