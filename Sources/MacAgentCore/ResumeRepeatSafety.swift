import Foundation

/// Whether repeating an operation that **may already have happened** is something Sonny may do
/// without asking (row 13, SONNY-210, PR #105 review F5).
///
/// **Why this exists at all, and why the risk engine cannot answer it.** Resuming an interrupted run
/// re-runs the unit that was in flight, because nothing can know how far into an adapter call the
/// power went. The branch's first answer was that this is safe because "a repeated unit goes through
/// the same risk assessment and the same approval gate any other run does" — true, and hollow for
/// most units, because under the consequence rule tier 1 and tier 2 auto-run and a prompt appears
/// only at tier 3 with a non-advisory escalation. The counterexample the review produced is exact:
/// `InvokeShortcutCapabilityAdapter.assessRisk` returns `.tier1` for a Shortcut with clean history,
/// so a chain `[create_local_draft, invoke_shortcut]` killed while the Shortcut was running offers
/// the Shortcut as remaining, and Continue fires it a second time with no prompt. If that Shortcut
/// sends a message, the message is sent twice — **an action that reaches someone other than the
/// user, taken without asking, which is the consequence rule's central case.**
///
/// **And `CapabilityRiskEscalation.Consequence.affectsOthers` cannot be read for this**, which is
/// the reason a second classification exists rather than a reuse. That case is *armed but empty*:
/// its own documentation says no v1 capability carries it, and `invoke_shortcut` raises no
/// escalation at all — it returns a bare tier. Asking the risk engine "does this affect others"
/// therefore returns no for the one operation that provably can.
///
/// **One-directional, which is what makes a second classification safe.** Nothing here can make an
/// action easier: the only thing it does is *withhold* Sonny's offer to continue. Every path it
/// gates already required the user to press Continue, and refusing to offer never lets anything run
/// that would not otherwise have run. That is the same shape `.claude/rules` requires of any
/// screen-derived signal — it may add scrutiny and never remove it.
public enum ResumeRepeatSafety: Equatable, Sendable {
    /// Doing it twice reaches nobody but the user and undoes nothing they have.
    case safeToRepeat
    /// Doing it twice could reach someone else, spend something, or hand work to something Sonny
    /// cannot see inside. Sonny does not offer to continue a task whose remaining work contains one.
    case mustNotRepeatSilently
}

extension AgentOperation {
    /// Whether repeating this operation is safe to do without asking.
    ///
    /// **Exhaustive with no `default`, and that is the point**: a new operation cannot be added
    /// without someone deciding whether Sonny may do it twice on its own. The bar is the founder's
    /// consequence rule — *does repeating it reach someone other than the user* — and not tidiness.
    /// A second local file, a second browser tab, a second identical save are all `.safeToRepeat`:
    /// they are untidy, the branch discloses them as a cost of resuming, and none of them is the
    /// class the rule protects.
    public var resumeRepeatSafety: ResumeRepeatSafety {
        switch self {
        case .invokeShortcut:
            // **The counterexample this classification was written for.** A Shortcut is a program
            // Sonny cannot see inside: it can send mail, post a message, or make a purchase, and
            // `assessRisk` gives it tier 1 once its history is clean. Repeating it is exactly the
            // silent double-send.
            return .mustNotRepeatSilently
        case .runRoutine:
            // A stored routine is a program Sonny cannot see inside *from the plan*: the step
            // carries a name, and the steps behind that name can change between the interruption
            // and the resume. `StoredRoutine.forbiddenStepOperations` keeps a vision session out of
            // one, but **not** `invoke_shortcut` — so a routine can wrap the case above.
            return .mustNotRepeatSilently
        case .visionSession:
            // It redoes whatever it did on screen, and screen actions are the one place this
            // product already models affects-others: `VisionConsequenceClassifier` carries a word
            // list for exactly that (`affectsOthersLabelWords`). What a repeated session clicks is
            // not knowable in advance, which is the same reason as the two above.
            return .mustNotRepeatSilently
        case .startWatching:
            // **The one `.mustNotRepeatSilently` here that is not about reaching someone else, and
            // it is deliberate** (SONNY-382). Repeating it reads a public page and writes a local
            // record — by the bar the three above use, that is `.safeToRepeat`. What it also does is
            // occupy a second of `StandingWatcherLimits.maxActive`'s five slots with a duplicate the
            // user cannot tell apart from the first, and then notify twice about one change, days
            // later, when nobody is present to connect the second banner to a resume they approved.
            // The founders' cap exists precisely to stop watchers accumulating unnoticed, so
            // creating one on Sonny's own initiative is the thing that cap is about. A user who
            // wants a second watcher asks for one.
            return .mustNotRepeatSilently
        case .unsupported:
            // Fails closed. It cannot execute, so this is an answer to a question that never gets
            // asked — and the safe direction for an operation whose meaning is "Sonny does not know
            // what this is" is the one that does not offer to do it twice.
            return .mustNotRepeatSilently

        case .scanSelectLargestFiles, .scanDocx, .getFinderSelection, .lookupClipboardHistory,
             .lookupRecentArtifacts, .calculateUtility, .showPermissionReadiness, .fetchHNHeadlines:
            // Reads. Repeating one changes nothing at all.
            return .safeToRepeat

        case .createZip, .convertDocxToPDF, .writeMarkdown, .createLocalDraft, .webToMarkdown:
            // Local writes, and the honest cost of repeating one is a **second file** rather than a
            // lost first: `create_local_draft` bumps a name that is taken rather than overwriting
            // it. Untidy, disclosed, and not the class the consequence rule protects. `web_to_markdown`
            // also re-fetches — public pages, read-only — and re-spends a model call the user has
            // just asked for by pressing Continue.
            return .safeToRepeat

        case .openApp, .openAppSearchURL, .openURL, .openHackerNews, .openGeneratedArtifact,
             .revealInFinder, .switchRunningApp, .playMedia, .openWorkspace:
            // Opening or showing something. Repeating one leaves a duplicate window or tab and
            // reaches nobody. `open_url` is restricted to validated http/https by
            // `OpenSafeURLCapabilityAdapter`, and whatever a first fetch of that URL did, it did on
            // the first run too — resuming does not widen it.
            return .safeToRepeat

        case .expandSnippet:
            // Returns the snippet's text as the run's summary and touches nothing else — no
            // pasteboard, no file. Repeating it produces the same sentence twice, which is as close
            // to free as a repeat gets. (This comment claimed a pasteboard write until PR #105's
            // re-check read `SnippetExpansionCapabilityAdapter.execute`: the classification was
            // right and the reason given for it was describing a stronger effect than the code has.)
            return .safeToRepeat

        case .rename:
            // **Safe, and the reasoning is the collision rule rather than a judgement about how bad
            // a second rename would be** (SONNY-385). Repeating a rename that already finished finds
            // no source and fails; repeating one where the user has since put a new file at the old
            // path finds the destination occupied and is refused by name. Neither outcome destroys
            // anything, and neither reaches anyone but the user, which is this classification's bar.
            //
            // It is also never a *silent* repeat, which is what this property is actually about:
            // `RenameCapabilityAdapter.assessRisk` raises an unconditional `.destructive`
            // escalation, so every rename asks — on a resume exactly as on a first run.
            return .safeToRepeat

        case .saveRoutine, .saveSnippet, .createWorkspace, .editWorkspace:
            // Writes to Sonny's own stores, with the same content the interrupted attempt carried —
            // so a repeat is idempotent in content rather than destructive. They stay
            // `.safeToRepeat` deliberately: the destructive class in the consequence rule is about
            // replacing something *the user already had*, and a repeat of the very save that was in
            // flight replaces it with itself.
            return .safeToRepeat

        case .clarify:
            // Never executes — it is how a run pauses to ask, and the executor throws rather than
            // running it. A plan that is only a clarification is resumable precisely because
            // nothing has happened.
            return .safeToRepeat
        }
    }
}
