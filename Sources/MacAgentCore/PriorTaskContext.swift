import Foundation

public struct PriorTaskContext: Codable, Equatable, Sendable {
    public static let defaultExpirationInterval: TimeInterval = 10 * 60

    public var previousCommand: String
    public var planSummary: String
    public var steps: [PriorTaskStepContext]
    public var outcome: PriorTaskOutcome
    public var createdAt: Date
    /// Whether the user **pointed at this task on purpose** (row E, SONNY-150), rather than it
    /// being left behind by the last run.
    ///
    /// **It is what exempts a context from the ten-minute window, and the exemption is the whole
    /// reason this flag exists.** The window is there so an *automatic* context does not leak into
    /// an unrelated later command — a task from an hour ago has nothing to do with what the user is
    /// typing now. A context the user armed by opening one task and pressing Follow up is not that
    /// case, and applying the window to it silently kills the feature: `createdAt` carries the
    /// original task's real timestamp, so a task from yesterday reads as expired on the very next
    /// `currentContext()` call, the read drops it, and the follow-up reaches the planner with no
    /// context at all — looking, from the outside, exactly like it worked.
    ///
    /// **The other obvious fix is worse.** Stamping `Date()` instead would keep the context alive by
    /// making `Captured at:` a lie *inside the trusted block*, which is the one place in the prompt
    /// the planner's own system prompt describes as authoritative.
    ///
    /// **Exemption from the timer is not permission to persist.** An armed context is consumed by
    /// the next dispatch and cleared — arm, use once, gone — the same lifecycle
    /// `AgentViewModel.pendingWorkspaceBinding` already has. It must not survive into the command
    /// after it, and `PriorTaskContextStore.consumeArmedContext()` is what makes that true rather
    /// than incidental.
    ///
    /// Defaulted `false`, so every automatically-recorded context is unchanged and every existing
    /// call site keeps its behaviour.
    public var isArmed: Bool

    public init(
        previousCommand: String,
        planSummary: String,
        steps: [PriorTaskStepContext],
        outcome: PriorTaskOutcome,
        createdAt: Date,
        isArmed: Bool = false
    ) {
        self.previousCommand = previousCommand
        self.planSummary = planSummary
        self.steps = steps
        self.outcome = outcome
        self.createdAt = createdAt
        self.isArmed = isArmed
    }

    public init(
        command: String,
        plan: AgentPlan,
        outcome: PriorTaskOutcome,
        createdAt: Date
    ) {
        self.init(
            previousCommand: command.trimmingCharacters(in: .whitespacesAndNewlines),
            planSummary: plan.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            steps: plan.steps.map(PriorTaskStepContext.init(step:)),
            outcome: outcome,
            createdAt: createdAt
        )
    }

    public init(
        command: String,
        outcome: PriorTaskOutcome,
        createdAt: Date
    ) {
        self.init(
            previousCommand: command.trimmingCharacters(in: .whitespacesAndNewlines),
            planSummary: "",
            steps: [],
            outcome: outcome,
            createdAt: createdAt
        )
    }

    /// The context for a follow-up the user **explicitly armed** on a past task (SONNY-150).
    ///
    /// Rehydrated from what that task stored: its command, the plan summary and steps
    /// `TaskPlanDetailStore` kept, and an outcome built from the row's status and stored result.
    /// Everything reaches the planner through `plannerContextText`, which escapes every field it
    /// interpolates — so the escaping is inherited by construction rather than remembered at the
    /// call site. **Nothing may assemble a prompt string from a stored record anywhere else.**
    ///
    /// - Parameter completedAt: the original task's own completion time, kept as `createdAt`. See
    ///   `isArmed` for why neither of the two obvious alternatives works.
    public init(
        armedFollowUpOn command: String,
        planSummary: String,
        steps: [PriorTaskStepContext],
        outcome: PriorTaskOutcome,
        completedAt: Date
    ) {
        self.init(
            previousCommand: command.trimmingCharacters(in: .whitespacesAndNewlines),
            planSummary: planSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            steps: steps,
            outcome: outcome,
            createdAt: completedAt,
            isArmed: true
        )
    }

    /// An armed context never expires; an automatic one expires exactly as it always has.
    public func isExpired(
        at now: Date,
        expirationInterval: TimeInterval = Self.defaultExpirationInterval
    ) -> Bool {
        guard !isArmed else {
            return false
        }
        return now.timeIntervalSince(createdAt) > expirationInterval
    }

    public var shortDisplayText: String {
        let summary = planSummary.isEmpty ? previousCommand : planSummary
        guard summary.count > 72 else {
            return summary
        }
        return String(summary.prefix(69)) + "..."
    }

    public var plannerContextText: String {
        let formatter = ISO8601DateFormatter()
        let stepLines = steps.enumerated().map { index, step in
            "\(index + 1). \(Self.escapeForPlanner(step.plannerText))"
        }

        // **These two say what is missing and never why** (SONNY-150). They used to read
        // "prior task failed before preparation completed", which names a cause that is only
        // sometimes the reason. Row E made the other case common: every task recorded before this
        // row has no stored plan, so a follow-up on one would put that sentence twice, directly
        // above `Previous outcome: completed - …` — a flat contradiction inside a segment the
        // planner's own system prompt describes as authoritative. "Not recorded" is true of the
        // live no-plan case and the rehydrated pre-row-E case alike.
        let planSummaryText = planSummary.isEmpty
            ? "- not recorded"
            : Self.escapeForPlanner(planSummary)
        let stepsText = stepLines.isEmpty
            ? "- none recorded"
            : stepLines.joined(separator: "\n")

        return """
        TRUSTED_PRIOR_TASK_CONTEXT_BEGIN
        Previous command: \(Self.escapeForPlanner(previousCommand))
        Previous plan summary: \(planSummaryText)
        Previous plan steps:
        \(stepsText)
        Previous outcome: \(Self.escapeForPlanner(outcome.plannerText))
        Captured at: \(formatter.string(from: createdAt))
        TRUSTED_PRIOR_TASK_CONTEXT_END
        """
    }

    /// Neutralize the trusted-block delimiters anywhere inside interpolated content.
    ///
    /// **Every interpolated field goes through this, and two did not** (PR #50 cycle-2, F13b).
    /// `previousCommand` and `planSummary` were escaped; `outcome.plannerText` and `step.plannerText`
    /// were not, so a prior task's *outcome* could close the trusted block early and everything after
    /// it landed outside the wrapper in a `user` message the planner reads.
    ///
    /// **The omission was harmless until row I and is not any more.** Before this branch every
    /// `AgentRunResult.summary` was a code-authored string from a deterministic adapter — "Created 3
    /// files" — so no interpolated outcome could contain a delimiter unless the user typed one, and
    /// the command *was* escaped. Row I ships the first capability whose summary is free text
    /// authored by a model that just read the user's screen, and the vision system prompt does not
    /// merely allow that text through: when the model meets injected text the rules tell it to
    /// "describe what you saw in your rationale". So the designed response to an injection attempt
    /// was to transcribe it into the one field that reached the trusted segment unescaped.
    ///
    /// The rule this file now follows without exception: **nothing is interpolated into
    /// `plannerContextText` raw.** A new field added between these delimiters gets escaped or it is a
    /// hole, and the only defence against forgetting is that every existing line does it.
    private static func escapeForPlanner(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: "TRUSTED_PRIOR_TASK_CONTEXT_BEGIN",
                with: "[escaped prior-task delimiter: TRUSTED_PRIOR_TASK_CONTEXT_BEGIN]"
            )
            .replacingOccurrences(
                of: "TRUSTED_PRIOR_TASK_CONTEXT_END",
                with: "[escaped prior-task delimiter: TRUSTED_PRIOR_TASK_CONTEXT_END]"
            )
    }
}

public struct PriorTaskStepContext: Codable, Equatable, Sendable {
    public var operation: AgentOperation
    public var description: String
    public var details: [String]

    public init(operation: AgentOperation, description: String, details: [String]) {
        self.operation = operation
        self.description = description
        self.details = details
    }

    public init(step: AgentStep) {
        var details: [String] = []
        Self.append("inputPath", step.inputPath, to: &details)
        Self.append("outputPath", step.outputPath, to: &details)
        Self.append("count", step.count.map(String.init), to: &details)
        Self.append("targetURL", step.targetURL, to: &details)
        Self.append("appName", step.appName, to: &details)
        Self.append("mediaProvider", step.mediaProvider?.rawValue, to: &details)
        Self.append("mediaTitle", step.mediaTitle, to: &details)
        Self.append("mediaArtist", step.mediaArtist, to: &details)
        Self.append("contextSource", step.contextSource?.rawValue, to: &details)
        Self.append("routineName", step.routineName, to: &details)
        Self.append("workspaceName", step.workspaceName, to: &details)
        Self.append("sourceURLs", step.sourceURLs?.joined(separator: ", "), to: &details)
        Self.append("searchQuery", step.searchQuery, to: &details)
        Self.append("draftTitle", step.draftTitle, to: &details)
        Self.append("shortcutName", step.shortcutName, to: &details)
        Self.append("shortcutInput", step.shortcutInput, to: &details)

        self.init(
            operation: step.operation,
            description: step.description.trimmingCharacters(in: .whitespacesAndNewlines),
            details: details
        )
    }

    public var plannerText: String {
        let detailText = details.isEmpty ? "" : " (\(details.joined(separator: "; ")))"
        return "\(operation.rawValue): \(description)\(detailText)"
    }

    private static func append(_ key: String, _ value: String?, to details: inout [String]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return
        }
        details.append("\(key)=\(value)")
    }
}

public struct PriorTaskOutcome: Codable, Equatable, Sendable {
    public var status: PriorTaskOutcomeStatus
    public var summary: String
    /// **Who wrote `summary`** (SONNY-197). Carried rather than dropped, because this type is what
    /// the planner sees and `StoredTaskResult` — the type that holds the same text on disk — has
    /// always known the answer. Before this field, `AgentViewModel.followUpOnTask` rehydrated a
    /// stored task into a context and read `record.result?.text` while `record.result?.provenance`
    /// sat unread on the same expression, so a model-authored paragraph entered the trusted block
    /// indistinguishable from "Zipped 3 files."
    ///
    /// **Nothing reads it yet, and this changes no behaviour.** `plannerContextText` routes all four
    /// interpolated fields through `escapeForPlanner` regardless of provenance, and the trusted
    /// block's shape is deliberately unchanged — adding a line to it would be a prompt change, which
    /// is a different decision from carrying a fact. What this buys is that the first reader who
    /// *does* want to treat model-authored prior-task text differently — a tighter length budget, an
    /// untrusted wrapper rather than the trusted one, an audit surface — is handed a value that
    /// knows, instead of having to re-derive it from a record this type no longer references. Row I's
    /// lesson in the repository's own words: a structural guarantee is only as wide as the type that
    /// carries it.
    ///
    /// Defaults to `.codeAuthored` so every existing construction site is unchanged, and that
    /// default is the honest one: the deterministic strings this repository builds are the ordinary
    /// case, and the one producer of free model text is the screen-control session. The default is
    /// safe for the synthesized `Codable` too — this type reaches no disk, `PriorTaskContextStore`
    /// holds one context in memory and nothing persists it across launches — so there is no stored
    /// shape without the key to decode.
    public var provenance: StoredTaskResult.Provenance

    public init(
        status: PriorTaskOutcomeStatus,
        summary: String,
        provenance: StoredTaskResult.Provenance = .codeAuthored
    ) {
        self.status = status
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.provenance = provenance
    }

    public var plannerText: String {
        if summary.isEmpty {
            return status.rawValue
        }
        return "\(status.rawValue) - \(summary)"
    }
}

public enum PriorTaskOutcomeStatus: String, Codable, Equatable, Sendable {
    case prepared
    case dryRun = "dry_run"
    case completed
    case failed
    case canceled
    case approvalNeeded = "approval_needed"
    case clarificationNeeded = "clarification_needed"
}

public final class PriorTaskContextStore {
    private var storedContext: PriorTaskContext?
    private let expirationInterval: TimeInterval
    private let now: () -> Date

    public init(
        expirationInterval: TimeInterval = PriorTaskContext.defaultExpirationInterval,
        now: @escaping () -> Date = Date.init
    ) {
        self.expirationInterval = expirationInterval
        self.now = now
    }

    public func currentContext() -> PriorTaskContext? {
        guard let storedContext else {
            return nil
        }
        if storedContext.isExpired(at: now(), expirationInterval: expirationInterval) {
            self.storedContext = nil
            return nil
        }
        return storedContext
    }

    /// Spends an armed context: after this, the run that just read it is the only one that ever
    /// sees it (SONNY-150).
    ///
    /// **Explicit rather than left to the replacement that usually happens anyway.** Every terminal
    /// path does call `record(...)` afterwards, which overwrites the stored context — but "usually
    /// overwritten later" is not the same promise as "spent now", and the difference is a follow-up
    /// silently attaching itself to a second command on whatever path turns out not to record.
    /// A no-op on an ordinary context, which has its own expiry.
    public func consumeArmedContext() {
        guard storedContext?.isArmed == true else {
            return
        }
        storedContext = nil
    }

    public func record(command: String, plan: AgentPlan, outcome: PriorTaskOutcome) {
        storedContext = PriorTaskContext(
            command: command,
            plan: plan,
            outcome: outcome,
            createdAt: now()
        )
    }

    public func record(command: String, outcome: PriorTaskOutcome) {
        storedContext = PriorTaskContext(
            command: command,
            outcome: outcome,
            createdAt: now()
        )
    }

    public func replace(with context: PriorTaskContext) {
        storedContext = context
    }

    public func clear() {
        storedContext = nil
    }
}
