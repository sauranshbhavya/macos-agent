import Foundation

/// Starts one standing watcher: "tell me when this page changes" (SONNY-382).
///
/// **This adapter creates a watcher; it never checks one.** Executing reads the page once, stores
/// that reading as the baseline, and returns. Everything afterwards — the fifteen-minute cadence,
/// the two-reading rule, the four endings and the notification — belongs to
/// `AgentViewModel.checkStandingWatchers` and `StandingWatcherEvaluator`, and runs on a pulse with
/// no plan and no run behind it (SONNY-236). So what this step's approval is actually about is one
/// public GET now and one record in `resumable-tasks.json`, plus the standing consequence of a page
/// being fetched again on a timer for as long as the watcher lives.
///
/// **There is no route to acting here, switched off or otherwise** (founder decision 2026-08-31,
/// SONNY-236). A watcher notifies and does nothing else, so this adapter writes a record with no
/// plan, no steps and no executor reference, and nothing downstream can dispatch one. That is the
/// same sentence `StandingWatcher`'s own doc comment makes, restated at the only door that creates
/// one, because an unreachable capability in the tree is a thing a later session finds and turns on.
///
/// **The baseline is read through `context.webPageLoader`, not through
/// `LiveStandingWatcherObserver`.** They are the same fetch — the observer wraps a
/// `PublicWebPageLoader` and calls `load(rawURL:).readableText` — and the context already carries
/// one that every fixture controls. Constructing an observer here would put a second, unseamed
/// network path inside a capability, which is the shape `StandingWatcherObserving` exists to avoid
/// one layer out.
public struct StandingWatcherCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.watchers.start",
        displayName: "Watch a page for a change",
        description: "Watch one public web page and notify the user when its readable text changes.",
        operations: [.startWatching],
        plannerTools: [
            AgentTool(
                operation: .startWatching,
                name: "Watch a page for a change",
                description: "Watch one public http/https page and tell the user when it changes. Sonny only notifies; it cannot act on the change.",
                requiredFields: ["targetURL", "watchSubject"],
                sideEffects: ["read one public web page", "write local watcher record"],
                dryRunBehavior: "Show the page and what is being watched for, without starting anything.",
                examples: ["Tell me when https://example.com/status changes"]
            )
        ],
        requiredPermissions: [CapabilityPermissionMetadata(requirement: .networkAccess)],
        // Tier 2, the same as saving a routine, and for the same reason: this writes one file inside
        // Sonny's own store and reaches nobody. It is deliberately not tier 3 — nothing is
        // overwritten (`ResumableTaskStore.saveWatcher` refuses at the cap rather than evicting) and
        // nothing leaves the machine except a GET of a page the user named. It is deliberately not
        // tier 1 either: what the user is approving is a page being fetched on a timer for up to a
        // week, and that standing consequence is worth a panel the first time.
        defaultRiskTier: .tier2
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try watchSpec(plan, context: context)
        return [
            ActionPreview(
                title: "Watch \(spec.url.absoluteString)",
                // The cadence and the lifetime are in the *approval*, and that is not the
                // explanatory copy the 2026-08-14 rule forbids. A preview's whole job is to say what
                // pressing the button will cause, and what this one causes is repeated requests to
                // somebody else's server for a week. The Routines row is the surface that rule is
                // about, and it names a state and a control and nothing else.
                details: [
                    "Watching for: \(spec.subject)",
                    // **Each number comes from whatever actually decides it, which is not one
                    // place** (SONNY-236's R2). `AgentViewModel.checkStandingWatchers` drives the
                    // evaluator on its `.standard` default, so `.standard` is what a cadence and a
                    // lifetime honestly are; the *cap on how many* is enforced by
                    // `ResumableTaskStore.saveWatcher` against the store's own injected `limits`,
                    // so that one is read there (in `watchSpec`). Reading all three off the store
                    // would let a fixture's injected interval into a sentence the checker will not
                    // obey, which is the two-sources-for-one-decision shape R2 named.
                    "Checks every \(Self.minuteCount(StandingWatcherLimits.standard.checkInterval)) for up to \(StandingWatcherNoticeCopy.dayCount(StandingWatcherLimits.standard.maxLifetime))"
                ],
                writes: [context.resumableTaskStore.fileURL.path]
            )
        ]
    }

    public func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        // Plain `try`, never `try?`, for the reason `SaveRoutineCapabilityAdapter.assessRisk`
        // records: an unreadable store must not answer the same as an empty one. Here it decides
        // whether the cap is already spent, and a swallowed error would let a plan be approved that
        // `execute` then refuses.
        _ = try watchSpec(plan, context: context)
        return CapabilityRiskAssessment(
            defaultTier: metadata.defaultRiskTier,
            effectiveTier: metadata.defaultRiskTier,
            escalations: []
        )
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let spec = try watchSpec(plan, context: context)
        // Refused out loud rather than saved anyway or dropped quietly, the rule
        // `SaveRoutineCapabilityAdapter` states: the user asked for this by name, so a silent no-op
        // would report a watcher that does not exist. The row this names is "Unfinished tasks",
        // which is the row `resumable-tasks.json` has — watchers share that file by SONNY-236's
        // decision, and that row's own copy already names watchers.
        guard context.allowsRecording(to: .resumableTasks) else {
            throw MemoryDisabledError(category: .resumableTasks)
        }

        log(.act, "Reading \(spec.url.absoluteString)")
        // The one fetch this step makes. A failure here fails the step rather than starting a
        // watcher with an empty baseline: a digest of "" differs from every real reading, so the
        // next check would confirm a change that never happened.
        let page = try await context.webPageLoader.load(rawURL: spec.url.absoluteString)

        let watcher = StandingWatcher(
            subject: spec.subject,
            url: spec.url,
            createdAt: context.now(),
            baselineDigest: StandingWatcherEvaluator.digest(of: page.readableText)
        )
        // The real choke point. `preview` asked the same question above so the refusal arrives
        // before an approval rather than after one, and this is the answer that counts — the store
        // enforces the cap for every door, this one included.
        try context.resumableTaskStore.saveWatcher(watcher)
        log(.summarize, "Watching")

        return AgentRunResult(
            plan: plan,
            previews: previews,
            summary: "Sonny is watching \u{201C}\(watcher.subject)\u{201D}."
        )
    }

    private struct WatchSpec {
        var subject: String
        var url: URL
    }

    @MainActor
    private func watchSpec(_ plan: AgentPlan, context: CapabilityExecutionContext) throws -> WatchSpec {
        guard let step = plan.steps.first(where: { $0.operation == .startWatching }) else {
            throw AgentExecutionError.invalidPlan("start_watching step is missing.")
        }
        // Validated here as well as inside `PublicWebPageLoader.load` and again on every later
        // check. A stored URL is not trusted input just because Sonny wrote it, and validating at
        // the creation door is what keeps a private or non-http address from ever becoming a record
        // that something on a timer will try to fetch.
        let url = try SafeURL.validateWebURL(step.targetURL)
        let subject = (step.watchSubject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else {
            throw AgentExecutionError.invalidPlan("start_watching needs watchSubject: what to tell the user about.")
        }
        // Capped here rather than only in the record (PR #187, F4). Every other surface reads the
        // stored watcher, which `StandingWatcher.init` caps; the approval panel below reads this
        // spec, one gate before any record exists — so without this the one surface the user is
        // asked to read before consenting was the only uncapped one.
        let label = StandingWatcher.cappedSubject(subject)

        // Asked before an approval panel is raised, so "you already have five" arrives instead of a
        // panel the user approves and a refusal underneath it. `ResumableTaskStore.saveWatcher` is
        // still the guard — this is the early half of it, and it reads the same store.
        let limit = context.resumableTaskStore.limits.maxActive
        let existing = try context.resumableTaskStore.loadWatchers()
        guard existing.count < limit else {
            throw StandingWatcherStoreError.tooManyWatchers(limit: limit)
        }

        return WatchSpec(subject: label, url: url)
    }

    /// "15 minutes", "1 minute" — derived from the cap for `StandingWatcherNoticeCopy.dayCount`'s
    /// reason, so shortening `checkInterval` cannot leave an approval quoting the old number.
    static func minuteCount(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded()))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
