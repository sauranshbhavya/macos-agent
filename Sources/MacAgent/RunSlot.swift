import Foundation
import MacAgentCore

/// The identity of one run (SONNY-456).
///
/// A run is one slot of `AgentViewModel.runSlots`: everything the view model used to hold as "the"
/// run — the plan, the step statuses, the parked approval and the runner that approval resumes, the
/// clarification, the outcome — now lives in the slot, and the id is how a surface names the run it
/// is showing so that an answer reaches that run and no other.
struct RunID: Hashable, Sendable, CustomStringConvertible {
    let value: UUID

    init() {
        value = UUID()
    }

    init(_ value: UUID) {
        self.value = value
    }

    var description: String {
        value.uuidString
    }
}

/// One parked approval's address: the run it is parked on and the token it was parked with
/// (SONNY-456). An answer that carries this reaches that question and no other.
struct ApprovalTarget: Hashable, Sendable {
    let runID: RunID
    let token: UUID
}

/// Which run the code executing right now belongs to (SONNY-456).
///
/// **Bound at the one place each run's work begins, and inherited by everything under it.** Every
/// `Task` that carries a run's work — `start`, the approval that resumes it, the scheduled routine —
/// is created inside `RunScope.$current.withValue(id)`, and an unstructured `Task {}` inherits the
/// task-local values of the context that created it. So the ~150 places in `AgentViewModel` that
/// write `isRunning`, `plan`, `approvalRequest` and the rest keep their spelling and write to their
/// own run's slot, however many runs are in flight.
///
/// **Outside any run, the answer is `nil`** and the view model reads the run the widget is focused
/// on. That is the right reading for every caller that is not a run: a view drawing a panel, a
/// control the user pressed on that panel, a test reading state. Those callers act on the run they
/// are looking at, and `AgentViewModel.focusedRunID` is exactly that.
///
/// **Chosen over threading a `RunID` parameter through every function, and the reason is which way
/// a mistake fails.** With an explicit parameter, a site that was missed still compiles and still
/// writes — to the focused run, which is a different run whenever more than one is in flight. With
/// the scope, a missed site is one that runs *outside* the run's task (a timer, a notification, a
/// `DispatchQueue` hop), and `AgentViewModel` answers that with the focused run too; so both designs
/// share that one failure, and the scope removes every other.
///
/// **Known to run outside any run, and right only while focus cannot move under them** — each one is
/// owed a binding, or a proof it cannot outlive a focus change, before a second run can exist
/// (SONNY-456's comments list them in order):
/// - **The four screen-control cancellation hops** in `AgentViewModel+VisionSession.swift`. Each is a
///   `Task` started inside `withTaskCancellationHandler`'s `onCancel`, which runs in the context of
///   whoever cancelled, so it reads the continuation of the run *that* context names. Once focus can
///   move, stopping one run while the widget shows another reads the wrong run's continuation: the
///   stopped run is never resumed, never finishes, and holds its slot for good.
/// - **Voice** (`startVoiceRecording`, `stopVoiceRecordingAndTranscribe`, and the `Task`s they
///   start). They write `errorMessage` and `errorIsPersistent` through `setError`, clear
///   `errorMessage` and `finalSummary`, write `currentTaskID` and `taskUsageSummary` (and reset the
///   one shared `taskUsageRecorder`), set `preserveUsageForNextStart`, write `clarificationAnswer`
///   after reading `clarificationQuestion`, and hand a transcript to `dispatch`, so the run it
///   starts begins in whichever slot is focused when the transcript lands.
/// - Timers and observers: the routine timer and the wake observer start a scheduled run in the
///   focused slot, and the whole wipe clears the focused slot only.
enum RunScope {
    @TaskLocal static var current: RunID?
}

/// The state of one run that moved out of `AgentViewModel` (SONNY-456). Each property here is the one
/// `AgentViewModel` used to declare for its single run, with the same name, type and default, plus
/// `approvalToken`; `AgentViewModel` forwards its old property to the slot of the run in scope, so
/// nothing that read or wrote the old property changed.
///
/// **Not everything that describes a run moved, and the difference matters to the next layer.**
/// These are still one per view model: `taskUsageRecorder` — while `currentTaskID` and
/// `taskUsageSummary` moved, so `beginNewTaskIdentity()` now resets one shared recorder beside two
/// per-run values that were written as one lifetime; `widgetWasExpandedForThisRun`, which any run
/// starting resets for all of them; `completedRunNotice`, which the next finished run overwrites;
/// `taskRecordingPolicy`; and the screen-control session's `visionSessionEnvironment`,
/// `visionUserPauseMonitor` and `visionEmergencyStopHotKey`. With one run each is exactly what it
/// was. With two, each is a decision still to make.
struct RunSlot {
    let id: RunID

    var isRunning = false
    var plan: AgentPlan?
    var finalSummary = ""
    var errorMessage: String?
    var errorIsPersistent = false
    var clarificationQuestion: String?
    var clarificationAnswer = ""
    var suggestions: [RunSuggestion] = []
    var stepStatuses: [String: AgentStepStatus] = [:]

    /// Written only through `setApprovalRequest(_:)`, together with `approvalToken`.
    private(set) var approvalRequest: RiskApprovalRequest?
    /// Minted afresh every time an approval parks on this run, and `nil` while none is parked.
    ///
    /// An approval is answered by naming the run *and* this token, so an answer given to one
    /// question can never approve a different one: not another run's (two runs can park requests
    /// that compare equal, since `RiskApprovalRequest` is a value), and not a later question on this
    /// same run (a notification's Allow pressed after the question it was posted for has gone).
    private(set) var approvalToken: UUID?

    /// The one way to park or clear an approval: both halves in one write, a fresh token for every
    /// park and none for a clear, so no code can put a new question under an old question's token.
    /// Returns the token minted, or `nil` for a clear.
    mutating func setApprovalRequest(_ request: RiskApprovalRequest?) -> UUID? {
        approvalRequest = request
        approvalToken = request == nil ? nil : UUID()
        return approvalToken
    }

    var visionCapturePreview: VisionCapturePreview?
    var visionSessionProgress: VisionSessionProgress?
    var visionDelegationRequest: VisionDelegationRequest?
    var visionSessionPause: VisionSessionPause?
    var ranWithoutAskingTrace: String?
    var itemJobProgress: ItemJobProgress?
    var taskUsageSummary: TaskUsageSummary = .empty
    var outcomeWasNotified = false
    var activeTaskOrigin: AgentViewModel.TaskOrigin = .commandCenter

    var preparedRun: PreparedAgentRun?
    var runner: AgentRunner?
    var currentTask: Task<Void, Never>?
    var visionApprovalContinuation: CheckedContinuation<RiskApprovalDecision?, Never>?
    var visionCaptureContinuation: CheckedContinuation<Bool, Never>?
    var visionDelegationContinuation: CheckedContinuation<Bool, Never>?
    var visionResumeContinuation: CheckedContinuation<Bool, Never>?
    var activeVisionSessionID: String?
    var approvedAppsForThisVisionIteration: (apps: [ApprovedApp], failure: String?)?
    var currentTaskID = UUID().uuidString
    var scheduledRunDisplayCommand: String?
    var clarificationAutoExecute = false
    var clarificationOrigin: AgentViewModel.TaskOrigin = .commandCenter
    var activeTaskScope: TaskWorkspaceScope = .unscoped
    var lastAssessedScope: TaskWorkspaceScope = .unscoped
    var explicitWorkspaceBinding: String?
    var clarificationWorkspaceBinding: String?
    var clarificationSubmittedCommand: String?
    var lastCommand = ""
    var pendingCommandForPriorTaskContext: String?
    var pendingTaskHistoryStartedAt: Date?
    var activeResumableTask: ResumableTask?
    var activeItemJobPlan: AgentPlan?
    var activeItemJobCompletedStepIDs: [String] = []
    var activeItemJobFailures: [ItemJobFailure] = []
    var preserveUsageForNextStart = false

    init(id: RunID = RunID()) {
        self.id = id
    }

    /// The address of the approval parked on this run now, or `nil` when none is.
    var parkedApproval: ApprovalTarget? {
        approvalToken.map { ApprovalTarget(runID: id, token: $0) }
    }

    /// Running, or parked on a question only the user can answer — the three terms
    /// `AgentViewModel.isTaskInFlight` has always used for its one run, plus three of the four
    /// questions a screen-control session parks, each holding a continuation exactly as an approval
    /// does. The fourth, a mid-loop approval, is `approvalRequest` and is already counted. Nothing
    /// reads this yet; it is what the cap of three will count once a second slot can exist.
    var isInFlight: Bool {
        isRunning || approvalRequest != nil || clarificationQuestion != nil
            || visionCapturePreview != nil || visionDelegationRequest != nil || visionSessionPause != nil
    }
}
