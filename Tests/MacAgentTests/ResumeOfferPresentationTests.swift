import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// The widget's offer to carry on with an unfinished task (row 13, SONNY-210) — its copy, and the
/// two wirings the founder's sign-off named as constraints.
///
/// The wiring pins are source scans because there is no way to drive SwiftUI here and no object to
/// interrogate: what is being held is where a branch sits in a precedence, and which token set a
/// panel is built from. `MacAgentSource.read` strips both comment syntaxes, so neither can be
/// satisfied by a sentence describing the code.
@MainActor
struct ResumeOfferPresentationTests {
    // MARK: - The copy

    /// The founder's own sentence, 2026-08-22: "you were partway through X, continue?" — the message
    /// is the first half and the button label is the second.
    @Test
    func theOfferNamesTheTaskAndTheButtonIsTheQuestionsAnswer() {
        #expect(
            ResumeOfferPresentation.message(command: "Zip my three largest files")
                == "You were partway through \u{201C}Zip my three largest files\u{201D}."
        )
        #expect(ResumeOfferPresentation.continueLabel == "Continue")
        #expect(ResumeOfferPresentation.dismissLabel == "Not now")
    }

    /// A long command is cut at a word boundary rather than mid-word, at this panel's own width.
    @Test
    func aLongCommandIsTruncatedAtAWordBoundary() {
        let long = "Zip my three largest files and then convert every document in the project folder to PDF"
        let truncated = ResumeOfferPresentation.truncatedCommand(long)

        #expect(truncated.count <= 61, "60 characters plus the ellipsis")
        #expect(truncated.hasSuffix("\u{2026}"))
        #expect(!truncated.dropLast().hasSuffix(" "), "cut at the space, not after it")
        #expect(long.hasPrefix(String(truncated.dropLast())))
    }

    /// **The squeeze the truncation alone cannot do.** A short first line followed by ten more is
    /// under any character budget and still eleven lines tall, which a pasted or dictated command
    /// really can be — and this panel is a fixed 472pt with one sentence in it.
    @Test
    func aMultiLineCommandBecomesOneLine() {
        let pasted = "Zip my files\n\nthen open the report\n  and email it"
        #expect(
            ResumeOfferPresentation.truncatedCommand(pasted)
                == "Zip my files then open the report and email it"
        )
    }

    /// Unreachable from a live run — `canSubmit` refuses an empty command — and answered anyway,
    /// because this text comes back off disk.
    @Test
    func aCommandlessRecordStillReadsAsASentence() {
        #expect(
            ResumeOfferPresentation.message(command: "   \n  ")
                == "You were partway through \u{201C}an untitled task\u{201D}."
        )
    }

    /// Nothing here explains how resuming works, per the founder's rule of 2026-08-14 — not which
    /// steps are left, not that a unit may re-run, not why the task stopped. What happened to the
    /// task is data and lives in the Memory row that lists it.
    @Test
    func noneOfTheOffersCopyExplainsHowItWorks() {
        let copy = [
            ResumeOfferPresentation.message(command: "Zip my files"),
            ResumeOfferPresentation.continueLabel,
            ResumeOfferPresentation.dismissLabel,
            ResumeOfferPresentation.continueAccessibilityLabel(command: "Zip my files"),
            ResumeOfferPresentation.dismissAccessibilityLabel(command: "Zip my files")
        ]
        let explanatory = ["step", "resume", "because", "Sonny will", "so that", "this means", "automatically"]
        for sentence in copy {
            for phrase in explanatory {
                #expect(
                    !sentence.localizedCaseInsensitiveContains(phrase),
                    "\u{201C}\(sentence)\u{201D} explains rather than asks"
                )
            }
        }
    }

    /// **Every Memory row's icon exists on the deployment target** (PR #105 review F3).
    ///
    /// `Package.swift` declares `.macOS(.v14)`. `Image(systemName:)` has no compile-time check and
    /// no runtime failure — a name the running system does not have simply renders nothing — so a
    /// symbol from a later SF Symbols release ships as a blank icon that nobody developing on a
    /// newer Mac can see. That is exactly what happened here: this row was
    /// `arrow.trianglehead.clockwise`, an SF Symbols 6 name, which is macOS 15.
    ///
    /// A test can't ask the system what a symbol's availability is, so this pins the set instead:
    /// changing one is a deliberate edit that comes here, and the note beside each name is the
    /// release it comes from.
    @Test
    func everyMemoryRowsIconIsAvailableOnTheDeploymentTarget() {
        let icons = MemoryCategory.allCases.map { ($0, MemoryRowPresentation.systemImageForTests(for: $0)) }
        let expected: [MemoryCategory: String] = [
            .routines: "repeat",                    // SF Symbols 1, macOS 11
            .workspaces: "rectangle.3.group",       // SF Symbols 1, macOS 11
            .taskHistory: "checklist",              // SF Symbols 3, macOS 12
            .recentArtifacts: "doc",                // SF Symbols 1, macOS 11
            .outputLocations: "folder",             // SF Symbols 1, macOS 11
            .clipboardHistory: "doc.on.clipboard",  // SF Symbols 1, macOS 11
            .snippets: "text.quote",                // SF Symbols 1, macOS 11
            .approvedApps: "app.badge.checkmark",   // SF Symbols 4, macOS 13
            .resumableTasks: "arrow.clockwise"      // SF Symbols 1, macOS 11
        ]
        for (category, icon) in icons {
            #expect(icon == expected[category], "\(category) renders \(icon)")
        }

        // And the family that bit: nothing in the shipped sources may name one, at any row.
        #expect(icons.allSatisfy { !$0.1.contains("trianglehead") })
    }

    // MARK: - Which dispatches continue the task in flight

    /// **Every route into `performStart` is classified, so a new one cannot arrive unclassified**
    /// (PR #105 review F1, and the re-enumeration that finding asked for).
    ///
    /// The defect: `performStart` drops its handle on the outstanding checkpoint at the top of every
    /// run. That is right for a run that is a *different* task and wrong for a run that is the *same
    /// task continuing* — and the answered-clarification door was the second kind while behaving
    /// like the first, so the answered run minted a second record and left the first as a live offer
    /// for a task that had finished. Patching that one door would have left the retry door, which
    /// has the identical shape and which this enumeration is what found.
    ///
    /// **The three doors that continue, and nothing else may.** `continueResumableTask` arms
    /// `.resuming` — it is rejoining a chain a finished unit already fed, so it carries that unit's
    /// file. `submitClarification` and `retryLastCommand` arm `.restarting` through one shared
    /// helper — nothing has executed, so there is nothing to carry. Every other dispatch is a task
    /// of its own and leaves the outstanding record exactly where it is, which is the founder's
    /// lifecycle rather than a leak.
    ///
    /// Counts rather than `contains`, per `MacAgentSource`'s own rule: a comment can add a token but
    /// cannot take one away, so a count sees both halves of a rewiring and a presence check sees
    /// neither.
    @Test
    func everyDispatchEntryPointDecidesWhetherItContinuesTheTaskInFlight() throws {
        let viewModel = try MacAgentSource.read("AgentViewModel.swift")

        // Exactly one arming site per kind, and the restart helper is declared once and called
        // twice — `submitClarification` and `retryLastCommand`.
        #expect(MacAgentSource.count(of: "pendingResumableContinuation = .resuming(task)", inText: viewModel) == 1)
        #expect(MacAgentSource.count(of: "pendingResumableContinuation = .restarting(task)", inText: viewModel) == 1)
        #expect(MacAgentSource.count(of: "armRestartOfTaskInFlight()", inText: viewModel) == 3)

        // The population of doors. `dispatch(...)` is the programmatic choke point every non-view
        // caller goes through, and `start(...)` is what it and the views call. A dispatch door added
        // later raises one of these and fails here until somebody decides which kind it is.
        let dispatchCallSites = MacAgentSource.count(of: "dispatch(", inText: viewModel)
            - MacAgentSource.count(of: "func dispatch(", inText: viewModel)
        #expect(
            dispatchCallSites == 7,
            """
            retryLastCommand (restart), runTaskAgain, runRoutineWidget, openWorkspaceWidget, \
            dispatchWorkspaceScopeEdit, dispatchTranscribedCommand, continueResumableTask (resume)
            """
        )

        // And the routes that reach `start(...)` without going through `dispatch` — the composer,
        // the answered clarification, the vision envelope, and the three Allow controls, which route
        // to `approvePendingRun` rather than starting anything.
        var startCallSites = 0
        for file in try MacAgentSource.appSourceFiles() {
            let text = try MacAgentSource.read(file)
            startCallSites += MacAgentSource.count(of: "start(", inText: text)
                - MacAgentSource.count(of: "func start(", inText: text)
                - MacAgentSource.count(of: "audioRecorder.start(", inText: text)
        }
        #expect(
            startCallSites == 7,
            """
            dispatch's own, submitClarification (restart), the vision envelope, the widget composer, \
            and three Allow controls (AppDelegate, CommandCenterView, FloatingWidgetView)
            """
        )
    }

    /// **F6/M32: the launch-time read is what makes the offer reach someone who never opens Command
    /// Center**, and no runtime assertion in this repository can reach an `NSApplicationDelegate`
    /// callback. Scanned in the shape `MemoryCommandCenterTests` already uses for three other
    /// wirings.
    @Test
    func theLaunchPathReadsTheUnfinishedTasksBeforeTheWidgetIsShown() throws {
        let delegate = try MacAgentSource.read("AppDelegate.swift")
        let launch = try MacAgentSource.braceBlock(
            of: delegate,
            openedBy: "func applicationDidFinishLaunching(_ notification: Notification) {"
        )

        #expect(MacAgentSource.count(of: "viewModel.refreshResumableTasks()", inText: launch) == 1)

        // Before the widget is shown, so the state exists by the time it renders.
        let read = try #require(launch.range(of: "viewModel.refreshResumableTasks()"))
        let show = try #require(launch.range(of: "widgetController.show()"))
        #expect(read.lowerBound < show.lowerBound)
    }

    /// **F6/M30: Continue starts a widget task, and the widget's own panel depends on it.**
    /// `hasVisibleWidgetPanel` gates both its running and its result branch on
    /// `activeTaskOrigin == .widget`, so a resumed run dispatched under any other origin shows
    /// nothing while it runs and no result when it ends — from a button in the widget.
    @Test
    func theResumeDispatchStatesTheWidgetOrigin() throws {
        let viewModel = try MacAgentSource.read("AgentViewModel.swift")
        let continueBody = try MacAgentSource.braceBlock(
            of: viewModel,
            openedBy: "func continueResumableTask(_ task: ResumableTask) -> Bool {"
        )
        #expect(MacAgentSource.count(of: "origin: .widget", inText: continueBody) == 1)
        #expect(MacAgentSource.count(of: "origin: .commandCenter", inText: continueBody) == 0)
        #expect(MacAgentSource.count(of: "origin: .scheduled", inText: continueBody) == 0)
    }

    /// **F6/M28 and F1's clearing site.** A run appends units only to its own record, and the line
    /// that holds that is `performStart`'s clear. Scanned because the runtime test for it
    /// (`aRunThatRecordsNothingDoesNotAppendItsStepsToTheLastRunsRecord`) proves the behaviour while
    /// this proves the clear is where the reset block is rather than somewhere a later edit moved it.
    @Test
    func performStartClearsItsHandleOnTheOutstandingCheckpoint() throws {
        let viewModel = try MacAgentSource.read("AgentViewModel.swift")
        // Four sites: `performStart`'s reset, the settle's delete branch, the per-entry delete,
        // and the wipe's in-memory clear. A fifth means somebody added a clearing site, which is
        // the change this test wants a reader to come and look at.
        #expect(MacAgentSource.count(of: "activeResumableTask = nil", inText: viewModel) == 4)
    }

    // MARK: - The two constraints the widget placement creates

    /// **System B only.** The floating widget's tokens are `WidgetTheme`/`WidgetType`; `SonnyTheme`
    /// and `SonnyType` are Command Center's and the two sets are deliberately separate rather than
    /// variants of each other. The founder restated the constraint on this specific panel when
    /// signing the design off on 2026-08-22, so it is held rather than assumed.
    @Test
    func theOfferPanelIsBuiltFromSystemBTokensOnly() throws {
        let panel = try MacAgentSource.braceBlock(
            of: MacAgentSource.read("FloatingWidgetView.swift"),
            openedBy: "private struct WidgetResumeOfferPanel: View {"
        )

        #expect(panel.contains("WidgetTheme."))
        #expect(panel.contains("WidgetType."))
        #expect(!panel.contains("SonnyTheme."), "System A tokens do not belong in the widget")
        #expect(!panel.contains("SonnyType."))
        #expect(!panel.contains("SonnyRadius."))
    }

    /// **Where the offer sits in the widget's precedence, pinned by position.**
    ///
    /// CLAUDE.md records this precedence as already delicate: it picks `.failure` ahead of `.result`,
    /// and a bookkeeping write failure routed into `errorMessage` twice replaced the result of a task
    /// that had succeeded. The offer is a fifth thing competing for the same panel, and the whole of
    /// its safety is that it is below every state describing the task the user is doing *now*. A
    /// branch moved above `.failure` would hide the reason a run stopped behind an offer to try
    /// again; above `.result` it would displace a finished task's answer.
    ///
    /// Asserted by *order within the property*, not by presence: a token can be added by a trailing
    /// comment, and presence would be satisfied by a branch sitting anywhere at all.
    @Test
    func theOfferIsTheLastBranchOfTheWidgetsPrecedenceBeforeIdle() throws {
        let state = try MacAgentSource.braceBlock(
            of: MacAgentSource.read("FloatingWidgetView.swift"),
            openedBy: "private var state: WidgetState {"
        )

        let failure = try #require(state.range(of: "return .failure(error)"))
        let result = try #require(state.range(of: "return .result(viewModel.finalSummary, suggestion)"))
        let offer = try #require(state.range(of: "return .resumeOffer(offer)"))
        let idle = try #require(state.range(of: "return .idle"))

        #expect(failure.lowerBound < offer.lowerBound, "a failure outranks the offer")
        #expect(result.lowerBound < offer.lowerBound, "a result outranks the offer")
        #expect(offer.lowerBound < idle.lowerBound, "the offer outranks nothing but idle")
    }

    /// `AgentViewModel.hasVisibleWidgetPanel` mirrors that precedence and the widget's panel does not
    /// render without it — so the offer's branch has to sit in the same place there too, after the
    /// summary check and before the final `false`.
    @Test
    func theViewModelsPanelPredicatePutsTheOfferInTheSamePlace() throws {
        let predicate = try MacAgentSource.braceBlock(
            of: MacAgentSource.read("AgentViewModel.swift"),
            openedBy: "var hasVisibleWidgetPanel: Bool {"
        )

        let summary = try #require(predicate.range(of: "if !finalSummary.isEmpty {"))
        let offer = try #require(predicate.range(of: "if resumeOffer != nil {"))
        let end = try #require(predicate.range(of: "return false"))

        #expect(summary.lowerBound < offer.lowerBound)
        #expect(offer.lowerBound < end.lowerBound)
    }
}
