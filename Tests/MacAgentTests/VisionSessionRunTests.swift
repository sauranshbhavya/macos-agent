import CoreGraphics
import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// SONNY-92: a whole vision session, end to end, through the real view model.
///
/// **Every double here replaces a machine, never a decision.** The capture backend, the recognizer,
/// the input synthesizer and the vision model are all fake; the plan, the executor, the adapter, the
/// containment layer, the risk engine, the approval surface and the view model are all real. So when
/// a test below asserts that a click on "Delete" raised an approval, that approval is the one the
/// floating widget would actually have rendered, derived by the same
/// `RiskApprovalPolicy.requirement(for:context:)` every other capability calls.
///
/// No test in this file posts a real input event or captures a real screen.
@MainActor
@Suite
struct VisionSessionRunTests {
    // MARK: - Doubles

    /// A vision model reading from a script. Records every prompt it was given, so a test can assert
    /// on what was actually sent as well as on what came back.
    private final class ScriptedVisionModel: VisionModelDeciding, @unchecked Sendable {
        private let replies: [String]
        private(set) var prompts: [String] = []
        private(set) var payloads: [RedactedPayload] = []
        private var index = 0

        init(_ replies: [String]) {
            self.replies = replies
        }

        var transcriptDescription: String { "scripted" }

        func decide(prompt: String, payload: RedactedPayload) async throws -> String {
            prompts.append(prompt)
            payloads.append(payload)
            defer { index += 1 }
            // Running off the end means the loop iterated more than the test scripted, which is a
            // test bug worth failing loudly rather than a stop condition worth papering over.
            guard index < replies.count else {
                return #"{"action":"stuck","rationale":"script exhausted"}"#
            }
            return replies[index]
        }
    }

    /// Records what would have been done to the machine, and does nothing to it.
    private final class RecordingSynthesizer: ScreenActionSynthesizing, @unchecked Sendable {
        enum Event: Equatable {
            case activated(String)
            case clicked(CGPoint)
            case typed(String)
            case pressed(VisionActionKey)
            case scrolled(VisionScrollDirection)
        }

        private(set) var events: [Event] = []
        var frontmost: String?
        /// After this many clicks, pretend another app took focus. Driven from inside the double so
        /// the change lands at a deterministic point in the loop — a test that flipped it from
        /// outside would be racing the loop it is testing.
        var stealFocusAfterClicks: Int?

        init(frontmost: String?) {
            self.frontmost = frontmost
        }

        func activateApp(bundleIdentifier: String) async -> Bool {
            events.append(.activated(bundleIdentifier))
            frontmost = bundleIdentifier
            return true
        }

        func frontmostBundleIdentifier() async -> String? { frontmost }

        func currentWindowFrame(windowID: UInt32) async -> CGRect? {
            CGRect(x: 0, y: 0, width: 800, height: 600)
        }

        func ownWindowFrames() async -> [CGRect] { [] }

        func click(atGlobalPoint point: CGPoint) async throws {
            events.append(.clicked(point))
            if let stealFocusAfterClicks, clickCount >= stealFocusAfterClicks {
                frontmost = "com.apple.Notes"
            }
        }

        func type(_ text: String) async throws {
            events.append(.typed(text))
        }

        func press(_ key: VisionActionKey) async throws {
            events.append(.pressed(key))
        }

        func scroll(atGlobalPoint point: CGPoint?, direction: VisionScrollDirection, amount: Int) async throws {
            events.append(.scrolled(direction))
        }

        var clickCount: Int { events.filter { if case .clicked = $0 { return true } else { return false } }.count }
    }

    private struct FakeCaptureBackend: ScreenCaptureBackend {
        let bundleIdentifier: String

        func shareableLayerZeroWindows() async throws -> [ScreenCaptureWindowInfo] {
            [
                ScreenCaptureWindowInfo(
                    windowID: 1,
                    bundleIdentifier: bundleIdentifier,
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                    title: "A window"
                )
            ]
        }

        func frontToBackLayerZeroWindowIDs() async -> [UInt32] { [1] }

        func captureImage(of window: ScreenCaptureWindowInfo) async throws -> ScreenCaptureBackendImage {
            ScreenCaptureBackendImage(pngData: Self.onePixelPNG, pixelWidth: 800, pixelHeight: 600)
        }

        /// A real, decodable 1x1 PNG. The redaction renderer only runs when a region is detected, and
        /// no test here detects one, but a capture that is not a PNG at all would be a fixture that
        /// tests a different failure than the one intended.
        static let onePixelPNG = Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
    }

    private struct GrantedPermissions: ScreenCapturePermissionChecking {
        func hasScreenRecordingPermission() -> Bool { true }
        func requestScreenRecordingPermission() -> Bool { true }
        func isAccessibilityTrusted() -> Bool { true }
        func requestAccessibilityTrust() -> Bool { true }
    }

    /// Finds no text, which is what a window with no secrets in it looks like.
    private struct EmptyRecognizer: ImageTextRecognizing {
        func recognizeText(inPNGData: Data, pixelWidth: Int, pixelHeight: Int) async throws -> [RecognizedTextObservation] {
            []
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        let viewModel: AgentViewModel
        let model: ScriptedVisionModel
        let synthesizer: RecordingSynthesizer
        let root: URL

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture(
        replies: [String],
        mode: AgentInteractionMode = .normal,
        bundleIdentifier: String = "com.apple.Safari",
        frontmost: String? = nil,
        limits: VisionSessionLimits = VisionSessionLimits(maximumIterations: 4, settleNanoseconds: 0)
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionSessionRunTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let suiteName = "VisionSessionRunTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)

        let viewModel = AgentViewModel(
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
            snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
            recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("artifacts.json")),
            shortcutCatalog: NoShortcuts(),
            shortcutRunHistoryStore: ShortcutRunHistoryStore(fileURL: root.appendingPathComponent("shortcut-history.json")),
            taskHistoryStore: TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json")),
            clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-settings.json")
            ),
            localDataDeletionService: LocalDataDeletionService(fileURLs: []),
            priorTaskContextStore: PriorTaskContextStore(),
            taskUsageRecorder: TaskUsageRecorder(),
            plannerProviderRegistry: PlannerProviderRegistry(
                defaultProvider: PlannerProvider(id: "unused", displayName: "Unused") { _ in UnreachableVisionPlanner() }
            ),
            plannerSelection: nil,
            userDefaults: userDefaults,
            whitelist: PathWhitelist(roots: [root])
        )
        viewModel.interactionMode = mode

        let model = ScriptedVisionModel(replies)
        let synthesizer = RecordingSynthesizer(frontmost: frontmost)
        viewModel.visionSessionEnvironment = VisionSessionEnvironment(
            captureService: ScreenCaptureService(
                permissionChecker: GrantedPermissions(),
                backend: FakeCaptureBackend(bundleIdentifier: bundleIdentifier)
            ),
            redactionService: LocalRedactionService(textRecognizer: EmptyRecognizer()),
            synthesizer: synthesizer,
            modelClient: model,
            limits: limits,
            interaction: viewModel
        )

        return Fixture(viewModel: viewModel, model: model, synthesizer: synthesizer, root: root)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            if Date() > deadline {
                Issue.record("timed out waiting for: \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForIdle(_ viewModel: AgentViewModel, timeout: TimeInterval = 4) async throws {
        try await waitUntil("the run to finish", timeout: timeout) { !viewModel.isRunning }
    }

    // MARK: - Ordinary actions run without asking

    /// **Normal mode: a whole session, silently.** Two ordinary clicks and a done, with no approval
    /// ever raised — which is founder decision 2's "Normal and Power run vision actions silently".
    @Test
    func anOrdinarySessionRunsToCompletionWithoutAskingInNormalMode() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":100,"y":100,"target":"Bookmarks","consequence":"ordinary","rationale":"open the sidebar"}"#,
            #"{"action":"click","x":120,"y":140,"target":"Reading List","consequence":"ordinary","rationale":"pick the list"}"#,
            #"{"action":"done","rationale":"The reading list is open."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open my reading list", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.synthesizer.clickCount == 2)
        #expect(fixture.viewModel.finalSummary == "The reading list is open.")
        // The app was brought forward exactly once, not on every iteration — an activation per loop
        // would be a focus steal per loop.
        #expect(fixture.synthesizer.events.filter { $0 == .activated("com.apple.Safari") }.count == 1)
    }

    // MARK: - The consequence rule, mid-loop

    /// **A destructive action asks, in Normal mode, mid-loop.** The standing rule the founder kept
    /// when they made screen control silent. The approval raised is a real one on the real surface.
    @Test
    func aDestructiveActionRaisesAnApprovalMidLoopInNormalMode() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"Delete","consequence":"ordinary","rationale":"remove it"}"#,
            #"{"action":"done","rationale":"Deleted."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "delete the draft", appName: "Safari")
        try await waitUntil("the mid-loop approval") { fixture.viewModel.approvalRequest != nil }

        let request = try #require(fixture.viewModel.approvalRequest)
        #expect(request.requirement == .explicitApproval)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.assessment.escalations.first?.consequence == .destructive)
        // The model called it ordinary; the label is what asked. The copy has to say which.
        #expect(request.assessment.escalations.first?.reason.contains("labelled") == true)
        #expect(request.approvalCopy.actionDescription.contains("Delete"))
        // Nothing was clicked while the question was open.
        #expect(fixture.synthesizer.clickCount == 0)

        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 1)
        #expect(fixture.viewModel.finalSummary == "Deleted.")
    }

    /// The same in Power mode — Power buys the user nothing here, which is the coordinator's final
    /// bound on it.
    @Test
    func aDestructiveActionAsksInPowerModeToo() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"click","x":10,"y":10,"target":"Delete","consequence":"destructive","rationale":"r"}"#],
            mode: .power
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "delete it", appName: "Safari")
        try await waitUntil("the mid-loop approval") { fixture.viewModel.approvalRequest != nil }

        #expect(fixture.viewModel.approvalRequest?.requirement == .explicitApproval)
        fixture.viewModel.cancelCurrentRun()
        try await waitForIdle(fixture.viewModel)
    }

    /// **The SONNY-62 re-arm, mid-loop.** One approval covers the action it was given for; a second,
    /// *different* tier-3 reason re-prompts rather than riding the first. Same tier, same
    /// requirement, entirely different question — which is exactly the case bare-tier comparison got
    /// wrong at the plan level and would get wrong here.
    @Test
    func aSecondDifferentTierThreeReasonRePromptsInsteadOfRidingTheFirstApproval() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"Send","consequence":"affects_others","rationale":"send it"}"#,
            #"{"action":"click","x":20,"y":20,"target":"Delete","consequence":"destructive","rationale":"clean up"}"#,
            #"{"action":"done","rationale":"Both done."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "send then tidy", appName: "Safari")

        try await waitUntil("the first approval") { fixture.viewModel.approvalRequest != nil }
        let first = try #require(fixture.viewModel.approvalRequest)
        #expect(first.approvalCopy.actionDescription.contains("Send"))
        let firstReasons = Set(first.assessment.escalations.map(\.reason))
        fixture.viewModel.start()

        try await waitUntil("the second, different approval") {
            fixture.viewModel.approvalRequest.map { request in
                Set(request.assessment.escalations.map(\.reason)) != firstReasons
            } ?? false
        }
        let second = try #require(fixture.viewModel.approvalRequest)
        #expect(second.approvalCopy.actionDescription.contains("Delete"))
        // The load-bearing assertion: the consent recorded for the first would not have covered the
        // second, which is *why* the second was raised at all.
        #expect(RiskApprovalDecision.approved(answering: first).authorizes(second) == false)

        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)
        #expect(fixture.synthesizer.clickCount == 2)
    }

    /// The other half of the re-arm, and the one that stops it being merely "ask every time": a
    /// *repeat* of the same reason rides the approval already given.
    @Test
    func repeatingTheSameReasonDoesNotAskTwice() async throws {
        let sendAgain = #"{"action":"click","x":10,"y":10,"target":"Send","consequence":"affects_others","rationale":"send"}"#
        let fixture = try makeFixture(replies: [
            sendAgain,
            sendAgain,
            #"{"action":"done","rationale":"Sent twice."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "send twice", appName: "Safari")
        try await waitUntil("the only approval") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 2)
        #expect(fixture.viewModel.finalSummary == "Sent twice.")
    }

    // MARK: - Safe mode

    /// **Safe mode asks before every vision action, and shows every capture before it is sent.** Two
    /// separate moments per iteration, because the capture goes out before the model has decided
    /// anything.
    @Test
    func safeModeShowsTheCaptureAndThenAsksAboutTheAction() async throws {
        let fixture = try makeFixture(
            replies: [
                #"{"action":"click","x":10,"y":10,"target":"Bookmarks","consequence":"ordinary","rationale":"r"}"#,
                #"{"action":"done","rationale":"Done."}"#
            ],
            mode: .safe
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open bookmarks", appName: "Safari")

        // **Safe mode gates the session envelope before the loop starts.** The plan-level assessment
        // is tier 3, and Safe's floor makes every runnable tier ask — so a Safe-mode user is asked
        // once about the session and then again about each capture and each action. Asserted rather
        // than skipped past, because it is the first thing a Safe-mode user actually experiences.
        try await waitUntil("the session-envelope approval") { fixture.viewModel.approvalRequest != nil }
        let envelope = try #require(fixture.viewModel.approvalRequest)
        #expect(envelope.approvalCopy.actionDescription.contains("Control Safari"))
        #expect(envelope.approvalCopy.dataLeavesDevice)
        #expect(fixture.model.prompts.isEmpty)
        fixture.viewModel.start()

        // The capture preview comes next, before a single byte has been sent.
        try await waitUntil("the capture preview") { fixture.viewModel.visionCapturePreview != nil }
        let preview = try #require(fixture.viewModel.visionCapturePreview)
        #expect(preview.appDisplayName == "Safari")
        #expect(preview.iteration == 1)
        #expect(preview.redactedPNGData != nil)
        #expect(fixture.model.prompts.isEmpty, "nothing may be sent before the user has seen it")

        fixture.viewModel.resolveVisionCapturePreview(allowing: true)

        // Then the action approval — for an *ordinary* action, which Normal would have run silently.
        try await waitUntil("the action approval") { fixture.viewModel.approvalRequest != nil }
        #expect(fixture.viewModel.approvalRequest?.requirement == .explicitApproval)
        #expect(fixture.model.prompts.count == 1)

        fixture.viewModel.start()
        try await waitUntil("the second capture preview") { fixture.viewModel.visionCapturePreview != nil }
        fixture.viewModel.resolveVisionCapturePreview(allowing: true)
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 1)
    }

    /// Declining the capture ends the session — there is no next step that does not begin with
    /// sending one.
    @Test
    func decliningTheCapturePreviewEndsTheSessionWithoutSendingAnything() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"click","x":10,"y":10,"target":"OK","rationale":"r"}"#],
            mode: .safe
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "do a thing", appName: "Safari")
        try await waitUntil("the session-envelope approval") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.start()
        try await waitUntil("the capture preview") { fixture.viewModel.visionCapturePreview != nil }
        fixture.viewModel.resolveVisionCapturePreview(allowing: false)
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.model.prompts.isEmpty)
        #expect(fixture.synthesizer.clickCount == 0)
        #expect(fixture.viewModel.finalSummary.contains("not to send"))
    }

    // MARK: - Stopping

    /// **One press ends the run.** The experiment's Option A, as the semantics of the stop control:
    /// the summary is the honest "Stopped.", not "You declined", and nothing further is clicked.
    @Test
    func onePressOfStopDuringAMidLoopApprovalEndsTheWholeSession() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"Delete","consequence":"destructive","rationale":"r"}"#,
            #"{"action":"click","x":20,"y":20,"target":"Bookmarks","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"done","rationale":"should never be reached"}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "delete then browse", appName: "Safari")
        try await waitUntil("the approval") { fixture.viewModel.approvalRequest != nil }

        fixture.viewModel.cancelCurrentRun()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.synthesizer.clickCount == 0, "the declined action must not run")
        #expect(fixture.model.prompts.count == 1, "the loop must not have asked the model again")
        #expect(!fixture.viewModel.finalSummary.contains("declined"))
        // A deny is a real approval resolution, so the one-time explainer is spent either way.
        #expect(fixture.viewModel.hasCompletedFirstApproval)
    }

    // MARK: - Containment, live

    /// The frontmost boundary, through the whole stack: another app takes focus mid-session and the
    /// next iteration refuses rather than clicking into a window Sonny never looked at.
    @Test
    func anotherAppTakingFocusMidSessionEndsTheSession() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"Bookmarks","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"click","x":20,"y":20,"target":"More","consequence":"ordinary","rationale":"r"}"#
        ])
        defer { fixture.tearDown() }

        fixture.synthesizer.stealFocusAfterClicks = 1
        fixture.viewModel.startVisionSession(goal: "browse", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 1)
        #expect(fixture.viewModel.finalSummary.contains("no longer the app in front"))
    }

    /// The iteration cap, through the whole stack: a model that never says done is stopped, with an
    /// honest sentence and no product surface offering to continue.
    @Test
    func aSessionThatNeverFinishesStopsAtTheIterationCap() async throws {
        let keepClicking = #"{"action":"click","x":10,"y":10,"target":"Next","consequence":"ordinary","rationale":"r"}"#
        let fixture = try makeFixture(
            replies: Array(repeating: keepClicking, count: 10),
            limits: VisionSessionLimits(maximumIterations: 3, settleNanoseconds: 0)
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "click forever", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 3)
        #expect(fixture.viewModel.finalSummary.contains("after 3 steps"))
    }

    /// **The terminal ban, from the user's own entry point.** No approval, no session, an honest
    /// refusal — and nothing was ever captured or sent.
    @Test
    func askingSonnyToControlATerminalIsRefusedWithNoApprovalAndNoCapture() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"click","x":1,"y":1,"target":"OK","rationale":"r"}"#],
            bundleIdentifier: "com.apple.Terminal",
            frontmost: "com.apple.Terminal"
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "run a command", appName: "Terminal")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.model.prompts.isEmpty)
        #expect(fixture.synthesizer.events.isEmpty)
        #expect(fixture.viewModel.errorMessage?.contains("never controls a terminal") == true)
    }

    // MARK: - Egress

    /// **Redaction ran on every capture that was sent**, and the model only ever saw the payload it
    /// produced. Structural rather than asserted — `decide` takes a `RedactedPayload` and nothing
    /// else can be handed to it — but pinned here so the count is checkable end to end.
    @Test
    func everyCaptureSentToTheModelWentThroughRedaction() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"A","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"click","x":20,"y":20,"target":"B","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"done","rationale":"Done."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "click two things", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.model.payloads.count == 3)
        for payload in fixture.model.payloads {
            #expect(payload.redactedImagePNGData != nil)
            #expect(payload.sourceBundleIdentifier == "com.apple.Safari")
        }
    }

    /// Every prompt the model received carried the boundary — asserted over the real prompts a real
    /// session produced, not over a builder call.
    @Test
    func everyPromptSentCarriesTheUntrustedContentBoundary() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"A","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"done","rationale":"Done."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "click a thing", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.model.prompts.count == 2)
        for prompt in fixture.model.prompts {
            #expect(prompt.contains(UntrustedContentBoundary.observedBeginDelimiter))
            #expect(prompt.contains(UntrustedContentBoundary.trustedInstructionBeginDelimiter))
            #expect(prompt.contains("click a thing"))
        }
    }
}

private struct UnreachableVisionPlanner: Planning {
    struct ReachedThePlanner: Error {}
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        throw ReachedThePlanner()
    }
}

private struct NoShortcuts: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { [] }
}
