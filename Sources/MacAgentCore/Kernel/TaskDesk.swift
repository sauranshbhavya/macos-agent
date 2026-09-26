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
    /// A saved list whose file is on this Mac but couldn't be read.
    public enum SavedList: Sendable, Hashable {
        case history
        case routines
    }

    @Published public private(set) var history: [FinishedTask] = []
    @Published public private(set) var routines: [RoutineGoal] = []
    @Published public private(set) var watchers: [StandingWatcher] = []
    @Published public private(set) var notices: [DeskNotice] = []
    /// Lists whose file couldn't be read the last time the desk read it. Each shows as empty here
    /// but isn't: nothing is saved over the file, and the next read tries it again.
    @Published public private(set) var unreadable: Set<SavedList> = []

    /// Whether there's history the person could delete, including a file that couldn't be read.
    public var hasHistoryToDelete: Bool {
        !history.isEmpty || unreadable.contains(.history)
    }

    public let controller: TaskController
    private let historyStore: FinishedTaskStore
    private let routineStore: RoutineGoalStore
    private let watcherStore: ResumableTaskStore
    private let pageReader: any StandingWatcherObserving
    private let instant: (String) -> [WireAction]?
    /// The saved routine a request names, if it names one (`InstantCommandResolver.routine(namedBy:in:)`).
    private let routineNamed: (String, [RoutineGoal]) -> RoutineGoal?
    private let mode: () -> AgentInteractionMode
    private let context: () -> TaskStartBody.Context
    private let now: () -> Date
    private let calendar: Calendar

    private var recorded: Set<TaskID> = []
    /// Tasks nobody started at the Mac, with the name the notice about each one uses.
    private var unattended: [TaskID: String] = [:]
    /// Routines whose run couldn't be recorded, so the person is told once rather than every check.
    private var couldNotMark: Set<UUID> = []
    private var watcherCheck: Task<Void, Never>?
    private var scheduleCheck: Task<Void, Never>?
    private var watching: AnyCancellable?

    /// The longest goal the protocol carries.
    public static let goalLimit = 4000

    public init(
        controller: TaskController,
        history: FinishedTaskStore,
        routines: RoutineGoalStore,
        watchers: ResumableTaskStore,
        pageReader: any StandingWatcherObserving = LiveStandingWatcherObserver(),
        instant: @escaping (String) -> [WireAction]?,
        routineNamed: @escaping (String, [RoutineGoal]) -> RoutineGoal?,
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
        self.routineNamed = routineNamed
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
        await reloadHistory()
        recorded.formUnion(history.map(\.id))
        await reloadRoutines()
        watchers = (try? watcherStore.loadWatchers()) ?? []
    }

    // MARK: Entry points

    /// The composer and voice. A request that names a saved routine ("run morning briefing") runs
    /// that routine, because the gateway never sees the routine list. A command the Mac recognises
    /// on its own runs locally with no model; anything else goes to the gateway. A follow-up always
    /// goes to the gateway, which has the earlier task's history.
    @discardableResult
    public func ask(
        _ text: String,
        origin: TaskOrigin = .composer,
        isPrivate: Bool = false,
        followingUp prior: TaskID? = nil
    ) async -> TaskSubmission? {
        let goal = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return nil }
        // Routines that can't be read name nothing, and the request goes to the gateway as typed.
        if prior == nil, let routine = routineNamed(goal, (try? await routineStore.all()) ?? []) {
            return await run(routine, isPrivate: isPrivate)
        }
        let request = TaskRequest(
            goal: String(goal.prefix(Self.goalLimit)),
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
    /// start (decision 9). A routine asked for privately runs privately.
    @discardableResult
    public func run(_ routine: RoutineGoal, isPrivate: Bool = false) async -> TaskSubmission {
        await controller.submit(TaskRequest(
            goal: routine.goal,
            origin: .routine,
            isPrivate: isPrivate,
            mode: mode(),
            context: context()
        ))
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
        guard let saved = await reloadRoutines() else { return }
        for routine in saved {
            guard var timing = routine.timing else { continue }
            let decision = RoutineScheduler.decision(for: timing, now: now(), calendar: calendar)
            let occurrence: Date
            switch decision {
            case .notDue:
                continue
            case .due(let at), .missed(let at):
                occurrence = at
            }
            // Marked before starting, so a slow start can't run the same occurrence twice. A mark
            // that can't be saved means the routine doesn't run: unmarked, it would run again at
            // every check.
            timing.lastRunAt = occurrence
            var updated = routine
            updated.timing = timing
            do {
                try await routineStore.save(updated)
                couldNotMark.remove(routine.id)
            } catch {
                if couldNotMark.insert(routine.id).inserted {
                    notices.append(DeskNotice(
                        kind: .missedSchedule,
                        message: "\"\(routine.name)\" didn't run because Sonny couldn't save that it had."
                    ))
                }
                continue
            }
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
        await reloadRoutines()
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

    // A failed change is logged by the store, and an unreadable file shows through `unreadable`.

    public func deleteHistory(_ id: TaskID) async {
        try? await historyStore.delete(id)
        await reloadHistory()
    }

    public func deleteAllHistory() async {
        try? await historyStore.deleteAll()
        await reloadHistory()
    }

    public func setTiming(_ timing: RoutineSchedule?, for routine: RoutineGoal) async {
        var updated = routine
        updated.timing = timing
        try? await routineStore.save(updated)
        await reloadRoutines()
    }

    public func deleteRoutine(_ routine: RoutineGoal) async {
        try? await routineStore.delete(routine.id)
        await reloadRoutines()
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
        await reloadRoutines()
        watchers = (try? watcherStore.loadWatchers()) ?? []
    }

    // MARK: Reading what's saved

    private func reloadHistory() async {
        history = await read(.history) { try await self.historyStore.all() } ?? []
    }

    /// The saved routines, or nil when their file couldn't be read.
    @discardableResult
    private func reloadRoutines() async -> [RoutineGoal]? {
        let saved = await read(.routines) { try await self.routineStore.all() }
        routines = saved ?? []
        return saved
    }

    private func read<Value>(_ list: SavedList, _ load: () async throws -> [Value]) async -> [Value]? {
        do {
            let values = try await load()
            unreadable.remove(list)
            return values
        } catch {
            unreadable.insert(list)
            return nil
        }
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
        await reloadHistory()
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
