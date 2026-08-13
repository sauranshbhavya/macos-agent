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

    /// The one-line ran-without-asking trace (SONNY-99): the sentence that lets a person watching a
    /// task tell "nothing happened because it was low-risk" from "something happened silently
    /// because a relaxation grant allowed it". It names the grant's *reason* — the workspace whose
    /// boundary allowed it, or that the user built the action on screen — never the internal enum,
    /// and the two grants read differently because they are different facts a user can act on.
    ///
    /// `nil` unless the grant actually changed the outcome. Two gates, both load-bearing:
    /// - `.none` never traces — a run with no grant is ordinary.
    /// - A tier at or below 1 never traces, **whatever the grant says**: tiers 0 and 1 auto-run on
    ///   their own in every grant column, so a grant reported there was outcome-irrelevant, and a
    ///   trace on a step that was always silent is exactly what would make the signal meaningless.
    ///   Tier ≥ 2 is precise under every policy: no tier-2-or-above cell is `.autoRun` without a
    ///   grant, so a granted auto-run at those tiers ran unprompted *because of* the grant.
    ///
    /// The workspace grant names the workspace; the fallback exists only because this function is
    /// total — an `.inScope` verdict cannot arise without a bound workspace to name.
    static func relaxationTraceLine(
        grant: RelaxationGrant,
        effectiveTier: CapabilityRiskTier,
        workspaceName: String?
    ) -> String? {
        guard effectiveTier.rawValue >= CapabilityRiskTier.tier2.rawValue else {
            return nil
        }
        switch grant {
        case .none:
            return nil
        case .inScopeWorkspace:
            let trimmed = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name = trimmed, !name.isEmpty else {
                return "Ran without asking — inside this workspace's boundary."
            }
            return "Ran without asking — inside the \(name) workspace's boundary."
        case .directUserAuthored:
            return "Ran without asking — you built this action on screen."
        }
    }
}
