import CoreGraphics
import Foundation
import ImageIO
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
        /// Called after each click, so a test can change the world at a deterministic point in the
        /// loop rather than racing it from outside.
        var afterClick: (@Sendable (Int) -> Void)?

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
            afterClick?(clickCount)
            if let throwsAfterDeliveringClick {
                self.throwsAfterDeliveringClick = nil
                throw throwsAfterDeliveringClick
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

        /// Makes the *next* click behave the way a real one interrupted by a stop does: the target
        /// app receives a complete down/up pair — `ClickEventSequence` guarantees the button comes
        /// back up — and then the call throws. Recording the click before throwing is the whole
        /// point: the click happened.
        var throwsAfterDeliveringClick: Error?

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
            ScreenCaptureBackendImage(pngData: Self.windowPNG, pixelWidth: 800, pixelHeight: 600)
        }

        /// A real, decodable 800x600 PNG — the size this backend claims to have captured.
        ///
        /// **It used to be a 1x1 PNG carrying a declared 800x600, and that mismatch was harmless only
        /// by accident** (SONNY-114). The old redaction path re-encoded the image only when a region
        /// was detected, and no test here detects one, so nothing ever decoded the bytes and noticed.
        /// The egress encoder decodes every capture, so the payload's dimensions are now the image's
        /// own — a 1x1 fixture would tell the model it was looking at a one-pixel screenshot and put
        /// every coordinate in these tests out of bounds. A fixture that lies about its own size is a
        /// fixture that tests something other than what it claims.
        static let windowPNG: Data = {
            let context = CGContext(
                data: nil,
                width: 800,
                height: 600,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1))
            context.fill(CGRect(x: 40, y: 40, width: 200, height: 60))
            let buffer = NSMutableData()
            let destination = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            _ = CGImageDestinationFinalize(destination)
            return buffer as Data
        }()
    }

    /// Stands in for the real Carbon registration, so the *wiring* can be pinned without any test
    /// taking a real global shortcut (PR #50 review, F4).
    /// Counts registrations for one test.
    ///
    /// Per-test rather than a static counter: Swift Testing runs tests in parallel, and a shared
    /// static made `builtCount` read 2 in a test that registered once. A counter that can be
    /// polluted by a neighbouring test is a counter that cannot support the assertion it exists for.
    private final class StopHotKeyLedger: @unchecked Sendable {
        private(set) var built = 0
        func recordBuild() { built += 1 }
    }

    private final class FakeStopHotKey: EmergencyStopHotKeyRegistering {
        private let onStop: @MainActor () -> Void

        init(onStop: @escaping @MainActor () -> Void) throws {
            self.onStop = onStop
        }

        /// Fires the handler the way a real `Ctrl-Opt-Esc` press would.
        @MainActor func press() { onStop() }
    }

    /// Grants that a test can take away mid-session.
    private final class RevocablePermissions: ScreenCapturePermissionChecking, @unchecked Sendable {
        var accessibilityTrusted = true
        func hasScreenRecordingPermission() -> Bool { true }
        func requestScreenRecordingPermission() -> Bool { true }
        func isAccessibilityTrusted() -> Bool { accessibilityTrusted }
        func requestAccessibilityTrust() -> Bool { accessibilityTrusted }
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

    /// Reads a different screen on each capture, so a test can put a shell on screen at a chosen
    /// iteration rather than only at the first (SONNY-139).
    ///
    /// The last script entry repeats once the script runs out, which is what a screen that stopped
    /// changing looks like — the alternative, returning nothing, would silently un-show a shell.
    private final class ScriptedRecognizer: ImageTextRecognizing, @unchecked Sendable {
        private let screens: [String]
        private(set) var calls = 0

        init(_ screens: [String]) {
            self.screens = screens
        }

        func recognizeText(inPNGData: Data, pixelWidth: Int, pixelHeight: Int) async throws -> [RecognizedTextObservation] {
            defer { calls += 1 }
            let screen = screens[min(calls, screens.count - 1)]
            // One observation per line, with a plausible box — the shape `VisionImageTextRecognizer`
            // produces. The boxes matter only because the redaction painter uses them; no test here
            // plants a secret.
            return screen.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
                RecognizedTextObservation(
                    string: String(line),
                    boundingBox: CGRect(x: 8, y: 8 + 18 * index, width: 700, height: 16)
                )
            }
        }
    }

    /// Vision OCR that cannot run. The point of the fixture is that this must not become a "no
    /// shell" answer.
    private struct ThrowingRecognizer: ImageTextRecognizing {
        struct Unavailable: Error {}
        func recognizeText(inPNGData: Data, pixelWidth: Int, pixelHeight: Int) async throws -> [RecognizedTextObservation] {
            throw Unavailable()
        }
    }

    /// A terminal window, as the recognizer would read it. Two independent signs — a prompt line and
    /// the shell's own error message — which is the threshold, not a landslide.
    private static let shellScreen = """
    Last login: Sat Aug 16 09:14:22 on ttys000
    sauransh@Mac macos-agent % ./scripts/deploy.sh
    zsh: permission denied: ./scripts/deploy.sh
    sauransh@Mac macos-agent %
    """

    /// An ordinary window with words on it, including one that is a command name — so a passing
    /// shell test cannot be explained by "any text at all refuses".
    private static let ordinaryScreen = """
    Reading List — Safari
    Bookmarks   History   Reading List
    Building a Mac agent, and what npm has to do with it
    """

    // MARK: - Fixture

    private struct Fixture {
        let viewModel: AgentViewModel
        let model: ScriptedVisionModel
        let synthesizer: RecordingSynthesizer
        let journal: VisionSessionJournalStore
        let root: URL

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// An attention monitor a test can flip mid-session.
    private final class SwitchableAttentionMonitor: SessionAttentionMonitoring, @unchecked Sendable {
        var state: SessionAttentionState = .attended
        var presentable = true
        func attentionState() async -> SessionAttentionState { state }
        func canPresentApproval() async -> Bool { presentable }
    }

    private func makeFixture(
        replies: [String],
        mode: AgentInteractionMode = .normal,
        bundleIdentifier: String = "com.apple.Safari",
        frontmost: String? = nil,
        limits: VisionSessionLimits = VisionSessionLimits(maximumIterations: 4, settleNanoseconds: 0),
        attention: SessionAttentionMonitoring? = nil,
        permissions: (any ScreenCapturePermissionChecking)? = nil,
        /// The planner a *delegated* instruction reaches. `nil` means the unreachable one, which is
        /// correct for every test whose delegations resolve instantly or do not delegate at all.
        delegationPlanner: (any Planning)? = nil,
        /// The egress encoding policy. The default is the shipping one, under which an 800x600
        /// fixture never resamples; a test that wants the resampled path supplies a budget the
        /// ladder cannot meet.
        egressPolicy: VisionCaptureEgressPolicy = .default,
        /// What the OCR pass reads off each capture. The default finds nothing, which is a window
        /// with no secrets and no shell on it; SONNY-139's tests supply screens instead.
        recognizer: (any ImageTextRecognizing)? = nil
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
            visionSessionJournalStore: VisionSessionJournalStore(fileURL: root.appendingPathComponent("vision-sessions.json")),
            clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-settings.json")
            ),
            localDataDeletionService: LocalDataDeletionService(fileURLs: []),
            priorTaskContextStore: PriorTaskContextStore(),
            taskUsageRecorder: TaskUsageRecorder(),
            plannerProviderRegistry: PlannerProviderRegistry(
                defaultProvider: PlannerProvider(id: "unused", displayName: "Unused") { _ in
                    delegationPlanner ?? UnreachableVisionPlanner()
                }
            ),
            plannerSelection: nil,
            userDefaults: userDefaults,
            whitelist: PathWhitelist(roots: [root])
        )
        viewModel.interactionMode = mode

        let model = ScriptedVisionModel(replies)
        let synthesizer = RecordingSynthesizer(frontmost: frontmost)
        let journal = VisionSessionJournalStore(fileURL: root.appendingPathComponent("vision-sessions.json"))
        viewModel.visionSessionEnvironment = VisionSessionEnvironment(
            captureService: ScreenCaptureService(
                permissionChecker: permissions ?? GrantedPermissions(),
                backend: FakeCaptureBackend(bundleIdentifier: bundleIdentifier)
            ),
            redactionService: LocalRedactionService(
                textRecognizer: recognizer ?? EmptyRecognizer(),
                egressPolicy: egressPolicy
            ),
            synthesizer: synthesizer,
            modelClient: model,
            limits: limits,
            attentionMonitor: attention ?? AlwaysAttendedMonitor(),
            permissionChecker: permissions ?? GrantedPermissions(),
            journalStore: journal,
            interaction: viewModel
        )

        return Fixture(
            viewModel: viewModel,
            model: model,
            synthesizer: synthesizer,
            journal: journal,
            root: root
        )
    }

    /// How long these helpers wait before declaring a hang (SONNY-159, SONNY-160, SONNY-161).
    ///
    /// **This is a deadlock backstop, not a timing assertion, and the distinction is the whole
    /// point.** Nothing in this suite is asserting that the vision loop is fast; every test here
    /// asserts what it *did*. A deadline exists only so that a genuine hang fails the run instead of
    /// wedging it forever. Read that way, the old three and four seconds were far too tight — they
    /// were close enough to real running time that they fired on a busy machine, which turned a
    /// backstop into a measurement of the hardware.
    ///
    /// **Why it fired.** This suite is `@MainActor` and Swift Testing runs suites concurrently, so
    /// every `@MainActor` test in this target interleaves on one actor; any test doing sustained
    /// synchronous work anywhere in the target pushes its neighbours toward their deadlines. The
    /// failures were never wrong answers — always `waitUntil` timeouts, on a test that varied
    /// between runs, with labels spread across the whole file. That spread is the signature of
    /// starvation rather than of one slow path.
    ///
    /// **The measured cost of getting this wrong.** On `main` at `89e317b`, twelve consecutive
    /// full-suite runs at ordinary load produced eleven passes and one failure — 42 issues in the
    /// failing run, 7.656 s against a 5.2–5.5 s norm. SONNY-159 measured the same rate more
    /// carefully on a quiet machine: 17 of 18 on `main` at `7b9fec9`, and 15 of 16 on
    /// `feature/terminal-screen-check` at `315419e`, indistinguishable at that sample size. Its
    /// worst observed run produced 88 issues. SONNY-161 then measured the other direction: two
    /// legitimately heavy task-history tests were enough to take the failure rate from zero in four
    /// runs to one in three.
    ///
    /// **Why the number below is a backstop and not a tuned threshold.** Tuning against a threshold
    /// nobody has measured is what SONNY-161 rejected, correctly. This is not that: the worst
    /// per-test wall clock observed across every run in those three investigations is under eight
    /// seconds, and thirty is roughly four times that. It is not chosen to be "enough" for a
    /// particular machine — it is chosen to be so far outside the range of *any* observed real
    /// completion that a failure here means the loop is stuck, which is the only thing this deadline
    /// was ever meant to catch.
    ///
    /// **What did not change, deliberately.** Not one test's assertions, and not the polling
    /// interval. Raising a backstop cannot make a passing test pass "more" — a test that completes
    /// still completes at exactly the same moment and asserts exactly what it did before. The only
    /// behaviour that changes is what happens when the condition never becomes true, and there the
    /// change is from "fail after 3 s, possibly because another test was busy" to "fail after 30 s,
    /// which means it is genuinely stuck."
    private static let hangBackstop: TimeInterval = 30

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = Self.hangBackstop,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            if Date() > deadline {
                // Says what a failure here means, because the previous message did not and the
                // cost of that was concrete: sessions reasoned about whether a red suite was
                // theirs, and one made changes on the misdiagnosis before reverting them.
                Issue.record("""
                    timed out after \(Int(timeout))s waiting for: \(description).
                    This deadline is a deadlock backstop, not a timing assertion — at this length it \
                    should only fire when the vision loop is genuinely stuck, not when the machine \
                    is busy. Treat it as a real failure and look for what is not completing.
                    """)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForIdle(_ viewModel: AgentViewModel, timeout: TimeInterval = Self.hangBackstop) async throws {
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

    /// **A `wait` decision waits and then the session carries on** — the one action kind with no
    /// end-to-end coverage until now (PR #50 cycle-2 residual).
    ///
    /// The reviewer mutated the loop's `.wait` arm to fall through to synthesis — the exact edit F2's
    /// fix names as the failure mode it guards — and the suite stayed green: nothing anywhere
    /// scripted a `wait`, so `grep '"action":"wait"'` over `Tests/` returned nothing and one of eight
    /// kinds was unexercised. The guard did fire, so the protection worked; the regression would
    /// simply have shipped green in a different way.
    ///
    /// Asserted on both halves: nothing is synthesized for the wait itself, and the session continues
    /// to the action after it rather than ending.
    @Test
    func aWaitDecisionWaitsAndTheSessionContinues() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"wait","rationale":"the page is still loading"}"#,
            #"{"action":"click","x":10,"y":10,"target":"Bookmarks","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"done","rationale":"Done."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "wait then click", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        // The wait synthesized nothing, and the click after it still happened.
        #expect(fixture.synthesizer.clickCount == 1)
        #expect(fixture.viewModel.finalSummary == "Done.")
        // Three iterations really ran — the wait cost one, so a wait that silently ended the session
        // or fell through to synthesis would fail here.
        #expect(fixture.model.prompts.count == 3)

        // A wait produces no journal entry: it drives nothing, so there is nothing to record.
        let record = try #require(try fixture.journal.loadAll().first)
        #expect(record.entries.count == 1)
        #expect(record.entries.first?.actionType == "click")

        // And the model was told it waited, so the next decision has that context.
        #expect(try #require(fixture.model.prompts.dropFirst().first).contains("waited for the screen to settle"))
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
        #expect(preview.redactedImageData != nil)
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

    /// **The widget must render the capture question, or a Safe-mode session hangs.**
    ///
    /// `hasVisibleWidgetPanel` is the single source of truth for both the widget's panel and
    /// `FloatingWidgetWindowController`'s compositing decision, so a parked continuation the panel
    /// declines to show is a session suspended with nothing on screen able to answer it. Pinned
    /// beside the other three unconditional states for the same reason they are.
    @Test
    func theWidgetPanelIsVisibleWhileACaptureIsWaitingToBeReviewed() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"done","rationale":"Done."}"#],
            mode: .safe
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "look", appName: "Safari")
        try await waitUntil("the session-envelope approval") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.start()
        try await waitUntil("the capture preview") { fixture.viewModel.visionCapturePreview != nil }

        #expect(fixture.viewModel.hasVisibleWidgetPanel)
        // And the composer stays closed while the question is open, so a user cannot start a second
        // task on top of a suspended session.
        #expect(fixture.viewModel.isRunning)

        fixture.viewModel.resolveVisionCapturePreview(allowing: true)
        try await waitForIdle(fixture.viewModel)
        #expect(fixture.viewModel.visionCapturePreview == nil)
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

    // MARK: - Delegation (SONNY-93, founder decision 4)

    /// **Normal mode never asks about the delegation itself**, and the delegated plan still runs
    /// through the ordinary engine gate — which is the whole distinction the founder drew.
    @Test
    func aDelegationRunsWithoutAskingInNormalModeAndItsResultReachesTheModel() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"delegate","instruction":"2 + 2","rationale":"arithmetic is not a clicking job"}"#,
            #"{"action":"done","rationale":"Finished."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "work out a sum", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.approvalRequest == nil, "a tier-0 delegated plan asks nothing")
        #expect(fixture.viewModel.visionDelegationRequest == nil, "Normal mode never asks about delegating")
        #expect(fixture.synthesizer.clickCount == 0)
        // The delegation cost one iteration, and its result came back as observed history the model
        // could read on the next turn.
        // `try #require` before indexing, not `#expect` (PR #50 review, F12): `#expect` is
        // non-fatal in Swift Testing, so a soft count assertion followed by a hard index traps the
        // *whole process* on regression, and every test scheduled after it never runs.
        #expect(fixture.model.prompts.count == 2)
        let secondPrompt = try #require(fixture.model.prompts.dropFirst().first)
        #expect(secondPrompt.contains("Sonny's own tools completed"))
        #expect(secondPrompt.contains("4"))
        #expect(fixture.viewModel.finalSummary == "Finished.")
    }

    /// **Safe mode asks first**, and the question is its own surface — not the approval card, because
    /// it is a question about method rather than about risk.
    @Test
    func safeModeAsksBeforeADelegationFires() async throws {
        let fixture = try makeFixture(
            replies: [
                #"{"action":"delegate","instruction":"2 + 2","rationale":"r"}"#,
                #"{"action":"done","rationale":"Finished."}"#
            ],
            mode: .safe
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "work out a sum", appName: "Safari")
        try await waitUntil("the session-envelope approval") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.start()
        try await waitUntil("the capture preview") { fixture.viewModel.visionCapturePreview != nil }
        fixture.viewModel.resolveVisionCapturePreview(allowing: true)

        try await waitUntil("the delegation question") { fixture.viewModel.visionDelegationRequest != nil }
        let request = try #require(fixture.viewModel.visionDelegationRequest)
        #expect(request.instructionText == "2 + 2")
        #expect(request.appDisplayName == "Safari")
        #expect(fixture.viewModel.hasVisibleWidgetPanel)

        fixture.viewModel.resolveVisionDelegation(allowing: true)

        // **And then the delegated plan asks on its own account.** Two questions, deliberately
        // different: the first is about method — should Sonny use its tools instead of clicking —
        // and this one is the ordinary gate on what the plan actually does, which in Safe mode fires
        // for every runnable tier. That is the founder's distinction made visible: the decision
        // removed a prompt about *delegating*, never the gate on the delegation's contents.
        try await waitUntil("the delegated plan's own approval") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.start()

        // Iteration two: another capture preview, then the model says done.
        try await waitUntil("the next capture preview") { fixture.viewModel.visionCapturePreview != nil }
        fixture.viewModel.resolveVisionCapturePreview(allowing: true)
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.finalSummary == "Finished.")
        // The delegated instruction really ran, through the instant resolver a typed "2 + 2" would
        // have taken — no model round trip for arithmetic.
        #expect(fixture.model.prompts.count == 2)
        #expect(try #require(fixture.model.prompts.dropFirst().first).contains("4"))
    }

    /// **Declining a delegation is not stopping.** The loop is told, and continues from the screen —
    /// the labelled deny SONNY-80's standing note asked for, arriving where it is obviously useful.
    @Test
    func decliningADelegationTellsTheModelAndKeepsTheSessionGoing() async throws {
        let fixture = try makeFixture(
            replies: [
                #"{"action":"delegate","instruction":"2 + 2","rationale":"r"}"#,
                #"{"action":"click","x":10,"y":10,"target":"Bookmarks","consequence":"ordinary","rationale":"r"}"#,
                #"{"action":"done","rationale":"Did it on screen."}"#
            ],
            mode: .safe
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "do a thing", appName: "Safari")
        try await waitUntil("the envelope approval") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.start()
        try await waitUntil("the capture preview") { fixture.viewModel.visionCapturePreview != nil }
        fixture.viewModel.resolveVisionCapturePreview(allowing: true)
        try await waitUntil("the delegation question") { fixture.viewModel.visionDelegationRequest != nil }

        fixture.viewModel.resolveVisionDelegation(allowing: false)
        // Declining the method means the delegated plan never runs, so its own gate never fires.
        #expect(fixture.viewModel.approvalRequest == nil)

        // The session did not end — the next iteration asked for the next capture, and once that is
        // allowed the model is told what happened rather than being left to guess.
        try await waitUntil("the second capture preview") { fixture.viewModel.visionCapturePreview != nil }
        fixture.viewModel.resolveVisionCapturePreview(allowing: true)
        try await waitUntil("the second prompt") { fixture.model.prompts.count == 2 }
        #expect(try #require(fixture.model.prompts.dropFirst().first).contains("you declined"))
        fixture.viewModel.cancelCurrentRun()
        try await waitForIdle(fixture.viewModel)
    }

    /// **No recursion.** A delegated plan carrying a vision step is refused before it is prepared —
    /// without which a model could delegate its way into a second session inside the first, each with
    /// its own iteration cap, and the cap would stop bounding anything.
    @Test
    func aDelegationCannotStartASecondVisionSession() async throws {
        // **The planner really does return a vision-bearing plan here.** An earlier version of this
        // test let the delegation reach the unreachable planner, which threw — so the delegation
        // failed for the wrong reason and the recursion guard was never executed. A mutation that
        // deleted the guard passed the whole suite. This planner is what makes the test bite.
        let fixture = try makeFixture(
            replies: [
                #"{"action":"delegate","instruction":"control Notes and write a note","rationale":"r"}"#,
                #"{"action":"done","rationale":"Finished on screen."}"#
            ],
            delegationPlanner: NestingVisionPlanner()
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "write a note", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.model.prompts.count == 2)
        // The loop was told the delegation could not be done, in the words the guard produces...
        #expect(try #require(fixture.model.prompts.dropFirst().first).contains("second screen-control session"))
        // ...and it carried on rather than nesting: one session, one iteration cap, one summary.
        #expect(fixture.viewModel.finalSummary == "Finished on screen.")
        #expect(fixture.synthesizer.events.filter { $0 == .activated("com.apple.Safari") }.count == 1)
    }

    /// **Stopping during a delegation question stops the run**, like the other two parked questions.
    @Test
    func stoppingDuringADelegationQuestionEndsTheSession() async throws {
        let fixture = try makeFixture(
            replies: [
                #"{"action":"delegate","instruction":"2 + 2","rationale":"r"}"#,
                #"{"action":"done","rationale":"should never be reached"}"#
            ],
            mode: .safe
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "do a thing", appName: "Safari")
        try await waitUntil("the envelope approval") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.start()
        try await waitUntil("the capture preview") { fixture.viewModel.visionCapturePreview != nil }
        fixture.viewModel.resolveVisionCapturePreview(allowing: true)
        try await waitUntil("the delegation question") { fixture.viewModel.visionDelegationRequest != nil }

        fixture.viewModel.cancelCurrentRun()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.visionDelegationRequest == nil)
        #expect(fixture.model.prompts.count == 1, "the loop must not have asked the model again")
    }

    // MARK: - The emergency-stop hotkey's wiring (PR #50 review, F4)

    /// **A live session really registers the hotkey, and every exit releases it.**
    ///
    /// Nothing asserted this before: removing the `registerEmergencyStopHotKey()` call from
    /// `visionSessionDidProgress` left the whole suite green, so `Ctrl-Opt-Esc` could have silently
    /// never registered for any session. The tests that existed called `emergencyStopVisionSession()`
    /// directly, which exercises the *handler* and says nothing about whether anything is listening.
    ///
    /// SONNY-95's closing comment claimed `isVisionSessionLive` is "the one definition both the HUD's
    /// visibility and the hotkey's registration window read, so the two cannot drift". The HUD half
    /// was pinned; this is the other half.
    @Test
    func aLiveSessionRegistersTheEmergencyStopHotKeyAndEveryExitReleasesIt() async throws {
        let ledger = StopHotKeyLedger()
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"A","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"done","rationale":"Done."}"#
        ])
        defer { fixture.tearDown() }
        fixture.viewModel.visionEmergencyStopHotKeyFactory = { onStop in
            ledger.recordBuild()
            return try FakeStopHotKey(onStop: onStop)
        }

        #expect(fixture.viewModel.visionEmergencyStopHotKey == nil, "nothing is held outside a session")

        fixture.viewModel.startVisionSession(goal: "click a thing", appName: "Safari")
        try await waitUntil("the hotkey to be registered") { fixture.viewModel.visionEmergencyStopHotKey != nil }
        #expect(ledger.built == 1, "exactly one registration per session, not one per iteration")

        try await waitForIdle(fixture.viewModel)

        // Released on exit — a permanently-held global shortcut is a key combination taken from every
        // other app on the machine, so the release matters as much as the registration.
        #expect(fixture.viewModel.visionEmergencyStopHotKey == nil)
        #expect(ledger.built == 1)
    }

    /// **The registered hotkey is wired to the stop, not merely constructed.** Pressing it ends the
    /// run — asserted through the object the production path actually built, rather than by calling
    /// the view model's method directly the way the older tests do.
    @Test
    func pressingTheRegisteredHotKeyStopsTheSession() async throws {
        let keepClicking = #"{"action":"click","x":10,"y":10,"target":"A","consequence":"ordinary","rationale":"r"}"#
        let fixture = try makeFixture(
            replies: Array(repeating: keepClicking, count: 8),
            limits: VisionSessionLimits(maximumIterations: 8, settleNanoseconds: 40_000_000)
        )
        defer { fixture.tearDown() }
        fixture.viewModel.visionEmergencyStopHotKeyFactory = { try FakeStopHotKey(onStop: $0) }

        fixture.viewModel.startVisionSession(goal: "click forever", appName: "Safari")
        try await waitUntil("the first click") { fixture.synthesizer.clickCount == 1 }

        let hotKey = try #require(fixture.viewModel.visionEmergencyStopHotKey as? FakeStopHotKey)
        hotKey.press()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount <= 2, "actual: \(fixture.synthesizer.clickCount)")
        #expect(fixture.viewModel.visionSessionProgress == nil)
    }

    /// A refused session never reaches the loop, so it must never take the shortcut either.
    @Test
    func aRefusedSessionNeverRegistersTheHotKey() async throws {
        let ledger = StopHotKeyLedger()
        let fixture = try makeFixture(
            replies: [#"{"action":"click","x":1,"y":1,"target":"OK","rationale":"r"}"#],
            bundleIdentifier: "com.apple.Terminal",
            frontmost: "com.apple.Terminal"
        )
        defer { fixture.tearDown() }
        fixture.viewModel.visionEmergencyStopHotKeyFactory = { onStop in
            ledger.recordBuild()
            return try FakeStopHotKey(onStop: onStop)
        }

        fixture.viewModel.startVisionSession(goal: "run a command", appName: "Terminal")
        try await waitForIdle(fixture.viewModel)

        #expect(ledger.built == 0)
        #expect(fixture.viewModel.visionEmergencyStopHotKey == nil)
    }

    // MARK: - The HUD (SONNY-95)

    /// **Power without covertness.** While Sonny controls an app the HUD says so, says which app,
    /// says what it is doing, and clears when the session ends.
    @Test
    func theHudRendersForALiveSessionAndClearsWhenItEnds() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"Bookmarks","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"done","rationale":"Done."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open bookmarks", appName: "Safari")
        try await waitUntil("the HUD") { fixture.viewModel.visionSessionProgress != nil }

        let progress = try #require(fixture.viewModel.visionSessionProgress)
        #expect(progress.appDisplayName == "Safari")
        #expect(progress.iteration == 1)
        #expect(progress.maximumIterations == 4)
        #expect(!progress.currentAction.isEmpty)
        #expect(fixture.viewModel.hasVisibleWidgetPanel)
        #expect(fixture.viewModel.isVisionSessionLive)

        try await waitForIdle(fixture.viewModel)
        #expect(fixture.viewModel.visionSessionProgress == nil)
        #expect(!fixture.viewModel.isVisionSessionLive)
    }

    /// The action line names the action Sonny is about to take, not a generic "working".
    @Test
    func theHudsActionLineNamesTheActualAction() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"Reading List","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"done","rationale":"Done."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open the reading list", appName: "Safari")
        try await waitUntil("the action line") {
            fixture.viewModel.visionSessionProgress?.currentAction.contains("Reading List") == true
        }
        try await waitForIdle(fixture.viewModel)
    }

    /// **Pause from the HUD shares the attention machinery**, so a user-initiated pause reaches the
    /// loop by exactly the path a locked screen does — one paused state, not two that must agree.
    @Test
    func pausingFromTheHudFreezesTheLoopAndWaitsForAnExplicitResume() async throws {
        let attention = UserPausableAttentionMonitor(base: AlwaysAttendedMonitor())
        let fixture = try makeFixture(
            replies: [
                #"{"action":"click","x":10,"y":10,"target":"A","consequence":"ordinary","rationale":"r"}"#,
                #"{"action":"click","x":20,"y":20,"target":"B","consequence":"ordinary","rationale":"r"}"#,
                #"{"action":"done","rationale":"Done."}"#
            ],
            attention: attention
        )
        defer { fixture.tearDown() }
        fixture.viewModel.visionUserPauseMonitor = attention

        // Paused from inside the click, so it lands before the next iteration's attention check
        // rather than racing it — an outside call could arrive after iteration two had already
        // passed its gate, and the test would then be measuring the race. Same fix as the lock and
        // revocation tests above.
        fixture.synthesizer.afterClick = { count in
            if count == 1 { attention.pause() }
        }
        fixture.viewModel.startVisionSession(goal: "click two things", appName: "Safari")
        try await waitUntil("the pause") { fixture.viewModel.visionSessionPause != nil }
        #expect(fixture.viewModel.visionSessionPause?.reason == .userPaused)

        // Frozen: no capture, no synthesis, until the user says otherwise.
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.synthesizer.clickCount == 1)

        fixture.viewModel.resolveVisionPause(resuming: true)
        try await waitForIdle(fixture.viewModel)
        #expect(fixture.synthesizer.clickCount == 2)
    }

    /// **Stop halts before the next action**, not after the whole session — cooperative cancellation
    /// between iterations, which plan §B5 left as a NOT-VERIFIED question and this ticket turns into
    /// a tested requirement.
    @Test
    func stopHaltsBeforeTheNextActionRatherThanAfterTheSession() async throws {
        let keepClicking = #"{"action":"click","x":10,"y":10,"target":"A","consequence":"ordinary","rationale":"r"}"#
        let fixture = try makeFixture(
            replies: Array(repeating: keepClicking, count: 8),
            limits: VisionSessionLimits(maximumIterations: 8, settleNanoseconds: 40_000_000)
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "click forever", appName: "Safari")
        try await waitUntil("the first click") { fixture.synthesizer.clickCount == 1 }

        fixture.viewModel.emergencyStopVisionSession()
        try await waitForIdle(fixture.viewModel)

        // The clicks stop essentially where the press landed — nowhere near the cap of 8.
        #expect(fixture.synthesizer.clickCount <= 2, "actual: \(fixture.synthesizer.clickCount)")
        #expect(fixture.viewModel.visionSessionProgress == nil)
    }

    /// The emergency stop is inert when no session is live, so a stray hotkey press cannot cancel
    /// the user's ordinary task.
    @Test
    func theEmergencyStopDoesNothingWhenNoSessionIsLive() async throws {
        let fixture = try makeFixture(replies: [])
        defer { fixture.tearDown() }

        fixture.viewModel.emergencyStopVisionSession()

        #expect(!fixture.viewModel.isRunning)
        #expect(fixture.viewModel.finalSummary.isEmpty)
        #expect(fixture.viewModel.errorMessage == nil)
    }

    /// **Permission revocation takes the same stop path.** §13.5's invariant is one implementation of
    /// "control was lost, for any reason" — with a distinct reason code and copy routing the user to
    /// the Permission Center.
    @Test
    func revokingAccessibilityMidSessionStopsItAndRoutesToThePermissionCenter() async throws {
        let permissions = RevocablePermissions()
        let fixture = try makeFixture(
            replies: Array(repeating: #"{"action":"click","x":10,"y":10,"target":"A","consequence":"ordinary","rationale":"r"}"#, count: 4),
            permissions: permissions
        )
        defer { fixture.tearDown() }

        // Revoked from inside the click, so it lands before the next iteration's poll rather than
        // racing it.
        fixture.synthesizer.afterClick = { count in
            if count == 1 { permissions.accessibilityTrusted = false }
        }
        fixture.viewModel.startVisionSession(goal: "click things", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 1, "no further action after control was lost")
        #expect(fixture.viewModel.finalSummary.contains("permission to control your Mac was turned off"))
        #expect(fixture.viewModel.finalSummary.contains("Permission Center"))
    }

    // MARK: - Session-bound: pause and explicit resume (SONNY-94)

    /// **The user walking away pauses the session, and only the user resumes it.**
    ///
    /// Not ends — pauses. Attention is the one refusal a human can actually answer ("I am back"), so
    /// the session suspends rather than throwing away work they may still want. Every other
    /// containment refusal is a fact no answer changes, and those still end.
    @Test
    func lockingTheScreenMidSessionPausesAndOnlyAnExplicitResumeContinuesIt() async throws {
        let attention = SwitchableAttentionMonitor()
        let fixture = try makeFixture(
            replies: [
                #"{"action":"click","x":10,"y":10,"target":"A","consequence":"ordinary","rationale":"r"}"#,
                #"{"action":"click","x":20,"y":20,"target":"B","consequence":"ordinary","rationale":"r"}"#,
                #"{"action":"done","rationale":"Done."}"#
            ],
            attention: attention
        )
        defer { fixture.tearDown() }

        // Locked from inside the click, so the change lands before the next iteration's check
        // rather than racing it — an outside flip could arrive after iteration two had already
        // passed its attention gate, and the test would then be measuring the race.
        fixture.synthesizer.afterClick = { count in
            // Exactly once, so the resume below finds an unlocked Mac rather than re-locking it on
            // every click.
            if count == 1 { attention.state = .screenLocked }
        }
        fixture.viewModel.startVisionSession(goal: "click two things", appName: "Safari")
        try await waitUntil("the pause") { fixture.viewModel.visionSessionPause != nil }

        let pause = try #require(fixture.viewModel.visionSessionPause)
        #expect(pause.reason == .screenLocked)
        #expect(pause.appDisplayName == "Safari")
        #expect(fixture.viewModel.hasVisibleWidgetPanel)

        // **Unlocking alone does not resume.** The screen becoming available is not the user asking
        // Sonny to carry on, and a session that resumed itself here would be moving the cursor of
        // someone who has not looked at the screen yet.
        attention.state = .attended
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.viewModel.visionSessionPause != nil, "only an explicit resume may continue it")
        #expect(fixture.synthesizer.clickCount == 1, "nothing happened while it waited")

        fixture.viewModel.resolveVisionPause(resuming: true)
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 2)
        #expect(fixture.viewModel.finalSummary == "Done.")
    }

    /// Ending a paused session from the pause panel stops it with the attention reason, not a
    /// generic cancellation — the user is owed the true one.
    @Test
    func endingFromThePausePanelStopsTheSessionWithTheAttentionReason() async throws {
        let attention = SwitchableAttentionMonitor()
        attention.state = .userIdle
        let fixture = try makeFixture(
            replies: [#"{"action":"click","x":10,"y":10,"target":"A","rationale":"r"}"#],
            attention: attention
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "do a thing", appName: "Safari")
        try await waitUntil("the pause") { fixture.viewModel.visionSessionPause != nil }
        #expect(fixture.viewModel.visionSessionPause?.reason == .userIdle)

        fixture.viewModel.resolveVisionPause(resuming: false)
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.finalSummary.contains("you have been away"))
        #expect(fixture.synthesizer.clickCount == 0)
    }

    /// A resume while the condition still holds pauses again rather than pressing on — the user's
    /// press is a claim, and the OS is what confirms it.
    @Test
    func resumingWhileStillAwayPausesAgainRatherThanPressingOn() async throws {
        let attention = SwitchableAttentionMonitor()
        attention.state = .displayAsleep
        let fixture = try makeFixture(
            replies: [#"{"action":"click","x":10,"y":10,"target":"A","rationale":"r"}"#],
            attention: attention
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "do a thing", appName: "Safari")
        try await waitUntil("the first pause") { fixture.viewModel.visionSessionPause != nil }

        fixture.viewModel.resolveVisionPause(resuming: true)
        try await waitUntil("the second pause") { fixture.viewModel.visionSessionPause != nil }
        #expect(fixture.synthesizer.clickCount == 0)
        #expect(fixture.model.prompts.isEmpty, "nothing was captured or sent while away")

        fixture.viewModel.cancelCurrentRun()
        try await waitForIdle(fixture.viewModel)
    }

    /// **§13.1: a tier-3 approval is not shown to a locked screen**, and the session stops rather
    /// than acting without an answer. Reachable because a screen can lock in the seconds a model
    /// spent deciding — after the iteration-start check has already passed.
    @Test
    func aDestructiveActionComingDueOnALockedScreenStopsRatherThanActing() async throws {
        let attention = SwitchableAttentionMonitor()
        let fixture = try makeFixture(
            replies: [#"{"action":"click","x":10,"y":10,"target":"Delete","consequence":"destructive","rationale":"r"}"#],
            attention: attention
        )
        defer { fixture.tearDown() }

        // Attended at iteration start, but not presentable by the time the approval comes due.
        attention.presentable = false

        fixture.viewModel.startVisionSession(goal: "delete a thing", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.approvalRequest == nil, "no approval may be raised for a locked screen")
        #expect(fixture.synthesizer.clickCount == 0, "and the action must not run unapproved")
        #expect(fixture.viewModel.finalSummary.contains("your Mac was locked"))
    }

    /// The same locked screen does *not* stop an ordinary action, because no approval was coming
    /// due — the §13.1 gate is about approvals, not about acting.
    @Test
    func anOrdinaryActionIsUnaffectedByApprovalPresentability() async throws {
        let attention = SwitchableAttentionMonitor()
        attention.presentable = false
        let fixture = try makeFixture(
            replies: [
                #"{"action":"click","x":10,"y":10,"target":"Bookmarks","consequence":"ordinary","rationale":"r"}"#,
                #"{"action":"done","rationale":"Done."}"#
            ],
            attention: attention
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "browse", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 1)
        #expect(fixture.viewModel.finalSummary == "Done.")
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

    // MARK: - The action journal (SONNY-96)

    /// **Every synthesized action produces exactly one journal entry**, written by the engine as the
    /// action executes — the acceptance criterion, and the difference between an audit surface and a
    /// summary.
    @Test
    func everySynthesizedActionProducesExactlyOneJournalEntry() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"Bookmarks","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"type","text":"hello","target":"search","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"key","key":"tab","target":"","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"done","rationale":"Done."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "do three things", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        let records = try fixture.journal.loadAll()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.entries.count == 3)
        #expect(record.entries.map(\.actionType) == ["click", "type", "key"])
        #expect(record.goal == "do three things")
        #expect(record.appDisplayName == "Safari")
        #expect(record.endReasonCode == "completed")
        #expect(record.endedAt != nil)

        // Actions that do not drive the machine produce no entry — a `done` is not something Sonny
        // did to the user's app.
        #expect(!record.entries.contains { $0.actionType == "done" })
    }

    /// The entry records the tier the action was *actually* assessed at, including a mid-loop
    /// escalation — a record of a destructive click that said tier 1 would be a record that hides
    /// the thing it exists to show.
    @Test
    func aMidLoopEscalationIsRecordedAtItsRealTierAndApprovalState() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"Bookmarks","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"click","x":20,"y":20,"target":"Delete","consequence":"destructive","rationale":"r"}"#,
            #"{"action":"done","rationale":"Done."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "tidy up", appName: "Safari")
        try await waitUntil("the approval") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        let entries = try #require(try fixture.journal.loadAll().first?.entries)
        #expect(entries.count == 2)
        let ordinary = try #require(entries.first)
        let destructive = try #require(entries.dropFirst().first)

        #expect(ordinary.riskTier == .tier1)
        #expect(ordinary.consequence == .advisory)
        #expect(ordinary.approvalState == .ranWithoutAsking)

        #expect(destructive.riskTier == .tier3)
        #expect(destructive.consequence == .destructive)
        #expect(destructive.approvalState == .approved)
        #expect(destructive.targetDescription == "Delete")
        #expect(destructive.imageX == 20)
        #expect(destructive.imageY == 20)
        #expect(!destructive.observationAfter.isEmpty)
    }

    /// A repeat of the same reason rides the earlier approval, and the record says so rather than
    /// claiming the user was asked twice.
    @Test
    func anActionCoveredByAnEarlierApprovalIsRecordedAsSuch() async throws {
        let send = #"{"action":"click","x":10,"y":10,"target":"Send","consequence":"affects_others","rationale":"r"}"#
        let fixture = try makeFixture(replies: [send, send, #"{"action":"done","rationale":"Sent."}"#])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "send twice", appName: "Safari")
        try await waitUntil("the only approval") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        let entries = try #require(try fixture.journal.loadAll().first?.entries)
        #expect(entries.count == 2)
        #expect(try #require(entries.first).approvalState == .approved)
        #expect(try #require(entries.dropFirst().first).approvalState == .coveredByEarlierApproval)
    }

    /// **A stopped session still leaves a record**, with the reason it ended — the runs someone most
    /// wants to read afterwards are exactly the ones that did not finish cleanly.
    @Test
    func aStoppedSessionStillLeavesARecordWithItsReason() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"Delete","consequence":"destructive","rationale":"r"}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "delete a thing", appName: "Safari")
        try await waitUntil("the approval") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.cancelCurrentRun()
        try await waitForIdle(fixture.viewModel)

        let record = try #require(try fixture.journal.loadAll().first)
        #expect(record.endReasonCode == "user_stopped")
        // The declined action never ran, so it left no entry — the record shows what happened, not
        // what was proposed.
        #expect(record.entries.isEmpty)
    }

    /// **The task-history row links to the journal**, and a non-vision row does not — the linkage
    /// decision rows D and E inherit.
    @Test
    func aVisionTasksHistoryRowLinksToItsJournalAndAnOrdinaryRowDoesNot() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"A","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"done","rationale":"Done."}"#
        ])
        defer { fixture.tearDown() }

        // An ordinary task first, so the negative half is asserted against a real row rather than
        // an absence.
        fixture.viewModel.command = "2 + 2"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        fixture.viewModel.startVisionSession(goal: "click a thing", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        let rows = fixture.viewModel.taskHistoryRecords
        let visionRow = try #require(rows.first { $0.command.contains("Control Safari") })
        let ordinaryRow = try #require(rows.first { $0.command == "2 + 2" })

        let sessionID = try #require(visionRow.visionSessionID)
        #expect(ordinaryRow.visionSessionID == nil)

        // And the link resolves to the session that actually ran.
        let record = try #require(try fixture.journal.record(withID: sessionID))
        #expect(record.appDisplayName == "Safari")
        #expect(record.entries.count == 1)
    }

    /// **A click interrupted by a stop is still journalled** (PR #50 review, F11).
    ///
    /// `ClickEventSequence` posts `leftMouseDown`, sleeps 80ms, and on cancellation posts
    /// `leftMouseUp` before rethrowing — so the target app receives a complete down/up pair, which is
    /// a real click. The throw used to propagate past `journal(...)`, so the record showed nothing:
    /// the one run whose record was silently incomplete was the run someone stopped mid-click, which
    /// is the run they would most want to read. It also contradicted SONNY-96's own criterion — every
    /// synthesized action produces exactly one entry — and its own stated principle, that a record
    /// showing only what succeeded reads as a cleaner run than the one that happened.
    @Test
    func aClickInterruptedByAStopIsStillRecordedInTheJournal() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"A","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"done","rationale":"should never be reached"}"#
        ])
        defer { fixture.tearDown() }
        fixture.synthesizer.throwsAfterDeliveringClick = CancellationError()

        fixture.viewModel.startVisionSession(goal: "click a thing", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        // The click really was delivered — that is the premise, not an incidental.
        #expect(fixture.synthesizer.clickCount == 1)

        let record = try #require(try fixture.journal.loadAll().first)
        let entry = try #require(record.entries.first)
        #expect(record.entries.count == 1, "the delivered click must appear exactly once")
        #expect(entry.actionType == "click")
        #expect(entry.imageX == 10)
        #expect(entry.observationAfter.contains("stopped mid-click"))
        #expect(entry.observationAfter.contains("button was released"))
        // And the session ended on the stop rather than continuing to the next scripted reply.
        #expect(record.endReasonCode == "user_stopped")
        #expect(fixture.model.prompts.count == 1)
    }

    // MARK: - Screen-derived text never reaches the planner provider (PR #50 cycle-2, F13)

    /// **A secret in the model's closing rationale never reaches the planner.**
    ///
    /// The rationale is free text the vision model writes after reading the user's screen, and it
    /// becomes the run summary — which flows into `PriorTaskContext` and is sent to the *planner*
    /// provider as a `user` message on the next command within ten minutes. F5 closed the
    /// screen-text route to the vision provider; this was the same class arriving at a different one.
    ///
    /// Driven end to end: a real session finishes with a rationale containing a key, then a real
    /// follow-up command goes through a recording planner, and the assertion is on what that planner
    /// was actually handed.
    @Test
    func aSecretInTheModelsRationaleNeverReachesThePlanner() async throws {
        let secret = "sk-rationaleAAAAAAAAAAAAAAAAAAAA1234"
        let planner = RecordingPlanner()
        let fixture = try makeFixture(
            replies: [
                "{\"action\":\"done\",\"rationale\":\"I read the note. It said the key is \(secret) and I stopped.\"}"
            ],
            delegationPlanner: planner
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "read the note", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        // The summary the user sees is already masked.
        #expect(!fixture.viewModel.finalSummary.contains(secret))

        // And the follow-up command's prior-task context — the thing that actually goes to the
        // planner — does not carry it either.
        fixture.viewModel.command = "now do the other thing"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        #expect(!planner.contextTexts.isEmpty, "the follow-up must really have carried prior-task context")
        for text in planner.contextTexts {
            #expect(!text.contains(secret), "the rationale's secret reached the planner")
        }
    }

    /// **A secret in a delegated instruction never reaches the planner**, and the instruction is what
    /// the planner is literally asked to plan — so this asserts on the command string itself.
    @Test
    func aSecretInADelegatedInstructionNeverReachesThePlanner() async throws {
        let secret = "sk-delegateBBBBBBBBBBBBBBBBBBBB5678"
        let planner = RecordingPlanner()
        let fixture = try makeFixture(
            replies: [
                "{\"action\":\"delegate\",\"instruction\":\"save a note containing \(secret)\",\"rationale\":\"r\"}",
                #"{"action":"done","rationale":"Done."}"#
            ],
            delegationPlanner: planner
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "save something", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(!planner.commands.isEmpty, "the delegation must really have reached the planner")
        for command in planner.commands {
            #expect(!command.contains(secret), "the delegated instruction's secret reached the planner")
        }
        // The masking is visible rather than the text being dropped — the planner still gets a
        // usable instruction, or delegation would be broken rather than safe.
        #expect(planner.commands.contains { $0.contains("save a note containing") })
    }

    /// Both redactions are recorded on the session, not silently applied — a secret masked out of a
    /// rationale with nothing saying so would be a record that under-reports what Sonny did.
    @Test
    func sessionLevelRedactionsAreRecordedOnTheJournal() async throws {
        let secret = "sk-recordCCCCCCCCCCCCCCCCCCCCCC9012"
        let fixture = try makeFixture(replies: [
            "{\"action\":\"done\",\"rationale\":\"the key is \(secret)\"}"
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "read", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        let record = try #require(try fixture.journal.loadAll().first)
        #expect(!record.sessionRedactionSummary.isEmpty, "the rationale's redaction must be recorded")
        #expect(record.endSummary?.contains(secret) == false)
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
            #expect(payload.redactedImageData != nil)
            #expect(payload.sourceBundleIdentifier == "com.apple.Safari")
        }
    }

    /// **A resampled capture's coordinates come back through the size the model was shown, end to
    /// end** (SONNY-114). This is the test that would have caught the bug the resampling could have
    /// introduced, and it runs through the real runner rather than the resolver alone.
    ///
    /// The capture is 800x600 pixels over an 800x600-point window; the egress ladder is given a
    /// budget it cannot meet, so it resamples to its 0.5 floor and the model is shown 400x300. The
    /// model then names (100, 75) — the middle of what it saw, which is the middle of the window,
    /// which is (200, 150) on screen. A resolver still scaling by the capture's own pixel count would
    /// have clicked (100, 75): inside the window, plausible, and half as far in as intended.
    ///
    /// Everything the model was told and everything recorded about its answer belongs to the same
    /// space, so the prompt's declared dimensions and the journal's image coordinates are asserted
    /// here too — three surfaces that have to agree, and used to read from two different sources.
    @Test
    func aResampledCaptureResolvesItsClickThroughTheSizeTheModelWasShown() async throws {
        let fixture = try makeFixture(
            replies: [
                #"{"action":"click","x":100,"y":75,"target":"Middle","consequence":"ordinary","rationale":"r"}"#,
                #"{"action":"done","rationale":"Done."}"#
            ],
            egressPolicy: VisionCaptureEgressPolicy(
                maximumImageBytes: 1,
                ladder: VisionCaptureEgressPolicy.default.ladder
            )
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "click the middle", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        let payload = try #require(fixture.model.payloads.first)
        #expect(payload.imagePixelWidth == 400)
        #expect(payload.imagePixelHeight == 300)

        let prompt = try #require(fixture.model.prompts.first)
        #expect(prompt.contains("400x300 pixels"))
        #expect(prompt.contains("0 <= x < 400"))
        #expect(!prompt.contains("800x600 pixels"))

        #expect(fixture.synthesizer.events.contains(.clicked(CGPoint(x: 200, y: 150))))

        let record = try #require(try fixture.journal.loadAll().first)
        let entry = try #require(record.entries.first)
        #expect(entry.imageX == 100)
        #expect(entry.imageY == 75)
        #expect(entry.observationAfter.contains("(200, 150)"))
    }

    /// The bounds the model is held to are the ones it was given. A point inside the capture but
    /// outside the resampled image it actually saw is a point it never could have meant, and the
    /// history line sent back names the size it was shown rather than the capture's.
    @Test
    func aPointOutsideTheResampledImageIsSkippedAndReportedInTheSizeTheModelWasGiven() async throws {
        let fixture = try makeFixture(
            replies: [
                #"{"action":"click","x":500,"y":75,"target":"Far","consequence":"ordinary","rationale":"r"}"#,
                #"{"action":"done","rationale":"Done."}"#
            ],
            egressPolicy: VisionCaptureEgressPolicy(
                maximumImageBytes: 1,
                ladder: VisionCaptureEgressPolicy.default.ladder
            )
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "click out of bounds", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 0)
        let secondPrompt = try #require(fixture.model.prompts.dropFirst().first)
        #expect(secondPrompt.contains("outside the 400x300 screenshot"))
        #expect(!secondPrompt.contains("outside the 800x600 screenshot"))
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

    // MARK: - The screen check (SONNY-139)

    /// The sentence under test, taken from the production enum rather than written out here — so a
    /// test cannot pass against copy that drifted, and so the panel and the record are compared
    /// against **one** expression rather than two hand-copied strings that could diverge.
    private static var shellRefusalSentence: String {
        VisionContainmentRefusal
            .screenShowsShell(ShellSurfaceDetector.verdict(for: shellScreen))
            .userFacingReason
    }

    /// **A window showing a shell ends the session, in every mode**, before anything is sent and
    /// before anything is clicked.
    ///
    /// All three modes, because Power is the reason this check exists: it asks about no app, so the
    /// ten-name deny list is otherwise the only thing standing there, and a terminal nobody listed
    /// reaches the loop unchallenged. Safe is here for the opposite reason — its capture-review
    /// prompt sits *below* the shell check, so a shell must not even get as far as asking the user
    /// whether to send a picture of it.
    ///
    /// **Safe mode's session-envelope approval comes first and is answered here**, because it is a
    /// *plan*-level gate that fires before the loop starts — it is not the per-app control consent
    /// row J's later branches add, which is the prompt the design says the first capture precedes.
    /// The two are easy to read as contradicting each other and do not.
    ///
    /// Asserted on all four surfaces that have to agree: nothing reached the model, nothing reached
    /// the machine, the sentence the user reads, and the sentence the record keeps.
    @Test(arguments: [AgentInteractionMode.safe, .normal, .power])
    func aWindowShowingAShellEndsTheSessionInEveryMode(mode: AgentInteractionMode) async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"click","x":10,"y":10,"target":"OK","consequence":"ordinary","rationale":"r"}"#],
            mode: mode,
            recognizer: ScriptedRecognizer([Self.shellScreen])
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "run the deploy script", appName: "Safari")
        if mode == .safe {
            try await waitUntil("the session-envelope approval") { fixture.viewModel.approvalRequest != nil }
            #expect(fixture.model.prompts.isEmpty)
            fixture.viewModel.start()
        }
        try await waitForIdle(fixture.viewModel)

        // Nothing left the device and nothing touched the machine.
        #expect(fixture.model.prompts.isEmpty)
        #expect(fixture.model.payloads.isEmpty)
        #expect(fixture.synthesizer.events.filter { $0 != .activated("com.apple.Safari") }.isEmpty)
        // Safe mode's capture review never opened: the shell check runs before it.
        #expect(fixture.viewModel.visionCapturePreview == nil)
        #expect(fixture.viewModel.approvalRequest == nil)

        // The user-facing surface and the recorded reason, asserted as the same string.
        #expect(fixture.viewModel.finalSummary == Self.shellRefusalSentence)
        let record = try #require(try fixture.journal.loadAll().first)
        #expect(record.endSummary == Self.shellRefusalSentence)
        #expect(record.endReasonCode == "screen_shows_shell")
        #expect(record.entries.isEmpty)
    }

    /// **The same screen without the shell proceeds normally**, which is what stops the test above
    /// from passing for the wrong reason. A capture that carries recognized text, goes through the
    /// same recognizer seam and the same redaction path, and simply is not a shell, reaches the
    /// model and produces a click.
    @Test
    func anOrdinaryWindowWithTextOnItIsUnaffectedByTheScreenCheck() async throws {
        let fixture = try makeFixture(
            replies: [
                #"{"action":"click","x":10,"y":10,"target":"Reading List","consequence":"ordinary","rationale":"r"}"#,
                #"{"action":"done","rationale":"Opened."}"#
            ],
            recognizer: ScriptedRecognizer([Self.ordinaryScreen])
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open my reading list", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.model.prompts.count == 2)
        #expect(fixture.synthesizer.clickCount == 1)
        #expect(fixture.viewModel.finalSummary == "Opened.")
    }

    /// **Every capture, not only the first.** A screen changes under you, so an answer computed once
    /// per session is an answer that cannot notice a shell opening in a window it already cleared.
    ///
    /// The shell appears on the *third* capture: two ordinary iterations run and click, and the
    /// third ends the session. A check wired to run once would let all three through, and a check
    /// wired to the wrong iteration would stop at the wrong count — so the click count is asserted
    /// exactly rather than as "some clicks happened".
    @Test
    func theScreenCheckRunsOnEveryCaptureNotOnlyTheFirst() async throws {
        let click = #"{"action":"click","x":10,"y":10,"target":"Next","consequence":"ordinary","rationale":"r"}"#
        let fixture = try makeFixture(
            replies: [click, click, click, click],
            recognizer: ScriptedRecognizer([
                Self.ordinaryScreen,
                Self.ordinaryScreen,
                Self.shellScreen
            ])
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "keep going", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 2)
        #expect(fixture.model.prompts.count == 2)
        #expect(fixture.viewModel.finalSummary == Self.shellRefusalSentence)
        let record = try #require(try fixture.journal.loadAll().first)
        #expect(record.endReasonCode == "screen_shows_shell")
        // The two clicks that did happen are in the record; the refusal added no entry of its own.
        #expect(record.entries.count == 2)
    }

    /// **An unreadable screen is not permission.** This is asserted as *the session ends*, never as
    /// "the verdict came back no-shell" — the distinction is the whole content of failing closed,
    /// and a check that answered "no shell" when it could not see would be the worst possible
    /// outcome.
    ///
    /// The property is inherited rather than re-implemented: `redactCapture` throws
    /// `detectionUnavailable` when recognition fails, and the runner propagates it. A mutation that
    /// deleted that propagation — `try?` with a default, or a recognizer failure mapped to an empty
    /// observation list — would make this test fail, because the session would run on and click.
    @Test
    func anUnreadableScreenEndsTheSessionRatherThanProducingANoShellVerdict() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"click","x":10,"y":10,"target":"OK","consequence":"ordinary","rationale":"r"}"#],
            recognizer: ThrowingRecognizer()
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "do something", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        // Nothing was sent, nothing was clicked, and the run did not quietly succeed.
        #expect(fixture.model.prompts.isEmpty)
        #expect(fixture.synthesizer.clickCount == 0)
        #expect(fixture.viewModel.errorMessage?.contains("could not scan this capture") == true)
        let record = try #require(try fixture.journal.loadAll().first)
        #expect(record.endReasonCode == "failed")
        #expect(record.entries.isEmpty)
    }

    /// **The static deny list still refuses first, and the screen check did not replace it.** A
    /// terminal app is refused at the adapter's door with the *terminal* sentence, never the shell
    /// one — so the two refusals stay distinguishable in the record and in the panel, and a reader
    /// can tell which boundary fired.
    ///
    /// This is the ordering constraint as behaviour: the deny list answers before a capture is ever
    /// taken, which is why the recognizer below is never even asked.
    @Test
    func aListedTerminalIsStillRefusedByNameBeforeAnyCaptureIsTaken() async throws {
        let recognizer = ScriptedRecognizer([Self.shellScreen])
        let fixture = try makeFixture(
            replies: [#"{"action":"click","x":1,"y":1,"target":"OK","rationale":"r"}"#],
            bundleIdentifier: "com.apple.Terminal",
            frontmost: "com.apple.Terminal",
            recognizer: recognizer
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "run a command", appName: "Terminal")
        try await waitForIdle(fixture.viewModel)

        #expect(recognizer.calls == 0)
        #expect(fixture.model.prompts.isEmpty)
        #expect(fixture.viewModel.errorMessage?.contains("never controls a terminal") == true)
        #expect(fixture.viewModel.errorMessage?.contains("that window is showing a shell") == false)
    }
}

/// A planner that answers every instruction with a vision-bearing plan.
///
/// Exists for exactly one test: the recursion guard cannot be exercised unless something actually
/// tries to nest.
private struct NestingVisionPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        AgentPlan(
            summary: "Control Notes",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "nested-1",
                    operation: .visionSession,
                    description: "Control Notes",
                    appName: "Notes",
                    visionGoal: "write a note"
                )
            ]
        )
    }
}

/// Records every command and every prior-task context the planner was handed.
///
/// The planner is a *different provider* from the vision model, so a secret that never reaches the
/// vision prompt can still reach this one — which is exactly the route F13 found. Recording both the
/// command and the context text is what lets a test assert on each independently.
final class RecordingPlanner: Planning, @unchecked Sendable {
    private(set) var commands: [String] = []
    private(set) var contextTexts: [String] = []

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        commands.append(command)
        if let priorTaskContext {
            contextTexts.append(priorTaskContext.plannerContextText)
        }
        return AgentPlan(
            summary: "Noted.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "note", operation: .calculateUtility, description: "Calculate", searchQuery: "1 + 1")
            ]
        )
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
