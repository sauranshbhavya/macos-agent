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

    /// **Every dispatch door is classified, and the classification is checked — not just the
    /// population** (PR #105 review F1, and its re-check).
    ///
    /// The defect this exists for: `performStart` drops its handle on the outstanding checkpoint at
    /// the top of every run, which is right for a run that is a *different* task and wrong for a run
    /// that is the *same task continuing*. Three doors were wrong at one point or another —
    /// `submitClarification` (reported), `retryLastCommand` (found by enumerating), and
    /// `runTaskAgain` (found by the re-check, *while this test was green and naming it*).
    ///
    /// **That last one is why this test changed shape.** The first version counted call sites and
    /// listed the doors in its failure message. It pinned that no door could arrive *unclassified*,
    /// and it said nothing about whether the classification was *right* — so `runTaskAgain` sat in
    /// its own message as one of the seven while being the one that was wrong. A scan that lists a
    /// door and mis-classifies it is worse than one that misses it, because it reads as coverage.
    ///
    /// So each door is now named with the answer it is supposed to give, and the answer is read off
    /// its own body. The count assertions stay underneath: they are what forces a *new* door into
    /// the table rather than past it.
    ///
    /// **What this still cannot see, and it is worth saying rather than leaving to be discovered:**
    /// a body that arms too *late* — after the `dispatch` it was meant to precede — still reads as
    /// arming. This pins **classification**; the behavioural tests in `ResumableTaskRunTests` are
    /// what pin **timing**, by running each door and reading the store back. Neither is redundant:
    /// this one catches a door that never arms at all, including one added later that no behavioural
    /// test knows exists, and those catch an arm that is present and useless.
    @Test
    func everyDispatchDoorIsClassifiedAndTheClassificationIsChecked() throws {
        let viewModel = try MacAgentSource.read("AgentViewModel.swift")

        /// The three ways a door says "this dispatch continues the task the record describes".
        /// `pendingResumableContinuation = nil` is deliberately not one of them — that is a door
        /// *dropping* an arm it could not use, which every door is free to do.
        let armingTokens = [
            "armRestartOfTaskInFlight()",
            "armRestartOfRecordedTask(record)",
            "pendingResumableContinuation = .resuming(task)"
        ]

        let doors: [(name: String, anchor: String, continuesTheTask: Bool)] = [
            // Continues: the same task starting over, or picking up where it stopped.
            ("retryLastCommand", "func retryLastCommand(origin: TaskOrigin = .widget) {", true),
            ("runTaskAgain", "func runTaskAgain(_ record: CompletedTaskRecord) -> Bool {", true),
            ("submitClarification", "func submitClarification() {", true),
            ("continueResumableTask", "func continueResumableTask(_ task: ResumableTask) -> Bool {", true),
            // A task of its own. Each leaves any outstanding record exactly where it is, which is
            // the founder's lifecycle rather than a leak: an unfinished task survives the user
            // doing something else.
            ("runRoutineWidget", "func runRoutineWidget(_ routine: StoredRoutine) {", false),
            ("openWorkspaceWidget", "func openWorkspaceWidget(_ workspace: StoredWorkspace) {", false),
            (
                "dispatchWorkspaceScopeEdit",
                "func dispatchWorkspaceScopeEdit(_ edit: WorkspaceScopeEditDispatch) -> Bool {",
                false
            ),
            (
                "dispatchTranscribedCommand",
                "func dispatchTranscribedCommand(_ transcript: String, origin: TaskOrigin = .widget) {",
                false
            )
        ]

        for door in doors {
            let body = try MacAgentSource.braceBlock(of: viewModel, openedBy: door.anchor)

            // The row really names a door, so a table entry cannot drift onto a function that
            // dispatches nothing and quietly stop covering anything.
            let dispatches = MacAgentSource.count(of: "dispatch(", inText: body)
                + MacAgentSource.count(of: "start(", inText: body)
            #expect(dispatches > 0, "\(door.name) is in the door table but dispatches nothing")

            let arms = armingTokens.contains { MacAgentSource.count(of: $0, inText: body) > 0 }
            #expect(
                arms == door.continuesTheTask,
                door.continuesTheTask
                    ? "\(door.name) is the same task continuing and must arm a continuation"
                    : "\(door.name) is a task of its own and must not arm one"
            )
        }

        // The arming sites themselves, so an arm cannot be added somewhere the table above does not
        // look. One `.resuming` (the resume door), and two `.restarting` — one inside each restart
        // helper, which is what makes the two helpers two rather than one with a branch.
        #expect(MacAgentSource.count(of: "pendingResumableContinuation = .resuming(task)", inText: viewModel) == 1)
        #expect(MacAgentSource.count(of: "pendingResumableContinuation = .restarting(task)", inText: viewModel) == 2)
        // Three: the declaration plus its two callers — the declaration takes no argument, so it
        // matches the same text a call does.
        #expect(MacAgentSource.count(of: "armRestartOfTaskInFlight()", inText: viewModel) == 3)
        // One: its single caller. The declaration takes a labelled parameter, so it does not match.
        #expect(MacAgentSource.count(of: "armRestartOfRecordedTask(record)", inText: viewModel) == 1)

        // The population, which is what forces a new door into the table rather than past it.
        // `dispatch` is private to this file, so every one of its call sites is here.
        let dispatchCallSites = MacAgentSource.count(of: "dispatch(", inText: viewModel)
            - MacAgentSource.count(of: "func dispatch(", inText: viewModel)
        #expect(dispatchCallSites == 7, "a dispatch call site was added or removed — classify it above")
        #expect(
            doors.count == dispatchCallSites + 1,
            "the table is the seven dispatch callers plus submitClarification, which reaches start() directly"
        )

        // And the routes into `performStart` that do not go through `dispatch`, counted across every
        // app source file: `dispatch`'s own, `submitClarification`'s, the vision envelope's, the
        // widget composer's, and three Allow controls that answer a pending approval rather than
        // starting anything.
        var startCallSites = 0
        for file in try MacAgentSource.appSourceFiles() {
            let text = try MacAgentSource.read(file)
            startCallSites += MacAgentSource.count(of: "start(", inText: text)
                - MacAgentSource.count(of: "func start(", inText: text)
                - MacAgentSource.count(of: "audioRecorder.start(", inText: text)
        }
        #expect(startCallSites == 7, "a route into performStart was added or removed — classify it above")
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
