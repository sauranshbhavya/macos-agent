import Combine
import Foundation

/// Something the person should hear about that they didn't just ask for: a scheduled run's result,
/// a missed schedule, or a watcher that stopped.
public struct DeskNotice: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// A scheduled or watcher-started task ended.
        case unattendedRun
        /// A schedule's time passed while the Mac was asleep or Sonny was closed.
        case missedSchedule
        /// A watcher stopped without its page changing.
        case watcherStopped
    }

    public let id: UUID
    public let kind: Kind
    public let message: String
    /// The task the notice is about, when there is one.
    public let task: TaskID?
    /// Whether that task came from a schedule or a watcher.
    public let origin: TaskOrigin?

    public init(id: UUID = UUID(), kind: Kind, message: String, task: TaskID? = nil, origin: TaskOrigin? = nil) {
        self.id = id
        self.kind = kind
        self.message = message
        self.task = task
        self.origin = origin
    }
}

/// Every way a task starts on this Mac, in one place (V2 plan section 6, "Entry points").
///
/// The composer, voice, a routine, a schedule, a follow-up and a watcher each make the same
/// `TaskRequest`, and each goes through `TaskController`. Nothing here reads which window is in
/// front. The desk also keeps local history: a task that ends is written to `FinishedTaskStore`
/// unless it was private (decision 10).
@MainActor
public final class TaskDesk: ObservableObject {
    @Published public private(set) var history: [FinishedTask] = []
    @Published public private(set) var routines: [RoutineGoal] = []
    @Published public private(set) var watchers: [StandingWatcher] = []
    @Published public private(set) var notices: [DeskNotice] = []

    public let controller: TaskController
    private let historyStore: FinishedTaskStore
    private let routineStore: RoutineGoalStore
    private let watcherStore: ResumableTaskStore
    private let pageReader: any StandingWatcherObserving
    private let instant: (String) -> [WireAction]?
    private let mode: () -> AgentInteractionMode
    private let context: () -> TaskStartBody.Context
    private let now: () -> Date
    private let calendar: Calendar

    private var recorded: Set<TaskID> = []
    /// Tasks nobody started at the Mac, with the name the notice about each one uses.
    private var unattended: [TaskID: String] = [:]
    private var watcherCheck: Task<Void, Never>?
    private var scheduleCheck: Task<Void, Never>?
    private var watching: AnyCancellable?

    public init(
        controller: TaskController,
        history: FinishedTaskStore,
        routines: RoutineGoalStore,
        watchers: ResumableTaskStore,
        pageReader: any StandingWatcherObserving = LiveStandingWatcherObserver(),
        instant: @escaping (String) -> [WireAction]?,
        mode: @escaping () -> AgentInteractionMode,
        context: @escaping () -> TaskStartBody.Context = { .init() },
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.controller = controller
        self.historyStore = history
        self.routineStore = routines
        self.watcherStore = watchers
        self.pageReader = pageReader
        self.instant = instant
        self.mode = mode
        self.context = context
        self.now = now
        self.calendar = calendar
        watching = controller.$tasks.sink { [weak self] tasks in
            // Delivered after the controller's own publish completes, so the desk reads settled state.
            Task { @MainActor in await self?.recordFinished(tasks) }
        }
    }

    /// Reads history, routines and watchers from disk.
    public func load() async {
        history = await historyStore.all()
        recorded.formUnion(history.map(\.id))
        routines = await routineStore.all()
        watchers = (try? watcherStore.loadWatchers()) ?? []
    }

    // MARK: Entry points

    /// The composer and voice. A command the Mac recognises on its own runs locally with no model;
    /// anything else goes to the gateway. A follow-up always goes to the gateway, which has the
    /// earlier task's history.
    @discardableResult
    public func ask(
        _ text: String,
        origin: TaskOrigin = .composer,
        isPrivate: Bool = false,
        followingUp prior: TaskID? = nil
    ) async -> TaskSubmission? {
        let goal = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return nil }
        let request = TaskRequest(
            goal: goal,
            origin: prior == nil ? origin : .followUp,
            isPrivate: isPrivate,
            mode: mode(),
            priorTask: prior,
            context: context()
        )
        if prior == nil, let actions = instant(goal) {
            return await controller.submitLocal(request, actions: actions)
        }
        return await controller.submit(request)
    }

    /// Runs a saved routine now, with the person at the Mac. The goal is planned again from the
    /// start (decision 9).
    @discardableResult
    public func run(_ routine: RoutineGoal) async -> TaskSubmission {
        await controller.submit(TaskRequest(goal: routine.goal, origin: .routine, mode: mode(), context: context()))
    }

    /// Starts every routine whose time has come. A scheduled run is unattended: anything that
    /// would need a yes is refused, and the person hears about it afterwards. A check that starts
    /// while another is still running waits for it rather than reading the same occurrences again.
    public func runDueRoutines() async {
        if let running = scheduleCheck {
            await running.value
            return
        }
        let check = Task { await self.startDueRoutines() }
        scheduleCheck = check
        await check.value
        scheduleCheck = nil
    }

    private func startDueRoutines() async {
        for routine in await routineStore.all() {
            guard var timing = routine.timing else { continue }
            let decision = RoutineScheduler.decision(for: timing, now: now(), calendar: calendar)
            let occurrence: Date
            switch decision {
            case .notDue:
                continue
            case .due(let at), .missed(let at):
                occurrence = at
            }
            // Marked before starting, so a slow start can't run the same occurrence twice.
            timing.lastRunAt = occurrence
            var updated = routine
            updated.timing = timing
            try? await routineStore.save(updated)
            if case .missed = decision {
                notices.append(DeskNotice(
                    kind: .missedSchedule,
                    message: "\"\(routine.name)\" didn't run at its time because the Mac was asleep or Sonny was closed."
                ))
                continue
            }
            let submission = await controller.submit(TaskRequest(
                goal: routine.goal,
                origin: .schedule,
                unattended: true,
                mode: mode(),
                context: context()
            ))
            unattended[submission.task] = routine.name
            if case .failed(let task, let failure) = submission {
                recordNotice(for: task, name: routine.name, origin: .schedule, failure: failure.message)
            }
        }
        routines = await routineStore.all()
    }

    /// Checks the watchers that are due, one page at a time. When a page has changed, the watcher
    /// ends and starts an unattended task that reads the page and says what changed.
    public func checkWatchers() async {
        if let running = watcherCheck {
            await running.value
            return
        }
        let check = Task { await self.checkDueWatchers() }
        watcherCheck = check
        await check.value
        watcherCheck = nil
    }

    // MARK: Changing what's saved

    public func deleteHistory(_ id: TaskID) async {
        try? await historyStore.delete(id)
        history = await historyStore.all()
    }

    public func deleteAllHistory() async {
        try? await historyStore.deleteAll()
        history = []
    }

    public func setTiming(_ timing: RoutineSchedule?, for routine: RoutineGoal) async {
        var updated = routine
        updated.timing = timing
        try? await routineStore.save(updated)
        routines = await routineStore.all()
    }

    public func deleteRoutine(_ routine: RoutineGoal) async {
        try? await routineStore.delete(routine.id)
        routines = await routineStore.all()
    }

    public func stopWatching(_ watcher: StandingWatcher) {
        try? watcherStore.deleteWatcher(id: watcher.id)
        watchers = (try? watcherStore.loadWatchers()) ?? []
    }

    public func dismiss(_ notice: DeskNotice) {
        notices.removeAll { $0.id == notice.id }
    }

    /// Re-reads routines and watchers after a task may have changed them (`save_routine`,
    /// `start_watching`).
    public func refreshSaved() async {
        routines = await routineStore.all()
        watchers = (try? watcherStore.loadWatchers()) ?? []
    }

    // MARK: Finished tasks

    private func recordFinished(_ tasks: [TaskSnapshot]) async {
        let ended = tasks.filter { $0.phase.isTerminal && !recorded.contains($0.id) }
        guard !ended.isEmpty else { return }
        for task in ended {
            recorded.insert(task.id)
            // The store refuses a private task too; this keeps it out of memory as well.
            if !task.isPrivate {
                try? await historyStore.record(task, finishedAt: now())
            }
            if let name = unattended.removeValue(forKey: task.id) {
                notices.append(Self.notice(for: task, name: name))
            }
        }
        history = await historyStore.all()
        await refreshSaved()
    }

    private func recordNotice(for task: TaskID, name: String, origin: TaskOrigin, failure: String) {
        unattended.removeValue(forKey: task)
        notices.append(DeskNotice(kind: .unattendedRun, message: "\"\(name)\" didn't run: \(failure)", task: task, origin: origin))
    }

    static func notice(for task: TaskSnapshot, name: String) -> DeskNotice {
        let message: String
        if let refused = task.actions.first(where: { $0.status == .refused }) {
            message = "\"\(name)\" stopped where it needed you: \(refused.title). Run it yourself to finish it."
        } else {
            switch task.phase {
            case .completed(let summary): message = "\"\(name)\" ran. \(summary)"
            case .failed(let failure): message = "\"\(name)\" didn't finish. \(failure.message)"
            default: message = "\"\(name)\" stopped."
            }
        }
        return DeskNotice(kind: .unattendedRun, message: message, task: task.id, origin: task.origin)
    }

    // MARK: Watchers

    private func checkDueWatchers() async {
        let current = (try? watcherStore.loadWatchers()) ?? []
        for watcher in current {
            let checkedAt = now()
            switch StandingWatcherEvaluator.decideBeforeObserving(watcher, now: checkedAt) {
            case .notDue:
                continue
            case .stopped(let stopped, let reason):
                await finish(stopped, reason: reason)
            case .pending, .unchanged:
                let decision: StandingWatcherDecision
                if let text = await read(watcher.url) {
                    decision = StandingWatcherEvaluator.apply(
                        reading: StandingWatcherEvaluator.digest(of: text),
                        to: watcher,
                        now: checkedAt
                    )
                } else {
                    decision = StandingWatcherEvaluator.applyFailure(to: watcher, now: checkedAt)
                }
                switch decision {
                case .notDue:
                    break
                case .pending(let updated), .unchanged(let updated):
                    try? watcherStore.saveWatcher(updated)
                case .stopped(let stopped, let reason):
                    await finish(stopped, reason: reason)
                }
            }
        }
        watchers = (try? watcherStore.loadWatchers()) ?? []
    }

    /// The page's readable text, or nil when it couldn't be read in time. A reader that ignores
    /// cancellation can't hold the check past the timeout: whichever ends first answers.
    private func read(_ url: URL) async -> String? {
        let timeout = StandingWatcherLimits.standard.checkTimeout
        return await withCheckedContinuation { continuation in
            let answer = FirstAnswer(continuation)
            let reading = Task { @MainActor in
                answer.give(try? await self.pageReader.readableText(at: url))
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                reading.cancel()
                answer.give(nil)
            }
        }
    }

    private func finish(_ watcher: StandingWatcher, reason: StandingWatcherStopReason) async {
        try? watcherStore.deleteWatcher(id: watcher.id)
        guard reason == .changed else {
            notices.append(DeskNotice(kind: .watcherStopped, message: StandingWatcherNoticeCopy.message(for: reason, watcher: watcher)))
            return
        }
        let goal = """
        A page I asked you to watch has changed. I was watching it for: \(watcher.subject)
        Read \(watcher.url.absoluteString) and tell me in one or two sentences what changed.
        """
        let submission = await controller.submit(TaskRequest(goal: goal, origin: .watcher, unattended: true, mode: mode()))
        unattended[submission.task] = watcher.subject
        if case .failed(let task, let failure) = submission {
            recordNotice(for: task, name: watcher.subject, origin: .watcher, failure: failure.message)
        }
    }
}

/// Resumes a continuation with the first answer it's given and ignores the rest.
@MainActor
private final class FirstAnswer {
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func give(_ text: String?) {
        continuation?.resume(returning: text)
        continuation = nil
    }
}
