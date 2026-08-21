import Foundation
import MacAgentCore

enum AgentActivityPresentation {
    static func planStepTitle(_ step: AgentStep) -> String {
        let description = step.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? operationTitle(step) : description
    }

    static func operationTitle(_ step: AgentStep) -> String {
        switch step.operation {
        case .openApp:
            return "Open \(step.appName ?? "app")"
        case .openAppSearchURL:
            return "Open search"
        case .openURL:
            return "Open \(step.targetURL ?? "URL")"
        case .openGeneratedArtifact:
            return "Open result"
        case .createLocalDraft:
            return "Create draft"
        case .calculateUtility:
            return "Calculate"
        case .lookupClipboardHistory:
            return "Search clipboard history"
        case .saveSnippet:
            return "Save snippet"
        case .expandSnippet:
            return "Expand snippet"
        case .switchRunningApp:
            return "Switch to \(step.appName ?? "app")"
        case .lookupRecentArtifacts:
            return "Find recent results"
        case .invokeShortcut:
            return "Run \(step.shortcutName ?? "Shortcut")"
        case .visionSession:
            // The pinned name when the resolve phase has run, the user's raw word before it. Named
            // rather than generic ("Control an app") because this string is what the widget shows
            // while Sonny is moving the real cursor, and the app it is moving it in is the single
            // most important thing to say.
            return "Control \(step.resolvedAppName ?? step.appName ?? "app")"
        case .playMedia:
            return "Play \(step.mediaTitle ?? "music")"
        case .scanSelectLargestFiles:
            return "Find largest files"
        case .createZip:
            return "Create zip archive"
        case .scanDocx:
            return "Find Word documents"
        case .convertDocxToPDF:
            return "Convert Word documents to PDF"
        case .openHackerNews:
            return "Open Hacker News"
        case .fetchHNHeadlines:
            return "Get Hacker News headlines"
        case .writeMarkdown:
            return "Save Markdown note"
        case .webToMarkdown:
            return "Create web research note"
        case .getFinderSelection:
            return "Read Finder selection"
        case .revealInFinder:
            return "Reveal in Finder"
        case .showPermissionReadiness:
            return "Check permissions"
        case .saveRoutine:
            return "Save routine"
        case .runRoutine:
            return "Run routine"
        case .createWorkspace:
            return "Create workspace"
        case .editWorkspace:
            return "Edit workspace"
        case .openWorkspace:
            return "Open workspace"
        case .clarify:
            return "Ask a follow-up question"
        case .unsupported:
            return "Unsupported action"
        }
    }



    static func eventIcon(_ phase: AgentPhase) -> String {
        switch phase {
        case .plan:
            return "sparkles"
        case .validate:
            return "checkmark.shield"
        case .risk:
            return "hand.raised"
        case .preview:
            return "eye"
        case .confirm:
            return "person.badge.shield.checkmark"
        case .act:
            return "arrow.triangle.2.circlepath"
        case .observe:
            return "checkmark.circle"
        case .summarize:
            return "checkmark.seal"
        }
    }

    /// The widget's in-composer binding indicator: which workspace the next command belongs to.
    ///
    /// A pure function rather than copy authored in the view body, following
    /// `firstRunApprovalExplainerLines`' precedent — this repo has no SwiftUI view-inspection
    /// harness, so a sentence written inline in a `Text(...)` is untestable and can ship wrong.
    ///
    /// Deliberately says "in", not "active in" or "switched to": the binding is per task, and copy
    /// implying a mode is how the rejected persistent-active-workspace design creeps back in.
    static func workspaceBindingIndicatorText(workspaceName: String) -> String {
        "In \(workspaceName)"
    }

    /// The accessibility label for the affordance that drops the binding again.
    static func clearWorkspaceBindingLabel(workspaceName: String) -> String {
        "Clear the \(workspaceName) workspace binding"
    }

    /// The workspace card's dispatch action title.
    static func newTaskInWorkspaceLabel(workspaceName: String) -> String {
        "New task in \(workspaceName)"
    }

    /// The explanatory lines the floating widget's permission panel puts above its "Allow access
    /// to …" row, in render order.
    ///
    /// Returns nothing once the user has resolved their first approval, so the steady-state panel
    /// stays exactly what the wireframe specifies (`docs/sonny-design-system-reference.md:145` —
    /// one "Allow access to [resource]" line plus two icon-only buttons, nothing else). The
    /// first-run moment is the one sanctioned deviation: `docs/sonny-founder-design-decisions.md`'s
    /// "Approval panel — first-run moment" asks for "first-time-specific framing on the panel
    /// itself," which is what the reassurance sentence already shipped for on 2026-07-24.
    ///
    /// `riskReason` joins it (SONNY-10) because that shipped sentence explains Sonny's *policy* —
    /// "we always ask" — without ever saying why *this* action was flagged, and the bar for this
    /// moment is that a new user can tell what is being asked **and why**. Command Center already
    /// renders `riskReason` for every approval via `RiskApprovalCopy.lines`; this only closes the
    /// gap on the surface most users meet first. Shown bare rather than with `lines`' "Why this is
    /// risky: " prefix — the widget's voice has no field labels ("Allow access to X"), and adding
    /// one here would read as a second design language inside one panel.
    ///
    /// Escalation reasons are deliberately not here: they are per-run facts, not first-run
    /// framing, and render in their own warning-colored line on every approval.
    static func firstRunApprovalExplainerLines(
        for request: RiskApprovalRequest,
        isFirstApproval: Bool
    ) -> [String] {
        guard isFirstApproval else {
            return []
        }

        return [
            "Sonny always asks first for actions like this — you decide, every time.",
            request.approvalCopy.riskReason
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    /// The disclosure lines an approval surface renders, selected by the mode it renders under
    /// (SONNY-90): Safe mode restores the "Data leaves device: yes/no" line in its §11.3
    /// position; every other mode omits it — E9's founder-ratified deviation, whose test citation
    /// lives on the copy tests. Normal and Power both count as not-Safe here: Power is row 18's
    /// mode landing as a setting first, identical to Normal today, and it must not leak the
    /// Safe-only label. A pure function on `firstRunApprovalExplainerLines`' precedent so the
    /// selection is pinned without a view-inspection harness; both directions have tests.
    static func approvalDisclosureLines(
        for request: RiskApprovalRequest,
        safeMode: Bool
    ) -> [String] {
        safeMode ? request.approvalCopy.safeModeLines : request.approvalCopy.lines
    }

    /// The widget's Safe-mode-only data-egress caption (SONNY-90). The widget's steady-state
    /// panel is one "Allow access to [resource]" row — no field-labeled lines — so Safe mode adds
    /// exactly this one line rather than the full disclosure; `nil` in every other mode means
    /// the widget renders nothing, which IS the ratified relocation.
    static func widgetDataEgressLine(
        for request: RiskApprovalRequest,
        safeMode: Bool
    ) -> String? {
        safeMode ? request.approvalCopy.dataLeavesDeviceLine : nil
    }

    /// The one-line ran-without-asking trace (SONNY-99, reshaped by the consequence rule
    /// 2026-08-13): the sentence that lets a person watching a task tell "nothing happened because
    /// it was low-risk" from "something happened silently because Sonny no longer asks for it".
    /// When the silent run carried advisory escalations, the trace names them — the out-of-scope
    /// resource, the workspace-entry removal, the whitelist-root widening — because those are the
    /// sentences the approval panel used to carry and the user still gets to read them; a silent
    /// run with nothing advisory states the rule instead.
    ///
    /// `nil` unless the silence is new. Two gates, both load-bearing:
    /// - Only `.autoRun` traces. A run that prompted was disclosed by the prompt; a
    ///   trust-approved routine run was disclosed by the user's own standing toggle; Safe mode
    ///   always prompts, so nothing traces inside it.
    /// - A tier at or below 1 never traces: tiers 0 and 1 always auto-ran, so a trace there would
    ///   mark a silence that was always ordinary and train the user to ignore the one that is not.
    ///   At tier 2 and above the silence is the consequence rule's own doing — before it, every
    ///   such run asked.
    static func ranWithoutAskingLine(
        requirement: RiskApprovalRequirement,
        effectiveTier: CapabilityRiskTier,
        advisoryReasons: [String]
    ) -> String? {
        guard requirement == .autoRun,
              effectiveTier.rawValue >= CapabilityRiskTier.tier2.rawValue else {
            return nil
        }
        let reasons = advisoryReasons
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !reasons.isEmpty else {
            return "Ran without asking — nothing here is destructive, and it affects no one else."
        }
        return "Ran without asking — worth knowing: " + reasons.joined(separator: " ")
    }
}

/// The copy for abandoning a clarification (SONNY-166).
///
/// **One copy, because two surfaces have to say the same thing.** The floating widget's
/// clarification panel and `CommandCenterAttentionPanel`'s mirror it — `.claude/rules/
/// macagent-ui-conventions.md`'s "Approval visibility" rule is that the two can never disagree
/// about one task, and two identical literals is exactly the shape that held until one of them
/// stopped saying anything (SONNY-173's missing-key message). The widget's control is icon-only, so
/// there `cancelLabel` is its tooltip and its VoiceOver name rather than visible text.
///
/// **The founder's wording, given verbatim on 2026-08-20**, chosen over "Never mind" and "Stop" so
/// that Sonny's two exits from a paused run speak with one voice: cancelling at an approval prompt
/// already writes "Approval canceled. No action was taken."
///
/// Nothing here explains how it works, per the founder's rule of 2026-08-14 — the label is the
/// whole message.
enum ClarificationPresentation {
    /// The Command Center button's visible text, and the widget button's tooltip and accessibility
    /// label.
    static let cancelLabel = "Cancel"

    /// What Sonny says once the question is abandoned.
    ///
    /// "No action was taken" is literally true rather than a softening: a clarification is raised
    /// inside `AgentRunner.prepare` and `performStart` returns on it before `executePreparedRun` is
    /// ever reached, so every step is still `.pending` and nothing has run. See
    /// `AgentViewModel.cancelCurrentRun()`'s clarification branch.
    static let canceledSummary = "Canceled. No action was taken."
}

/// The armed-follow-up chip and the action that arms it (row E, SONNY-150).
///
/// Copy approved by the founder on 2026-08-21, with the alternatives put beside it: the chip states
/// what is attached and names it, and the button is a bare verb, matching "Run again" next to it
/// rather than the verb-plus-object shape the two delete actions need in order to tell each other
/// apart.
enum FollowUpPresentation {
    /// The task-detail sheet's action.
    static let actionLabel = "Follow up"

    /// The most of the original command the chip shows.
    ///
    /// The composer pill is 472 wide and the chip row has 444 of it. A workspace chip and the
    /// "Won't be saved" chip take roughly 164 between them by estimate — their text at
    /// `WidgetType.captionSmall` plus 8 points of padding a side — so this keeps three chips inside
    /// the row without relying on `Text` truncation to rescue the layout. Each chip is
    /// `lineLimit(1)` with tail truncation anyway, so an unusually long workspace name shortens a
    /// chip rather than overflowing the row. Commands longer than this are
    /// cut at a word boundary where there is one, because "Zip the largest files in ~/Down…" reads
    /// and "Zip the largest files in ~/Downloa…" does not read any better for the four characters
    /// it bought.
    static let maximumChipCommandCharacters = 28

    /// What the chip says.
    static func chipText(command: String) -> String {
        "Following up: \(truncatedCommand(command))"
    }

    static func clearAccessibilityLabel(command: String) -> String {
        "Stop following up on \(truncatedCommand(command))"
    }

    /// A record with no command of its own still gets a chip, because the arm is real either way and
    /// an armed state with no chip is the invisible trusted block the chip exists to prevent.
    static func truncatedCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "an untitled task"
        }
        guard trimmed.count > maximumChipCommandCharacters else {
            return trimmed
        }
        let head = trimmed.prefix(maximumChipCommandCharacters)
        // Cut at the last space inside the budget when there is one that leaves something readable,
        // rather than mid-word.
        if let lastSpace = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: lastSpace) >= 12 {
            return head[head.startIndex..<lastSpace] + "\u{2026}"
        }
        return head + "\u{2026}"
    }
}

/// "Don't save this task" — the widget control's copy (SONNY-120).
///
/// **The label carries the whole meaning, because no sentence may sit beside it.** The founder's
/// decision of 2026-08-16: the feature is not called Incognito, because incognito borrows a promise
/// from browsers this cannot keep — files still get created, apps still open, the command still goes
/// to the provider — and the 2026-08-14 rule forbids the clarifying sentence that would normally fix
/// an over-promising name. So the name was narrowed until no sentence is needed.
///
/// Nothing here explains how it works. There is no tooltip, no help text and no disclosure line, and
/// `TaskRecordingPresentationTests` refuses copy that reads like one.
enum TaskRecordingPresentation {
    /// The control's accessibility label and its only name.
    static let controlLabel = "Don't save this task"

    /// The chip shown in the composer while it is on. Deliberately in the past-looking tense the
    /// user cares about — what will be true of this task once it is done.
    static let activeChipText = "Won't be saved"

    static let clearAccessibilityLabel = "Turn off don't save this task"

    /// The on state has to be unmissable, because the two mistakes are not symmetrical: leaving it
    /// on costs a history row nobody minds losing, and forgetting it is off records something the
    /// user wanted private — and that one cannot be undone after the fact.
    static func controlAccessibilityValue(isOn: Bool) -> String {
        isOn ? "On" : "Off"
    }
}
