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
/// **Known to run outside any run, and right only while focus cannot move under them:** the voice
/// recording and transcription `Task`s (`startVoiceRecording`, `stopVoiceRecordingAndTranscribe`), which
/// write `clarificationQuestion`, `currentTaskID` and `preserveUsageForNextStart` on the focused
/// run. While only one run can exist that is the run they mean. A full sweep of the pipeline for
/// hops of this kind is owed before a second run can exist (SONNY-456's handback comment).
enum RunScope {
    @TaskLocal static var current: RunID?
}

/// Everything one run holds (SONNY-456). Each property is the one `AgentViewModel` used to declare
/// for its single run, with the same name, type and default; `AgentViewModel` forwards its old
/// property to the slot of the run in scope, so nothing that read or wrote the old property changed.
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

    var approvalRequest: RiskApprovalRequest?
    /// Minted afresh every time an approval parks on this run, and `nil` while none is parked.
    ///
    /// An approval is answered by naming the run *and* this token, so an answer given to one
    /// question can never approve a different one: not another run's (two runs can park requests
    /// that compare equal, since `RiskApprovalRequest` is a value), and not a later question on this
    /// same run (a notification's Allow pressed after the question it was posted for has gone).
    var approvalToken: UUID?

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
