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
    /// lives on the copy tests. Normal and Power both count as not-Safe here, and that is the whole
    /// of what this function needs from the mode — **not** that the two are alike. Power stopped
    /// being Normal-identical on 2026-08-21, when row J made it the one mode that skips the per-app
    /// gate; what is unchanged is that neither is Safe, so neither leaks the Safe-only label. A pure function on `firstRunApprovalExplainerLines`' precedent so the
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

/// What the widget's composer says while it is not taking a command (SONNY-247).
///
/// **The behaviour this describes is correct and is not what was broken.** The composer is disabled
/// whenever a task occupies the app, and it should be: starting a second task while one is parked on
/// your answer is not something the product allows, and the answer has its own field a few pixels
/// above. What was broken is that none of that was visible — the field kept the idle placeholder,
/// stopped responding, and swallowed a paste, which is indistinguishable from a hung app. The
/// founder reported it twice in one day, once as "I cannot type inside the floating widget nor
/// copy-paste anything" and once as "when a clarification question is asked, the typing bar doesn't
/// work".
///
/// **Three states, not one, and the split is the point.** `FloatingWidgetView.isTaskInFlight` is a
/// disjunction over seven conditions, and treating them alike is what produced a placeholder that
/// was wrong in every one of them. A question parked on you, with the control that answers it right
/// there, is a different situation from a run in flight with nothing here to type into, and they get
/// different sentences.
///
/// Nothing here explains how anything works, per the founder's rule of 2026-08-14. Each line is the
/// composer describing its own state or naming where to act — not a sentence about the feature.
enum ComposerPresentation {
    /// What the composer is doing. `FloatingWidgetView.composerState` maps the view model onto this,
    /// and derives its `isTaskInFlight` back out of it, so the gate that disables the field and the
    /// sentence that explains why can never disagree.
    enum State: CaseIterable {
        /// Nothing is in the way. The field takes a command and the Start button is there.
        case ready

        /// A question is parked on the user, and the control that answers it is the one in the panel
        /// above this composer.
        ///
        /// **"Above" is load-bearing, and what makes it true is a branch order, not a predicate**
        /// (PR #107 review, F1). The first version of this argued from
        /// `AgentViewModel.hasVisibleWidgetPanel` — which answers "is a panel visible" — and then
        /// concluded "is *that* panel visible". Those are different questions and the second was
        /// false: `FloatingWidgetView.state` returns the first branch that matches, and a live
        /// screen-control session outranks both the approval and the clarification there, so an
        /// approval raised mid-session left the widget showing the controlling HUD — the app, the
        /// step count, Pause and Stop — while this composer said "answer above" over a panel with
        /// no question in it. The classification now rules out every branch that outranks a
        /// condition before calling it `.waitingOnYou`, so the sentence is carried by the ordering
        /// rather than by a claim about it.
        ///
        /// **The example above is history now, and the ordering it describes has moved** —
        /// SONNY-255 put `.permission` above `.controlling`, because an approval raised inside a
        /// session was a question the widget rendered nowhere at all. So an approval is
        /// `.waitingOnYou` whether or not a session is live, and the composer points at a panel that
        /// really is on screen in both cases. What has not changed is the argument: this case is
        /// carried by a branch order rather than by a predicate, and the order is `state`'s.
        case waitingOnYou

        /// A run is in flight and there is nothing here for the user to type into.
        ///
        /// Deliberately *not* folded into `waitingOnYou`, for two separate reasons. The running
        /// branch of `hasVisibleWidgetPanel` is origin-gated, so a run a Command Center row action
        /// started shows no widget panel at all and a sentence pointing "above" would point at
        /// nothing. And a live screen-control session lands here, because the panel it puts on
        /// screen is a progress HUD rather than a question.
        ///
        /// **The second reason covers a narrower window than it used to** (SONNY-255). It read "even
        /// while something is pending underneath it", which was true and was a defect: what was
        /// pending was an approval the widget rendered on no surface. An approval now takes the
        /// panel, so a session lands here only while nothing is parked on the user — which is the
        /// state this case is meant to describe.
        case working
    }

    /// The field's placeholder, which is the only thing on this surface that can say why a click
    /// achieved nothing.
    static func prompt(for state: State) -> String {
        switch state {
        case .ready:
            return "Let Sonny take it from here\u{2026}"
        case .waitingOnYou:
            return "Answer above first\u{2026}"
        case .working:
            return "Sonny is working\u{2026}"
        }
    }

    /// Whether the field takes input. The one place this question is answered, so a control added to
    /// the composer later cannot invent its own idea of "in flight".
    static func acceptsInput(_ state: State) -> Bool {
        state == .ready
    }
}

/// The floating widget's text fields — the ones a caret can be in — and the rule for which of them
/// gets it (SONNY-283).
///
/// **One value for the whole widget rather than a `Bool` per field.** The composer and the
/// clarification panel's answer field used to each own a `@FocusState` of their own, so "put the
/// caret where typing can land" was two decisions in two views held together by a convention: the
/// composer's helper wrote `false` while a question was parked, and the panel claimed the caret on
/// appear. That covered the keyboard. It did not cover the push-to-talk hotkey, whose presentation
/// request reached only the composer's helper — which correctly declined to focus a disabled field
/// and then had nothing else to focus, so the hotkey did nothing while a question was pending. With
/// the widget owning one `FocusState<WidgetInputField?>`, every summon asks `takingInput` and the
/// answer field is reachable from the same place the composer is.
enum WidgetInputField: Equatable {
    /// The composer pill at the bottom of the widget.
    case composer
    /// The clarification panel's answer field, rendered only while a question is parked.
    case clarificationAnswer

    /// Where the caret belongs, or `nil` when nothing on the widget takes typing.
    ///
    /// The clarification panel wins outright: while it is on screen the composer is `.disabled`
    /// (`ComposerPresentation.State.waitingOnYou`), so the two arguments never both say yes, and
    /// asking about the panel first keeps the caret out of a dead field even if they did. The
    /// composer takes it only in the one state that accepts input. Everything else — an approval, a
    /// run in flight, a screen-control session — leaves the caret nowhere, which is what those
    /// panels' own controls need.
    static func takingInput(
        clarificationPanelShowing: Bool,
        composer: ComposerPresentation.State
    ) -> WidgetInputField? {
        if clarificationPanelShowing {
            return .clarificationAnswer
        }
        if ComposerPresentation.acceptsInput(composer) {
            return .composer
        }
        return nil
    }
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

/// The widget's offer to carry on with an unfinished task (row 13, SONNY-210).
///
/// What a live screen-control session says about itself, and what the control that ends it is
/// called — on **both** surfaces that can be asked something mid-session (SONNY-255, and PR #132's
/// F1 for the second of them).
///
/// **The words are shared; the views are not, and that split is the whole design of this type.** The
/// floating widget is System B and Command Center is System A, and
/// `.claude/rules/macagent-ui-conventions.md` forbids either one's tokens leaving its own surface —
/// so `WidgetSessionIdentityLine` (`FloatingWidgetView.swift`) and `CommandCenterSessionContextRow`
/// (`CommandCenterView.swift`) are two views by necessity. **The second of those did not exist when
/// this sentence first named it** (PR #132 cycle 2, N1): Command Center's half was an inline `HStack`
/// inside `CommandCenterAttentionPanel.permissionContent`, so the doc comment of the type built to
/// stop shared-words drift was itself carrying a fabricated symbol. It was extracted rather than the
/// sentence weakened, which is the direction this branch's whole subject argues for.
/// What must not be two is the *sentence*: a user who reads "Sonny is controlling Safari" in the
/// widget and something else in Command Center is looking at one session described two ways, and
/// nothing in either file would have caught the divergence. So the strings live here, once, and each
/// surface renders them with its own tokens.
///
/// **`stopLabel` is a word, not a tone.** It says what the control does — ends the session — which is
/// the point of it having a word at all: on both surfaces it replaced an unlabelled or
/// mislabelled refusal that ended the whole session while reading as a per-step decline.
enum ScreenControlSessionPresentation {
    /// The first half of the identity line. The app's own name is the second, rendered in each
    /// surface's emphasis font, which is why this is a prefix rather than a formatted whole.
    static let controllingPrefix = "Sonny is controlling "

    /// The identity line as one string, for a surface that renders it without the emphasis split —
    /// and for a test that wants to assert the sentence rather than its halves.
    static func controllingMessage(appDisplayName: String) -> String {
        controllingPrefix + appDisplayName
    }

    /// How far into the session's own budget this iteration is.
    static func stepLine(iteration: Int, maximumIterations: Int) -> String {
        "Step \(iteration) of \(maximumIterations)"
    }

    /// The control that ends the session, on both surfaces.
    static let stopLabel = "Stop"

    /// Its VoiceOver name, which names the app because "Stop" alone does not say what stops.
    static func stopAccessibilityLabel(appDisplayName: String) -> String {
        "Stop Sonny controlling \(appDisplayName)"
    }

    /// The HUD's Pause, which exists on the widget's controlling panel and on neither surface's
    /// approval panel — see `WidgetControllingPanel` for why a control that acts at the top of the
    /// next iteration is not offered while the loop is parked on a continuation.
    static func pauseAccessibilityLabel(appDisplayName: String) -> String {
        "Pause Sonny controlling \(appDisplayName)"
    }
}

/// **The founder's own sentence, and it says exactly what pressing Continue does.** The decision of
/// 2026-08-22 is that Sonny *offers* the unfinished task the next time the user opens the floating
/// widget — "you were partway through X, continue?" — rather than waiting in a list to be found and
/// rather than resuming on its own. The message here is the first half of that and the Continue
/// label is the second.
///
/// Nothing here explains how resuming works, per the founder's rule of 2026-08-14: not which steps
/// are left, not that a unit may re-run, not why the task stopped. What happened to the task is data
/// and belongs in the Memory row that lists it, which is where `MemoryEntryPresentation` puts it;
/// the offer is a question with two answers.
enum ResumeOfferPresentation {
    /// The affirmative's word. **Its tooltip since SONNY-244, not its visible text** — the founder's
    /// decision of 2026-08-23 made the two controls a tick and a cross. It is not the VoiceOver name;
    /// that is `continueAccessibilityLabel`, which names the task an icon no longer can. Whether a
    /// tooltip in the floating widget fires at all is genuinely in doubt — `WidgetResumeOfferPanel`
    /// carries the finding and what it means for these two words.
    static let continueLabel = "Continue"
    /// The cross's tooltip, on the same footing as `continueLabel`.
    ///
    /// **"Don't ask again", because that is now what the cross does** (SONNY-282, founder decision
    /// 2026-08-25). It read "Not now" while the offer came back at every launch, and the words were
    /// accurate — the founder pressed the cross three times across three relaunches anyway, because
    /// a × carries "close this, and be done with it" whatever its tooltip says. The behaviour moved
    /// to match the glyph rather than the other way round: the cross stops the offer for good and
    /// deletes nothing, so the task is still listed under Memory, where it can be continued or
    /// deleted. macOS's own phrase for exactly this control is "Don't ask again", and the label says
    /// no more than that — where the task went is data on the Memory row, not a sentence here.
    static let declineLabel = "Don't ask again"

    /// The width the message is actually drawn at: the panel's fixed 472pt less `styledPanel`'s
    /// 18pt of padding a side.
    ///
    /// **Here rather than in the view because the layout it feeds is a measured fact, not a taste**
    /// (SONNY-244). `theMessageNeverDrawsTallerThanThePanelReservesForIt` re-derives the numbers
    /// below from real font metrics, and it can only do that if they are reachable from a test.
    static let panelContentWidth: CGFloat = 436

    /// `WidgetType.caption` is SF Pro Regular 13, whose line height is 16pt
    /// (`NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 13))` → 16.0, asserted by that
    /// same test rather than trusted from this comment).
    static let messageLineHeight: CGFloat = 16

    /// The most lines the message may draw, and therefore the most it can ever be tall.
    ///
    /// **Two, because a truncated command lands within a whisker of the one-versus-two-line
    /// boundary and essentially always crosses it.** `maximumCommandCharacters` squeezes every long
    /// command into the same band: measured at 13pt, the founder's two reported messages are 530.5pt
    /// and 531.4pt on one line against 436pt of width, and a third realistic one is 524.7pt. So the
    /// panel is permanently balanced on that edge — every one of them wraps to two lines with about
    /// 95pt on the second.
    ///
    /// **A third line arrives two different ways, and a count of characters is not either of them**
    /// (PR #107 review, F5 and its re-check). This first said "a 60-character word with no space in
    /// it", then "a run wider than two 436pt lines hold". Both were wrong, and the second is
    /// disproved by its own examples — two 436pt lines hold 872pt and not one of the three crossings
    /// below reaches it. The two real mechanisms:
    ///
    /// - **No break opportunity inside the quoted phrase.** A command with no space in it makes the
    ///   whole quoted phrase one unbreakable run, because an opening quote binds to the word after
    ///   it and a closing quote and period bind to the word before. Once that run exceeds a
    ///   *single* 436pt line it cannot share line one with the lead-in and cannot fit on line two
    ///   either, so it takes a line of its own and spills onto a third. Measured at 13pt, the run
    ///   crosses 436 between `W` x33 (425.75pt) and `W` x34 (438.25pt), and between `w` x42
    ///   (432.40pt) and `w` x43 (442.39pt) — one threshold, two different character counts, which
    ///   is the whole reason a count cannot express this.
    /// - **Packing, where nothing is unbreakable at all.** CJK breaks between characters, so no run
    ///   is ever too wide; the message crosses because whole-character breaks leave part of each
    ///   line unused. 54 of them need three lines at a message width of 871.21pt — *under* the
    ///   872pt two lines nominally hold, which is the clearest statement of why "wider than two
    ///   lines" was never the property.
    ///
    /// This cap tail-truncates all of them rather than letting the panel grow, and
    /// `aThirdLineArrivesTwoWaysAndTheCapCoversBoth` holds both mechanisms with a control one
    /// character under each Latin crossing.
    static let messageLineLimit = 2

    /// The height the panel holds open for the message, whatever it turns out to measure.
    ///
    /// **This is the whole of SONNY-244's layout fix, and it is a fix to a measurement rather than
    /// to a stack.** The founder saw the offer's controls drawn on top of the message's second line,
    /// intermittently — the same view at the same message length laid out both ways minutes apart —
    /// which is what a `Text` measured at one width and drawn at another looks like once
    /// `.fixedSize(horizontal: false, vertical: true)` is on it: that modifier is precisely what
    /// turns "this text got less height than it needs" from a truncation into an overflow onto
    /// whatever sits below. And a mis-measure is *cheap* here for the reason `messageLineLimit`
    /// gives. The widget's own outer content is 568pt wide — a 472pt pill, 12pt, and two 36pt
    /// circular buttons 12pt apart — which leaves **532pt** inside this panel's 18pt padding, and
    /// 532pt clears all three real messages on one line: 530.5, 531.4 and 524.7, the tightest of
    /// them by **0.6pt**. Whether SwiftUI ever measures at that width is not something reading the
    /// source can settle; that the panel sits two thirds of a point from flipping is.
    /// `everyTruncatedMessageSitsWithinAWhiskerOfTheOneLineBoundary` re-derives the comparison from
    /// live font metrics — it asserts the relationship rather than these three figures, which are
    /// what that same measurement printed.
    ///
    /// Reserving the two lines makes the message's slot a constant the stack can compute without
    /// measuring anything, so the controls below it are placed at the same offset in every pass.
    /// `minHeight` rather than `height` so a future font that needs more still gets it.
    static let reservedMessageHeight: CGFloat = messageLineHeight * CGFloat(messageLineLimit)

    static func message(command: String) -> String {
        "You were partway through \u{201C}\(truncatedCommand(command))\u{201D}."
    }

    static func continueAccessibilityLabel(command: String) -> String {
        "Continue \u{201C}\(truncatedCommand(command))\u{201D}"
    }

    /// The cross's VoiceOver name. Names the task, because a 10pt glyph cannot, and promises exactly
    /// what the control does — no more, since "it stays under Unfinished tasks" would be the
    /// explanatory sentence the 2026-08-14 rule keeps out of the product.
    static func declineAccessibilityLabel(command: String) -> String {
        "Don't ask again about \u{201C}\(truncatedCommand(command))\u{201D}"
    }

    /// The panel is a fixed 472pt wide and a command is whatever the user typed, so this squeezes
    /// and then trims.
    ///
    /// **Newlines first, and the truncation alone would not cover it**: a short first line followed
    /// by ten more is well under any character budget and still eleven lines tall, which a dictated
    /// or pasted command really can be.
    ///
    /// Its own function rather than `FollowUpPresentation.truncatedCommand`, which is the nearest
    /// thing: that one has a different budget, no newline squeeze, and an empty-case wording written
    /// for a chip that says "Following up: …". Sharing it would mean one of the two callers reading
    /// wrong, and this is copy rather than a rule — the thing this repository consolidates is a rule
    /// that must not drift, not two sentences that happen to look alike.
    static func truncatedCommand(_ command: String) -> String {
        let squeezed = command
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !squeezed.isEmpty else {
            // Unreachable from a live run — `canSubmit` refuses an empty command — and answered
            // anyway, because this text comes back off disk. The Tasks list already calls a
            // command-less record "Untitled task"; the offer uses the same word for the same thing.
            return "an untitled task"
        }
        guard squeezed.count > maximumCommandCharacters else {
            return squeezed
        }
        let head = squeezed.prefix(maximumCommandCharacters)
        // Cut at the last space inside the budget when one leaves something readable, rather than
        // mid-word — the same rule the follow-up chip uses, at this panel's own width.
        if let lastSpace = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: lastSpace) >= 12 {
            return head[head.startIndex..<lastSpace] + "\u{2026}"
        }
        return head + "\u{2026}"
    }

    private static let maximumCommandCharacters = 60
}
