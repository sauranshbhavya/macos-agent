import AppKit
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
    ///
    /// **The cross's word changed with its behaviour** (SONNY-282, founder decision 2026-08-25). It
    /// read "Not now" while the offer came back at every launch, which was accurate and did not
    /// help: the founder pressed it three times across three relaunches expecting it to stop. The
    /// cross now stops the offer for good and deletes nothing, and the tooltip says exactly that
    /// much — where the task went is data on the Memory row, not a sentence here.
    @Test
    func theOfferNamesTheTaskAndTheButtonIsTheQuestionsAnswer() {
        #expect(
            ResumeOfferPresentation.message(command: "Zip my three largest files")
                == "You were partway through \u{201C}Zip my three largest files\u{201D}."
        )
        #expect(ResumeOfferPresentation.continueLabel == "Continue")
        #expect(ResumeOfferPresentation.declineLabel == "Don't ask again")
        #expect(
            ResumeOfferPresentation.declineAccessibilityLabel(command: "Zip my three largest files")
                == "Don't ask again about \u{201C}Zip my three largest files\u{201D}"
        )
        // The old word may not come back by accident: it promised a return the cross no longer makes.
        #expect(!ResumeOfferPresentation.declineLabel.localizedCaseInsensitiveContains("not now"))
        #expect(
            !ResumeOfferPresentation.declineAccessibilityLabel(command: "Zip my files")
                .localizedCaseInsensitiveContains("not now")
        )
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
            ResumeOfferPresentation.declineLabel,
            ResumeOfferPresentation.continueAccessibilityLabel(command: "Zip my files"),
            ResumeOfferPresentation.declineAccessibilityLabel(command: "Zip my files")
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
            (
                "continueResumableTask",
                "func continueResumableTask(_ task: ResumableTask, origin: TaskOrigin) -> Bool {",
                true
            ),
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

    /// **F6/M30: Continue starts a task under the origin of the surface it was pressed on, and the
    /// widget's own panel depends on it.** `hasVisibleWidgetPanel` gates both its running and its
    /// result branch on `activeTaskOrigin == .widget`, so a resumed run dispatched from the widget
    /// under any other origin shows nothing while it runs and no result when it ends — from a
    /// button in the widget — and one dispatched from Command Center under `.widget` would move its
    /// progress into the widget while Command Center kept showing its own.
    ///
    /// **Two doors since SONNY-282**, so the origin is a parameter the body passes through untouched
    /// and each caller states its own: the widget's offer says `.widget`, the Memory sheet's row —
    /// through `continueUnfinishedTask(at:)` — says `.commandCenter`. Counted at all three sites,
    /// because a literal creeping back into the body would silently make one of the two callers a
    /// liar.
    @Test
    func eachResumeDoorStatesItsOwnOrigin() throws {
        let viewModel = try MacAgentSource.read("AgentViewModel.swift")
        let continueBody = try MacAgentSource.braceBlock(
            of: viewModel,
            openedBy: "func continueResumableTask(_ task: ResumableTask, origin: TaskOrigin) -> Bool {"
        )
        #expect(MacAgentSource.count(of: "origin: origin", inText: continueBody) == 1)
        #expect(MacAgentSource.count(of: "origin: .widget", inText: continueBody) == 0)
        #expect(MacAgentSource.count(of: "origin: .commandCenter", inText: continueBody) == 0)
        #expect(MacAgentSource.count(of: "origin: .scheduled", inText: continueBody) == 0)

        let memoryDoor = try MacAgentSource.braceBlock(
            of: viewModel,
            openedBy: "func continueUnfinishedTask(at index: Int) -> Bool {"
        )
        #expect(
            MacAgentSource.count(of: "continueResumableTask(resumableTasks[index], origin: .commandCenter)", inText: memoryDoor) == 1
        )

        let widget = try MacAgentSource.read("FloatingWidgetView.swift")
        #expect(MacAgentSource.count(of: "viewModel.continueResumableTask(task, origin: .widget)", inText: widget) == 1)
        #expect(MacAgentSource.count(of: "continueResumableTask(", inText: widget) == 1, "the widget has exactly one Continue")
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

    // MARK: - The layout defect (SONNY-244)

    /// **The message can never draw taller than the panel holds open for it, at any width.**
    ///
    /// This is the correctness condition for SONNY-244's fix, and it is the only part of that fix a
    /// test can reach: the founder saw the offer's two controls drawn on top of the message's second
    /// line, intermittently, and no agent can see this panel render. So what is held here is the
    /// arithmetic the reservation rests on — the caption font's real line height, and the real
    /// wrapped height of the real messages at the width they are really drawn at.
    ///
    /// **The `> reserved` case at the end is not a contradiction, it is the reason `lineLimit`
    /// exists.** A 60-character command with no space in it is the one input that needs a third
    /// line; the cap tail-truncates it rather than letting it grow the panel, so the drawn height
    /// stays inside the reservation even there. Remove the cap and this reservation stops being
    /// sufficient — the two are one mechanism.
    @Test
    func theMessageNeverDrawsTallerThanThePanelReservesForIt() {
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

        // The constant in the source is a measurement, so it is measured rather than trusted.
        #expect(lineHeight == ResumeOfferPresentation.messageLineHeight)
        #expect(
            ResumeOfferPresentation.reservedMessageHeight
                == ResumeOfferPresentation.messageLineHeight * CGFloat(ResumeOfferPresentation.messageLineLimit)
        )

        func drawnHeight(_ message: String, width: CGFloat) -> CGFloat {
            (message as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            ).height
        }

        let width = ResumeOfferPresentation.panelContentWidth

        // The two the founder reported, plus a third long command with no URL in it.
        let atTheBudget = [
            "summarize https://news.ycombinator.com and save it as a markdown file on my desktop",
            "summarize https://en.wikipedia.org/wiki/Machine_learning and save it to my desktop",
            "Convert every document in the project folder to PDF and then email the results to my team lead"
        ]
        for command in atTheBudget {
            let message = ResumeOfferPresentation.message(command: command)
            let height = drawnHeight(message, width: width)
            // Two lines, not one — which is why two are reserved rather than one. A copy or budget
            // change that puts these back on a single line should come here and shrink the
            // reservation rather than leave a line of empty panel behind.
            #expect(height > ResumeOfferPresentation.messageLineHeight, "\u{201C}\(message)\u{201D} fits on one line")
            #expect(height <= ResumeOfferPresentation.reservedMessageHeight, "\u{201C}\(message)\u{201D} needs \(height)pt")
        }

        // A short command is one line, and still sits inside the same reserved box.
        #expect(
            drawnHeight(ResumeOfferPresentation.message(command: "Zip my three largest files"), width: width)
                <= ResumeOfferPresentation.reservedMessageHeight
        )

        // The cap's own case: a single unbreakable word at the truncation budget needs three lines,
        // and is the only realistic input that does.
        let unbreakable = String(repeating: "w", count: 200)
        #expect(
            drawnHeight(ResumeOfferPresentation.message(command: unbreakable), width: width)
                > ResumeOfferPresentation.reservedMessageHeight
        )
    }

    /// **A third line arrives two different ways, and the cap has to cover both** (PR #107 review,
    /// F5 and its re-check).
    ///
    /// `messageLineLimit`'s doc first named a character count, then named a width — "wider than two
    /// 436pt lines hold" — and that second wording was disproved by its own examples: two lines hold
    /// 872pt and none of the three crossings reaches it. So this holds the mechanisms rather than an
    /// outcome, which is what stops the claim drifting back to a number a third time:
    ///
    /// - a Latin command with no space in it makes the quoted phrase one unbreakable run, and it
    ///   crosses when that run exceeds a **single** line;
    /// - CJK breaks between characters, so nothing is unbreakable and it crosses on **packing**,
    ///   at a message width still under what two lines nominally hold.
    ///
    /// Each Latin script gets its crossing *and* the character below it, so the assertions read a
    /// boundary rather than a constant — and the two boundaries land at different counts, which is
    /// the whole reason a count cannot express this.
    @Test
    func aThirdLineArrivesTwoWaysAndTheCapCoversBoth() {
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let width = ResumeOfferPresentation.panelContentWidth

        func rendered(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        func naturalHeight(_ command: String) -> CGFloat {
            (ResumeOfferPresentation.message(command: command) as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            ).height
        }
        /// The run with no break opportunity inside it: an opening quote binds to the word after it,
        /// a closing quote and period to the word before, so the whole quoted phrase is one run.
        func quotedRun(_ command: String) -> String {
            "\u{201C}\(command)\u{201D}."
        }

        // Mechanism one: the unbreakable run crossing a *single* line.
        let latin: [(script: String, character: String, fits: Int, crosses: Int)] = [
            (script: "uppercase W", character: "W", fits: 33, crosses: 34),
            (script: "lowercase w", character: "w", fits: 42, crosses: 43)
        ]
        for run in latin {
            let below = String(repeating: run.character, count: run.fits)
            let above = String(repeating: run.character, count: run.crosses)

            #expect(rendered(quotedRun(below)) <= width, "\(run.script) x\(run.fits) still fits one line")
            #expect(rendered(quotedRun(above)) > width, "\(run.script) x\(run.crosses) exceeds one line")

            #expect(
                naturalHeight(below) <= ResumeOfferPresentation.reservedMessageHeight,
                "\(run.script) x\(run.fits) is the control — two lines, inside the reservation"
            )
            #expect(
                naturalHeight(above) > ResumeOfferPresentation.reservedMessageHeight,
                "\(run.script) x\(run.crosses) needs the third line the cap exists to refuse"
            )
        }

        // One threshold, two counts — the reason the property is a width and never a count.
        #expect(Set(latin.map { $0.crosses }).count == latin.count)

        // Mechanism two: nothing unbreakable, so it crosses on packing instead — and it does so at a
        // message width *under* what two lines nominally hold, which is what disproves the wording
        // this test replaced.
        let packed = String(repeating: "\u{6F22}", count: 54)
        let twoLinesNominally = width * CGFloat(ResumeOfferPresentation.messageLineLimit)
        let packedMessage = ResumeOfferPresentation.message(command: packed)
        #expect(rendered(packedMessage) < twoLinesNominally, "under 872pt, and still three lines")
        #expect(naturalHeight(packed) > ResumeOfferPresentation.reservedMessageHeight)
        #expect(
            rendered(quotedRun(packed)) > width,
            "wider than a line, yet it is not the unbreakable-run mechanism — every character breaks"
        )
        #expect(
            naturalHeight(String(repeating: "\u{6F22}", count: 53)) <= ResumeOfferPresentation.reservedMessageHeight,
            "53 still packs into two lines — 54 is the crossing"
        )
    }

    /// **Why a mis-measured height is reachable at all, recorded as a number rather than a story.**
    ///
    /// The addendum on SONNY-244 is that the overlap is intermittent — the same view at the same
    /// message length laid out both ways minutes apart — which is what a `Text` measured at one width
    /// and drawn at another looks like. This pins how little slack there is: every message the
    /// truncation budget produces is *just* over one line at the panel's own 436pt, and *just* under
    /// one line at 532pt, which is the width left inside this panel's 18pt padding if it were ever
    /// measured against the widget's own outer content instead (472 pill + 12 + 36 + 12 + 36 = 568).
    ///
    /// A failure here is not a regression; it is the hazard changing shape. Whoever sees it should
    /// re-read `ResumeOfferPresentation.reservedMessageHeight` and decide whether the reservation is
    /// still the right size, not "fix" this number.
    @Test
    func everyTruncatedMessageSitsWithinAWhiskerOfTheOneLineBoundary() {
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let widgetOuterContentWidth: CGFloat = 472 + 12 + 36 + 12 + 36
        let mismeasuredWidth = widgetOuterContentWidth - 36

        for command in [
            "summarize https://news.ycombinator.com and save it as a markdown file on my desktop",
            "summarize https://en.wikipedia.org/wiki/Machine_learning and save it to my desktop",
            "Convert every document in the project folder to PDF and then email the results to my team lead"
        ] {
            let message = ResumeOfferPresentation.message(command: command)
            let singleLineWidth = (message as NSString).size(withAttributes: [.font: font]).width
            #expect(singleLineWidth > ResumeOfferPresentation.panelContentWidth, "wraps where it is drawn")
            #expect(singleLineWidth <= mismeasuredWidth, "and does not wrap where it could be measured")
        }
    }

    /// **The reservation and the cap are the fix, and neither survives alone.**
    ///
    /// Scanned rather than asserted at runtime for the reason every wiring pin in this file is: there
    /// is no way to drive SwiftUI here. What a later edit must not be able to do quietly is delete
    /// one of the two lines that make the message's slot a constant — the controls below it are
    /// placed off that constant, and a measured height is what put them on top of the sentence.
    @Test
    func theMessagesHeightIsReservedRatherThanMeasured() throws {
        let panel = try MacAgentSource.braceBlock(
            of: MacAgentSource.read("FloatingWidgetView.swift"),
            openedBy: "private struct WidgetResumeOfferPanel: View {"
        )

        #expect(MacAgentSource.count(of: ".lineLimit(ResumeOfferPresentation.messageLineLimit)", inText: panel) == 1)
        #expect(
            MacAgentSource.count(of: ".frame(minHeight: ResumeOfferPresentation.reservedMessageHeight)", inText: panel) == 1
        )
        // `minHeight`, not `height`: a font that ever needs more than the reservation must still get
        // it, which is the difference between a floor and a cage.
        #expect(MacAgentSource.count(of: ".frame(height: ResumeOfferPresentation.reservedMessageHeight)", inText: panel) == 0)
    }

    // MARK: - The founder's tick and cross (SONNY-244)

    /// **Two glyphs, and only the affirmative is tinted.**
    ///
    /// The founder's decision of 2026-08-23 replaced the two text buttons with a tick and a cross.
    /// The thing that decision could quietly cost is the distinction the words were carrying: with
    /// no text on either control, the tint is the whole of what separates "carry on" from "leave
    /// it". So the count is what is held — one tinted background and one untinted — rather than the
    /// mere presence of a tint, which a second tinted control would satisfy just as well.
    @Test
    func theOffersControlsAreATickAndACrossWithOnlyTheAffirmativeTinted() throws {
        let panel = try MacAgentSource.braceBlock(
            of: MacAgentSource.read("FloatingWidgetView.swift"),
            openedBy: "private struct WidgetResumeOfferPanel: View {"
        )

        #expect(MacAgentSource.count(of: "Image(systemName: \"checkmark\")", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "Image(systemName: \"xmark\")", inText: panel) == 1)
        // Both are SF Symbols 1 (macOS 11), inside `Package.swift`'s `.macOS(.v14)` deployment
        // target — the availability trap `everyMemoryRowsIconIsAvailableOnTheDeploymentTarget`
        // records, where a later symbol ships as a blank circle nobody developing on a newer Mac
        // can see.
        #expect(!panel.contains("trianglehead"))

        #expect(MacAgentSource.count(of: "widgetCircularBackground(tint: WidgetTheme.primaryAction)", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "widgetCircularBackground()", inText: panel) == 1)

        // One `Text` left in the panel: the message. A control that grew a label back would be a
        // third, and a control that lost its glyph would be caught above.
        #expect(MacAgentSource.count(of: "Text(", inText: panel) == 1)
    }

    /// **An icon-only control names itself twice, and the two names are different on purpose.**
    ///
    /// `.help` carries a word on hover — "Continue", "Don't ask again" — which is the right length
    /// for a tooltip over a 23pt circle. `.accessibilityLabel` keeps the full sentence naming the
    /// task, which matters *more* once there is no visible text, not less: it is the only place
    /// left that says which unfinished task the tick belongs to.
    ///
    /// Counted per token, both sides, so a swap is visible: wiring the cross's sentence onto the tick
    /// leaves one token absent and the other doubled.
    @Test
    func eachControlCarriesAHoverWordAndAVoiceOverSentenceNamingTheTask() throws {
        let panel = try MacAgentSource.braceBlock(
            of: MacAgentSource.read("FloatingWidgetView.swift"),
            openedBy: "private struct WidgetResumeOfferPanel: View {"
        )

        #expect(MacAgentSource.count(of: ".help(ResumeOfferPresentation.continueLabel)", inText: panel) == 1)
        #expect(MacAgentSource.count(of: ".help(ResumeOfferPresentation.declineLabel)", inText: panel) == 1)
        #expect(
            MacAgentSource.count(
                of: ".accessibilityLabel(ResumeOfferPresentation.continueAccessibilityLabel(command: command))",
                inText: panel
            ) == 1
        )
        #expect(
            MacAgentSource.count(
                of: ".accessibilityLabel(ResumeOfferPresentation.declineAccessibilityLabel(command: command))",
                inText: panel
            ) == 1
        )

        // The sentences still name the task — the whole reason they are the VoiceOver name rather
        // than the tooltip.
        #expect(ResumeOfferPresentation.continueAccessibilityLabel(command: "Zip my files").contains("Zip my files"))
        #expect(ResumeOfferPresentation.declineAccessibilityLabel(command: "Zip my files").contains("Zip my files"))
    }

    /// **The cross declines the offer for good; the tick continues** (SONNY-282).
    ///
    /// This used to hold that the cross was wired to the same "not now" closure the labelled button
    /// had been, and recorded the ambiguity — does a cross read as "close this panel" or as an
    /// answer? — as a question for the founder's manual pass. The pass answered it: the founder
    /// pressed the cross three times across three relaunches expecting the offer to stop. What is
    /// held now is that the glyph is wired to `onDecline`, which the view hands
    /// `declineResumeOffer()` — the persisted decline — and not to any closure that only hides the
    /// panel for a session.
    @Test
    func theCrossIsWiredToDeclineAndTheTickToContinue() throws {
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")
        let panel = try MacAgentSource.braceBlock(
            of: widget,
            openedBy: "private struct WidgetResumeOfferPanel: View {"
        )

        #expect(MacAgentSource.count(of: "Button(action: onDecline) {", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "Button(action: onContinue) {", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "onDismiss", inText: panel) == 0, "the session-only closure is gone from this panel")

        // The view hands the cross the persisted decline, and nothing else in the widget calls it.
        #expect(MacAgentSource.count(of: "onDecline: { viewModel.declineResumeOffer() }", inText: widget) == 1)
        #expect(MacAgentSource.count(of: "declineResumeOffer()", inText: widget) == 1)
        #expect(MacAgentSource.count(of: "dismissResumeOffer", inText: widget) == 0)
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
            openedBy: "var state: WidgetState {"
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
