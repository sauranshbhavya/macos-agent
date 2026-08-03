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
}
