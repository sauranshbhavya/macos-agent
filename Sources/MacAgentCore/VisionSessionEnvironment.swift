import Foundation

/// What the user is about to send, shown before it is sent.
///
/// Safe mode only, per founder decision 2 (2026-08-14): *"Safe asks before every vision action and
/// shows each capture before it is sent."* Two separate moments per iteration, because the capture
/// goes out **before** the model has decided anything — there is no single prompt that can both show
/// the screenshot and name the action it will produce.
///
/// Carries the redacted bytes, not the original: what the user is being shown is what will actually
/// leave, black boxes and all. Showing the unredacted capture and sending the redacted one would
/// make the preview a different picture from the one it claims to preview.
public struct VisionCapturePreview: Equatable, Sendable {
    public let appDisplayName: String
    public let windowTitle: String?
    public let redactedPNGData: Data?
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// What redaction found and painted over, so the user can see the preview is not merely a
    /// screenshot with a promise attached.
    public let redactionReport: [RedactionReportEntry]
    public let iteration: Int

    public init(
        appDisplayName: String,
        windowTitle: String?,
        redactedPNGData: Data?,
        pixelWidth: Int,
        pixelHeight: Int,
        redactionReport: [RedactionReportEntry],
        iteration: Int
    ) {
        self.appDisplayName = appDisplayName
        self.windowTitle = windowTitle
        self.redactedPNGData = redactedPNGData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.redactionReport = redactionReport
        self.iteration = iteration
    }
}

/// What the HUD is told while a session runs.
public struct VisionSessionProgress: Equatable, Sendable {
    public let appDisplayName: String
    public let iteration: Int
    public let maximumIterations: Int
    /// The action line — what Sonny is doing right now, in one sentence.
    public let currentAction: String

    public init(appDisplayName: String, iteration: Int, maximumIterations: Int, currentAction: String) {
        self.appDisplayName = appDisplayName
        self.iteration = iteration
        self.maximumIterations = maximumIterations
        self.currentAction = currentAction
    }
}

/// The UI half of a vision session: the two questions it may need to ask, and the progress it
/// reports.
///
/// `@MainActor` and class-bound because the only conformer is the view model, and the questions are
/// real UI. Everything on this protocol is a *question or a notification* — no conformer decides
/// whether an action may run. That decision is `VisionSessionContainment`'s, which asks the risk
/// engine; this protocol only carries the resulting question to a human and their answer back.
@MainActor
public protocol VisionSessionInteracting: AnyObject {
    /// Put a mid-loop approval in front of the user. Returns their decision, or `nil` if they
    /// declined.
    ///
    /// Throws `CancellationError` when the user stops the run instead of answering — which is a
    /// different outcome from declining and must stay different: a decline is an answer about one
    /// action, a stop is an answer about the session.
    func requestVisionActionApproval(_ request: RiskApprovalRequest) async throws -> RiskApprovalDecision?

    /// Safe mode's pre-send capture preview. Returns true to send.
    func confirmVisionCaptureBeforeSending(_ preview: VisionCapturePreview) async throws -> Bool

    /// Progress for the HUD.
    func visionSessionDidProgress(_ progress: VisionSessionProgress)

    /// The authority context this run is executing under — the same value the plan-level approval
    /// was derived from.
    ///
    /// Read per action rather than captured once, so that a user who switches to Safe mode part way
    /// through a session gets Safe mode for the rest of it. The reverse also holds and is the reason
    /// this is worth stating: switching *out* of Safe mode mid-session stops the per-action asking,
    /// which is the user exercising their own dial and not a bypass.
    func visionApprovalContext() -> ApprovalContext
}

/// Everything a vision session needs from outside `MacAgentCore`'s pure logic, in one field.
///
/// One aggregate rather than six fields on `CapabilityExecutionContext`, because every one of them
/// is meaningless without the others: a session with a capture service but no synthesizer cannot do
/// anything, and five separate optionals would make that unrepresentable-but-constructible. `nil` on
/// the context means "this build has no vision wiring", which is the honest state for every test
/// that is not about vision, and for `MacAgentCore` used on its own.
public struct VisionSessionEnvironment {
    public var captureService: ScreenCaptureService
    /// **Constructed with the live recognizer, and this is the one that bites.**
    /// `LocalRedactionService`'s `textRecognizer` parameter defaults to `VisionImageTextRecognizer`,
    /// so the default construction is already correct — but a recognizer that *succeeds* and returns
    /// no observations produces an empty report over the original pixels, with nothing thrown. That
    /// is a silent unredacted send, and it is what a stub or placeholder recognizer looks like. The
    /// fail-closed path only covers a recognizer that *throws*. (Recorded on SONNY-91 by PR #49's
    /// review so row I would be told rather than discover it.)
    public var redactionService: LocalRedactionService
    public var synthesizer: any ScreenActionSynthesizing
    public var modelClient: any VisionModelDeciding
    public var limits: VisionSessionLimits
    public var attentionMonitor: any SessionAttentionMonitoring
    public weak var interaction: (any VisionSessionInteracting)?

    public init(
        captureService: ScreenCaptureService,
        redactionService: LocalRedactionService,
        synthesizer: any ScreenActionSynthesizing,
        modelClient: any VisionModelDeciding,
        limits: VisionSessionLimits = .default,
        attentionMonitor: any SessionAttentionMonitoring = AlwaysAttendedMonitor(),
        interaction: (any VisionSessionInteracting)?
    ) {
        self.captureService = captureService
        self.redactionService = redactionService
        self.synthesizer = synthesizer
        self.modelClient = modelClient
        self.limits = limits
        self.attentionMonitor = attentionMonitor
        self.interaction = interaction
    }
}
