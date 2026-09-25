import Combine
import Foundation
import MacAgentTestSupport
import Testing
import UserNotifications
@testable import MacAgent
@testable import MacAgentCore

// MARK: - SONNY-533: a Retry re-runs the task its banner was posted for, and no other

/// The "Task failed" notification's Retry, driven through the real dispatch path: a real failure
/// raised by `performStart`, the announcement `AppDelegate` posts from, and the door that
/// announcement's address opens.
///
/// **Every test here asks which task ran, and answers it from the planner**, because that is the
/// only place the answer cannot be faked: a Retry that reaches the wrong task still starts a run,
/// still clears the failure and still goes idle, so every property of the view model looks the same
/// either way. The planner is asked to plan exactly the command that was re-run.
@Suite(.serialized)
@MainActor
struct RunAttributedRetryTests {
    /// SONNY-533's own scenario, with one run: X fails while the user is elsewhere, they come back
    /// and run Y, then press Retry on X's banner. Before the fix Y ran again.
    @Test
    func aBannerPressedAfterAnotherTaskWasRunRetriesNothing() async throws {
        let planned = PlannedCommands()
        let fixture = try makeDispatchFixture(planner: { RetryPlanner(folder: $0, planned: planned) })
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        var raised: [RaisedFailure] = []
        let subscription = viewModel.errorMessageRaised.sink { raised.append($0) }
        defer { subscription.cancel() }

        let run = viewModel.focusedRunID
        viewModel.command = "Draft one, which fails"
        viewModel.start()
        try await HangBackstop.waitOrAbandon(for: "the first task to fail") {
            slot(run, in: viewModel).map { !$0.isRunning && $0.errorMessage != nil } == true
        }
        let banner = try #require(raised.last?.retry, "a failed task was announced with nothing to retry")
        #expect(banner.runID == run)
        #expect(slot(run, in: viewModel)?.failedTask == banner)

        viewModel.command = "Draft two"
        viewModel.start()
        try await HangBackstop.waitOrAbandon(for: "the second task to finish") {
            slot(run, in: viewModel).map { !$0.isRunning && planned.commands.count == 2 } == true
        }
        try #require(viewModel.errorMessage == nil, "precondition: the second task succeeded")

        #expect(!viewModel.retryFailedRun(banner.runID, token: banner.token))
        // `start()` sets `isRunning` synchronously, so a press that started anything shows here.
        #expect(!viewModel.isRunning, "a stale banner's Retry started a run")
        #expect(viewModel.lastCommand == "Draft two")
        #expect(planned.commands == ["Draft one, which fails", "Draft two"])

        // And while a *different* task's failure stands, which is the state only the token tells
        // apart: the run is showing a failure, there is a last command, and neither is the banner's.
        viewModel.command = "Draft three, which fails"
        viewModel.start()
        try await HangBackstop.waitOrAbandon(for: "the third task to fail") {
            slot(run, in: viewModel).map { !$0.isRunning && planned.commands.count == 3 } == true
        }
        try #require(viewModel.errorMessage != nil, "precondition: a newer failure is showing")
        #expect(!viewModel.retryFailedRun(banner.runID, token: banner.token))
        #expect(!viewModel.isRunning, "the first task's banner re-ran the third task")
        #expect(planned.commands.count == 3)
    }

    /// The press that should work does: the failed task runs again, under its own words, and the
    /// banner that started it is spent — a second press finds nothing, so one banner is one retry.
    @Test
    func aBannerPressedWhileItsFailureStandsRetriesThatTaskOnce() async throws {
        let planned = PlannedCommands()
        let fixture = try makeDispatchFixture(planner: { RetryPlanner(folder: $0, planned: planned) })
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        var raised: [RaisedFailure] = []
        let subscription = viewModel.errorMessageRaised.sink { raised.append($0) }
        defer { subscription.cancel() }

        let run = viewModel.focusedRunID
        viewModel.command = "Draft one, which fails"
        viewModel.start()
        try await HangBackstop.waitOrAbandon(for: "the task to fail") {
            slot(run, in: viewModel).map { !$0.isRunning && $0.errorMessage != nil } == true
        }
        let banner = try #require(raised.last?.retry)

        #expect(viewModel.retryFailedRun(banner.runID, token: banner.token))
        #expect(slot(run, in: viewModel)?.retryToken == nil, "the submission did not spend the banner")
        #expect(!viewModel.retryFailedRun(banner.runID, token: banner.token), "one banner retried twice")
        try await HangBackstop.waitOrAbandon(for: "the retried task to fail again") {
            slot(run, in: viewModel).map { !$0.isRunning && planned.commands.count == 2 } == true
        }
        #expect(planned.commands == ["Draft one, which fails", "Draft one, which fails"])

        // The retry failed too, which is a new failure with a banner of its own: the old one still
        // answers nothing, and the new one names the same run under a different token.
        let second = try #require(raised.last?.retry)
        #expect(second.runID == run)
        #expect(second.token != banner.token)
        #expect(!viewModel.retryFailedRun(banner.runID, token: banner.token))
        #expect(!viewModel.retryFailedRun(RunID(), token: second.token), "a run that does not exist was retried")
    }

    /// Two runs, the widget left on the one that did *not* fail. "Whatever the run on screen was
    /// last asked" is then a different task from the one the banner names, which one run cannot
    /// show (PR #279's review, F2: a test with one run cannot tell "its run" from "the run on
    /// screen").
    @Test
    func aBannerForABackgroundRunRetriesThatRunAndNotTheOneOnScreen() async throws {
        let planned = PlannedCommands()
        let fixture = try makeDispatchFixture(planner: { RetryPlanner(folder: $0, planned: planned) })
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        var raised: [RaisedFailure] = []
        let subscription = viewModel.errorMessageRaised.sink { raised.append($0) }
        defer { subscription.cancel() }

        let onScreen = viewModel.focusedRunID
        viewModel.command = "Draft on screen"
        viewModel.start()
        try await HangBackstop.waitOrAbandon(for: "the run on screen to finish") {
            slot(onScreen, in: viewModel).map { !$0.isRunning && planned.commands.count == 1 } == true
        }

        let background = viewModel.addRunSlotForTests()
        RunScope.$current.withValue(background) {
            viewModel.command = "Draft in the background, which fails"
            viewModel.start()
        }
        try await HangBackstop.waitOrAbandon(for: "the background run to fail") {
            slot(background, in: viewModel).map { !$0.isRunning && $0.errorMessage != nil } == true
        }
        try #require(viewModel.focusedRunID == onScreen, "precondition: the widget is on the other run")
        let failure = try #require(raised.last)
        #expect(failure.runID == background)
        let banner = try #require(failure.retry)
        #expect(banner.runID == background)

        // Carried the way the banner carries it, and pressed the way the banner is pressed.
        let content = SonnyNotificationContent.taskFailed(message: failure.message, retry: failure.retry)
        let pressed = SonnyNotificationResponse(
            actionIdentifier: SonnyNotificationAction.retry,
            categoryIdentifier: content.categoryIdentifier,
            userInfo: content.userInfo
        )
        guard case .retry(let carried?) = pressed else {
            Issue.record("the failed task's banner did not land as a Retry carrying its task: \(pressed)")
            return
        }
        #expect(viewModel.retryFailedRun(carried.runID, token: carried.token))
        try await HangBackstop.waitOrAbandon(for: "the retried run to fail again") {
            slot(background, in: viewModel).map { !$0.isRunning && planned.commands.count == 3 } == true
        }
        #expect(
            planned.commands == [
                "Draft on screen",
                "Draft in the background, which fails",
                "Draft in the background, which fails"
            ],
            "the Retry re-ran the task of the run on screen"
        )
        #expect(slot(onScreen, in: viewModel)?.lastCommand == "Draft on screen")
        #expect(slot(onScreen, in: viewModel)?.errorMessage == nil, "the retry landed on the run on screen")
    }

    /// A failure that is nobody's task is announced with nothing to retry, and its notification
    /// offers nothing — even with a last command sitting in the run, which is the state the old
    /// banner re-ran it from.
    @Test
    func aFailureThatIsNobodysTaskIsAnnouncedWithNothingToRetry() async throws {
        let planned = PlannedCommands()
        let fixture = try makeDispatchFixture(planner: { RetryPlanner(folder: $0, planned: planned) })
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        let run = viewModel.focusedRunID
        viewModel.command = "Draft one"
        viewModel.start()
        try await HangBackstop.waitOrAbandon(for: "the task to finish") {
            slot(run, in: viewModel).map { !$0.isRunning && planned.commands.count == 1 } == true
        }
        try #require(!viewModel.lastCommand.isEmpty, "precondition: the run holds a last command")

        var raised: [RaisedFailure] = []
        let subscription = viewModel.errorMessageRaised.sink { raised.append($0) }
        defer { subscription.cancel() }
        viewModel.setError("Microphone permission was denied.", persistent: true)

        let failure = try #require(raised.last)
        #expect(failure.runID == run)
        #expect(failure.retry == nil)
        #expect(slot(run, in: viewModel)?.retryToken == nil)
        #expect(slot(run, in: viewModel)?.failedTask == nil)
        let content = SonnyNotificationContent.taskFailed(message: failure.message, retry: failure.retry)
        let withRetry = SonnyNotificationContent.taskFailed(
            message: failure.message,
            retry: FailureTarget(runID: run, token: UUID())
        )
        #expect(content.categoryIdentifier != withRetry.categoryIdentifier, "it was posted in the category that carries Retry")
        #expect(content.userInfo.isEmpty)
    }

    /// A Retry the cap refuses keeps its banner, and the door says it did not start (PR #287's F1).
    ///
    /// The cap's refusal is the one refusal on this path that *writes* — it publishes
    /// `tooManyRunsMessage` through `setError`, and publishing a failure retires the run's retry
    /// token. So before the fix this press returned `true`, replaced the failure on screen with the
    /// cap's sentence, and left the banner answering nothing ever after: the user was told to try
    /// again once a run finished, and trying again found nothing. Inert in the shipping app, since
    /// nothing there makes a second run; live in the lane that switches the feature on.
    @Test
    func aRetryTheCapRefusesKeepsItsBannerAndReportsThatItDidNotStart() async throws {
        let planned = PlannedCommands()
        let fixture = try makeDispatchFixture(planner: { RetryPlanner(folder: $0, planned: planned) })
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        var raised: [RaisedFailure] = []
        let subscription = viewModel.errorMessageRaised.sink { raised.append($0) }
        defer { subscription.cancel() }

        let run = viewModel.focusedRunID
        viewModel.command = "Draft one, which fails"
        viewModel.start()
        try await HangBackstop.waitOrAbandon(for: "the task to fail") {
            slot(run, in: viewModel).map { !$0.isRunning && $0.errorMessage != nil } == true
        }
        let banner = try #require(raised.last?.retry)
        let theFailureItWasPostedFor = try #require(slot(run, in: viewModel)?.errorMessage)

        // Three other runs fill the cap, and the widget stays on the run holding the banner.
        let others = (0..<3).map { _ in viewModel.addRunSlotForTests() }
        for id in others {
            RunScope.$current.withValue(id) { viewModel.isRunning = true }
        }
        try #require(viewModel.runsInFlight == AgentViewModel.maximumConcurrentRuns)
        try #require(!viewModel.canStartAnotherRun)

        #expect(!viewModel.retryFailedRun(banner.runID, token: banner.token), "the door reported a retry that never started")
        #expect(slot(run, in: viewModel)?.retryToken == banner.token, "the refusal spent the banner it was pressed on")
        #expect(slot(run, in: viewModel)?.errorMessage == theFailureItWasPostedFor, "the refusal replaced the failure the banner is about")
        #expect(!viewModel.isRunning, "a refused retry started a run")
        #expect(planned.commands.count == 1, "a refused retry reached the planner")

        // One run finishes, and the same banner — pressed a second time — still works.
        RunScope.$current.withValue(others[0]) { viewModel.isRunning = false }
        #expect(viewModel.retryFailedRun(banner.runID, token: banner.token))
        try await HangBackstop.waitOrAbandon(for: "the retried task to fail again") {
            slot(run, in: viewModel).map { !$0.isRunning && planned.commands.count == 2 } == true
        }
        #expect(planned.commands == ["Draft one, which fails", "Draft one, which fails"])
        for id in others.dropFirst() {
            RunScope.$current.withValue(id) { viewModel.isRunning = false }
        }
    }

    /// The two in-app Retry controls offer nothing for a failure that is not a task (PR #287's F2),
    /// which is the answer the notification for the same failure already gives by carrying no
    /// button — `aFailureThatIsNobodysTaskIsAnnouncedWithNothingToRetry` holds that half.
    ///
    /// The old gate asked whether the run had ever run a command, so after a microphone that would
    /// not open the widget offered a Retry that re-ran the last real task. That is SONNY-533's own
    /// sentence — work the person never asked to repeat — on the surface they are most likely to be
    /// looking at, and it is reachable today with one run.
    @Test
    func aFailureThatIsNobodysTaskOffersNoRetryOnEitherSurface() async throws {
        let planned = PlannedCommands()
        let fixture = try makeDispatchFixture(planner: { RetryPlanner(folder: $0, planned: planned) })
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        let run = viewModel.focusedRunID

        viewModel.command = "Draft one, which fails"
        viewModel.start()
        try await HangBackstop.waitOrAbandon(for: "the task to fail") {
            slot(run, in: viewModel).map { !$0.isRunning && $0.errorMessage != nil } == true
        }
        #expect(viewModel.canRetryFailedTask, "a task that failed is what Retry is for")

        viewModel.setError("Microphone permission was denied.", persistent: true)
        #expect(!viewModel.lastCommand.isEmpty, "precondition: the run still holds the task a stale Retry would re-run")
        #expect(!viewModel.canRetryFailedTask, "the failure on screen is not a task, and Retry would re-run a different one")
        #expect(slot(run, in: viewModel)?.failedTask == nil)

        // And pressing it anyway re-runs nothing: the gate is what hides the button, not the only
        // thing standing between the press and the planner.
        viewModel.retryLastCommand()
        #expect(viewModel.isRunning, "precondition: this press does dispatch, so the gate is the control")
        try await HangBackstop.waitOrAbandon(for: "the dispatched retry to settle") { !viewModel.isRunning }
    }

    /// The widget offers no Retry while the cap is full, and offers it again once a run finishes
    /// (PR #287's re-check, N1).
    ///
    /// **A press the cap refuses does nothing and says nothing**, because F1 made that refusal
    /// write nothing on purpose, so a button drawn on the failed-task half alone would be dead in
    /// the hand. One test per surface: each drives the predicate its own control is drawn from, and
    /// reads that control's wiring, because the views cannot be built in a test process.
    @Test
    func theWidgetsFailurePanelOffersNoRetryWhileTheCapIsFull() async throws {
        let full = try await makeAFailedTaskUnderAFullCap()
        defer { full.fixture.tearDown() }
        let viewModel = full.fixture.viewModel

        #expect(!viewModel.canRetryFailedTask, "the widget would draw a Retry that answers a press with nothing")

        let widget = try MacAgentSource.read("FloatingWidgetView.swift")
        #expect(MacAgentSource.count(of: "canRetry: viewModel.canRetryFailedTask,", inText: widget) == 1)
        #expect(MacAgentSource.count(of: "viewModel.retryLastCommand(", inText: widget) == 1)

        // The failure is still on screen; it is the cap that shut the gate, and a run finishing
        // opens it again.
        #expect(slot(full.run, in: viewModel)?.failedTask != nil)
        RunScope.$current.withValue(full.others[0]) { viewModel.isRunning = false }
        #expect(viewModel.canRetryFailedTask)
        full.settle()
    }

    /// Command Center's failure row, the same way. Its control sits inside
    /// `CommandCenterAttentionPanel`, which keeps reading the focused run — only the predicate
    /// moved (founders, 2026-09-24).
    @Test
    func commandCentersFailureRowOffersNoRetryWhileTheCapIsFull() async throws {
        let full = try await makeAFailedTaskUnderAFullCap()
        defer { full.fixture.tearDown() }
        let viewModel = full.fixture.viewModel

        #expect(!viewModel.canRetryFailedTask, "Command Center would draw a Retry that answers a press with nothing")

        let commandCenter = try MacAgentSource.read("CommandCenterView.swift")
        #expect(MacAgentSource.count(of: "if viewModel.canRetryFailedTask {", inText: commandCenter) == 1)
        #expect(MacAgentSource.count(of: "viewModel.retryLastCommand(", inText: commandCenter) == 1)

        #expect(slot(full.run, in: viewModel)?.failedTask != nil)
        RunScope.$current.withValue(full.others[0]) { viewModel.isRunning = false }
        #expect(viewModel.canRetryFailedTask)
        full.settle()
    }

    /// The delegate's half, read off the wiring for the reason the Allow's is: the closures cannot
    /// be built in a test process. The Retry names its run and token and no longer calls
    /// `retryLastCommand()`; the failure sink hands the announcement's own address to the post and
    /// records the hold on the run that failed (PR #279's delta review: that line was pinned by
    /// nothing, and `markOutcomeAsNotified()` bare passed the suite).
    @Test
    func theBannersRetryNamesTheFailedTaskAndTheHoldNamesTheRunThatFailed() throws {
        let delegate = try MacAgentSource.read("AppDelegate.swift")
        let retry = try MacAgentSource.region(of: delegate, from: "onRetry:", to: "onOpen:")
        #expect(MacAgentSource.count(of: "viewModel.retryFailedRun(target.runID, token: target.token)", inText: retry) == 1)
        #expect(MacAgentSource.count(of: "retryLastCommand", inText: retry) == 0)
        #expect(MacAgentSource.count(of: "guard let target else { return }", inText: retry) == 1)

        let sink = try MacAgentSource.region(of: delegate, from: "viewModel.errorMessageRaised", to: ".store(in: &cancellables)")
        #expect(
            MacAgentSource.count(
                of: "notificationService.postErrorNotification(message: failure.message, retry: failure.retry)",
                inText: sink
            ) == 1
        )
        #expect(MacAgentSource.count(of: "viewModel.markOutcomeAsNotified(for: failure.runID)", inText: sink) == 1)
        #expect(MacAgentSource.count(of: "markOutcomeAsNotified()", inText: sink) == 0)

        let service = try MacAgentSource.read("SonnyNotificationService.swift")
        let post = try MacAgentSource.braceBlock(
            of: service,
            openedBy: "func postErrorNotification(message: String, retry: FailureTarget?) {"
        )
        #expect(MacAgentSource.count(of: "deliver(SonnyNotificationContent.taskFailed(message: message, retry: retry))", inText: post) == 1)
        let land = try MacAgentSource.braceBlock(of: service, openedBy: "private func land(_ response: SonnyNotificationResponse) {")
        #expect(MacAgentSource.count(of: "case .retry(let target):\n            onRetry(target)", inText: land) == 1)
    }
}

// MARK: - The notification's own round trip, for both controls

/// What a notification carries, and where a press on it lands — both halves run for real, with only
/// the banner itself left out (PR #279's review, F3: neither control had this). The service that
/// delivers cannot exist in a test process, so the content it delivers and the decision it acts on
/// are `SonnyNotificationContent` and `SonnyNotificationResponse`, and this drives one into the
/// other exactly as a press does.
@Suite
struct NotificationRoundTripTests {
    private func press(_ action: String, on content: UNNotificationContent) -> SonnyNotificationResponse {
        SonnyNotificationResponse(
            actionIdentifier: action,
            categoryIdentifier: content.categoryIdentifier,
            userInfo: content.userInfo
        )
    }

    @Test
    func anAllowPressedOnAnApprovalsNotificationLandsWithThatApproval() {
        let target = ApprovalTarget(runID: RunID(), token: UUID())
        let content = SonnyNotificationContent.approvalNeeded(resource: "Desktop", target: target)
        #expect(content.title == "Approval needed")
        #expect(content.body == "Requesting access to Desktop")
        #expect(press(SonnyNotificationAction.allow, on: content) == .allow(target))
        #expect(press(UNNotificationDefaultActionIdentifier, on: content) == .open)
    }

    @Test
    func aRetryPressedOnAFailedTasksNotificationLandsWithThatTask() {
        let target = FailureTarget(runID: RunID(), token: UUID())
        let content = SonnyNotificationContent.taskFailed(message: "It did not work.", retry: target)
        #expect(content.title == "Task failed")
        #expect(content.body == "It did not work.")
        #expect(press(SonnyNotificationAction.retry, on: content) == .retry(target))
        #expect(press(UNNotificationDefaultActionIdentifier, on: content) == .open)
    }

    /// Each control reads its own notification and nothing else's: the same run and token under the
    /// other control's key name no approval and no failed task. A press that cannot happen today —
    /// each category registers one action — and the answer if a category ever gains the other.
    @Test
    func neitherControlReadsTheOtherNotificationsAddress() {
        let run = RunID()
        let token = UUID()
        let approval = SonnyNotificationContent.approvalNeeded(
            resource: "Desktop",
            target: ApprovalTarget(runID: run, token: token)
        )
        let failure = SonnyNotificationContent.taskFailed(
            message: "It did not work.",
            retry: FailureTarget(runID: run, token: token)
        )
        #expect(press(SonnyNotificationAction.retry, on: approval) == .retry(nil))
        #expect(press(SonnyNotificationAction.allow, on: failure) == .allow(nil))
        #expect(approval.categoryIdentifier != failure.categoryIdentifier)
    }

    @Test
    func aFailureWithNoFailedTaskCarriesNothingAndItsRetryWouldRetryNothing() {
        let content = SonnyNotificationContent.taskFailed(message: "The microphone is off.", retry: nil)
        #expect(content.title == "Task failed")
        #expect(content.userInfo.isEmpty)
        #expect(press(SonnyNotificationAction.retry, on: content) == .retry(nil))
        #expect(press(UNNotificationDefaultActionIdentifier, on: content) == .open)
        #expect(press("SOMETHING_ELSE", on: content) == .ignore)
    }

    @Test
    func aFailedTasksAddressReadsBackAsItselfAndAnUnreadableOneRetriesNothing() throws {
        let target = FailureTarget(runID: RunID(), token: UUID())
        let written = target.notificationUserInfo
        #expect(FailureTarget(notificationUserInfo: written) == target)
        #expect(Set(written.values) == [target.runID.value.uuidString, target.token.uuidString])
        #expect(FailureTarget(notificationUserInfo: [:]) == nil)
        for key in written.keys {
            var missingOne: [AnyHashable: Any] = written
            missingOne[key] = nil
            #expect(FailureTarget(notificationUserInfo: missingOne) == nil, "read with \(key) missing")

            var malformed: [AnyHashable: Any] = written
            malformed[key] = "not a uuid"
            #expect(FailureTarget(notificationUserInfo: malformed) == nil, "read with \(key) malformed")
        }

        // The halves are read from their own keys: swapped, they read back as a different address.
        try #require(written.count == 2)
        let keys = Array(written.keys)
        var swapped: [AnyHashable: Any] = [:]
        swapped[keys[0]] = written[keys[1]]
        swapped[keys[1]] = written[keys[0]]
        let readBack = try #require(FailureTarget(notificationUserInfo: swapped))
        #expect(readBack != target)
        #expect(readBack.runID == RunID(target.token))
    }
}

// MARK: - Fixtures

/// A run whose task failed, with the cap filled by three other runs — the state both in-app Retry
/// controls are drawn in when the gate has to be shut (PR #287's re-check, N1).
@MainActor
private func makeAFailedTaskUnderAFullCap() async throws -> (fixture: DispatchFixture, run: RunID, others: [RunID], settle: @MainActor () -> Void) {
    let planned = PlannedCommands()
    let fixture = try makeDispatchFixture(planner: { RetryPlanner(folder: $0, planned: planned) })
    let viewModel = fixture.viewModel
    let run = viewModel.focusedRunID

    viewModel.command = "Draft one, which fails"
    viewModel.start()
    try await HangBackstop.waitOrAbandon(for: "the task to fail") {
        slot(run, in: viewModel).map { !$0.isRunning && $0.errorMessage != nil } == true
    }
    try #require(slot(run, in: viewModel)?.failedTask != nil, "precondition: a failed task is on screen")

    let others = (0..<AgentViewModel.maximumConcurrentRuns).map { _ in viewModel.addRunSlotForTests() }
    for id in others {
        RunScope.$current.withValue(id) { viewModel.isRunning = true }
    }
    try #require(!viewModel.canStartAnotherRun, "precondition: the cap is full")

    return (fixture, run, others, {
        for id in others {
            RunScope.$current.withValue(id) { viewModel.isRunning = false }
        }
    })
}

/// Every command the planner was asked to plan, in order — the record of which task ran.
private final class PlannedCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var commands: [String] {
        lock.withLock { recorded }
    }

    func record(_ command: String) {
        lock.withLock { recorded.append(command) }
    }
}

private struct PlanningFailed: LocalizedError {
    var errorDescription: String? { "Sonny couldn't plan that." }
}

/// Fails the planning of any command that says it fails, and drafts a file that does not exist yet
/// for every other — a tier-2 write the consequence rule runs without asking, so a test reaches
/// idle with no approval to answer.
private struct RetryPlanner: Planning {
    let folder: URL
    let planned: PlannedCommands

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        planned.record(command)
        if command.contains("fails") {
            throw PlanningFailed()
        }
        return AgentPlan(
            summary: "Draft notes.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Draft notes.",
                    outputPath: folder.appendingPathComponent("\(UUID().uuidString).md").path,
                    draftTitle: "Notes",
                    draftContent: "Outline."
                )
            ]
        )
    }
}
