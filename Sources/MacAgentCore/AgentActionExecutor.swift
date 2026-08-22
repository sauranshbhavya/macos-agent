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
    /// Where this run's plan came from — see `PreparedPlanSource`. Stamped by `AgentRunner.prepare`,
    /// which is the only thing that knows the answer; `AgentActionExecutor` prepares a plan without
    /// caring how it was authored, so its own construction leaves the default in place.
    ///
    /// The default is `.planner` because that is the *least*-trusted answer. A carrier for a trust
    /// signal has to default to the value that grants nothing, so a construction site added later
    /// that says nothing inherits no trust it never asked for — the same safe-direction rule
    /// `AgentViewModel.start(fromComposer:)` defaults `false` for.
    public var source: PreparedPlanSource

    public init(
        plan: AgentPlan,
        previews: [ActionPreview],
        clarificationQuestion: String? = nil,
        source: PreparedPlanSource = .planner
    ) {
        self.plan = plan
        self.previews = previews
        self.clarificationQuestion = clarificationQuestion
        self.source = source
    }

    public var sideEffects: [String] {
        previews.flatMap(\.sideEffects)
    }
}

@MainActor
public final class AgentActionExecutor {
    /// Whether this run leaves traces (SONNY-120). A `let` rather than a settable property because
    /// `AgentViewModel.makeExecutor()` builds a fresh executor per run — so suppression cannot leak
    /// from one task into the next, which shared mutable state here would have allowed.
    private let recordingPolicy: TaskRecordingPolicy

    /// The standing memory switches (SONNY-208). A `let` for the same reason as the line above: a
    /// fresh executor per run means a switch flipped mid-run cannot half-apply to it.
    private let memoryRecording: MemoryRecordingSettings

    /// Read-only, for the suite: which policy this executor was built with. The policy itself stays
    /// private — nothing may change it after construction, which is what makes a fresh executor per
    /// run safe (PR #67 review, F2).
    public var suppressesTracesForTests: Bool {
        recordingPolicy.suppressesTraces
    }
    private let whitelist: PathWhitelist
    private let inventory: FileInventory
    private let zipArchiver: ZipArchiving
    private let documentConverter: DocumentConverting
    private let browserOpener: BrowserOpening
    private let hackerNewsFetcher: HackerNewsFetching
    private let appCatalog: MacAppCatalog
    private let installedAppResolver: any InstalledAppResolving
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
    private let visionSession: VisionSessionEnvironment?

    public init(
        recordingPolicy: TaskRecordingPolicy = .record,
        // Defaulted for the same reason `recordingPolicy` is: every existing construction site and
        // every test keeps recording exactly as before, and an adapter that never asks behaves as it
        // always did.
        memoryRecording: MemoryRecordingSettings = .recordEverything,
        whitelist: PathWhitelist = PathWhitelist(),
        inventory: FileInventory = FileInventory(),
        zipArchiver: ZipArchiving = ProcessZipArchiver(),
        documentConverter: DocumentConverting = AutoDocumentConverter(),
        browserOpener: BrowserOpening = WorkspaceBrowserOpener(),
        hackerNewsFetcher: HackerNewsFetching = HackerNewsAPIClient(),
        appCatalog: MacAppCatalog = .default,
        installedAppResolver: any InstalledAppResolving = InstalledAppResolver.shared,
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
        hotKeyReady: @escaping () -> Bool = { true },
        // `nil` means this executor has no screen-control wiring, which is the honest state for
        // `MacAgentCore` on its own and for every test that is not about vision. A vision session
        // reaching an executor built this way fails loudly with `visionUnavailable` rather than
        // half-running.
        visionSession: VisionSessionEnvironment? = nil
    ) {
        self.recordingPolicy = recordingPolicy
        self.memoryRecording = memoryRecording
        self.whitelist = whitelist
        self.inventory = inventory
        self.zipArchiver = zipArchiver
        self.documentConverter = documentConverter
        self.browserOpener = browserOpener
        self.hackerNewsFetcher = hackerNewsFetcher
        self.appCatalog = appCatalog
        self.installedAppResolver = installedAppResolver
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
        self.visionSession = visionSession
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
    /// SONNY-44 decoupled scope listing from launchability, so such an entry is skipped at open time
    /// and the open succeeds. It is not a clarification either; it is simply not an error.
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
    /// scope escalations' `toTier`, so nothing here can lower a tier — which everything reading
    /// that field depends on staying honest. The consumer population is larger than any closed
    /// list stays current with (this comment first said "four things"; row C's planning counted
    /// 151 references across 24 files at `0fdac1c`): five structural decision gates alone — the
    /// unattended gate (`approvedTier >= effectiveTier` against a fixed `.approved(.tier2)`), the
    /// stale-approval re-check in `AgentRunner.execute`, the `risk.assessed`/`risk.escalated`
    /// trace, `UnattendedTrustAdvisory` (which reads `effectiveTier` alone), and SONNY-54's
    /// manual-routine-trust check in `AgentViewModel`, whose own comment says it mirrors the
    /// execute gate — plus the approved-tier write-back, `RiskApprovalError`'s descriptions, and
    /// the tier handed to `approvalCopy(for:metadata:tier:)` below. The approval decision itself
    /// lives downstream: `RiskApprovalPolicy.requirement(for:context:)` maps this assessment under
    /// the consequence rule and never writes it — the tier and every escalation sentence leave
    /// here honest and arrive at their surfaces (panel or ran-without-asking trace) unedited. The
    /// `scopeVerdict` roll-up is data for the surfaces and the future vision cage, not a gate.
    public func assessRisk(plan: AgentPlan, scope: TaskWorkspaceScope) throws -> CapabilityRiskAssessment {
        try assessRisk(plan: plan, scope: scope, namedByEnclosingPlan: .none)
    }

    /// The whole of `assessRisk`, plus the destinations the plans enclosing this one already name.
    ///
    /// **Here for the same reason `execute` has it, and it is the half that keeps the tier-3 gate
    /// honest** (SONNY-220). A nested routine's generated destination is bumped at execution time
    /// away from what the outer plan names; if assessment does not apply the same bump it computes a
    /// *different* path, and the adapters' "output already exists" escalation — which is a
    /// `fileExists` check on the resolved path — then asks about a file the run will not touch while
    /// staying silent about the one it will overwrite. Measured before this was threaded, at
    /// `98b4668` plus the execute-side fix: with the bumped name already on disk, both orderings of
    /// the collision plan assessed `tier2` with **no** escalations, and the run then overwrote that
    /// file. That gap arrived with SONNY-190 rather than with this ticket — it is visible on `main`
    /// in the ordering SONNY-190 fixed — but this ticket creates the second ordering that reaches it,
    /// so closing it here is part of the fix rather than adjacent to it.
    ///
    /// The two seeds agree by construction because both are computed from the *same* resolved plan:
    /// `AgentRunner` prepares once and hands that plan to assessment and to execution alike, and
    /// `executeChain` derives its set from the plan it was given. What still differs is the claims
    /// half — execution also seeds from what earlier units really wrote, assessment has nothing to
    /// seed from because nothing has run — so a capability whose writes are not its steps'
    /// `outputPath`s (docx conversion, whose destinations are per-document) can still bump further at
    /// execution than at assessment. That residual predates this ticket and is the preview/assessment
    /// agreement question SONNY-218 owns, not the data-loss one this ticket closes.
    private func assessRisk(
        plan: AgentPlan,
        scope: TaskWorkspaceScope,
        namedByEnclosingPlan: PlannedDestinations
    ) throws -> CapabilityRiskAssessment {
        let resolvedPlan = try resolveDefaultOutputs(in: plan, namedByEnclosingPlan: namedByEnclosingPlan)
        // The same scope goes into the nested-plan closure, so a `run_routine` step's stored steps
        // are evaluated under the boundary its caller is bound by. Without it, a routine is a
        // laundering hole: its steps would escape the workspace the task naming it is inside.
        //
        // The nested closure is handed this plan's own destinations on top of whatever its caller
        // named, exactly as `executeChain` does — assessment walks the whole plan in one call rather
        // than segment by segment, so the set is complete here without an accumulator.
        let context = capabilityContext(
            namedByEnclosingPlan: namedByEnclosingPlan.union(PlannedDestinations(namedBy: resolvedPlan)),
            scope: scope
        )

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
                reason: "\(resource.value) is not part of the \(workspaceScope.workspaceName) workspace.",
                // Consequence rule (2026-08-13): being outside the workspace boundary is a fact
                // worth surfacing, not a consent worth interrupting for — the action itself
                // destroys nothing and reaches nobody. The reason lands on the
                // ran-without-asking trace instead of a prompt; the tier still rises so the
                // severity signal and the unattended ceiling stay honest.
                consequence: .advisory
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
    /// a plan whose routine writes outside the boundary reports `.inScope`.
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
        return try chainSegments(in: plan)
    }

    public func preview(
        plan: AgentPlan,
        claimedEarlierInThisRun: RunClaims = .none
    ) throws -> [ActionPreview] {
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
            return try previewCapability(for: .scanSelectLargestFiles, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .docx:
            return try previewCapability(for: .scanDocx, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .hackerNews:
            return try previewCapability(for: .openHackerNews, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .webResearch:
            return try previewCapability(for: .webToMarkdown, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .openApp:
            return try previewCapability(for: .openApp, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .openAppSearchURL:
            return try previewCapability(for: .openAppSearchURL, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .openURL:
            return try previewCapability(for: .openURL, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .openGeneratedArtifact:
            return try previewCapability(for: .openGeneratedArtifact, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .createLocalDraft:
            return try previewCapability(for: .createLocalDraft, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .calculator:
            return try previewCapability(for: .calculateUtility, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .clipboardHistory:
            return try previewCapability(for: .lookupClipboardHistory, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .snippetSave:
            return try previewCapability(for: .saveSnippet, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .snippetExpansion:
            return try previewCapability(for: .expandSnippet, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .runningAppSwitch:
            return try previewCapability(for: .switchRunningApp, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .recentArtifacts:
            return try previewCapability(for: .lookupRecentArtifacts, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .mediaOpen:
            return try previewCapability(for: .playMedia, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .finderSelection:
            return try previewCapability(for: .getFinderSelection, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .revealInFinder:
            return try previewCapability(for: .revealInFinder, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .permissionReadiness:
            return try previewCapability(for: .showPermissionReadiness, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .saveRoutine:
            return try previewCapability(for: .saveRoutine, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .runRoutine:
            return try previewCapability(for: .runRoutine, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .createWorkspace:
            return try previewCapability(for: .createWorkspace, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .editWorkspace:
            return try previewCapability(for: .editWorkspace, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .openWorkspace:
            return try previewCapability(for: .openWorkspace, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .invokeShortcut:
            return try previewCapability(for: .invokeShortcut, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .visionSession:
            return try previewCapability(for: .visionSession, plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        case .chain:
            return try previewChain(plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
        }
    }

    /// Runs an already-approved plan.
    ///
    /// `preferredBrowser` binds every URL this plan opens *on the injected browser-opener seam*
    /// to one browser — not `.playMedia`, which opens on the media seam and stays there by decision
    /// (SONNY-51, founder 2026-08-20). It is threaded as a parameter rather than held on the
    /// executor deliberately: `execute` suspends at every step,
    /// so executor-held state would be readable — and mutable — by any other main-actor task that
    /// interleaved, and a routine's browser could leak into a command the user ran meanwhile.
    /// Only `RunRoutineCapabilityAdapter` passes a non-nil value, through `executeNestedPlan`.
    public func execute(
        plan: AgentPlan,
        preferredBrowser: MacApp? = nil,
        claimedEarlierInThisRun: RunClaims = .none,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        // Every top-level run starts naming nothing: a plan's own destinations are added by
        // `executeChain` once they have been resolved, and only a *nested* plan is ever handed a
        // non-empty set. `PlannedDestinations` is deliberately not part of this public signature —
        // it is executor-internal plumbing, and the one thing it must never become is something an
        // adapter or a caller can hand in, since a set of intentions arriving from outside is
        // indistinguishable here from the run's own.
        try await execute(
            plan: plan,
            preferredBrowser: preferredBrowser,
            claimedEarlierInThisRun: claimedEarlierInThisRun,
            namedByEnclosingPlan: .none,
            log: log
        )
    }

    /// The whole of `execute`, plus the destinations the plans enclosing this one already name.
    ///
    /// `namedByEnclosingPlan` is **not defaulted**, on purpose: every internal call site states what
    /// the plan around it has named, and a new one that forgets is a compile error rather than a
    /// silent `.none` — which is the exact failure this ticket exists to fix, one level up.
    private func execute(
        plan: AgentPlan,
        preferredBrowser: MacApp?,
        claimedEarlierInThisRun: RunClaims,
        namedByEnclosingPlan: PlannedDestinations,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let resolvedPlan = try resolveDefaultOutputs(
            in: plan,
            claimedEarlierInThisRun: claimedEarlierInThisRun,
            namedByEnclosingPlan: namedByEnclosingPlan
        )
        let workflow = try workflow(in: resolvedPlan)

        switch workflow {
        case .clarify:
            throw AgentExecutionError.missingClarificationQuestion
        case .largestFiles:
            return try await executeCapability(for: .scanSelectLargestFiles, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .docx:
            return try await executeCapability(for: .scanDocx, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .hackerNews:
            return try await executeCapability(for: .openHackerNews, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .webResearch:
            return try await executeCapability(for: .webToMarkdown, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .openApp:
            return try await executeCapability(for: .openApp, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .openAppSearchURL:
            return try await executeCapability(for: .openAppSearchURL, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .openURL:
            return try await executeCapability(for: .openURL, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .openGeneratedArtifact:
            return try await executeCapability(for: .openGeneratedArtifact, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .createLocalDraft:
            return try await executeCapability(for: .createLocalDraft, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .calculator:
            return try await executeCapability(for: .calculateUtility, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .clipboardHistory:
            return try await executeCapability(for: .lookupClipboardHistory, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .snippetSave:
            return try await executeCapability(for: .saveSnippet, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .snippetExpansion:
            return try await executeCapability(for: .expandSnippet, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .runningAppSwitch:
            return try await executeCapability(for: .switchRunningApp, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .recentArtifacts:
            return try await executeCapability(for: .lookupRecentArtifacts, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .mediaOpen:
            return try await executeCapability(for: .playMedia, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .finderSelection:
            return try await executeCapability(for: .getFinderSelection, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .revealInFinder:
            return try await executeCapability(for: .revealInFinder, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .permissionReadiness:
            return try await executeCapability(for: .showPermissionReadiness, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .saveRoutine:
            return try await executeCapability(for: .saveRoutine, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .runRoutine:
            return try await executeCapability(for: .runRoutine, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .createWorkspace:
            return try await executeCapability(for: .createWorkspace, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .editWorkspace:
            return try await executeCapability(for: .editWorkspace, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .openWorkspace:
            return try await executeCapability(for: .openWorkspace, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .invokeShortcut:
            return try await executeCapability(for: .invokeShortcut, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .visionSession:
            return try await executeCapability(for: .visionSession, plan: resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
        case .chain:
            return try await executeChain(resolvedPlan, preferredBrowser: preferredBrowser, claimedEarlierInThisRun: claimedEarlierInThisRun, namedByEnclosingPlan: namedByEnclosingPlan, log: log)
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
        case visionSession
        case chain
    }

    /// Which dispatch a plan takes: one adapter call, or the segmented chain walk.
    ///
    /// **A plan is a chain exactly when it holds more than one unit of work** — where a unit is what
    /// `segmentPlans(in:)` cuts, and a unit is what one adapter call can actually service. This used
    /// to be two rules that had to agree and did not: a `shouldChainWhenRepeated` membership list
    /// answered "does repeating this workflow make a chain", while `segmentPlans` separately decided
    /// where the cuts fall. Five workflows sat in the list's false arm — `.clarify`, `.largestFiles`,
    /// `.docx`, `.hackerNews`, `.webResearch` — because each absorbs several steps into one adapter
    /// call, and the list could not express "several, but only one of each". So a plan repeating one
    /// of them was handed to a single adapter call whole, and every adapter resolves its spec with
    /// `.first(where:)`: "zip the 3 largest files in ~/Desktop/A and the 3 largest in ~/Desktop/B"
    /// created one archive, dropped the other two steps with no error and no log line, and reported
    /// the archive it did create as a success (SONNY-34).
    ///
    /// Counting units subsumes the list rather than extending it. Every workflow in the old true arm
    /// maps from exactly one operation, so its unit is always a single step and "more than one step"
    /// and "more than one unit" are the same statement — including `.editWorkspace`, whose repeats
    /// chain for the reason recorded on `segmentPlans`. The five in the false arm are the only ones
    /// where the two statements differ, and for those the unit count is the honest answer.
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

        guard plan.steps.count > 1 else {
            return workflow
        }

        // A repeated clarification is the one repeat that must not become a chain, and must not
        // silently keep the first question either. A clarification is a question asked *instead of*
        // acting — `execute` refuses the workflow outright — so there is nothing to run twice, and
        // `clarificationQuestion(in:)` answering with the first `question` while a second went
        // unasked is precisely the silent drop this ticket ends. It gets the same error a
        // clarification mixed with real work already gets, because it violates the same rule.
        if workflow == .clarify {
            throw AgentExecutionError.invalidPlan("Clarification must be the only planned step.")
        }

        return try segmentPlans(in: plan).count > 1 ? .chain : workflow
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
        case .visionSession:
            return .visionSession
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

    /// Fills in every default the plan leaves open, **one unit at a time**.
    ///
    /// Adapters resolve with `.first(where:)`, so what an adapter can correctly answer for is one
    /// unit — the same thing `preview`/`execute` hand it. This used to call each adapter once with
    /// the *whole* plan, which is right for a plan holding one unit and wrong for every plan holding
    /// more: "draft a note about X and another about Y" left the second `.createLocalDraft` step at
    /// `outputPath == nil` in the prepared plan, so the preview and the approval copy's "Involves:"
    /// line named one file while the run wrote two, and the second file's timestamped default name
    /// was re-derived independently at assessment time and again at execution time — meaning the path
    /// the risk engine checked for a collision was not the path that got written (SONNY-35).
    ///
    /// Resolving per unit fixes that at the cause rather than in the two adapters the ticket named:
    /// every one of the seven `resolveDefaultOutputs` overrides is correct on a unit, and none of
    /// them was ever handed one. `LargestFilesZipCapabilityAdapter` in particular could not have been
    /// fixed adapter-side alone — a second `create_zip`'s default folder comes from *its own* unit's
    /// scan step, which the whole-plan call cannot tell apart from the first unit's.
    ///
    /// Two things stay whole-plan on purpose, both marked below: `edit_workspace`'s plan-shape rule,
    /// which is unenforceable from inside a unit, and a resolver's right to replace the plan with a
    /// clarification.
    private func resolveDefaultOutputs(
        in plan: AgentPlan,
        claimedEarlierInThisRun: RunClaims = .none,
        namedByEnclosingPlan: PlannedDestinations = .none
    ) throws -> AgentPlan {
        _ = try workflow(in: plan)

        var resolvedSteps: [AgentStep] = []
        // **Seeded from the run's claims, not empty** (SONNY-190). A nested routine runs its own
        // `execute`, which resolves its own plan — so before this parameter existed the nested
        // resolve disambiguated against nothing, and a routine's generated default collided with a
        // path the outer plan had already produced. Measured rather than reasoned about, on the
        // real clock: an outer `create_local_draft` followed by a routine containing one produced
        // **one** file, holding the routine's text, three times out of three. The outer document was
        // destroyed and the run's own `previews.writes` named the same path twice, so nothing in the
        // report showed it. That is not the narrow same-second race it was filed as — two file
        // writes inside one run land in the same second essentially always, and `Timestamp.fileSafe`
        // is whole-second.
        //
        // `RunClaims.destinations` is folded with the same `DestinationKey.folded` this set uses, so
        // seeding is a union of like with like rather than a translation. The two are deliberately
        // *not* merged into one type: this set is pre-resolution intent, accumulated from the
        // `outputPath` each unit resolves to, and `RunClaims` is post-execution fact, accumulated
        // from the `ActionPreview.writes` each unit produced. Merging them would make the ordering
        // question — which is filled in when — a property of one type instead of a parameter, and
        // the parameter is what makes it answerable: at the moment a nested plan resolves, every
        // outer unit before it has executed and recorded its writes, and none after it has.
        //
        // **And seeded a second time from what the outer plan already *names*, which is the half
        // the claims cannot supply** (SONNY-220). The claims answer for units that have already run;
        // the outer plan's own destinations are decided at `prepare`, before anything runs, and they
        // never move afterwards — a step arriving at `execute` with an `outputPath` has
        // `hasOwnOutputPath` true and is deliberately never regenerated or bumped. So the claims
        // alone fix exactly one ordering. `[create_local_draft, run_routine]` is safe because the
        // outer draft has executed and claimed by the time the routine resolves; the *same two steps
        // reversed* were not, because the routine resolves first and nothing it can see mentions the
        // outer plan's name — measured, three runs out of three on the real clock at `98b4668`, one
        // file left holding the outer plan's text with the routine's document destroyed, and
        // `previews.writes` naming the same path twice so nothing in the report showed it.
        //
        // Which of the two moves is the right question, and the answer is not symmetric: the outer
        // plan named its destination at `prepare` and the user approved a panel saying so, so the
        // prepared plan's names are what `aChainWritesOnlyFilesThePreparedPlanAlreadyNamed` holds
        // this executor to. The nested plan resolves later, so the nested plan is the one that moves.
        //
        // **Both halves are load-bearing, and neither may be dropped.** The plan-intent half is what
        // fixes the reverse ordering above. The claims half is what protects a shape the plan-intent
        // half is structurally blind to: **a chain of two or more sibling `run_routine` steps whose
        // routines can generate colliding defaults.** A `run_routine` step carries no `outputPath`,
        // so `PlannedDestinations(namedBy:)` built from such a plan is empty with respect to
        // everything the nested routines will generate, and the only thing between the second
        // routine's draft and the first routine's file is what `executeChain` recorded after the
        // first segment really ran. `segmentPlans(in:)`' repeat rule cuts the second `run_routine`
        // into its own unit, so the plan classifies as `.chain`, and
        // `StoredRoutine.forbiddenStepOperations` forbids a `run_routine` *inside* a saved routine
        // rather than two of them at the outer level — nothing blocks this plan.
        //
        // **Recorded because this comment previously said the opposite** (PR #96 review, F1). It
        // claimed the claims half "covers a population that today is empty", on the strength of a
        // mutation battery at `e3dee83` where dropping it left the whole suite passing. The battery
        // was right and the inference was wrong: nothing in the suite exercised the sibling-routine
        // shape, so the mutant killed a document nothing was watching.
        // `twoSiblingRoutinesThatEachDraftKeepBothDocuments` is that shape, and the same mutant is
        // now killed by it (`scripts/mutate`, 1 mutant, 1 killed, stamped at `24fa0ba`). **A green
        // suite under a mutant is a statement about the suite, not about the code.**
        //
        // The two halves still answer different questions and overlap rather than nest. Of the eight
        // adapters that produce `ActionPreview.writes` — `git grep -l 'writes:' Sources/MacAgentCore |
        // grep CapabilityAdapter` at `24fa0ba`, which prints 8 — **three** write exactly the
        // `outputPath` their own `resolveDefaultOutputs` pinned, so `namedByEnclosingPlan` holds
        // those paths too: `CreateLocalDraftCapabilityAdapter`, `LargestFilesZipCapabilityAdapter`,
        // `WebResearchMarkdownCapabilityAdapter`. The other **five** write somewhere no step's
        // `outputPath` names: `DocxConversionCapabilityAdapter`, whose per-document PDFs sit inside
        // the output *folder* its step names, and `CreateWorkspaceCapabilityAdapter`,
        // `EditWorkspaceCapabilityAdapter`, `SaveRoutineCapabilityAdapter` and
        // `SnippetSaveCapabilityAdapter`, which write their stores' own JSON files. (That split read
        // "five" and "three" until PR #96's review transposed it back — the member list was right and
        // the two count words were not.) Those five cannot collide with a generated default —
        // `draft-<slug>-<stamp>.md`, `web-research-<stamp>.md`, `largest-files-<stamp>.zip` or a
        // Shortcut's output can equal neither a `.pdf` nor a store file — which is why the claims
        // half's reachable contribution is the *nested* one above rather than a docx one.
        var claimedOutputPaths: Set<String> = claimedEarlierInThisRun.destinations
            .union(namedByEnclosingPlan.paths)

        for unit in try segmentPlans(in: plan) {
            // Which steps arrived with a destination of their own, captured *before* resolution:
            // only the ones that did not are eligible for the collision bump below.
            let broughtOwnDestination = unit.steps.map(Self.hasOwnOutputPath)
            let resolved = try resolveUnitDefaultOutputs(in: unit)

            // A resolver may answer with a clarification instead of a resolution —
            // `InvokeShortcutCapabilityAdapter` does exactly that for a missing or unknown Shortcut
            // name. A clarification has to be the only step in a plan, so it replaces the *whole*
            // plan, which is what it did when this ran once over the whole plan, and returning here
            // keeps that. Resolving the remaining units first would only build state this discards.
            if resolved.steps.contains(where: { $0.operation == .clarify }) {
                return resolved
            }

            var claimedForUnit = resolved
            // The `broughtOwnDestination` flags are positional, so they are only meaningful while the
            // unit's step count is unchanged. Enumerated: of the seven resolvers, only
            // `InvokeShortcutCapabilityAdapter` alters the step list, and only by replacing the plan
            // with a clarification, which the early return above already caught. Asserted rather than
            // trusted, for the same reason `chainSegments(in:)` asserts its own invariant — a future
            // resolver that dropped a step mid-unit would silently mislabel an explicit destination as
            // generated and rename a file the plan named. (PR #41 review, SONNY-35 "checked and
            // correct" note.)
            guard claimedForUnit.steps.count == broughtOwnDestination.count else {
                throw AgentExecutionError.invalidPlan(
                    "Resolving default outputs changed the number of steps in a unit of work."
                )
            }
            for (index, broughtOwn) in zip(claimedForUnit.steps.indices, broughtOwnDestination) where !broughtOwn {
                guard let generated = claimedForUnit.steps[index].outputPath,
                      !generated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                claimedForUnit.steps[index].outputPath = Self.unclaimedOutputPath(
                    from: generated,
                    claimed: claimedOutputPaths
                )
            }

            for step in claimedForUnit.steps {
                guard let path = step.outputPath,
                      !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                claimedOutputPaths.insert(DestinationKey.folded(path))
            }
            resolvedSteps.append(contentsOf: claimedForUnit.steps)
        }

        var resolvedPlan = plan
        resolvedPlan.steps = resolvedSteps

        // Resolves no output of its own — it is here because this is the only place an adapter is
        // handed the *whole* plan, and `edit_workspace`'s plan-shape rule (at most one edit per
        // workspace) is unenforceable from inside a single unit. The three gates all pass through
        // here: `prepare`, `assessRisk` and `execute` each resolve before doing anything else.
        if resolvedPlan.steps.contains(where: { $0.operation == .editWorkspace }) {
            resolvedPlan = try capabilityRegistry
                .adapter(for: .editWorkspace)
                .resolveDefaultOutputs(in: resolvedPlan, context: capabilityContext(scope: .unscoped))
        }

        // **Whole-plan, and that is the entire point of it being here rather than in
        // `resolveUnitDefaultOutputs` where it started (PR #50 review, F1).**
        //
        // A vision step's target may be named by its own `appName` *or* by an app an earlier step in
        // the same plan put on screen — SONNY-93's contracted inheritance. `segmentPlans(in:)` splits
        // on workflow, and `open_app` and `vision_session` are different workflows, so a per-unit
        // resolver is handed a plan containing only the vision step: `precededBy` is always empty,
        // the inheritance can never fire, and the adapter's clarification then replaced the *whole*
        // mixed plan. "Open Notes and write my standup there" answered "Which app should Sonny
        // control?" — after the user had already said Notes.
        //
        // The same reasoning `edit_workspace` above is here for: this is the only place an adapter is
        // handed the whole plan, and a rule about a step's *relationship to other steps* is
        // unenforceable from inside a single unit.
        //
        // The clarification early-return inside the segment loop does not cover this block, so it is
        // handled explicitly: a vision plan with no resolvable target still fails to a clarification
        // that replaces the whole plan, which is the never-frontmost rule and must not be lost by
        // moving the dispatch.
        if resolvedPlan.steps.contains(where: { $0.operation == .visionSession }) {
            resolvedPlan = try capabilityRegistry
                .adapter(for: .visionSession)
                .resolveDefaultOutputs(in: resolvedPlan, context: capabilityContext(scope: .unscoped))
            if let clarification = resolvedPlan.steps.first(where: { $0.operation == .clarify }) {
                return AgentPlan(
                    summary: resolvedPlan.summary,
                    requiresConfirmation: false,
                    steps: [clarification]
                )
            }
        }

        return resolvedPlan
    }

    private static func hasOwnOutputPath(_ step: AgentStep) -> Bool {
        step.outputPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// A generated destination no earlier step of the same plan has already taken, suffixing
    /// `-2`, `-3`, … before the extension until it is free.
    ///
    /// Only *generated* destinations are bumped, never one the plan named itself: writing somewhere
    /// other than where a plan explicitly said to would be a worse failure than the collision. And
    /// the comparison is against paths claimed **within this plan only** — deliberately not against
    /// what exists on disk. A generated path that collides with a real file on disk is what the
    /// adapters' tier-3 "output already exists" escalation is for, and quietly sidestepping it here
    /// would delete a warning the user is entitled to.
    ///
    /// Without this, two units that generate the same default write one file: two `web_to_markdown`
    /// steps with no destinations both resolve to `web-research-<timestamp>.md` in the same second,
    /// so the second silently overwrites the first — the same silent loss SONNY-34 fixed one level up.
    /// `claimed` holds `DestinationKey.folded` keys, and **both** the entry test and the candidate
    /// test below consult it and nothing else. Each is half of the same boundary, and each is pinned
    /// by its own mutation: teaching the entry test about the filesystem bumps a first destination
    /// that already exists on disk to `-2`, which is precisely how the tier-3 "output already exists"
    /// escalation would get suppressed, and the first mutation battery only covered the candidate
    /// half (PR #41 review, SONNY-35 F2).
    private static func unclaimedOutputPath(from path: String, claimed: Set<String>) -> String {
        guard claimed.contains(DestinationKey.folded(path)) else {
            return path
        }

        let url = URL(fileURLWithPath: path)
        let pathExtension = url.pathExtension
        let base = url.deletingPathExtension()
        var suffix = 2
        while true {
            let stem = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent)-\(suffix)")
            let candidate = pathExtension.isEmpty ? stem : stem.appendingPathExtension(pathExtension)
            if !claimed.contains(DestinationKey.folded(candidate.path)) {
                return candidate.path
            }
            suffix += 1
        }
    }

    /// The per-unit half of `resolveDefaultOutputs(in:)`: every resolver whose answer depends only
    /// on the unit it is given.
    private func resolveUnitDefaultOutputs(in plan: AgentPlan) throws -> AgentPlan {
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

        if resolvedPlan.steps.contains(where: { $0.operation == .writeMarkdown }) {
            resolvedPlan = try capabilityRegistry
                .adapter(for: .writeMarkdown)
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

        // Resolves no output path — it pins the running app the query will actually activate, so
        // that every gate downstream of this phase (the scope assessment above all) reads one
        // identity rather than re-fuzzy-matching the query per gate (SONNY-58). Idempotent by the
        // adapter's own pin-once rule, which matters here more than for the output-path resolvers:
        // this function runs on every one of the three gates, and a re-resolution at execute time
        // would be exactly the assessment-versus-execution divergence the pin exists to close.
        if resolvedPlan.steps.contains(where: { $0.operation == .switchRunningApp }) {
            resolvedPlan = try capabilityRegistry
                .adapter(for: .switchRunningApp)
                .resolveDefaultOutputs(in: resolvedPlan, context: capabilityContext(scope: .unscoped))
        }

        // `vision_session` is deliberately NOT resolved here — see the whole-plan block at the end
        // of `resolveDefaultOutputs(in:)`. It needs to see steps this unit does not contain.

        return resolvedPlan
    }

    private func validateSupported(_ plan: AgentPlan) throws {
        if let unsupported = plan.steps.first(where: { $0.operation == .unsupported }) {
            throw AgentExecutionError.unsupported(unsupported.description)
        }
    }

    private func previewCapability(
        for operation: AgentOperation,
        plan: AgentPlan,
        claimedEarlierInThisRun: RunClaims = .none
    ) throws -> [ActionPreview] {
        try capabilityRegistry
            .adapter(for: operation)
            .preview(
                plan: plan,
                context: capabilityContext(
                    claimedEarlierInThisRun: claimedEarlierInThisRun,
                    scope: .unscoped
                )
            )
    }

    private func executeCapability(
        for operation: AgentOperation,
        plan: AgentPlan,
        preferredBrowser: MacApp?,
        claimedEarlierInThisRun: RunClaims = .none,
        namedByEnclosingPlan: PlannedDestinations,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        try await capabilityRegistry
            .adapter(for: operation)
            .execute(
                plan: plan,
                context: capabilityContext(
                    preferredBrowser: preferredBrowser,
                    claimedEarlierInThisRun: claimedEarlierInThisRun,
                    namedByEnclosingPlan: namedByEnclosingPlan,
                    scope: .unscoped
                ),
                log: log
            )
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
        let base: String
        if !summary.isEmpty {
            base = summary
        } else {
            let names = unique(metadata.map(\.displayName))
            base = names.isEmpty ? "Run the prepared plan" : names.joined(separator: ", ")
        }

        guard let split = Self.visionSplitDisclosure(for: plan) else {
            return base
        }
        return "\(base) \(split)"
    }

    /// **One plan, both halves disclosed** (SONNY-93).
    ///
    /// A mixed plan runs some steps through precise, previewable, individually-gated adapters and
    /// one step by a model looking at a window and deciding what to click. Those are very different
    /// things to agree to, and the plan summary — written by the planner, describing the *goal* —
    /// says nothing about the difference. So when a prompt fires at all, its copy names it.
    ///
    /// Appended to the summary rather than replacing it, and appended in the *executor* rather than
    /// carried on the adapter's own `approvalCopy`, because the plan-level assessment builds its copy
    /// fresh from the whole plan and an adapter's copy never reaches a plan-level prompt. Returns
    /// `nil` for every plan with no vision step, which is every plan the product had before row I.
    static func visionSplitDisclosure(for plan: AgentPlan) -> String? {
        guard let vision = plan.steps.first(where: { $0.operation == .visionSession }) else {
            return nil
        }
        let app = vision.resolvedAppName ?? vision.appName ?? "an app"
        let goal = (vision.visionGoal ?? vision.description).trimmingCharacters(in: .whitespacesAndNewlines)
        let supportedCount = plan.steps.filter { $0.operation != .visionSession && $0.operation != .clarify }.count

        if supportedCount == 0 {
            return "Sonny will do this by controlling \(app) directly — clicking and typing in its window the way you would."
        }
        let stepWord = supportedCount == 1 ? "step" : "steps"
        return "Sonny will do \(supportedCount) \(stepWord) with its own tools, then attempt "
            + "\u{201C}\(goal)\u{201D} by controlling \(app) directly — clicking and typing in its window."
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
            // The pinned identity outranks the query that found it (SONNY-58): an approval line
            // reading "chrom" about a switch that will activate Google Chrome names the wrong
            // thing. Nil for every step the resolve phase does not pin, so everything else renders
            // exactly as before.
            appendIfPresent(step.resolvedAppName ?? step.appName, to: &resources)
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

    /// **The membership rule is bidirectional (SONNY-32, landed with SONNY-88):** an operation is
    /// in this set — or handled by `stepLeavesDevice`'s switch — *if and only if* executing it
    /// can send anything off the device. The original rule (SONNY-10) stated only the forward
    /// direction, guarding against a false "yes"; the converse is the more dangerous direction —
    /// a user told nothing leaves the device approves on that basis — and it is a live invariant,
    /// not a review habit: `EgressClassificationTests` classifies every `AgentOperation` case
    /// against this rule explicitly, so a new operation cannot land unclassified.
    ///
    /// Membership here means egress on *every* execution, whatever the step's parameters say. An
    /// operation whose egress depends on saved content it merely names — a workspace, a routine —
    /// cannot be answered by the operation alone and belongs in `stepLeavesDevice`'s switch
    /// instead. (`writeMarkdown` is deliberately in neither: it is a local file write, and the
    /// solitary-step shape that used to promote it silently into the network-touching Hacker News
    /// preset is now rejected as an incomplete plan — see
    /// `WebResearchMarkdownCapabilityAdapter.isHackerNewsPreset`.)
    ///
    /// Internal, not private, exactly so `EgressClassificationTests` can hold the whole enum
    /// against this set.
    static let dataEgressOperations: Set<AgentOperation> = [
        .openHackerNews,
        .fetchHNHeadlines,
        .webToMarkdown,
        .openAppSearchURL,
        .openURL,
        .playMedia,
        .invokeShortcut,
        // A vision session sends a screenshot of the user's app window to the vision model on every
        // iteration. This is the most literal egress in the product — redacted first (SONNY-89's
        // structural non-bypass), but pixels of the user's screen all the same — so Safe mode's
        // "Data leaves device: yes" line must read yes, and does.
        .visionSession
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
            // `.editWorkspace` belongs here for the same reason the other two do, and it is the
            // *common* tier-2 case for that capability: adding to a workspace never escalates, so
            // this is the sentence almost every workspace edit shows. Left out, it fell through to
            // "Delete generated local files manually if needed." — an edit generates no files.
            // A membership list, like `StoredRoutine.forbiddenStepOperations`, has no compiler guard
            // forcing a new operation to be classified; both had to be found by hand.
            if plan.steps.contains(where: { [.saveRoutine, .createWorkspace, .editWorkspace].contains($0.operation) }) {
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
        claimedEarlierInThisRun: RunClaims = .none,
        namedByEnclosingPlan: PlannedDestinations = .none,
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
            installedAppResolver: installedAppResolver,
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
            claimedEarlierInThisRun: claimedEarlierInThisRun,
            taskScope: scope,
            assessNestedPlan: { [weak self] plan, nestedScope in
                guard let self else {
                    throw AgentExecutionError.invalidPlan("Executor is unavailable for nested risk assessment.")
                }
                return try self.assessRisk(
                    plan: plan,
                    scope: nestedScope,
                    namedByEnclosingPlan: namedByEnclosingPlan
                )
            },
            // **The nested plan inherits this context's claims** (SONNY-163). Both closures used to
            // call through with no `RunClaims`, so a routine run as a unit of a chain started from
            // `.none` and could not tell "this run wrote that PDF two seconds ago" from "that PDF
            // predates this run".
            //
            // Measured rather than reasoned, which the ticket asked for. A chain of
            // `[scan_docx, convert]` over folder A followed by a `run_routine` converting folder B,
            // both into one output folder, both holding a `report.docx`: the preview promised
            // `Out/report.pdf` *twice* — a plan naming one file for two documents — and the run then
            // reported "No DOCX files needed conversion in …/B. Skipped 1 existing PDF outputs.",
            // leaving one file in the folder. The user is told their second document was skipped
            // because a PDF already exists, and that PDF is the one this same run made seconds
            // earlier. That is the sentence SONNY-76 exists to prevent, reached through the routine
            // door rather than the chain door, and it costs the user a document.
            //
            // **Captured, not added as a closure parameter.** `preferredBrowser` travels as an
            // explicit argument because the *adapter* computes it — the routine's binding is derived
            // from the routine's own steps. Claims are not the adapter's to compute or to choose: the
            // value in force is whatever this context was built with, so capturing it is both the
            // honest semantic and the shape no adapter can accidentally drop. It also keeps the
            // stored closure types unchanged, which is what SONNY-163 assumed a fix could not do.
            //
            // Recursion is bounded at one level: `StoredRoutine.forbiddenStepOperations` refuses a
            // nested `run_routine`, so a routine's plan can never re-enter this closure.
            //
            // `SaveRoutineCapabilityAdapter` previews a nested plan it will not run, and inherits the
            // claims too. Deliberate rather than overlooked: the alternative is a second rule for
            // which nested previews see the run's claims, and the listing it produces ("Will
            // include: …") describes what those steps would do if run, for which the run's own
            // claims are the accurate context.
            previewNestedPlan: { [weak self] plan in
                guard let self else {
                    throw AgentExecutionError.invalidPlan("Executor is unavailable for nested preview.")
                }
                return try self.preview(plan: plan, claimedEarlierInThisRun: claimedEarlierInThisRun)
            },
            executeNestedPlan: { [weak self] plan, nestedBrowser, log in
                guard let self else {
                    throw AgentExecutionError.invalidPlan("Executor is unavailable for nested execution.")
                }
                return try await self.execute(
                    plan: plan,
                    preferredBrowser: nestedBrowser,
                    claimedEarlierInThisRun: claimedEarlierInThisRun,
                    namedByEnclosingPlan: namedByEnclosingPlan,
                    log: log
                )
            },
            visionSession: visionSession,
            recordingPolicy: recordingPolicy,
            memoryRecording: memoryRecording
        )
    }

    /// `claimedEarlierInThisRun` is threaded rather than dropped (PR #65 review, F4).
    ///
    /// **Unreachable today and fixed anyway.** A chain segment is never itself a chain, so this
    /// parameter is always `.none` in practice and no behaviour changes — which also means no test
    /// can distinguish the two versions, and none is added rather than one that would pass either
    /// way. What it removes is an asymmetry between two *public* entry points: `execute` threaded it
    /// through its `.chain` case and `preview` did not, so the same plan handed to each would have
    /// been treated differently the first time a chain could nest.
    private func previewChain(
        _ plan: AgentPlan,
        claimedEarlierInThisRun: RunClaims = .none
    ) throws -> [ActionPreview] {
        var previews: [ActionPreview] = []
        var previousArtifactPath: String?

        // The same accumulation as `executeChain`, over what each unit *says* it will do. Without it
        // the preview and the run disagree about the second unit — the panel names `report.pdf` and
        // the run writes `report-2.pdf` — and a plan that promises one file and writes another is the
        // shape `aChainWritesOnlyFilesThePreparedPlanAlreadyNamed` exists to forbid.
        var claimed = claimedEarlierInThisRun

        for segment in try chainSegments(in: plan) {
            let resolved = resolvePreviousArtifactPathIfNeeded(in: segment, previousArtifactPath: previousArtifactPath)
            let segmentPreviews = try preview(plan: resolved, claimedEarlierInThisRun: claimed)
            previews.append(contentsOf: segmentPreviews)
            for written in segmentPreviews.flatMap(\.writes) {
                claimed.recordWrite(written)
            }
            for converted in segmentPreviews.flatMap(\.convertedSources) {
                claimed.recordConversion(ofSource: converted.sourcePath, to: converted.destinationPath)
            }
            if let producedPath = segmentPreviews.flatMap(\.writes).last {
                previousArtifactPath = producedPath
            }
        }

        return previews
    }

    private func executeChain(
        _ plan: AgentPlan,
        preferredBrowser: MacApp?,
        claimedEarlierInThisRun: RunClaims = .none,
        namedByEnclosingPlan: PlannedDestinations,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        var summaries: [String] = []
        var summaryProvenance: StoredTaskResult.Provenance = .codeAuthored
        var suggestions: [RunSuggestion] = []
        var previews: [ActionPreview] = []
        var previousArtifactPath: String?
        // What earlier units of this chain have done, carried forward — see `RunClaims` for why it is
        // two sets rather than one. Accumulated from the previews each unit actually produced rather
        // than through a second return channel.
        var claimed = claimedEarlierInThisRun
        // And what this chain's *whole* plan already names, added to whatever the plans enclosing it
        // named (SONNY-220). `plan` here is always resolved — `execute` resolves before dispatching
        // to this function — so every generated default has its final name by now, and a unit that
        // has not run yet is as visible as one that has.
        //
        // **This is the half `claimed` cannot cover, and it is why it is computed here rather than
        // inside `execute`.** A segment sees only its own steps, so a `[run_routine]` segment asked
        // to name its destinations names none; the outer draft it must not collide with lives in a
        // *different* segment of the same chain. Whole-plan is the only altitude at which that fact
        // exists.
        //
        // The whole plan's set is handed to every segment, its own destinations included, and that
        // costs nothing: a resolved step carries an `outputPath`, so `hasOwnOutputPath` is true and
        // the bump below never applies to it. What it buys is that the set means one thing — "what
        // this run's plan names" — rather than a per-segment subtraction whose correctness would
        // depend on the segmentation staying exactly as it is.
        //
        // The union with `namedByEnclosingPlan` is **live, not defensive** (PR #96 review, F3). This
        // comment used to say the parameter "is always `.none` here" on the grounds that a chain
        // segment is never itself a chain — true, and not the only way to arrive: a *stored routine*
        // of more than one workflow, say `[open_url, create_local_draft]`, classifies as `.chain`
        // too, so `executeNestedPlan` re-enters `execute` and reaches this function a second time
        // carrying the outer plan's destinations. The union is what keeps them from being dropped on
        // that path. Behaviour is the same either way today — the nested draft is already bumped
        // before that call — but a comment claiming a live path is dead is an invitation to delete
        // it, which is the same defect this function's seed comment carries a correction for.
        let namedByThisRun = namedByEnclosingPlan.union(PlannedDestinations(namedBy: plan))

        for segment in try chainSegments(in: plan) {
            let resolved = resolvePreviousArtifactPathIfNeeded(in: segment, previousArtifactPath: previousArtifactPath)
            let result = try await execute(
                plan: resolved,
                preferredBrowser: preferredBrowser,
                claimedEarlierInThisRun: claimed,
                namedByEnclosingPlan: namedByThisRun,
                log: log
            )
            for written in result.previews.flatMap(\.writes) {
                claimed.recordWrite(written)
            }
            for converted in result.previews.flatMap(\.convertedSources) {
                claimed.recordConversion(ofSource: converted.sourcePath, to: converted.destinationPath)
            }
            summaries.append(result.summary)
            // Forwarded, not authored (SONNY-147): a chain whose vision segment wrote free text
            // produces a joined summary that contains it, so the join is model-authored as soon as
            // any one segment was. `.codeAuthored` on the whole because the joining is done here
            // would launder the one segment the declaration exists to mark.
            if result.summaryProvenance == .modelAuthored {
                summaryProvenance = .modelAuthored
            }
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
        return AgentRunResult(
            plan: plan,
            previews: previews,
            summary: summary,
            summaryProvenance: summaryProvenance,
            suggestions: suggestions
        )
    }

    /// The plan cut into the units the executor dispatches: **a unit is a maximal run of consecutive
    /// steps mapping to one `Workflow`, cut only where the run genuinely repeats itself.**
    ///
    /// One rule, and it is the rule the adapters already assume rather than a second opinion about
    /// plan shape. Every adapter resolves its spec with `.first(where:)` per operation it owns, so
    /// one adapter call services at most one step of each operation: `[scan, zip]` is one unit
    /// because `LargestFilesZipCapabilityAdapter` reads across both, and `[scan, zip, scan, zip]` is
    /// two because a single call would service the first pair and silently drop the second. Steps of
    /// different workflows are never absorbed together, which is what makes a multi-workflow plan a
    /// chain of at least two units.
    ///
    /// **A repeated operation cuts the run only when what follows is a *repeat*, not a fragment** —
    /// formally, when the steps from the repeat to the end of the run cover exactly the operations
    /// the unit already covers. Anything else is absorbed, and the adapter's own `.first(where:)`
    /// drops it, which is what the whole-plan call did before this branch and is right: the plan
    /// named one archive, one conversion, one digest.
    ///
    /// A plain "any duplicate cuts here" rule shipped in the first draft of SONNY-34 and was wrong in
    /// the dangerous direction, because it ends a unit *mid-workflow* and no adapter gates on its
    /// companion step being present — each one manufactures a default and acts. `[scan, scan, zip]`
    /// built a second archive nobody asked for, `[scan_docx, scan_docx, convert]` wrote a PDF into the
    /// source folder instead of the requested output folder, and `[open_hn, fetch, fetch]` opened the
    /// browser twice and reported two saves to one path — the second silently over the first, at tier
    /// 2, because at assessment time the file did not exist yet. That last one is the exact defect
    /// class this branch exists to end, and SONNY-35's suffixing had no purchase on it: neither
    /// fragment carries a `.writeMarkdown` step, so no `outputPath` is ever resolved to compare.
    /// (PR #41 review, F1.) All three are now single units again and are regression fixtures.
    ///
    /// Two other consequences of generalising away from the old switch, both improvements: a run led
    /// by a *later* member of its workflow is grouped (`[fetchHNHeadlines, writeMarkdown]` with no
    /// `openHackerNews` step, `[createZip, scanSelectLargestFiles]`), where the old anchors split it
    /// into units no adapter services separately; and `.editWorkspace` keeps chaining on repeat for
    /// the reason it always did — two edits of two *different* workspaces need one unit each, since a
    /// step carries one `workspaceName`. Its same-workspace plan-shape rule lives in
    /// `EditWorkspaceCapabilityAdapter.resolveDefaultOutputs`, which `resolveDefaultOutputs(in:)` calls
    /// on the whole plan once the per-unit walk has reassembled it — after this, not before, and the
    /// rule is indifferent to which because the walk never touches `.editWorkspace` steps and
    /// reassembly preserves step order.
    ///
    /// **Termination invariant.** Re-cutting a unit yields that same single unit, so a unit can never
    /// re-classify as `.chain` and recurse on itself — which is what makes it safe for `workflow(in:)`
    /// to classify a multi-unit plan as `.chain` while `previewChain`/`executeChain` re-enter
    /// `preview`/`execute` per unit. The proof survives absorption, which is worth spelling out
    /// because a unit may now contain a repeated operation: suppose the walk cut a unit `U =
    /// steps[0..<j]`, which required `ops(steps[j..<runEnd]) == ops(U)`, and suppose re-cutting `U`
    /// would break at some repeat `i < j`, which requires `ops(steps[i..<j]) == ops(steps[0..<i])`.
    /// Then `ops(steps[i..<runEnd]) = ops(steps[i..<j]) ∪ ops(steps[j..<runEnd]) = ops(steps[0..<i])`,
    /// so the original walk would have cut at `i` too and `U` would never have contained it.
    /// Contradiction. `chainSegments(in:)` checks the remaining half at runtime rather than leaving it
    /// to this argument alone.
    private func segmentPlans(in plan: AgentPlan) throws -> [AgentPlan] {
        var segments: [AgentPlan] = []
        var index = 0

        while index < plan.steps.count {
            let unitWorkflow = try workflow(for: plan.steps[index].operation)
            // The maximal run of consecutive steps sharing this workflow. Every decision below is
            // made inside one run — a step of a different workflow always ends the unit.
            var runEnd = index + 1
            while runEnd < plan.steps.count,
                  try workflow(for: plan.steps[runEnd].operation) == unitWorkflow {
                runEnd += 1
            }

            var operations: Set<AgentOperation> = [plan.steps[index].operation]
            var end = index + 1
            while end < runEnd {
                let operation = plan.steps[end].operation
                if operations.contains(operation),
                   Set(plan.steps[end..<runEnd].map(\.operation)) == operations {
                    break
                }
                operations.insert(operation)
                end += 1
            }

            segments.append(segmentPlan(from: plan, steps: Array(plan.steps[index..<end])))
            index = end
        }

        return segments
    }

    /// `segmentPlans(in:)` for a plan `workflow(in:)` has already classified `.chain`, refusing the
    /// one segment count that would recurse.
    ///
    /// **Exactly one** unit is the dangerous count, and the only one refused. It would mean the
    /// classifier and the cutter disagree, and the shape that disagreement takes is not a wrong
    /// answer: `previewChain`/`executeChain` would hand the identical plan back to
    /// `preview`/`execute`, which would classify it `.chain` again, and so on. Unbounded re-entry in
    /// a synchronous call chain ends in a stack-overflow crash, so it is worth one comparison to
    /// turn it into a thrown message instead.
    ///
    /// **Zero units passes through, deliberately.** A plan with no steps classifies `.chain` — an
    /// empty `Set` of workflows is not a count of one — and cuts to no units, and the two chain
    /// loops simply do not run: no previews, no writes, tier 0. That is exactly what the executor did
    /// before this branch, and it is reachable in practice, not only from a malformed planner
    /// response: `RoutineStore.save` accepts a routine with no steps (`validateStepSafety` has
    /// nothing to reject), and `RunRoutineCapabilityAdapter` previews and assesses that routine's
    /// empty nested plan through this same path. An earlier draft of this guard refused zero as well,
    /// which turned that benign no-op into a thrown error — an unrequested behavior change of exactly
    /// the kind this branch was fixing elsewhere (PR #41 review, F2). Rejecting an empty plan outright
    /// was considered and declined for the same reason: it may well be the right product answer, but
    /// it is a decision no ticket here asked for, and it belongs to whoever makes it deliberately.
    ///
    /// With zero handled here, the count this refuses is genuinely unreachable, and the enumeration is
    /// now complete rather than partial: zero cuts to zero and passes; a one-step plan never reaches
    /// `.chain` at all, because `workflow(in:)` returns the bare workflow when `steps.count == 1`; and
    /// any plan of two or more steps that reaches `.chain` did so either by holding two workflows,
    /// which never share a unit, or by `workflow(in:)` measuring more than one unit with this same
    /// function. So the guard cannot fire without a source change — which is the claim SONNY-34's
    /// first records made while having enumerated only the middle case.
    private func chainSegments(in plan: AgentPlan) throws -> [AgentPlan] {
        let segments = try segmentPlans(in: plan)
        guard segments.count != 1 else {
            throw AgentExecutionError.invalidPlan("A chained plan must contain more than one unit of work.")
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
