import CoreGraphics
import Foundation
import ImageIO
import MacAgentTestSupport
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
        /// What to throw instead of answering, and at which 1-based iteration (SONNY-131).
        ///
        /// **A property of this double rather than a second double**, because what the mid-loop tests
        /// need is a session that runs normally and *then* fails: a separate always-failing model
        /// could only ever test iteration one, which is the case the decision is least about.
        private let failure: (iteration: Int, error: any Error)?
        private(set) var prompts: [String] = []
        private(set) var payloads: [RedactedPayload] = []
        /// Every session context the loop passed, in order — so a test can assert on §4.5's two
        /// session fields as the runner produced them rather than as a client happened to send them.
        private(set) var sessions: [VisionSessionRequestContext] = []
        private var index = 0

        init(_ replies: [String], failingAt failure: (iteration: Int, error: any Error)? = nil) {
            self.replies = replies
            self.failure = failure
        }

        var transcriptDescription: String { "scripted" }

        func decide(
            prompt: String,
            payload: RedactedPayload,
            session: VisionSessionRequestContext
        ) async throws -> String {
            prompts.append(prompt)
            payloads.append(payload)
            sessions.append(session)
            if let failure, failure.iteration == session.iteration {
                throw failure.error
            }
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

    /// **A VS Code window with its terminal panel open and nothing having gone wrong** — manual-test
    /// item 2, and the case PR #57's F2 found the session ran straight through. Nothing on this
    /// screen has failed: no diagnostic, no banner, no `ls -l` output. Its two signs are a real
    /// prompt and a command typed at it.
    private static let idleTerminalPanelScreen = """
    EXPLORER                    deploy.sh
    PROBLEMS   OUTPUT   TERMINAL   PORTS
    sauransh@Mac macos-agent % ls
    README.md  Sources  Tests  docs
    sauransh@Mac macos-agent %
    """

    // MARK: - Fixture

    private struct Fixture {
        let viewModel: AgentViewModel
        let model: ScriptedVisionModel
        let synthesizer: RecordingSynthesizer
        let journal: VisionSessionJournalStore
        /// Row E (SONNY-147). Exposed so a test can read what a screen-control run actually stored,
        /// off the file rather than off published state.
        let taskHistoryStore: TaskHistoryStore
        let taskPlanDetailStore: TaskPlanDetailStore
        let routineStore: RoutineStore
        /// The same store instance the view model was built with, so a test can seed a grant before
        /// a run and read back what an Allow wrote (SONNY-143).
        let approvedApps: ApprovedAppStore
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
        /// A grants file to share with an earlier fixture, so a "second run" test really re-reads
        /// what the first run wrote rather than a value cached in one view model (SONNY-143).
        approvedAppsFile: URL? = nil,
        /// Whether the target app already carries a grant when the session starts.
        ///
        /// **Defaults to `true` because the per-app gate is now a step of the loop, not a step of
        /// the plan** (PR #88's fix round, §4.3). Every session on an app the current mode does not
        /// already allow pauses after its first capture and asks — which in Safe mode is every app
        /// the user has not approved by hand, including the starter list's. Tests about the capture
        /// preview, delegation, the iteration cap and the rest are not about that question, and
        /// leaving them to meet it would make each of them a test of two things. The gate's own
        /// tests pass `false` and answer it.
        appControlAlreadyGranted: Bool = true,
        /// The planner a *delegated* instruction reaches. `nil` means the unreachable one, which is
        /// correct for every test whose delegations resolve instantly or do not delegate at all.
        delegationPlanner: (any Planning)? = nil,
        /// The egress encoding policy. The default is the shipping one, under which an 800x600
        /// fixture never resamples; a test that wants the resampled path supplies a budget the
        /// ladder cannot meet.
        egressPolicy: VisionCaptureEgressPolicy = .default,
        /// What the OCR pass reads off each capture. The default finds nothing, which is a window
        /// with no secrets and no shell on it; SONNY-139's tests supply screens instead.
        recognizer: (any ImageTextRecognizing)? = nil,
        /// A send that fails at a chosen iteration — SONNY-131's mid-loop decision (`nil` for every
        /// test that is not about it).
        modelFailure: (iteration: Int, error: any Error)? = nil,
        /// A **real** `SonnyVisionModelClient` in place of the scripted double, for the one test
        /// whose subject is what happens on the wire between iterations (SONNY-136).
        ///
        /// `nil` everywhere else, and that is the right default: every other test here is about the
        /// loop's own decisions, and routing those through a URL stub would make each of them a test
        /// of the client as well. When this is passed, `Fixture.model` is a scripted model that
        /// never runs and its recordings say nothing — the test that passes this reads the wire
        /// instead.
        visionModelClient: (any VisionModelDeciding)? = nil,
        /// The client the view model itself is built with. Defaults to the hermetic one, which is
        /// what every test that is not about the network wants; the token-expiry test hands over the
        /// same signed-in client its vision client sends through, because §3.3's single-flight
        /// refresh guard is state on one actor and two clients would be two of them.
        backendClient: SonnyBackendClient? = nil
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionSessionRunTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let suiteName = "VisionSessionRunTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)

        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let taskHistoryStore = TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json"))
        let taskPlanDetailStore = TaskPlanDetailStore(
            fileURL: root.appendingPathComponent("task-plan-details.json")
        )
        let approvedAppStore = ApprovedAppStore(
            fileURL: approvedAppsFile ?? root.appendingPathComponent("approved-apps.json")
        )
        if appControlAlreadyGranted, approvedAppsFile == nil {
            try approvedAppStore.approve(
                bundleIdentifier: bundleIdentifier,
                displayName: bundleIdentifier,
                approvedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
        let viewModel = AgentViewModel(
            routineStore: routineStore,
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
            snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
            recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("artifacts.json")),
            shortcutCatalog: NoShortcuts(),
            finderRevealer: hermeticFinderRevealer,
            shortcutRunHistoryStore: ShortcutRunHistoryStore(fileURL: root.appendingPathComponent("shortcut-history.json")),
            taskHistoryStore: taskHistoryStore,
            taskPlanDetailStore: taskPlanDetailStore,
            visionSessionJournalStore: VisionSessionJournalStore(fileURL: root.appendingPathComponent("vision-sessions.json")),
            clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-settings.json")
            ),
            approvedAppStore: approvedAppStore,
            outputLocationStore: OutputLocationStore(
                fileURL: root.appendingPathComponent("output-locations.json"),
                // The same roots this fixture hands the view model, so the store answers
                // "is this an output location" against the folders the run really used.
                whitelist: PathWhitelist(roots: [root])
            ),
            resumableTaskStore: ResumableTaskStore(fileURL: root.appendingPathComponent("resumable-tasks.json")),
            clipboardHistoryMonitor: ClipboardHistoryMonitor(
                reader: HermeticPasteboardReader(),
                store: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard-history.json")),
                settingsStore: ClipboardHistorySettingsStore(
                    fileURL: root.appendingPathComponent("clipboard-history-settings.json")
                )
            ),
            localDataDeletionService: LocalDataDeletionService(fileURLs: []),
            // SONNY-130: undefaulted like the stores, and for a worse reason — this client holds the
            // Keychain session every packaged build on this Mac shares. Hermetic: no environment, so
            // every request fails before a URL is built, and an in-memory Keychain of its own.
            backendClient: backendClient ?? makeHermeticBackendClient(),
            priorTaskContextStore: PriorTaskContextStore(),
            taskUsageRecorder: TaskUsageRecorder(),
            makePlanner: { _, _ in delegationPlanner ?? UnreachableVisionPlanner() },
            userDefaults: userDefaults,
            whitelist: PathWhitelist(roots: [root])
        )
        viewModel.interactionMode = mode

        let model = ScriptedVisionModel(replies, failingAt: modelFailure)
        let synthesizer = RecordingSynthesizer(frontmost: frontmost)
        let journal = VisionSessionJournalStore(fileURL: root.appendingPathComponent("vision-sessions.json"))
        viewModel.visionSessionEnvironment = VisionSessionEnvironment(
            captureService: ScreenCaptureService(
                permissionChecker: permissions ?? DeterministicScreenPermissions(),
                backend: FakeCaptureBackend(bundleIdentifier: bundleIdentifier)
            ),
            redactionService: LocalRedactionService(
                textRecognizer: recognizer ?? EmptyRecognizer(),
                egressPolicy: egressPolicy
            ),
            synthesizer: synthesizer,
            modelClient: visionModelClient ?? model,
            limits: limits,
            attentionMonitor: attention ?? AlwaysAttendedMonitor(),
            permissionChecker: permissions ?? DeterministicScreenPermissions(),
            journalStore: journal,
            interaction: viewModel
        )

        return Fixture(
            viewModel: viewModel,
            model: model,
            synthesizer: synthesizer,
            journal: journal,
            taskHistoryStore: taskHistoryStore,
            taskPlanDetailStore: taskPlanDetailStore,
            routineStore: routineStore,
            approvedApps: approvedAppStore,
            root: root
        )
    }

    /// How long these helpers wait before declaring a hang, and — since SONNY-302 — what reaching
    /// that deadline is allowed to mean.
    ///
    /// The number is unchanged at thirty seconds and the reasoning for it is unchanged
    /// (SONNY-159, SONNY-160, SONNY-161): nothing in this suite asserts that the vision loop is
    /// fast, every test here asserts what it *did*, and a deadline exists only so that a genuine
    /// hang fails the run instead of wedging it forever. The worst per-test wall clock observed
    /// across those three investigations was under eight seconds, and thirty is roughly four times
    /// that.
    ///
    /// **What SONNY-302 changed is not the number, it is what the timeout claims.** Thirty seconds
    /// of wall clock in this process buys a wait one or two looks at its condition, not thousands,
    /// because every `@MainActor` test in the target shares one actor whose queue is hundreds of
    /// jobs deep — so a timeout was firing on runs where nothing had been observed at all, and the
    /// test then carried on and produced a second wave of failures that looked exactly like
    /// deadlocks. `HangBackstop` holds the measurements, the rule that replaces it, and the two
    /// wordings a timeout can now fail with. Read it before changing anything here.
    private static let hangBackstop: TimeInterval = HangBackstop.deadlockDeadline

    /// `sourceLocation` is threaded through both of these so that a timeout points at the line that
    /// asked for the wait rather than at this helper. With 65 call-site lines among 77 test
    /// functions in this one file (`grep -cE 'waitUntil[(]'` and `grep -c '^    @Test'` over it —
    /// the patterns are bracketed and anchored so that this sentence is not itself counted, which
    /// the plainer ones were: writing them the obvious way moved both numbers by one), the
    /// difference is between a failure that names the test's step and one that names this function
    /// sixty-five times over.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = Self.hangBackstop,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () -> Bool
    ) async throws {
        try await HangBackstop.wait(
            for: description,
            deadline: timeout,
            sourceLocation: sourceLocation,
            until: condition
        )
    }

    private func waitForIdle(
        _ viewModel: AgentViewModel,
        timeout: TimeInterval = Self.hangBackstop,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitUntil("the run to finish", timeout: timeout, sourceLocation: sourceLocation) {
            !viewModel.isRunning
        }
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

    // MARK: - Row J: the per-app control gate, through the real dispatch path

    /// **The test that discharges the dead-hook risk** (SONNY-143), and the reason it is written
    /// this way rather than as a resolver unit test.
    ///
    /// Row I shipped a resolver hook that nothing ever called: `AgentActionExecutor`'s resolve
    /// dispatch was a hand-maintained list of `if`s, so the vision adapter's `resolveDefaultOutputs`
    /// existed and was never invoked, and every vision plan reached all three gates unpinned. The
    /// same class bit twice on that one branch. A component test on `AppControlResolver` looks
    /// exactly like this from the inside and proves nothing about whether the product asks. This
    /// drives a real plan through `startVisionSession` → `performStart` → the real assessment → the
    /// real gate, and asserts on `viewModel.approvalRequest`.
    ///
    /// **VS Code is the unapproved app on purpose, and the choice is not arbitrary.** It is the
    /// founder's own worked example of this feature — *"a developer who wants Sonny inside VS Code
    /// approves it by hand: one click, once, ever"* — and it is *permanently* off the starter list,
    /// held there by `noStarterEntryIsACodeEditorOrScriptHost`, so this test cannot turn green one
    /// day because somebody added the app it happened to pick. It also resolves under test:
    /// `InstalledAppResolver.shared` uses `FixedAppSource.aliasTableRoster` in a test process, so
    /// the installed universe here is exactly `MacAppCatalog.default`'s twelve entries and none of
    /// this depends on what is installed on the machine running the suite.
    @Test
    func anAppOutsideTheStarterListAsksInNormalModeThroughTheRealPath() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"done","rationale":"done."}"#],
            bundleIdentifier: "com.microsoft.VSCode",
            appControlAlreadyGranted: false
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open the extensions panel", appName: "VS Code")
        try await waitUntil("the per-app control question") { fixture.viewModel.approvalRequest != nil }

        let request = try #require(fixture.viewModel.approvalRequest)
        #expect(request.requirement == .explicitApproval)
        // Nothing ran: no capture reached the model and nothing touched the machine.
        #expect(fixture.model.prompts.isEmpty)
        #expect(fixture.synthesizer.clickCount == 0)
        // And nothing was stored — the question is open, not answered.
        #expect(try fixture.approvedApps.loadAll().isEmpty)

        fixture.viewModel.cancelCurrentRun()
        try await waitForIdle(fixture.viewModel)
    }

    /// The other half of the same claim, and it is what makes the half above mean anything: a
    /// starter-list app runs silently in Normal, through the identical path.
    @Test
    func aStarterListAppNeverRaisesAPerAppQuestionInNormalMode() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"done","rationale":"done."}"#],
            appControlAlreadyGranted: false
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open my reading list", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.viewModel.finalSummary == "done.")
        // Silent because the starter list already covers Safari — so nothing was written to the
        // user's own list either. The starter list is a baseline, not a way of filling that list in.
        #expect(try fixture.approvedApps.loadAll().isEmpty)
    }

    /// **One approval, two effects.** Allowing runs the session *and* writes the grant, and the
    /// grant is what makes the next run silent. Asserted end to end rather than by inspecting the
    /// store alone, because "the stored app is silent on the next run" is the user-visible claim.
    @Test
    func allowingStoresTheAppAndTheNextRunDoesNotAsk() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"done","rationale":"first."}"#],
            bundleIdentifier: "com.microsoft.VSCode",
            appControlAlreadyGranted: false
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open the extensions panel", appName: "VS Code")
        try await waitUntil("the per-app control question") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.finalSummary == "first.")
        let stored = try fixture.approvedApps.loadAll()
        #expect(stored.map(\.bundleIdentifier) == ["com.microsoft.VSCode"])
        // The display name is what the revocation surface will render, so it is the app's name and
        // not its identifier.
        #expect(stored.first?.displayName == "VS Code")

        // The second run, in a fresh view model over the same store file — a grant that only lived
        // in memory would pass an in-process re-run and fail a real relaunch.
        let second = try makeFixture(
            replies: [#"{"action":"done","rationale":"second."}"#],
            bundleIdentifier: "com.microsoft.VSCode",
            approvedAppsFile: fixture.approvedApps.fileURL,
            appControlAlreadyGranted: false
        )
        defer { second.tearDown() }

        second.viewModel.startVisionSession(goal: "open the extensions panel", appName: "VS Code")
        try await waitForIdle(second.viewModel)

        #expect(second.viewModel.approvalRequest == nil)
        #expect(second.viewModel.finalSummary == "second.")
    }

    /// **Denying stops the session, writes nothing, and the next run asks again.**
    ///
    /// Denial is not the absence of an answer — it is an answer that grants nothing. All three
    /// halves are asserted here because a mutation battery showed the first one held by nothing: a
    /// mutant that let the session run on after a decline survived the whole suite (PR #88's fix
    /// round, M12). "Nothing was stored" and "it asked again" were both still true of a session that
    /// had gone ahead and driven the app anyway, which is the outcome the question exists to
    /// prevent.
    @Test
    func denyingStoresNothingAndTheNextRunAsksAgain() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"done","rationale":"done."}"#],
            bundleIdentifier: "com.microsoft.VSCode",
            appControlAlreadyGranted: false
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open the extensions panel", appName: "VS Code")
        try await waitUntil("the per-app control question") { fixture.viewModel.approvalRequest != nil }
        // The first capture has been taken — that is what §4.3's ordering means — but it has not
        // been sent, and nothing has been driven.
        #expect(fixture.model.prompts.isEmpty)
        fixture.viewModel.cancelCurrentRun()
        try await waitForIdle(fixture.viewModel)

        // **The session stopped.** Nothing reached the model and nothing touched the machine after
        // the answer, which is what a declined question has to mean.
        #expect(fixture.model.prompts.isEmpty)
        #expect(fixture.model.payloads.isEmpty)
        #expect(fixture.synthesizer.clickCount == 0)
        #expect(try fixture.approvedApps.loadAll().isEmpty)

        fixture.viewModel.startVisionSession(goal: "open the extensions panel", appName: "VS Code")
        try await waitUntil("the second per-app control question") { fixture.viewModel.approvalRequest != nil }
        #expect(fixture.viewModel.approvalRequest?.requirement == .explicitApproval)
        fixture.viewModel.cancelCurrentRun()
        try await waitForIdle(fixture.viewModel)
    }

    /// **The prompt's own words, on both surfaces.**
    ///
    /// The panel already named the app, from `RiskApprovalCopy.involvedResource`; what row J adds is
    /// that the answer sticks, and the founder put that in the escalation reason — the existing
    /// channel for *why the user is being asked*, rendered in amber on the floating widget and on
    /// `CommandCenterAttentionPanel` alike. Both surfaces join
    /// `request.assessment.escalations.map(\.reason)`, so asserting on that join is asserting what
    /// each of them puts on screen; reusing the ordinary approval path is precisely what gets the
    /// second surface for free.
    @Test
    func thePromptNamesTheAppAndSaysTheAnswerIsRemembered() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"done","rationale":"done."}"#],
            bundleIdentifier: "com.microsoft.VSCode",
            appControlAlreadyGranted: false
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open the extensions panel", appName: "VS Code")
        try await waitUntil("the per-app control question") { fixture.viewModel.approvalRequest != nil }

        let request = try #require(fixture.viewModel.approvalRequest)
        #expect(request.approvalCopy.involvedResource == "VS Code")
        let reasons = request.assessment.escalations.map(\.reason).joined(separator: " ")
        #expect(reasons.contains("Sonny has not been allowed to control VS Code yet."))
        #expect(reasons.contains("Allowing it here keeps it allowed."))
        // **This request is the per-app question's own, not the session envelope's.** They were one
        // assessment while the question was asked at plan time; §4.3 moved the question into the
        // loop and the sentence moved with it, so the envelope's screenshot disclosure belongs to
        // the plan gate and is deliberately not repeated here. Asserted rather than left implicit,
        // because a request carrying both would mean the plan-time assessment had grown a standing
        // again.
        #expect(!reasons.contains("will send redacted screenshots"))
        #expect(request.assessment.escalations.count == 1)
        // The data-egress fact is on the copy, where Safe mode's own line reads it: allowing is what
        // makes this capture and every later one leave the device.
        #expect(request.approvalCopy.dataLeavesDevice)

        fixture.viewModel.cancelCurrentRun()
        try await waitForIdle(fixture.viewModel)
    }

    /// The negative half: an app that needs no permission gets no such sentence. Without this, the
    /// test above would pass against an adapter that appended the line unconditionally — and an
    /// unconditional line would land on the ran-without-asking trace, telling a user who was never
    /// asked what allowing would have done.
    @Test
    func anAlreadyAllowedAppCarriesNoRememberedSentence() async throws {
        let fixture = try makeFixture(replies: [#"{"action":"done","rationale":"done."}"#])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open my reading list", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.approvalRequest == nil)
        let trace = fixture.viewModel.ranWithoutAskingTrace ?? ""
        #expect(!trace.contains("has not been allowed"))
        #expect(!trace.contains("keeps it allowed"))
    }

    /// **Power asks about no app — and still asks about a destructive action.** Asserted together in
    /// one test on purpose: "Power skips the per-app gate" must never be readable as "Power asks
    /// nothing", and two separate tests would let either half rot without the other noticing.
    @Test
    func powerSkipsThePerAppGateAndStillAsksAboutADestructiveAction() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"click","x":10,"y":10,"target":"Delete","consequence":"destructive","rationale":"r"}"#],
            mode: .power,
            bundleIdentifier: "com.microsoft.VSCode",
            appControlAlreadyGranted: false
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "tidy up the workspace", appName: "VS Code")
        try await waitUntil("the mid-loop consequence-rule approval") { fixture.viewModel.approvalRequest != nil }

        // The one question raised is the destructive action's, not the app's: the session already
        // started, took a capture and reached its first decision.
        let request = try #require(fixture.viewModel.approvalRequest)
        #expect(request.requirement == .explicitApproval)
        #expect(request.approvalCopy.actionDescription.contains("Delete"))
        #expect(!fixture.model.prompts.isEmpty, "the session ran, so the per-app gate did not stop it")
        // Power writes nothing to anybody's list: the gate did not run, so there was nothing to
        // answer and nothing to remember.
        #expect(try fixture.approvedApps.loadAll().isEmpty)

        fixture.viewModel.cancelCurrentRun()
        try await waitForIdle(fixture.viewModel)
    }

    /// **A terminal is refused in every mode, never prompted — including when the store somehow
    /// contains one.**
    ///
    /// A grant can only reach the file by being written there by something other than
    /// `ApprovedAppStore.approve`, which refuses a listed terminal. This seeds the file directly to
    /// make that case real anyway, because the property being pinned is *ordering*: the deny list
    /// refuses at three doors above any requirement, so no stored grant can resurrect a terminal.
    /// Folding the terminal check into the per-app gate as "an app that is always denied" is
    /// forbidden precisely so this stays true.
    @Test(arguments: [AgentInteractionMode.safe, .normal, .power])
    func aTerminalIsRefusedAndNeverPromptedEvenWithAStoredGrant(mode: AgentInteractionMode) async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"done","rationale":"done."}"#],
            mode: mode,
            bundleIdentifier: "com.apple.Terminal",
            appControlAlreadyGranted: false
        )
        defer { fixture.tearDown() }
        // Written past `approve`, which would have refused it — the point is that a file containing
        // one changes nothing.
        try seedRawGrant(
            at: fixture.approvedApps.fileURL,
            bundleIdentifier: "com.apple.Terminal",
            displayName: "Terminal"
        )
        #expect(try fixture.approvedApps.loadAll().map(\.bundleIdentifier) == ["com.apple.Terminal"])

        fixture.viewModel.startVisionSession(goal: "run a command", appName: "Terminal")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.approvalRequest == nil, "a terminal is never a question")
        #expect(fixture.model.prompts.isEmpty)
        #expect(fixture.synthesizer.clickCount == 0)
        let message = try #require(fixture.viewModel.errorMessage)
        #expect(message.contains("Sonny never controls a terminal"))
    }

    /// **Revoking mid-session stops it at the next iteration.**
    ///
    /// The grant is re-asked at the top of every iteration rather than trusted from the plan gate,
    /// because a grant is durable and a session is long: the answer that started this one can stop
    /// being true while it runs. The session below is allowed to take its first action, then the
    /// grant is removed underneath it, and the next iteration ends the session rather than
    /// re-prompting — a containment refusal never re-prompts, and the user has just answered this
    /// exact question in the other direction.
    @Test
    func revokingTheGrantMidSessionEndsTheSessionAtTheNextIteration() async throws {
        let fixture = try makeFixture(
            replies: [
                #"{"action":"click","x":10,"y":10,"target":"General","consequence":"ordinary","rationale":"r"}"#,
                #"{"action":"done","rationale":"never reached."}"#
            ],
            bundleIdentifier: "com.microsoft.VSCode",
            appControlAlreadyGranted: false
        )
        defer { fixture.tearDown() }
        try seedRawGrant(
            at: fixture.approvedApps.fileURL,
            bundleIdentifier: "com.microsoft.VSCode",
            displayName: "VS Code"
        )

        fixture.viewModel.startVisionSession(goal: "open the extensions panel", appName: "VS Code")
        // The first action lands, which is what makes this a *mid*-session revocation rather than a
        // refusal at the gate.
        try await waitUntil("the first synthesized action") { fixture.synthesizer.clickCount == 1 }
        try revokeAllGrants(at: fixture.approvedApps.fileURL)
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 1, "no action after the revocation")
        #expect(fixture.viewModel.approvalRequest == nil, "a withdrawn grant is not re-prompted")
        let summary = fixture.viewModel.finalSummary + (fixture.viewModel.errorMessage ?? "")
        #expect(summary.contains("no longer allowed to control VS Code"))
    }

    /// **Founder decision 4, through the product**: Normal → Safe keeps the user's own list and
    /// drops the starter list's contribution.
    ///
    /// Asserted as behaviour rather than as a store inspection, which is the acceptance criterion's
    /// own wording and the right one: the store keeping a row is not the claim — the claim is that
    /// the user is not asked again about the app they approved, and *is* asked about the one only
    /// Sonny's own list ever vouched for. Both halves run through `startVisionSession` with only
    /// `interactionMode` changing between them.
    ///
    /// The founder asked that the reasoning be kept verbatim: *auto-clearing destroys user data on
    /// a toggle, which the consequence rule says should ask first.*
    @Test
    func switchingToSafeKeepsTheUsersOwnGrantAndDropsTheStarterListsContribution() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"done","rationale":"first."}"#],
            bundleIdentifier: "com.microsoft.VSCode",
            appControlAlreadyGranted: false
        )
        defer { fixture.tearDown() }

        // In Normal, approve VS Code by hand — the founder's one click, once, ever. The question
        // arrives after the first capture, which is §4.3's ordering.
        fixture.viewModel.startVisionSession(goal: "open the extensions panel", appName: "VS Code")
        try await waitUntil("the per-app control question") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)
        #expect(try fixture.approvedApps.loadAll().map(\.bundleIdentifier) == ["com.microsoft.VSCode"])

        // Switch to Safe, over the same grants file. Safe's own floor asks about the session
        // envelope at the plan gate — that is unchanged and is not this gate — and after allowing
        // it, the user's own grant means **no per-app question follows**: the loop goes straight on
        // to Safe's capture review.
        let afterSwitch = try makeFixture(
            replies: [#"{"action":"done","rationale":"second."}"#],
            mode: .safe,
            bundleIdentifier: "com.microsoft.VSCode",
            approvedAppsFile: fixture.approvedApps.fileURL,
            appControlAlreadyGranted: false
        )
        defer { afterSwitch.tearDown() }
        afterSwitch.viewModel.startVisionSession(goal: "open the extensions panel", appName: "VS Code")
        try await waitUntil("Safe mode's session-envelope question") { afterSwitch.viewModel.approvalRequest != nil }
        let envelope = try #require(afterSwitch.viewModel.approvalRequest)
        #expect(envelope.assessment.escalations.map(\.reason).joined(separator: " ")
            .contains("will send redacted screenshots"))
        afterSwitch.viewModel.start()

        // The next thing waiting is the capture preview, not another approval — the grant survived
        // the switch.
        try await waitUntil("Safe mode's capture review") { afterSwitch.viewModel.visionCapturePreview != nil }
        #expect(afterSwitch.viewModel.approvalRequest == nil, "the user's own grant survives a switch to Safe")
        afterSwitch.viewModel.resolveVisionCapturePreview(allowing: false)
        try await waitForIdle(afterSwitch.viewModel)

        // And a starter-list app, which Normal ran silently, **is** asked about in Safe — after its
        // own first capture, and before its capture review. The starter list's contribution really
        // is dropped, and it is the reason that says so.
        let starterInSafe = try makeFixture(
            replies: [#"{"action":"done","rationale":"third."}"#],
            mode: .safe,
            approvedAppsFile: fixture.approvedApps.fileURL,
            appControlAlreadyGranted: false
        )
        defer { starterInSafe.tearDown() }
        starterInSafe.viewModel.startVisionSession(goal: "open my reading list", appName: "Safari")
        try await waitUntil("Safe mode's session-envelope question") { starterInSafe.viewModel.approvalRequest != nil }
        starterInSafe.viewModel.start()
        try await waitUntil("Safe mode's per-app question about Safari") {
            starterInSafe.viewModel.approvalRequest?.approvalCopy.involvedResource == "Safari"
                && starterInSafe.viewModel.approvalRequest?.assessment.escalations
                    .contains { $0.reason.contains("has not been allowed") } == true
        }
        let dropped = try #require(starterInSafe.viewModel.approvalRequest)
        let droppedReasons = dropped.assessment.escalations.map(\.reason).joined(separator: " ")
        #expect(droppedReasons.contains("Sonny has not been allowed to control Safari yet."))
        starterInSafe.viewModel.cancelCurrentRun()
        try await waitForIdle(starterInSafe.viewModel)
    }

    /// **A write failure says the right thing, and the run does not start** — the half of SONNY-140's
    /// load-versus-write requirement that had no call site until this ticket gave it one.
    ///
    /// The two failures are different problems and must not share a sentence.
    /// `recordLocalStorageLoadFailure`'s wording is hardcoded to "could not be decrypted or decoded",
    /// which describes an existing file that will not read back — the wrong problem entirely for a
    /// save that failed, and conflating the two is a bug this repository has shipped once already.
    /// So this asserts the write sentence literally *and* asserts the load sentence is absent.
    ///
    /// **This test found a real defect and the fix is what it now pins.** The first implementation
    /// recorded the failure as a storage notice and started the session anyway, on the reasoning
    /// that a bookkeeping failure is not a task failure. It is here: the session's own
    /// per-iteration re-resolution finds no grant on its first iteration and ends the session with
    /// "Sonny stopped because it is no longer allowed to control VS Code" — said to somebody who had
    /// just pressed Allow. The run stopped either way; only the reason the user read was false. So a
    /// grant that cannot be written now stops the run at the gate, with one true sentence.
    @Test
    func aFailedGrantWriteSaysSoInItsOwnWordsAndStopsTheRun() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApprovedAppWriteFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A regular file where the store wants its directory, so `createDirectory` cannot succeed.
        let blocked = root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked, options: .atomic)

        let fixture = try makeFixture(
            replies: [#"{"action":"done","rationale":"ran anyway."}"#],
            bundleIdentifier: "com.microsoft.VSCode",
            approvedAppsFile: blocked.appendingPathComponent("approved-apps.json"),
            appControlAlreadyGranted: false
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open the extensions panel", appName: "VS Code")
        try await waitUntil("the per-app control question") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        // The storage banner, in its own words. `recordLocalStorageWriteFailure` rather than the
        // load banner, whose "could not be decrypted or decoded" describes an existing file that
        // will not read back — the wrong problem entirely for a save that failed.
        let notice = try #require(fixture.viewModel.localStorageNotice)
        #expect(notice.hasPrefix("Sonny could not save that you allowed it to control VS Code:"))
        #expect(
            !notice.contains("could not be decrypted or decoded"),
            "a save failure must not borrow the load banner's wording"
        )

        // And the session's own sentence, which is the half this fix round is about: it says the
        // save failed, and it does **not** say the user withdrew anything.
        let summary = fixture.viewModel.finalSummary + (fixture.viewModel.errorMessage ?? "")
        #expect(summary.contains("could not save that you allowed it to control VS Code"))
        #expect(!summary.contains("no longer allowed"))
        // Nothing ran past the gate.
        #expect(fixture.synthesizer.clickCount == 0)
        #expect(fixture.viewModel.approvalRequest == nil)
    }

    // MARK: - PR #88 fix round: the ordering §4.3 requires

    /// **F1's pin: the first capture and the shell check run before the per-app approval.**
    ///
    /// Founder decision, recorded 2026-08-21: §4.3's capture-first ordering wins over §2.3's
    /// reuse-the-ordinary-plan-time-path for this one approval, because only the capture reveals a
    /// shell in a window whose *app* no name list refuses. An unlisted terminal — one this
    /// repository has never heard of, which is the gap SONNY-102 is about — must therefore be caught
    /// by that first capture **before any approval is asked and before any grant is minted**,
    /// otherwise the accidental-approval trap the decision exists to close is still open: the user
    /// meets an unknown app as an ordinary per-app question and allows one by mistake.
    ///
    /// VS Code stands in for that unlisted app here. It is off the starter list, it is in the test
    /// process's installed universe, and its window showing a shell is the embedded-shell case
    /// exactly — the sharpest form of the gap, since no bundle identifier distinguishes "has a
    /// terminal panel in it".
    @Test
    func aFirstCaptureShowingAShellRefusesBeforeAnyPerAppApprovalIsAskedOrGrantMinted() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"click","x":10,"y":10,"target":"OK","consequence":"ordinary","rationale":"r"}"#],
            bundleIdentifier: "com.microsoft.VSCode",
            appControlAlreadyGranted: false,
            recognizer: ScriptedRecognizer([Self.shellScreen])
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "run the deploy script", appName: "VS Code")
        try await waitForIdle(fixture.viewModel)

        // The refusal fired, and it is the shell's — not the per-app gate's.
        let summary = fixture.viewModel.finalSummary + (fixture.viewModel.errorMessage ?? "")
        #expect(summary.contains("that window is showing a shell"))
        // **Nothing was ever asked.** This is the assertion the ordering exists for.
        #expect(fixture.viewModel.approvalRequest == nil)
        // **And nothing was minted.** A grant for an app Sonny refuses would outlive the session
        // that minted it and sit in the revocation list looking like permission.
        #expect(try fixture.approvedApps.loadAll().isEmpty)
        // Nothing left the device and nothing touched the machine.
        #expect(fixture.model.prompts.isEmpty)
        #expect(fixture.synthesizer.clickCount == 0)
    }

    /// **F2's pin: a plan-level Allow mints no grant.**
    ///
    /// The plan here is mixed — a vision step plus a draft that would overwrite an existing file —
    /// which is the shape that made this reachable: the destructive step raises the plan-level
    /// prompt, the vision step names an app, and the branch's first implementation minted a grant
    /// for that app on any plan-level Allow whose plan happened to carry a vision target. Nothing on
    /// that panel disclosed it, the app in question is one only *Sonny's* starter list vouched for,
    /// and the grant then outranked a later switch to Safe — which is precisely founder decision 4
    /// turned upside down.
    ///
    /// Under §4.3's ordering there is no plan-time per-app write at all: the grant is minted inside
    /// the session, after the first capture clears the screen check, by the person answering the
    /// per-app question. Safari is allowed here by the starter list, so no such question is asked
    /// and the store stays empty — which is the whole claim.
    @Test
    func aPlanLevelAllowOnAMixedPlanMintsNoAppGrant() async throws {
        // The planner's output has to sit inside the fixture's own whitelist root, and that root
        // only exists once the fixture does — hence the box.
        let planner = MixedVisionAndDraftPlanner()
        let fixture = try makeFixture(
            replies: [#"{"action":"done","rationale":"done."}"#],
            appControlAlreadyGranted: false,
            delegationPlanner: planner
        )
        defer { fixture.tearDown() }
        let draft = fixture.root.appendingPathComponent("notes.md")
        planner.output = draft
        // The file that makes the draft step destructive, and therefore makes the plan ask.
        try "an existing draft".write(to: draft, atomically: true, encoding: .utf8)

        fixture.viewModel.command = "tidy up my reading list and write the notes"
        fixture.viewModel.start()
        try await waitUntil("the plan-level destructive approval") { fixture.viewModel.approvalRequest != nil }

        // The prompt is the overwrite's, and it says nothing about controlling an app.
        let request = try #require(fixture.viewModel.approvalRequest)
        let reasons = request.assessment.escalations.map(\.reason).joined(separator: " ")
        #expect(reasons.contains("already exists"))
        #expect(!reasons.contains("has not been allowed to control"))

        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        // Nothing was minted by that Allow, and nothing was minted by the session either — Safari is
        // on the starter list, so the per-app question never arose.
        #expect(try fixture.approvedApps.loadAll().isEmpty)
    }

    /// **F3's pin: a grants file that will not open is not a withdrawal.**
    ///
    /// The two are different facts and the user is owed the right one. "Sonny stopped because it is
    /// no longer allowed to control Safari" told somebody who withdrew nothing that they had — the
    /// same class of untrue sentence this branch had already removed from the write path, arriving
    /// again by the read path.
    ///
    /// The file is corrupted *after* the session's first action lands, so this is genuinely
    /// mid-session rather than a refusal at the gate.
    @Test
    func aGrantsFileThatWillNotOpenStopsTheSessionWithoutCallingItAWithdrawal() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"Bookmarks","consequence":"ordinary","rationale":"r"}"#,
            #"{"action":"done","rationale":"never reached."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open my reading list", appName: "Safari")
        try await waitUntil("the first synthesized action") { fixture.synthesizer.clickCount == 1 }
        try corruptGrantsFile(at: fixture.approvedApps.fileURL)
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 1, "no action after the file stopped opening")
        #expect(fixture.viewModel.approvalRequest == nil, "an unreadable file is not a question")
        let summary = fixture.viewModel.finalSummary + (fixture.viewModel.errorMessage ?? "")
        #expect(summary.contains("could not read which apps you have allowed it to control"))
        #expect(summary.contains("Safari"))
        // The sentence this test exists to prevent.
        #expect(!summary.contains("no longer allowed"))
        // And the storage banner says which store failed, in the load wording, which is correct here
        // — this really is an existing file that would not read back.
        let notice = try #require(fixture.viewModel.localStorageNotice)
        #expect(notice.contains("allowed apps: A local data file exists but could not be decrypted or decoded."))
    }

    /// **F3's other half: switching to Safe mid-session for a starter-list-only app really is a
    /// withdrawal**, and belongs under that case rather than a new one.
    ///
    /// Nothing was removed from the user's list — there was never anything on it. What changed is
    /// the dial the user turned themselves, and in Safe the starter list vouches for nothing. So
    /// "no longer allowed" is true here, and the case doc now names this as its third cause instead
    /// of the two it listed.
    @Test
    func switchingToSafeMidSessionWithdrawsAStarterListOnlyAppsStanding() async throws {
        let fixture = try makeFixture(
            replies: [
                #"{"action":"click","x":10,"y":10,"target":"Bookmarks","consequence":"ordinary","rationale":"r"}"#,
                #"{"action":"done","rationale":"never reached."}"#
            ],
            appControlAlreadyGranted: false
        )
        defer { fixture.tearDown() }

        // Normal, Safari, no user grant: the starter list alone is what allows it, so the session
        // starts and acts with no per-app question at all.
        fixture.viewModel.startVisionSession(goal: "open my reading list", appName: "Safari")
        try await waitUntil("the first synthesized action") { fixture.synthesizer.clickCount == 1 }
        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(try fixture.approvedApps.loadAll().isEmpty)

        fixture.viewModel.interactionMode = .safe
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 1, "no action after the dial moved")
        let summary = fixture.viewModel.finalSummary + (fixture.viewModel.errorMessage ?? "")
        #expect(summary.contains("no longer allowed to control Safari"))
        // Nothing was minted on the way out: a mode switch does not fill in the user's own list.
        #expect(try fixture.approvedApps.loadAll().isEmpty)
    }

    /// **F5's pin: leaving Power mid-session withdraws a standing nothing else vouched for.**
    ///
    /// The cause the enumerated list missed. `AppControlResolver`'s Power arm returns `.allowed`
    /// unconditionally — it consults no list at all — so a session started in Power on an app that
    /// is on neither the starter list nor the user's own list has a standing that exists only while
    /// the dial says Power. Moving to **Normal** takes it away, which is the case a reader working
    /// from the Normal → Safe cause alone would not expect, since Normal is the *looser* of the two
    /// destinations.
    ///
    /// VS Code is the app precisely because it is on neither list and is held off the starter list
    /// permanently by guard (b).
    @Test
    func leavingPowerMidSessionWithdrawsAStandingOnlyPowerVouchedFor() async throws {
        let fixture = try makeFixture(
            replies: [
                #"{"action":"click","x":10,"y":10,"target":"Extensions","consequence":"ordinary","rationale":"r"}"#,
                #"{"action":"done","rationale":"never reached."}"#
            ],
            mode: .power,
            bundleIdentifier: "com.microsoft.VSCode",
            appControlAlreadyGranted: false
        )
        defer { fixture.tearDown() }

        // Power asks about no app, so the session starts and acts with no per-app question at all
        // and nothing is written to anybody's list.
        fixture.viewModel.startVisionSession(goal: "open the extensions panel", appName: "VS Code")
        try await waitUntil("the first synthesized action") { fixture.synthesizer.clickCount == 1 }
        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(try fixture.approvedApps.loadAll().isEmpty)

        // Not to Safe — to **Normal**, the looser destination, which is the half the list missed.
        fixture.viewModel.interactionMode = .normal
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 1, "no action after the dial moved")
        #expect(fixture.viewModel.approvalRequest == nil, "a withdrawn standing is not re-prompted")
        let summary = fixture.viewModel.finalSummary + (fixture.viewModel.errorMessage ?? "")
        #expect(summary.contains("no longer allowed to control VS Code"))
        #expect(try fixture.approvedApps.loadAll().isEmpty)
    }

    /// **The second guard on the screen-check half of §4.3's ordering** (PR #88 records round, F8).
    ///
    /// §4.3 has two halves and they fail to different mutations. *Capture before question* is held
    /// by `thePerAppQuestionArrivesOnlyAfterACaptureThatWasScannedAndNeverSent` and by the test
    /// below it. *Shell verdict before question* — an unlisted app whose window is showing a shell
    /// must be refused rather than asked about — was held by
    /// `aFirstCaptureShowingAShellRefusesBeforeAnyPerAppApprovalIsAskedOrGrantMinted` and **by
    /// nothing else**, which made the accidental-approval trap the founder's decision exists to
    /// close a single point of failure, sitting on the adjacent-lines reorder a future session is
    /// most likely to make.
    ///
    /// **The observable here is deliberately not the one that test uses.** It reads the *persisted
    /// session record* rather than published view-model state: under the correct ordering the
    /// session ends and the journal keeps `screen_shows_shell` with no entries, and under the
    /// reorder the loop is parked on a question and there is no end record at all. So an edit that
    /// broke one test's surface leaves the other's intact, and the wait below settles on whichever
    /// happens first rather than on a timeout.
    ///
    /// It also pins something the other test does not: **what the audit trail says happened.** A
    /// refusal the record describes differently from the panel is a refusal nobody can audit, and
    /// for this ordering the record is the only place the difference is durable.
    @Test
    func theRecordOfAnUnapprovedShellAppSaysTheShellRefusedItAndNotThatItWasAsked() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"click","x":10,"y":10,"target":"OK","consequence":"ordinary","rationale":"r"}"#],
            bundleIdentifier: "com.microsoft.VSCode",
            appControlAlreadyGranted: false,
            recognizer: ScriptedRecognizer([Self.shellScreen])
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "run the deploy script", appName: "VS Code")
        // Whichever comes first — a question, or the session ending. Under the reorder the question
        // wins and the assertions below fail on a missing record rather than on a 30s backstop.
        try await waitUntil("the session to settle one way or the other") {
            fixture.viewModel.approvalRequest != nil || !fixture.viewModel.isRunning
        }

        let record = try #require(
            try fixture.journal.loadAll().first,
            "the session should have ended and written its record, not parked on a question"
        )
        #expect(record.endReasonCode == "screen_shows_shell")
        #expect(record.entries.isEmpty, "nothing was done, so nothing is journalled")
        #expect(record.appDisplayName == "VS Code")
        // And the two facts the trap is about: nobody was asked, and nothing was minted.
        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(try fixture.approvedApps.loadAll().isEmpty)
    }

    /// **F8's second guard on §4.3's ordering, from a genuinely different angle.**
    ///
    /// The founder's whole decision rests on one property — no per-app question before a capture has
    /// been taken and put through the screen check — and it was held by exactly one test, in a file
    /// the rebase touches.
    ///
    /// **The first version of this test did not hold it, and a mutation battery is what said so.**
    /// It asserted that no prompt and no payload had reached the model when the question appeared,
    /// and that the app had been activated — all of which are equally true with the gate moved
    /// *above* the capture, because nothing is sent either way and `checkIterationStart` activates
    /// the target before both orderings. Mutant M15, which reverses the ordering outright, was
    /// killed by the shell test alone; this one stayed green. The claim that it was a second guard
    /// was made in a commit message before the battery ran, and was wrong.
    ///
    /// What actually distinguishes the two orderings is whether the **OCR pass has run** when the
    /// question is raised: the capture is redacted before the shell verdict exists, so a recognizer
    /// that counts its calls is the observable. One call means the capture was taken and scanned
    /// first; zero means the question came before any of it.
    @Test
    func thePerAppQuestionArrivesOnlyAfterACaptureThatWasScannedAndNeverSent() async throws {
        let recognizer = ScriptedRecognizer([Self.ordinaryScreen])
        let fixture = try makeFixture(
            replies: [#"{"action":"done","rationale":"never reached."}"#],
            bundleIdentifier: "com.microsoft.VSCode",
            appControlAlreadyGranted: false,
            recognizer: recognizer
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open the extensions panel", appName: "VS Code")
        try await waitUntil("the per-app control question") { fixture.viewModel.approvalRequest != nil }

        // **The ordering, as one number.** A capture was taken and put through the redaction pass —
        // which is where the shell verdict comes from — before the question was raised.
        #expect(
            recognizer.calls == 1,
            "the per-app question must not arrive before a capture has been scanned (§4.3)"
        )
        // And it went nowhere: no prompt and no image reached the model while the question is open.
        // These do not distinguish the orderings on their own, which is exactly the mistake this
        // test's first version made; they are here for what they do say, which is that a capture
        // taken for the gate's sake never leaves the device.
        #expect(fixture.model.prompts.isEmpty)
        #expect(fixture.model.payloads.isEmpty)
        #expect(fixture.synthesizer.clickCount == 0)
        #expect(try fixture.approvedApps.loadAll().isEmpty)

        fixture.viewModel.cancelCurrentRun()
        try await waitForIdle(fixture.viewModel)
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

    /// **The capture review's step line is whole, and it says "Step 2 of 8" rather than "Step 2 of
    /// Safari"** (SONNY-303).
    ///
    /// `VisionCapturePreview` carried `iteration` and no cap, so the panel interpolated the app's
    /// display name where the second half belongs and Safe mode's pre-send review read as nonsense.
    /// The cap is a field on the type now, taken from `containment.limits.maximumIterations` at the
    /// one construction site, which is the same value that iteration's own
    /// `visionSessionDidProgress` call carries — so the two panels cannot come to disagree about how
    /// long the session is. (This said "three lines above it" of a call eighteen lines above it; a
    /// distance drifts and a symbol does not — PR #140 review, F3.)
    ///
    /// Asserted at the **second** iteration, and with a cap that is neither the iteration nor the
    /// fixture's default, because "Step 2 of 8" is the sentence the founder's decision names and
    /// because a test that reads 1 and 4 could pass on a field wired to the wrong number. The
    /// sentence itself goes through `ScreenControlSessionPresentation.stepLine`, which is what the
    /// panel calls — the source scan in `WidgetSessionApprovalPanelTests` says the panel calls it,
    /// and this says what it produces for a real preview.
    @Test
    func theCaptureReviewsStepLineNamesTheIterationCapRatherThanTheApp() async throws {
        let fixture = try makeFixture(
            replies: [
                #"{"action":"click","x":10,"y":10,"target":"Bookmarks","consequence":"ordinary","rationale":"r"}"#,
                #"{"action":"done","rationale":"Done."}"#
            ],
            mode: .safe,
            limits: VisionSessionLimits(maximumIterations: 8, settleNanoseconds: 0)
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open bookmarks", appName: "Safari")
        try await waitUntil("the session-envelope approval") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.start()

        try await waitUntil("the first capture preview") { fixture.viewModel.visionCapturePreview != nil }
        let first = try #require(fixture.viewModel.visionCapturePreview)
        #expect(first.iteration == 1)
        #expect(first.maximumIterations == 8, "the session's own budget, not the fixture default of 4")
        #expect(
            ScreenControlSessionPresentation.stepLine(
                iteration: first.iteration,
                maximumIterations: first.maximumIterations
            ) == "Step 1 of 8"
        )
        // The app's name is still on the panel — in the sentence that is about the app — and this is
        // the half the defect confused it with.
        #expect(first.appDisplayName == "Safari")

        fixture.viewModel.resolveVisionCapturePreview(allowing: true)
        try await waitUntil("the action approval") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.start()

        try await waitUntil("the second capture preview") { fixture.viewModel.visionCapturePreview != nil }
        let second = try #require(fixture.viewModel.visionCapturePreview)
        #expect(second.iteration == 2)
        #expect(second.maximumIterations == 8, "the cap does not move with the iteration")
        #expect(
            ScreenControlSessionPresentation.stepLine(
                iteration: second.iteration,
                maximumIterations: second.maximumIterations
            ) == "Step 2 of 8"
        )
        // The same session, so the HUD's own count and the preview's agree rather than being two
        // readings of one budget.
        let progress = try #require(fixture.viewModel.visionSessionProgress)
        #expect(progress.maximumIterations == second.maximumIterations)

        fixture.viewModel.resolveVisionCapturePreview(allowing: true)
        try await waitForIdle(fixture.viewModel)
    }

    /// **The widget must render the capture question, or a Safe-mode session hangs.**
    ///
    /// `hasVisibleWidgetPanel` is the single source of truth for the widget's panel, so a parked
    /// continuation the panel declines to show is a session suspended with nothing on screen able
    /// to answer it. Pinned beside the other three unconditional states for the same reason they
    /// are. (This named `FloatingWidgetWindowController`'s compositing decision as the predicate's
    /// second reader until SONNY-189; that mode was superseded on 2026-07-21 and the second reader
    /// is now `FloatingWidgetView.isMicHintSlotFree`.)
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

    // MARK: - The widget while a mid-loop approval is parked (SONNY-255)

    /// **The panel the user is actually looking at, asked of the widget rather than of its source.**
    ///
    /// This is the assertion the defect needed and did not have. `FloatingWidgetView.state` is an
    /// ordered chain, `.controlling` sat above `.permission`, and `visionSessionProgress` is written
    /// at the top of every iteration and cleared only at session end — so from iteration 1 the
    /// widget showed the HUD, a panel with no question in it, while the loop waited on an answer.
    /// Every source scan in the suite agreed, correctly, that each branch was where the file said it
    /// was; none of them could say what the widget *resolved to*, which is why `state` is now
    /// internal and this test reads it.
    ///
    /// The run is the ordinary mid-loop consequence-rule approval — the common path, not an edge:
    /// the per-action gate raises it after the iteration's own progress report, so both values are
    /// set together every time.
    @Test
    func theWidgetShowsTheApprovalRatherThanTheHudWhileAMidLoopQuestionIsParked() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"Delete","consequence":"destructive","rationale":"remove it"}"#,
            #"{"action":"done","rationale":"Deleted."}"#
        ])
        defer { fixture.tearDown() }
        let widget = FloatingWidgetView(viewModel: fixture.viewModel)

        fixture.viewModel.startVisionSession(goal: "delete the draft", appName: "Safari")
        try await waitUntil("the mid-loop approval") { fixture.viewModel.approvalRequest != nil }

        // Both are set — which is the whole premise, and is what made the old ordering unreachable
        // rather than merely unlucky.
        let progress = try #require(fixture.viewModel.visionSessionProgress)
        #expect(progress.appDisplayName == "Safari")
        let request = try #require(fixture.viewModel.approvalRequest)

        guard case .permission(let shown) = widget.state else {
            Issue.record("the widget resolved to \(widget.state) with an approval pending mid-session")
            return
        }
        // The same request, not merely *a* permission state: one approval object reaches both
        // surfaces, which is what "no second approval surface" means concretely.
        #expect(shown.approvalCopy.actionDescription == request.approvalCopy.actionDescription)
        #expect(shown.approvalCopy.actionDescription.contains("Delete"))

        // And the composer agrees with the panel above it rather than describing the HUD.
        #expect(ComposerPresentation.prompt(for: widget.composerState) == "Answer above first\u{2026}")

        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)
        #expect(fixture.synthesizer.clickCount == 1)
    }

    /// **The HUD comes back the moment the question is answered, and the session carries on.**
    ///
    /// The other half of the reorder: `.permission` outranking `.controlling` is only correct if the
    /// approval clears when it is answered — otherwise a stale question would cover the progress
    /// line for the rest of the session, which is the same defect pointing the other way.
    /// `resolveVisionApproval` clears `approvalRequest` synchronously before resuming the
    /// continuation, and this is what says so from the widget's side.
    @Test
    func answeringTheApprovalPutsTheHudBackAndTheSessionContinues() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"Delete","consequence":"destructive","rationale":"remove it"}"#,
            #"{"action":"click","x":20,"y":20,"target":"Bookmarks","consequence":"ordinary","rationale":"carry on"}"#,
            #"{"action":"done","rationale":"Deleted."}"#
        ])
        defer { fixture.tearDown() }
        let widget = FloatingWidgetView(viewModel: fixture.viewModel)

        fixture.viewModel.startVisionSession(goal: "delete then browse", appName: "Safari")
        try await waitUntil("the mid-loop approval") { fixture.viewModel.approvalRequest != nil }

        fixture.viewModel.start()

        // Synchronously after the press, before the loop has had a chance to advance: the question
        // is gone and the HUD is what the widget draws again.
        #expect(fixture.viewModel.approvalRequest == nil)
        guard case .controlling = widget.state else {
            Issue.record("the widget resolved to \(widget.state) immediately after the approval was allowed")
            return
        }

        try await waitForIdle(fixture.viewModel)
        #expect(fixture.synthesizer.clickCount == 2)
        #expect(fixture.viewModel.finalSummary == "Deleted.")
        // Session over: neither panel is on screen anymore.
        #expect(fixture.viewModel.visionSessionProgress == nil)
        #expect(fixture.viewModel.approvalRequest == nil)
    }

    /// **Stop stays reachable while the question is up**, which is the constraint the reorder had to
    /// respect: the HUD it displaces is where the emergency control for a program driving the user's
    /// screen lived.
    ///
    /// Driven through the closure the panel is actually handed — `emergencyStopVisionSession`, the
    /// same call the HUD's own Stop makes — rather than through `cancelCurrentRun`, so what is
    /// exercised is the wiring and not just the underlying stop. The session ends, the click the
    /// approval was asking about never happens, and the run reports being stopped rather than
    /// reporting that the user declined an action.
    @Test
    func stopFromTheApprovalPanelEndsTheSessionWithoutTakingTheAction() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"Delete","consequence":"destructive","rationale":"remove it"}"#,
            #"{"action":"done","rationale":"Deleted."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "delete the draft", appName: "Safari")
        try await waitUntil("the mid-loop approval") { fixture.viewModel.approvalRequest != nil }

        // Live by the same predicate the panel's Stop is gated on, so the guard inside it is
        // satisfied for the reason the panel assumes rather than by accident.
        #expect(fixture.viewModel.isVisionSessionLive)
        fixture.viewModel.emergencyStopVisionSession()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 0, "the action under question was never taken")
        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.viewModel.visionSessionProgress == nil)
        #expect(!fixture.viewModel.isVisionSessionLive)
        // A stop reads as a stop, on both surfaces that record one. The task's own summary is the
        // cancellation sentence every cancelled run gets, and the session's journal closes as
        // `user_stopped` rather than as the declined-action refusal a `nil` decision would produce
        // if the cancellation check inside `requestVisionActionApproval` were not there.
        #expect(fixture.viewModel.finalSummary == "Canceled.")
        let record = try #require(try fixture.journal.loadAll().first)
        #expect(record.endReasonCode == "user_stopped")
        #expect(record.entries.isEmpty, "the action under question left no entry — it never ran")
    }

    /// **Permission revocation takes the same stop path.** §13.5's invariant is one implementation of
    /// "control was lost, for any reason" — with a distinct reason code and copy routing the user to
    /// the Permission Center.
    @Test
    func revokingAccessibilityMidSessionStopsItAndRoutesToThePermissionCenter() async throws {
        // Grants this test takes away mid-session: the shared stub's flags are `var`s for exactly
        // this, and `accessibilityTrusted` starts true by default.
        let permissions = DeterministicScreenPermissions()
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
    // MARK: - SONNY-136: a token that expires between iterations

    /// **The one test in this file that talks to a real client over a URL stub**, because its
    /// subject is what happens on the wire between two iterations rather than what the loop decides.
    ///
    /// SONNY-136's fifth requirement: a screen-control session makes up to twelve sequential
    /// requests with continuity held entirely client-side in the runner's `history`, and an access
    /// token that expires partway through must refresh and carry on rather than drop the session.
    /// `VisionSessionRunner`'s own declaration states the outcome — "`auth.token_expired` between
    /// iteration 4 and 5 never reaches this type" — and §7.2 case 1a's words for what the user gets
    /// are "nothing — this is invisible when it works".
    ///
    /// **That paragraph named this test before it existed.** It cited
    /// `aTokenExpiryMidSessionIsInvisibleAndTheSessionCarriesOn` as what held the claim and no such
    /// test was in the tree at `4824e50` (`git grep -c aTokenExpiryMidSession -- Tests` → exit 1,
    /// no output). The behaviour was real — the refresh lives in `SonnyBackendClient.send` and its
    /// own suite covers it on a single request — but nothing had ever run it inside a session, which
    /// is the case the requirement is about: a refresh that worked on request one and lost the
    /// history on request five would pass every existing test.
    ///
    /// **Four things are asserted, and the last two are what make it more than "it did not crash".**
    /// The session reaches `done` at the iteration it was scripted to; exactly one refresh POST is
    /// made, not one per subsequent request; every send after the refresh carries the *new* bearer;
    /// and the user is told nothing at all — no error, and the final summary is the session's own.
    @Test
    func aTokenExpiryMidSessionIsInvisibleAndTheSessionCarriesOn() async throws {
        let backend = SignedInBackendFixture(accessToken: "access-before")
        let recorded = RecordedBackendRequests()
        // The token expires on the fourth screen request, which is mid-session by construction: the
        // script runs six iterations, so there are sends on both sides of it.
        let expireOnScreenRequest = 4
        let screenRequests = Counter()
        backend.register { request in
            recorded.append(request)
            let path = request.url?.path ?? ""
            if path == "/v1/auth/refresh" {
                return .reply(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: try! JSONSerialization.data(withJSONObject: [
                        "access_token": "access-after",
                        "token_type": "Bearer",
                        "expires_in": 3600,
                        "expires_at": "2026-08-28T10:41:07Z",
                        "refresh_token": "refresh-after",
                        "user": ["id": "test-user"],
                    ])
                )
            }
            let attempt = screenRequests.next()
            if attempt == expireOnScreenRequest {
                return .reply(
                    statusCode: 401,
                    headers: ["Content-Type": "application/json"],
                    body: try! JSONSerialization.data(withJSONObject: [
                        "error": [
                            "code": "auth.token_expired",
                            "message": "Server-authored sentence the client must never display.",
                            "retryable": false,
                            "request_id": "req_expired",
                        ],
                    ])
                )
            }
            // Five clicks then done. The replay of the expired request is the fifth screen call and
            // must get the same answer the fourth would have, so the script is keyed on how many
            // *answers* have been given rather than on the raw attempt number.
            let answered = attempt > expireOnScreenRequest ? attempt - 1 : attempt
            let outputText = answered >= 6
                ? #"{"action":"done","rationale":"Finished after the refresh."}"#
                : #"{"action":"click","x":10,"y":10,"target":"Next","consequence":"ordinary","rationale":"r"}"#
            return .reply(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try! JSONSerialization.data(withJSONObject: [
                    "request_id": "req_screen_\(attempt)",
                    "output_text": outputText,
                ])
            )
        }

        let fixture = try makeFixture(
            // Unused: the environment takes the real client below. The array cannot be empty because
            // `ScriptedVisionModel` would answer "stuck" from it if it were ever reached, and a
            // session that ended "stuck" is exactly the failure this test must not read as a pass.
            replies: [#"{"action":"done","rationale":"the scripted model must not run"}"#],
            limits: VisionSessionLimits(maximumIterations: 12, settleNanoseconds: 0),
            visionModelClient: SonnyVisionModelClient(
                client: backend.client,
                taskContext: BackendTaskContext(taskID: "task-expiry", retention: .standard)
            ),
            backendClient: backend.client
        )
        defer {
            backend.unregister()
            fixture.tearDown()
        }

        fixture.viewModel.startVisionSession(goal: "click a few times", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        // The session ran past the expiry and finished on its own terms.
        #expect(fixture.viewModel.finalSummary == "Finished after the refresh.")
        #expect(fixture.synthesizer.clickCount == 5)
        #expect(fixture.model.prompts.isEmpty, "the scripted double was reached; the real client was not used")

        let paths = recorded.all.map(\.path)
        #expect(paths.filter { $0 == "/v1/auth/refresh" }.count == 1, "\(paths)")
        // Seven screen calls for six answers: the expired one and its replay.
        #expect(paths.filter { $0 == "/v1/screen/analyze" }.count == 7, "\(paths)")

        // **The replay and everything after it carry the new token.** Without this the test would
        // pass on a client that refreshed and then went on presenting the dead credential, which the
        // stub above would happily keep answering.
        let screenCalls = recorded.all.filter { $0.path == "/v1/screen/analyze" }
        #expect(screenCalls.prefix(4).allSatisfy { $0.authorization == "Bearer access-before" })
        #expect(screenCalls.dropFirst(4).count == 3)
        #expect(screenCalls.dropFirst(4).allSatisfy { $0.authorization == "Bearer access-after" })

        // And §7.2 case 1a's promise: the user is told nothing, because nothing happened to them.
        #expect(fixture.viewModel.errorMessage == nil)

        // **The continuity itself, which nothing above reads** (PR #153's F6). Every assertion so
        // far is about paths, counts and `Authorization` headers, and a session that refreshed
        // perfectly and then forgot everything it had done would satisfy all of them — the stub
        // scripts its replies off a request counter rather than off content, so it would finish
        // byte-identically. Continuity is held entirely client-side in `VisionSessionRunner`'s own
        // `history`, which reaches the wire inside the observed block, so a *later* body carrying an
        // *earlier* iteration's line is the only place it is observable at all.
        //
        // Mutating the runner to drop its history from iteration 5 leaves every other assertion here
        // green, which is the same vacuity the phantom citation had: a test that exists and checks
        // the wrong thing.
        let lastScreenBody = try #require(screenCalls.last).text
        #expect(
            lastScreenBody.contains("iteration 1: clicked"),
            "the send after the refresh carried no history from before it"
        )
        #expect(
            lastScreenBody.contains("iteration 4: clicked"),
            "the send after the refresh lost the iterations either side of the expiry"
        )
        // The first send cannot carry a history, which is what makes the two above a real
        // difference rather than a string that is always present.
        #expect(!(try #require(screenCalls.first).text.contains("iteration 1: clicked")))
    }

    /// A counter the stub handler can advance. `BackendStubURLProtocol` runs its handler on a
    /// URLSession worker, so this is a lock rather than an actor or a captured `var`.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    // MARK: - SONNY-131: mid-loop failure, decided rather than discovered

    /// **The decision, exercised end to end: a send that fails at iteration 3 of a longer session
    /// stops the session there, keeps the two actions it already took, and says so.**
    ///
    /// `VisionSessionInterrupted`'s own declaration carries the reasoning for each half. What this
    /// asserts is the concrete outcome the contract's §12 asks SONNY-131 to pick and pin: not a
    /// retry, not a carry-on, and not a silent stop.
    @Test
    func aSendThatFailsMidSessionStopsTheSessionThereAndKeepsWhatItDid() async throws {
        let click = #"{"action":"click","x":10,"y":10,"target":"Next","consequence":"ordinary","rationale":"r"}"#
        let fixture = try makeFixture(
            replies: Array(repeating: click, count: 8),
            limits: VisionSessionLimits(maximumIterations: 8, settleNanoseconds: 0),
            modelFailure: (
                iteration: 3,
                error: VisionModelClientError.backend(.api(SonnyBackendAPIError(
                    code: .providerUnavailable,
                    statusCode: 502,
                    message: "Server-authored sentence the client must never display.",
                    requestID: "req_err_1",
                    retryAfter: nil,
                    envelopeSaysRetryable: true
                )))
            )
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "click a few times", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        // **It stopped at the failing iteration**, rather than carrying on to the cap of 8. Three
        // sends were attempted and two clicks landed, so the session really was mid-flight.
        #expect(fixture.model.prompts.count == 3)
        #expect(fixture.synthesizer.clickCount == 2)

        // **The partial history is what the user is told**, and the sentence is the app's own.
        let message = try #require(fixture.viewModel.errorMessage)
        #expect(message == "Sonny couldn't finish this one. Try again. It stopped after 2 steps in Safari.")
        // §7.1: never the server's sentence, and never a status.
        #expect(!message.contains("Server-authored"))
        #expect(!message.contains("502"))

        // **The journal closes with a reason of its own**, so a reader can tell a send failure apart
        // from the generic `failed` every other throw produces — and the two actions that did happen
        // are still recorded, which is the durable half of "partial history".
        let record = try #require(try fixture.journal.loadAll().first)
        #expect(record.endReasonCode == "send_failed")
        #expect(record.entries.count == 2)
        #expect(record.endSummary == message)
    }

    /// **No retry loop here, and the count is the assertion.** Three sends for three iterations —
    /// not six, not nine. Every retry §9.3 allows has already happened inside `SonnyBackendClient`,
    /// which retries on the failure's own `code` and reuses the operation's idempotency key; a
    /// second loop at this level would multiply those ceilings on a route whose client timeout is
    /// 120 seconds, and would mint a fresh key per attempt, which §9.1 forbids.
    ///
    /// The failure used is the *most* retryable code in §7.2 — `server.error`, three attempts with
    /// backoff — so if this loop retried anything, it would retry this.
    @Test
    func aRetryableFailureIsNotRetriedAgainByTheSessionLoop() async throws {
        let click = #"{"action":"click","x":10,"y":10,"target":"Next","consequence":"ordinary","rationale":"r"}"#
        let fixture = try makeFixture(
            replies: Array(repeating: click, count: 8),
            limits: VisionSessionLimits(maximumIterations: 8, settleNanoseconds: 0),
            modelFailure: (
                iteration: 3,
                error: VisionModelClientError.backend(.api(SonnyBackendAPIError(
                    code: .serverError,
                    statusCode: 500,
                    message: "irrelevant",
                    requestID: nil,
                    retryAfter: nil,
                    envelopeSaysRetryable: true
                )))
            )
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "click a few times", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.model.prompts.count == 3, "the loop must not send iteration 3 more than once")
        // And the code really is one the shared client would have retried, so the count above is
        // about this loop rather than about an unretryable failure.
        #expect(SonnyBackendErrorCode.serverError.maximumAttempts == 3)
        #expect(SonnyBackendErrorCode.serverError.isRetryable(envelopeSaysRetryable: true))
    }

    /// **A session that fails on its very first send says nothing about steps**, because "stopped
    /// after 0 steps" is noise. The other half of the sentence rule the test above pins.
    @Test
    func aSendThatFailsBeforeAnyActionSaysNothingAboutSteps() async throws {
        let click = #"{"action":"click","x":10,"y":10,"target":"Next","consequence":"ordinary","rationale":"r"}"#
        let fixture = try makeFixture(
            replies: Array(repeating: click, count: 4),
            modelFailure: (iteration: 1, error: VisionModelClientError.backend(.offline))
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "click once", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.synthesizer.clickCount == 0)
        let message = try #require(fixture.viewModel.errorMessage)
        // §7.2 case 7's whole point: offline is the one failure that means every local capability
        // still works, and the sentence has to say so rather than "something went wrong".
        #expect(message == "You're offline. Everything Sonny does on this Mac still works.")
        #expect(!message.contains("step"))
    }

    /// **An oversize capture is refused with a message naming the real problem**, through the same
    /// mid-loop path — so the acceptance criterion holds where a user actually meets it rather than
    /// only at the client's own unit test.
    ///
    /// The failure injected is the exact error `SonnyVisionModelClient` throws above its ceiling.
    @Test
    func anOversizeCaptureEndsTheSessionWithASentenceNamingTheScreenshot() async throws {
        let click = #"{"action":"click","x":10,"y":10,"target":"Next","consequence":"ordinary","rationale":"r"}"#
        let fixture = try makeFixture(
            replies: Array(repeating: click, count: 4),
            modelFailure: (
                iteration: 1,
                error: VisionModelClientError.payloadTooLarge(bytes: 5_000_000, limit: 3_000_000)
            )
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "click once", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        let message = try #require(fixture.viewModel.errorMessage)
        #expect(message.contains("The window screenshot is 5000000 bytes"))
        #expect(message.contains("over the 3000000-byte limit"))
    }

    /// **A cancellation mid-send stays a cancellation**, and does not become a send failure.
    ///
    /// §12's first rule is that cancellation beats every timeout, and the sentence a user who pressed
    /// stop gets must not say something went wrong. The journal is the checkable half: `user_stopped`
    /// rather than `send_failed`.
    @Test
    func aCancellationDuringASendIsNotReportedAsASendFailure() async throws {
        let click = #"{"action":"click","x":10,"y":10,"target":"Next","consequence":"ordinary","rationale":"r"}"#
        let fixture = try makeFixture(
            replies: Array(repeating: click, count: 8),
            limits: VisionSessionLimits(maximumIterations: 8, settleNanoseconds: 0),
            // `SonnyBackendError.cancelled` is what the shared client raises when its request is cut,
            // which is the shape the emergency stop actually produces — not a bare `CancellationError`.
            modelFailure: (iteration: 2, error: VisionModelClientError.backend(.cancelled))
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "click a few times", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        let record = try #require(try fixture.journal.loadAll().first)
        #expect(record.endReasonCode == "user_stopped")
        #expect(record.endSummary == "Stopped.")
        #expect(fixture.viewModel.errorMessage == nil, "a stop is not a failure to report")
    }

    /// **Every send carries §4.5's two session fields, and they are the runner's own numbers.**
    ///
    /// The iteration is 1-based and matches the HUD's; the session id is the journal's, so a request
    /// on the wire and the row in the task history name the same run. One id across every iteration
    /// is the property that lets metering price a session rather than a request.
    @Test
    func everySendCarriesTheJournalsSessionIdAndItsOwnIterationNumber() async throws {
        let click = #"{"action":"click","x":10,"y":10,"target":"Next","consequence":"ordinary","rationale":"r"}"#
        let fixture = try makeFixture(
            replies: Array(repeating: click, count: 3)
                + [#"{"action":"done","rationale":"finished."}"#],
            limits: VisionSessionLimits(maximumIterations: 6, settleNanoseconds: 0)
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "click a few times", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        let record = try #require(try fixture.journal.loadAll().first)
        #expect(fixture.model.sessions.map(\.iteration) == [1, 2, 3, 4])
        #expect(Set(fixture.model.sessions.map(\.sessionID)) == [record.id])
    }

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

        fixture.viewModel.startVisionSession(goal: "tidy up the workspace", appName: "Safari")
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
    /// budget it cannot meet, so it resamples to its 0.5 floor and the model is shown 400x300, so one
    /// sent pixel is two points. The model then names (100, 75), a quarter of the way into what it
    /// saw; that pixel's centre is (100.5, 75.5) sent pixels, which is **(201, 151)** on screen. A
    /// resolver still scaling by the capture's own pixel count would have clicked (100.5, 75.5):
    /// inside the window, plausible, and half as far in as intended — that two-fold gap is what this
    /// test is for.
    ///
    /// The odd half-points are SONNY-145's centre sampling: a named pixel resolves to the middle of
    /// the region it covers rather than its leading edge. **The offset is half a *sent* pixel**, so
    /// it scales with the resample and stays inside the one answer about the picture's size this
    /// test exists to protect. Half a fixed *point* would be a second answer, and it would land here
    /// at (200.5, 150.5).
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

        #expect(fixture.synthesizer.events.contains(.clicked(CGPoint(x: 201, y: 151))))

        let record = try #require(try fixture.journal.loadAll().first)
        let entry = try #require(record.entries.first)
        #expect(entry.imageX == 100)
        #expect(entry.imageY == 75)
        #expect(entry.observationAfter.contains("(201, 151)"))
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
        var tags: Set<String> = []
        for prompt in fixture.model.prompts {
            #expect(prompt.contains(UntrustedContentBoundary.observedBeginName))
            #expect(prompt.contains(UntrustedContentBoundary.trustedInstructionBeginName))
            #expect(prompt.contains("click a thing"))
            if let tag = Self.segmentTag(in: prompt) {
                tags.insert(tag)
            }
        }
        // **Two iterations, two tags, measured through the real runner** (SONNY-234). The freshness
        // property is asserted on the builder's own default in
        // `UntrustedContentBoundaryTagTests.theTagIsFreshForEveryPromptAndNeverReused`; what this
        // adds is that the loop does not hoist one tag across the session. It matters here because
        // the loop is what feeds model-authored history back into the next prompt, so a session-wide
        // tag would be echoable by the one party that has seen it.
        #expect(tags.count == 2, "two iterations produced \(tags.count) distinct segment tags")
    }

    /// The twenty tag letters a prompt's observed-segment marker carries, or nil if it carries none.
    private static func segmentTag(in prompt: String) -> String? {
        let name = Array("\(UntrustedContentBoundary.observedBeginName)_".unicodeScalars)
        let scalars = Array(prompt.unicodeScalars)
        guard scalars.count > name.count else { return nil }
        for start in 0...(scalars.count - name.count) where Array(scalars[start..<(start + name.count)]) == name {
            let letters = scalars[(start + name.count)...].prefix { (65...90).contains($0.value) }
            return letters.isEmpty ? nil : String(String.UnicodeScalarView(letters))
        }
        return nil
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
    /// name-based deny list is otherwise the only thing standing there, and a terminal nobody listed
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

    /// **An editor with its terminal panel open, where nothing has failed, ends the session** — the
    /// embedded-shell case this ticket exists for, driven through the real runner (PR #57 F2).
    ///
    /// The detector-level corpus pins the signals; this pins that the session actually stops. Before
    /// the fix this screen reached one sign and the session ran on: manual-test item 2 would have
    /// passed or failed depending on whether the founder's last command happened to error, which is
    /// not a property anything should depend on.
    @Test
    func anEditorWithATerminalPanelEndsTheSessionEvenWhenNothingHasFailed() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"click","x":10,"y":10,"target":"Run","consequence":"ordinary","rationale":"r"}"#],
            recognizer: ScriptedRecognizer([Self.idleTerminalPanelScreen])
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "run the tests", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.model.prompts.isEmpty)
        #expect(fixture.synthesizer.clickCount == 0)
        #expect(fixture.viewModel.finalSummary == Self.shellRefusalSentence)
        let record = try #require(try fixture.journal.loadAll().first)
        #expect(record.endReasonCode == "screen_shows_shell")
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

    // MARK: - What a screen-control run stores (row E, SONNY-147)

    /// **The one model-authored result in the product, declared and carried all the way to disk.**
    ///
    /// This is SONNY-147's "assert the vision path declares model-authored", taken end to end
    /// through the real dispatch path rather than at the adapter: `startVisionSession` builds a plan
    /// and hands it to `start(prebuiltPlan:)`, so the row this writes is the row a typed command
    /// would have written. Read back off the file, not off published state.
    @Test
    func aScreenControlRunStoresItsSummaryAsModelAuthored() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":100,"y":100,"target":"Bookmarks","consequence":"ordinary","rationale":"open the sidebar"}"#,
            #"{"action":"done","rationale":"The reading list is open."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open my reading list", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        let record = try #require(try fixture.taskHistoryStore.loadAll().last)
        let result = try #require(record.result)
        #expect(result.provenance == .modelAuthored)
        #expect(result.text == "The reading list is open.")
        // And the plan that produced it landed in the sibling store, keyed on this row's own id.
        let taskID = try #require(record.id)
        let detail = try #require(try fixture.taskPlanDetailStore.detail(forTaskID: taskID))
        #expect(detail.planSummary == "Control Safari: open my reading list")
        #expect(detail.steps.map(\.operation) == [.visionSession])
        #expect(detail.completedAt == record.completedAt)
    }

    /// **The live recording path carries the same declaration into the planner's context**
    /// (SONNY-197), which is the hop that used to drop it — `PriorTaskOutcome` had two stored
    /// properties and provenance was not one of them, so the value `recordPriorTaskContext` already
    /// received as `resultProvenance` reached `StoredTaskResult` on disk and stopped there.
    ///
    /// Asserted beside the on-disk test above rather than in place of it, because they are two
    /// different hops out of the same call: one writes the record, the other writes the context the
    /// next command's planner will read. Both were being handed the same value; only one used it.
    @Test
    func aScreenControlRunsPriorTaskContextIsMarkedModelAuthoredToo() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"done","rationale":"The reading list is open."}"#
        ])
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open my reading list", appName: "Safari")
        try await waitForIdle(fixture.viewModel)

        let context = try #require(fixture.viewModel.priorTaskContext)
        #expect(context.outcome.provenance == .modelAuthored)
        #expect(context.outcome.summary == "The reading list is open.")
    }

    /// And an ordinary run's does not, so the marking means something. A calculator command is
    /// entirely deterministic string-building by this repository.
    @Test
    func anOrdinaryRunsPriorTaskContextStaysCodeAuthored() async throws {
        let fixture = try makeFixture(replies: [])
        defer { fixture.tearDown() }

        fixture.viewModel.command = "calc 2*2"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        let context = try #require(fixture.viewModel.priorTaskContext)
        #expect(context.outcome.provenance == .codeAuthored)
        #expect(context.outcome.summary.contains("4"))
    }

    /// **The chain join must not launder the model's text.** A plan that does some work with
    /// Sonny's own tools and *then* controls an app is a shape the product supports and describes to
    /// the user in so many words — `AgentActionExecutor.visionSplitDisclosure` writes "Sonny will do
    /// 1 step with its own tools, then attempt … by controlling Safari directly". Two units of work
    /// means `executeChain`, which joins one summary per segment, and the joined string contains the
    /// model's sentence. Declaring the join `.codeAuthored` because the joining happens in this
    /// repository is exactly the mistake this fails on.
    @Test
    func aChainWhoseScreenControlSegmentWrotePartOfTheSummaryStoresItAsModelAuthored() async throws {
        let fixture = try makeFixture(
            replies: [#"{"action":"done","rationale":"The reading list is open."}"#],
            // The planner for this run, returning the mixed shape: one ordinary step, then vision.
            // The calculator is the only second step available here that touches nothing — this
            // fixture injects no hermetic app/browser seams, so an `open_app` step would really open
            // Safari on the developer's machine.
            delegationPlanner: MixedVisionAndToolPlanner()
        )
        defer { fixture.tearDown() }

        fixture.viewModel.command = "add these up and then open my reading list"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        let record = try #require(try fixture.taskHistoryStore.loadAll().last)
        let result = try #require(record.result)
        #expect(result.provenance == .modelAuthored, "the chain's join must not launder the model's text")
        // Both halves are in the stored string, which is what makes the provenance question real
        // rather than academic.
        #expect(result.text.contains("2"))
        #expect(result.text.contains("The reading list is open."))
        // And the whole plan reached the plan store, both steps of it.
        let taskID = try #require(record.id)
        let detail = try #require(try fixture.taskPlanDetailStore.detail(forTaskID: taskID))
        #expect(detail.steps.map(\.operation) == [.calculateUtility, .visionSession])
    }

    // MARK: - Running a screen-control task again (row E, SONNY-149)

    /// **"Run again" on a screen-control task starts a fresh session and replays nothing.**
    ///
    /// This is the case the whole no-replay decision is easiest to get wrong on, because "retry a
    /// screen-control task" reads like replaying the clicks — and replaying stored clicks blind is
    /// precisely the unsafe thing. The journal is a record of what happened, not a script: the second
    /// run goes back through the planner, resolves to a vision session of its own, and is gated as
    /// any new vision command is.
    ///
    /// Asserted on the journal itself, not on "a run happened": two sessions with different ids, the
    /// first one's entries untouched, and the new task-history row pointing at the new session.
    @Test
    func runningAgainAScreenControlTaskStartsAFreshSessionAndExtendsNoJournal() async throws {
        let fixture = try makeFixture(
            replies: [
                #"{"action":"click","x":100,"y":100,"target":"Bookmarks","consequence":"ordinary","rationale":"open the sidebar"}"#,
                #"{"action":"done","rationale":"The reading list is open."}"#,
                // The second run's whole script.
                #"{"action":"done","rationale":"It was already open."}"#
            ],
            // The second run reaches the planner, because a run-again dispatches the record's
            // command text rather than the plan the first run produced. This is what turns that
            // text back into a vision plan.
            delegationPlanner: VisionOnlyPlanner()
        )
        defer { fixture.tearDown() }

        fixture.viewModel.startVisionSession(goal: "open my reading list", appName: "Safari")
        try await waitForIdle(fixture.viewModel)
        let firstRow = try #require(try fixture.taskHistoryStore.loadAll().last)
        let firstSessionID = try #require(firstRow.visionSessionID)
        let firstSession = try #require(try fixture.journal.record(withID: firstSessionID))
        #expect(firstSession.entries.count == 1, "the first session really did do something")

        fixture.viewModel.runTaskAgain(firstRow)
        try await waitForIdle(fixture.viewModel)

        // A second row, and it points at a different session.
        let rows = try fixture.taskHistoryStore.loadAll()
        #expect(rows.count == 2)
        let secondSessionID = try #require(rows.last?.visionSessionID)
        #expect(secondSessionID != firstSessionID, "a fresh session, not the old one carried forward")

        // Two sessions in the journal, and the first is byte-for-byte what it was: not extended,
        // not reopened, not replayed.
        let sessions = try fixture.journal.loadAll()
        #expect(sessions.count == 2)
        #expect(try fixture.journal.record(withID: firstSessionID) == firstSession)
        let secondSession = try #require(try fixture.journal.record(withID: secondSessionID))
        #expect(secondSession.entries.isEmpty, "the second run's own actions, not the first's")
        // And the second run really was planned rather than replayed.
        #expect(fixture.viewModel.finalSummary == "It was already open.")
    }

    // MARK: - The HUD for a session the widget did not start (SONNY-299)

    /// **A screen session started from Command Center shows its HUD, and this is the door that
    /// proves it is reachable.**
    ///
    /// `AgentViewModel.hasVisibleWidgetPanel` had no `visionSessionProgress` term at all, so a live
    /// session with nothing parked on it fell through to the origin-gated running branch, which
    /// answers `activeTaskOrigin == .widget`. `FloatingWidgetView.state` resolved to `.controlling`
    /// and the panel that draws it was never rendered: Sonny moved the cursor with the widget
    /// sitting as its ordinary pill — no statement of what it was controlling, no Pause, no Stop.
    ///
    /// Run again on a screen-control task is the reachable path, not a synthetic origin: it
    /// dispatches `origin: .commandCenter` with a comment saying why, and the command text re-plans
    /// into a session of its own (`runningAgainAScreenControlTaskStartsAFreshSessionAndExtendsNoJournal`
    /// is the same flow, asserted on the journal instead).
    ///
    /// **The moment is caught deterministically rather than by racing the loop.** A mid-loop
    /// approval suspends the second session on a continuation with both `approvalRequest` and
    /// `visionSessionProgress` set; allowing it clears the question synchronously, before the loop
    /// can advance, which is the one instant where `.controlling` is provably the state and no wall
    /// clock decides it. Every other branch that could have carried the panel is asserted absent at
    /// that instant, so the `#expect` below can only be answered by the session term.
    @Test
    func aScreenSessionStartedFromCommandCenterShowsItsHudOnTheWidget() async throws {
        let fixture = try makeFixture(
            replies: [
                // The first run, so there is a screen-control row to press Run again on.
                #"{"action":"done","rationale":"It was already open."}"#,
                // The run-again session: one destructive action to park on, then finish.
                #"{"action":"click","x":10,"y":10,"target":"Delete","consequence":"destructive","rationale":"remove it"}"#,
                #"{"action":"done","rationale":"Deleted."}"#
            ],
            // Run again dispatches the record's command text, so something has to turn that text
            // back into a vision plan.
            delegationPlanner: VisionOnlyPlanner()
        )
        defer { fixture.tearDown() }
        let widget = FloatingWidgetView(viewModel: fixture.viewModel)

        fixture.viewModel.startVisionSession(goal: "open my reading list", appName: "Safari")
        try await waitForIdle(fixture.viewModel)
        let row = try #require(try fixture.taskHistoryStore.loadAll().last)
        #expect(row.visionSessionID != nil, "the first run really was a screen-control task")

        fixture.viewModel.runTaskAgain(row)
        try await waitUntil("the run-again session's mid-loop approval") {
            fixture.viewModel.approvalRequest != nil
        }
        // The premise: this is a Command-Center-origin session, which is what the old predicate
        // answered `false` for.
        #expect(fixture.viewModel.activeTaskOrigin == .commandCenter)
        let parked = try #require(fixture.viewModel.visionSessionProgress)
        #expect(parked.appDisplayName == "Safari")

        fixture.viewModel.start()

        // Synchronously after the press: the question is gone, the session is not.
        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.viewModel.visionCapturePreview == nil)
        #expect(fixture.viewModel.visionDelegationRequest == nil)
        #expect(fixture.viewModel.visionSessionPause == nil)
        #expect(fixture.viewModel.clarificationQuestion == nil)
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.isRunning)
        #expect(fixture.viewModel.activeTaskOrigin == .commandCenter)

        // The fix. Before it, every assertion above held and this one was `false`.
        #expect(fixture.viewModel.hasVisibleWidgetPanel)
        guard case .controlling(let progress) = widget.state else {
            Issue.record("the widget resolved to \(widget.state) during a Command-Center-origin session")
            return
        }
        #expect(progress.appDisplayName == "Safari")
        #expect(progress.iteration >= 1)

        try await waitForIdle(fixture.viewModel)
        #expect(fixture.synthesizer.clickCount == 1)
        #expect(fixture.viewModel.visionSessionProgress == nil)
        #expect(!fixture.viewModel.hasVisibleWidgetPanel, "the HUD clears with the session")
    }

    /// **The widget's own door still shows the HUD**, asserted here rather than assumed from the
    /// test above: the fix adds an unconditional branch, and an unconditional branch is only worth
    /// having if the case that already worked still does. Same instant, same construction, the one
    /// difference being the origin the session was started with.
    @Test
    func aScreenSessionStartedFromTheWidgetStillShowsItsHud() async throws {
        let fixture = try makeFixture(replies: [
            #"{"action":"click","x":10,"y":10,"target":"Delete","consequence":"destructive","rationale":"remove it"}"#,
            #"{"action":"done","rationale":"Deleted."}"#
        ])
        defer { fixture.tearDown() }
        let widget = FloatingWidgetView(viewModel: fixture.viewModel)

        fixture.viewModel.startVisionSession(goal: "delete the draft", appName: "Safari", origin: .widget)
        try await waitUntil("the mid-loop approval") { fixture.viewModel.approvalRequest != nil }
        fixture.viewModel.start()

        #expect(fixture.viewModel.activeTaskOrigin == .widget)
        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.viewModel.hasVisibleWidgetPanel)
        guard case .controlling = widget.state else {
            Issue.record("the widget resolved to \(widget.state) during a widget-origin session")
            return
        }

        try await waitForIdle(fixture.viewModel)
    }

    /// **The session term sits where `state` puts `.controlling`, and carries no origin.**
    ///
    /// The two tests above are about the origin that is reachable today. This is about the two
    /// properties agreeing, which is what their doc comments promise each other and what was false
    /// for the whole life of the HUD. Asserted by *position within the property*, not by presence: a
    /// term placed below the origin-gated running branch would be dead code that reads like a fix,
    /// and a term placed above the parked questions would answer a question the user is looking at
    /// with a progress line.
    ///
    /// The origin half is asserted as the shape of the branch — `return true`, with no
    /// `activeTaskOrigin` between it and the `if` — because origin-agnosticism is the one property
    /// a behaviour test cannot finish: `.scheduled` is unreachable for screen control by three
    /// independent refusals (`StoredRoutine.forbiddenStepOperations`, `performScheduledRun`'s belt,
    /// and its fixed `.approved(.tier2)` ceiling), so no run can be built that would exercise it.
    @Test
    func thePanelPredicatePutsTheLiveSessionWhereTheWidgetsOwnPrecedenceDoes() throws {
        let predicate = try MacAgentSource.braceBlock(
            of: MacAgentSource.read("AgentViewModel.swift"),
            openedBy: "var hasVisibleWidgetPanel: Bool {"
        )
        let parked = try #require(predicate.range(of: "if visionCapturePreview != nil"))
        let approval = try #require(predicate.range(of: "if approvalRequest != nil {"))
        let session = try #require(predicate.range(of: "if visionSessionProgress != nil {"))
        let clarification = try #require(predicate.range(of: "if clarificationQuestion != nil {"))
        let running = try #require(predicate.range(of: "if isRunning {"))

        #expect(parked.lowerBound < session.lowerBound, "a parked question outranks the progress line")
        #expect(approval.lowerBound < session.lowerBound, "so does an approval (SONNY-255)")
        #expect(session.lowerBound < clarification.lowerBound)
        #expect(session.lowerBound < running.lowerBound, "above the origin gate, or it is unreachable")

        // Unconditional: what follows the branch is `return true`, and nothing between the two
        // mentions the origin.
        let branch = predicate[session.upperBound...]
        let body = try #require(branch.range(of: "}"))
        #expect(branch[..<body.lowerBound].contains("return true"))
        #expect(!branch[..<body.lowerBound].contains("activeTaskOrigin"))

        // And the same ordering on the widget's side, so "mirrors exactly" is checked on both
        // properties rather than asserted on one and trusted on the other.
        let state = try MacAgentSource.braceBlock(
            of: MacAgentSource.read("FloatingWidgetView.swift"),
            openedBy: "var state: WidgetState {"
        )
        let statePermission = try #require(state.range(of: "return .permission(approvalRequest)"))
        let stateControlling = try #require(state.range(of: "return .controlling(progress)"))
        let stateClarification = try #require(state.range(of: "return .clarification(question)"))
        let stateWorking = try #require(state.range(of: "return .working"))
        #expect(statePermission.lowerBound < stateControlling.lowerBound)
        #expect(stateControlling.lowerBound < stateClarification.lowerBound)
        #expect(stateControlling.lowerBound < stateWorking.lowerBound)
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

/// One ordinary step, then a screen-control session — the mixed shape
/// `AgentActionExecutor.visionSplitDisclosure` exists to describe, and the only reachable way a
/// model-authored summary reaches `executeChain`'s join.
private struct MixedVisionAndToolPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        AgentPlan(
            summary: "Add up and then read the list",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "calc", operation: .calculateUtility, description: "Calculate", searchQuery: "1 + 1"),
                AgentStep(
                    id: "vision",
                    operation: .visionSession,
                    description: "Control Safari",
                    appName: "Safari",
                    visionGoal: "open my reading list"
                )
            ]
        )
    }
}

/// Turns any command into a one-step screen-control plan for Safari — what a planner does with
/// "Control Safari: open my reading list", which is the text `startVisionSession` puts in the
/// command field and therefore the text a run-again sends back through it.
private struct VisionOnlyPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        AgentPlan(
            summary: "Control Safari",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "vision",
                    operation: .visionSession,
                    description: "Control Safari",
                    appName: "Safari",
                    visionGoal: "open my reading list"
                )
            ]
        )
    }
}

private struct NoShortcuts: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { [] }
}

/// Writes a grant straight into the store's file, past `ApprovedAppStore.approve` (SONNY-143).
///
/// Only two tests use it and both need exactly this: `approve` refuses a listed terminal, so a
/// terminal grant cannot be created through the product at all — and the property being pinned is
/// that a file containing one changes nothing, because the deny list refuses above the consent
/// model. The encryption is the store's own default, which under test is the deterministic
/// ephemeral key, so the file the store reads back is a real encrypted store file.
@MainActor
private func seedRawGrant(at fileURL: URL, bundleIdentifier: String, displayName: String) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let payload = [
        ApprovedApp(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            approvedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    ]
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try LocalStorageEncryption.shared.encode(payload, encoder: encoder).write(to: fileURL, options: .atomic)
}

/// Removes every grant, the way the revocation surface will and the way a local-data wipe already
/// does. Written as an empty encrypted store rather than a deleted file, because "the list is empty"
/// and "there is no list yet" must both resolve the same way and the first is the one a revocation
/// produces.
@MainActor
private func revokeAllGrants(at fileURL: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try LocalStorageEncryption.shared
        .encode([ApprovedApp](), encoder: encoder)
        .write(to: fileURL, options: .atomic)
}

/// A plan that controls an app **and** overwrites a file — the mixed shape that made a plan-level
/// Allow mint an undisclosed app grant (PR #88, F2). The draft step is what raises the prompt; the
/// vision step is what the old write keyed off.
private final class MixedVisionAndDraftPlanner: Planning, @unchecked Sendable {
    /// Set after the fixture exists, because the whitelist root the draft must live under is the
    /// fixture's own and is created inside it.
    var output: URL = URL(fileURLWithPath: "/dev/null")

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        AgentPlan(
            summary: "Tidy the reading list and write the notes.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "vision-1",
                    operation: .visionSession,
                    description: "Control Safari to tidy the reading list",
                    appName: "Safari",
                    visionGoal: "tidy the reading list"
                ),
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Write the notes.",
                    outputPath: output.path,
                    draftTitle: "Notes",
                    draftContent: "Outline for today."
                )
            ]
        )
    }
}

/// Leaves a file at the store's path that carries the encrypted header and will not decrypt — the
/// shape a real corrupted or wrong-key store has, and the one `LocalStorageEncryption.decode`
/// reports as `undecodableLocalData` rather than as legacy plaintext (PR #88, F3).
@MainActor
private func corruptGrantsFile(at fileURL: URL) throws {
    var data = LocalStorageEncryption.fileHeader
    data.append(Data(repeating: 0x7F, count: 96))
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: .atomic)
}
