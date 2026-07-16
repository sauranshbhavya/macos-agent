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

    static func statusTitle(_ status: AgentStepStatus) -> String {
        switch status {
        case .pending:
            return "Ready"
        case .running:
            return "In progress"
        case .complete:
            return "Complete"
        case .failed:
            return "Needs attention"
        case .canceled:
            return "Canceled"
        }
    }

    static func eventTitle(_ event: AgentEvent) -> String {
        switch event.phase {
        case .plan:
            return "Understanding"
        case .validate:
            return "Checking"
        case .risk:
            return "Safety check"
        case .preview:
            return "Ready to review"
        case .confirm:
            return event.message.localizedCaseInsensitiveContains("required")
                ? "Needs approval"
                : "Approved"
        case .act:
            return "Working"
        case .observe:
            return "Update"
        case .summarize:
            if event.message.hasPrefix("Stopped")
                || event.message.localizedCaseInsensitiveContains("failed")
                || event.message.localizedCaseInsensitiveContains("canceled") {
                return "Stopped"
            }
            return "Done"
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

    static func eventMessage(_ event: AgentEvent) -> String {
        let message = event.message.trimmingCharacters(in: .whitespacesAndNewlines)
        switch message {
        case "Sending command to planner":
            return "Understanding your request"
        case "Resolved command locally":
            return "Understood this command on your Mac"
        case "Short-lived prior task context available to planner":
            return "Using your recent task for context"
        case "Validating whitelist and supported operations":
            return "Checking supported actions and allowed locations"
        case "Typed command auto-approved execution", "Voice command auto-approved execution", "Execution approved":
            return "No extra approval needed"
        case "Execution paused by preview-only approval policy":
            return "Preview ready. This action will not run under the current settings."
        case "Execution refused by approval policy":
            return "Sonny stopped this action to keep you safe."
        default:
            break
        }

        if message.hasPrefix("Received plan: ") {
            return "Plan ready: " + String(message.dropFirst("Received plan: ".count))
        }
        if message.hasPrefix("Prepared "), message.contains(" preview item") {
            let count = message.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
            return "Ready to review \(count) action\(count == 1 ? "" : "s")"
        }
        if message.hasPrefix("Approval required for ") {
            return "Waiting for your approval"
        }
        if message.hasPrefix("User approved ") {
            return "You approved this action"
        }
        if message.hasPrefix("risk.assessed:") {
            if message.localizedCaseInsensitiveContains("approval: Auto-run") {
                return "Safety check complete. No approval needed."
            }
            if message.localizedCaseInsensitiveContains("approval: Refuse") {
                return "Safety check complete. This action cannot run."
            }
            return "Safety check complete. Waiting for your approval."
        }
        if message.hasPrefix("risk.escalated:"), let reason = message.split(separator: ":", maxSplits: 2).last {
            return "This action needs extra care: \(String(reason).trimmingCharacters(in: .whitespaces))"
        }
        if message.hasPrefix("Recorded ") {
            return message.replacingOccurrences(of: "Recorded", with: "Saved", options: .anchored)
                + " to Recent Outputs"
        }
        if message.hasPrefix("Could not record recent artifacts:") {
            return message.replacingOccurrences(
                of: "Could not record recent artifacts:",
                with: "Could not add results to Recent Outputs:",
                options: .anchored
            )
        }
        return message
    }

    static func previewSideEffect(_ sideEffect: String) -> String {
        if sideEffect.hasPrefix("Write: ") {
            return "Creates " + String(sideEffect.dropFirst("Write: ".count))
        }
        if sideEffect.hasPrefix("Open: ") {
            return "Opens " + String(sideEffect.dropFirst("Open: ".count))
        }
        if sideEffect.hasPrefix("Convert: ") {
            return "Converts " + String(sideEffect.dropFirst("Convert: ".count))
        }
        return sideEffect
    }
}
