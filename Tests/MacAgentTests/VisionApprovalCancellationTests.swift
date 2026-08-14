import CoreGraphics
import Foundation
import os
import Testing
@testable import MacAgent
@testable import MacAgentCore

// SONNY-80, PR #42 review finding F3 — the vision-approval continuation leak.
//
// `awaitVisionApproval` parks a continuation while a vision-delegated coordinator action waits on
// the widget's approval card. `start()` cancels `currentTask` on every new command, so with a bare
// `withCheckedContinuation` that continuation was never resumed: the vision run stayed suspended
// forever and `visionApprovalContinuation` stayed armed. The damage lands on the *next* run —
// `approvePendingRun` checks the vision continuation first, so the next approval click resumed the
// stale one with the new request's tier and the click the user actually made was swallowed.
//
// Both halves are pinned below, because the leak is only observable through the second one.

@Suite
@MainActor
struct VisionApprovalCancellationTests {
    @Test
    func newCommandDuringAPendingVisionApprovalReleasesTheContinuationAndLeavesTheNextApprovalIntact() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root)
        let viewModel = fixture.viewModel

        // `delegateToCoordinator` is the real entry point the vision loop calls, parked here on the
        // same tier-2 approval any `snippet save` raises. The task is the test's own, and what it
        // pins is the primitive's contract — a cancelled await must release its continuation rather
        // than park it forever. Worth being exact about reachability, because the review's F3 repro
        // ("type a new command") does not hold: while an approval is parked, `start()` returns at
        // its `isAwaitingApproval` guard and never reaches `currentTask?.cancel()`, and
        // `approvePendingRun` and the routine scheduler are gated the same way. The one production
        // path that cancels a vision run from this state is `cancelCurrentRun`'s own vision branch
        // (Option A) — covered end to end by `oneCancelPress…` below. This test is what keeps the
        // failure mode that branch would otherwise expose, a stale continuation swallowing the next
        // run's approval click, from being reachable at all.
        let delegation = DelegationOutcome()
        let delegationTask = Task { @MainActor in
            do {
                delegation.value = .returned(try await viewModel.delegateToCoordinator(
                    VisionCoordinatorRequest(
                        instruction: "snippet save ;vision-delegated = Alpha",
                        rationale: "The screen offers no way to do this."
                    )
                ))
            } catch {
                delegation.value = .threw(error)
            }
        }
        try await waitUntil("the vision-delegated approval to be raised") {
            viewModel.approvalRequest != nil
        }
        #expect(delegation.value == nil)

        delegationTask.cancel()

        // Half one — the cleanup. The parked continuation is resumed rather than leaked, and the
        // card it raised goes with it. Remove the cancellation handler and this is the wait that
        // times out, because nothing resumes the continuation at all.
        try await waitUntil("the parked vision approval continuation to be released") {
            delegation.value != nil
        }
        #expect(delegation.value?.isCancellation == true)
        #expect(viewModel.approvalRequest == nil)

        // Half two — the next run's approval has to land on itself, not on the corpse of the
        // cancelled vision run.
        viewModel.command = "snippet save ;fresh-command = Beta"
        viewModel.start()
        try await waitUntilIdle(viewModel)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.approvalRequest != nil)

        // `start()` while awaiting approval *is* the approval click — the same call the widget's
        // Approve control makes.
        viewModel.start()
        try await waitUntilIdle(viewModel)

        let saved = try fixture.snippetStore.loadAll()
        #expect(saved[";fresh-command"]?.expansion == "Beta")
        // The other half of the cross-wire: a swallowed click also resumed the stale delegation,
        // which would then have executed the *previous* command's prepared plan.
        #expect(saved[";vision-delegated"] == nil)
        #expect(viewModel.taskHistoryRecords.map(\.command) == ["snippet save ;fresh-command = Beta"])
        #expect(viewModel.taskHistoryRecords.last?.outcomeStatus == .completed)
        #expect(viewModel.approvalRequest == nil)
    }

    /// SONNY-80 Option A (founder, 2026-08-14). One press of the app's cancel control during a
    /// vision-delegated approval ends the run. Before it, the press declined the delegation and the
    /// loop carried on clicking — a second press was needed to stop it — while the identical press
    /// during a clarification ended the run immediately. This drives the *real* loop (mock substrate,
    /// scripted model) through the *real* view-model mapping, so the "Canceled." summary asserted
    /// here is the one the widget would actually render.
    @Test
    func oneCancelPressDuringADelegatedApprovalEndsTheVisionRunInsteadOfDecliningAndContinuing() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root)
        let viewModel = fixture.viewModel
        let driver = RecordingComputerUseDriver(image: try makeImage())
        let decider = ScriptedVisionDecider(replies: [
            #"{"action":"delegate","instruction":"snippet save ;vision-delegated = Alpha","rationale":"The screen offers no way to do this."}"#,
            // Never reached once the run ends on the first press. If it is, the loop kept going.
            #"{"action":"done","rationale":"Finished."}"#
        ])

        let finished = FinishedFlag()
        startVisionLoop(viewModel: viewModel, driver: driver, decider: decider, finished: finished)
        try await waitUntil("the vision-delegated approval to be raised") {
            viewModel.approvalRequest != nil
        }

        viewModel.cancelCurrentRun()

        try await waitUntil("the vision run to end") { finished.value }
        #expect(viewModel.finalSummary == "Canceled.")
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.approvalRequest == nil)
        // A deny is a real approval resolution, so the first-approval explainer is spent — the one
        // thing this branch must keep doing that the cancellation handler deliberately does not.
        #expect(viewModel.hasCompletedFirstApproval)
        // The loop stopped where it was: no second capture, no second question to the model, and
        // the declined action never ran.
        #expect(await driver.captureCount == 1)
        #expect(await driver.clickCount == 0)
        #expect(decider.recordedPrompts.count == 1)
        #expect(try fixture.snippetStore.loadAll()[";vision-delegated"] == nil)
    }

    /// The reference behavior Option A aligns to, pinned beside it so the two can only diverge on
    /// purpose: the same single press during a vision *clarification* has always ended the run, and
    /// still does, with the same summary.
    @Test
    func oneCancelPressDuringAVisionClarificationEndsTheRunTheSameWay() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root)
        let viewModel = fixture.viewModel
        let driver = RecordingComputerUseDriver(image: try makeImage())
        let decider = ScriptedVisionDecider(replies: [
            #"{"action":"clarify","question":"Which account should I use?","rationale":"Two are visible."}"#,
            #"{"action":"done","rationale":"Finished."}"#
        ])

        let finished = FinishedFlag()
        startVisionLoop(viewModel: viewModel, driver: driver, decider: decider, finished: finished)
        try await waitUntil("the vision clarification to be raised") {
            viewModel.clarificationQuestion != nil
        }

        viewModel.cancelCurrentRun()

        try await waitUntil("the vision run to end") { finished.value }
        #expect(viewModel.finalSummary == "Canceled.")
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.clarificationQuestion == nil)
        // Not an approval, so this stays false — the two branches differ exactly where they should.
        #expect(!viewModel.hasCompletedFirstApproval)
        #expect(await driver.captureCount == 1)
        #expect(decider.recordedPrompts.count == 1)
    }
}

// MARK: - Test doubles and fixture

/// A mailbox for the delegation's terminal outcome, polled instead of `await`ed on purpose: with
/// the continuation leaked, `await delegationTask.value` never returns and the test would hang
/// rather than fail. Every wait in this file is bounded for the same reason.
@MainActor
private final class DelegationOutcome {
    enum Value {
        case returned(VisionCoordinatorResult)
        case threw(any Error)

        var isCancellation: Bool {
            guard case .threw(let error) = self else {
                return false
            }
            return error is CancellationError
        }
    }

    var value: Value?
}

/// Starts the real `VisionActionLoop` against a mock substrate and a scripted model, through the
/// real `AgentViewModel` mapping (`runVisionLoop`), as the view model's own `currentTask` — the
/// property `cancelCurrentRun` cancels. `start()`'s production `vision:` branch does the same thing
/// with a live ScreenCaptureKit driver and a live model client, which is why it is unreachable here.
/// `settleScale: 0` removes the loop's human-paced sleeps, so the *only* thing that can end a run in
/// these tests is a real cancellation, never a sleep that happened to notice one.
@MainActor
private func startVisionLoop(
    viewModel: AgentViewModel,
    driver: any ComputerUseDriver,
    decider: any VisionDeciding,
    finished: FinishedFlag
) {
    let task = Task { @MainActor in
        await viewModel.runVisionLoop(VisionActionRequest(appName: "Mock App", goal: "press the button")) { request in
            try await VisionActionLoop.run(
                request,
                driver: driver,
                decider: decider,
                interaction: viewModel,
                settleScale: 0
            )
        }
        finished.value = true
    }
    viewModel.adoptVisionLoopTaskForTesting(task)
}

@MainActor
private final class FinishedFlag {
    var value = false
}

/// Counts what the loop asked the machine to do, so "the run stopped" can be asserted as an absence
/// of further work rather than inferred from the summary string alone.
private actor RecordingComputerUseDriver: ComputerUseDriver {
    nonisolated let substrateDescription = "mock"

    private let image: CGImage
    private(set) var captureCount = 0
    private(set) var clickCount = 0
    private(set) var typedTexts: [String] = []

    init(image: CGImage) {
        self.image = image
    }

    nonisolated func preflightPermissions() throws {}

    func prepare() async throws {}

    func activateApp(named appName: String) async -> pid_t? { 4242 }

    func visibleAppNames() async -> [String] { ["Mock App"] }

    func captureFrontWindow(ofProcess pid: pid_t, appName: String) async throws -> DriverWindowCapture {
        captureCount += 1
        return DriverWindowCapture(
            image: image,
            windowID: 42,
            ownerPID: pid,
            windowFrame: CGRect(x: 100, y: 100, width: CGFloat(image.width), height: CGFloat(image.height)),
            windowTitle: "Mock Window"
        )
    }

    func clickInWindow(_ capture: DriverWindowCapture, atImagePoint point: CGPoint, avoiding forbiddenGlobalRects: [CGRect]) async throws -> DriverClickOutcome {
        clickCount += 1
        return .posted(globalPoint: CGPoint(
            x: capture.windowFrame.origin.x + point.x,
            y: capture.windowFrame.origin.y + point.y
        ))
    }

    func doubleClickInWindow(_ capture: DriverWindowCapture, atImagePoint point: CGPoint, avoiding forbiddenGlobalRects: [CGRect]) async throws -> DriverClickOutcome {
        try await clickInWindow(capture, atImagePoint: point, avoiding: forbiddenGlobalRects)
    }

    func typeText(_ text: String) async throws {
        typedTexts.append(text)
    }

    func pressKey(_ key: ComputerUseKey) async throws {}

    func scrollInWindow(_ capture: DriverWindowCapture, atImagePoint point: CGPoint?, direction: ComputerUseScrollDirection, amount: Int) async throws {}

    func shutdown() async {}
}

private final class ScriptedVisionDecider: VisionDeciding, Sendable {
    private struct State: Sendable {
        var replies: [String]
        var prompts: [String] = []
    }

    let transcriptDescription = "scripted"
    private let state: OSAllocatedUnfairLock<State>

    init(replies: [String]) {
        self.state = OSAllocatedUnfairLock(initialState: State(replies: replies))
    }

    var recordedPrompts: [String] {
        state.withLock { $0.prompts }
    }

    func decide(prompt: String, pngData: Data) async throws -> (reply: String, latencySeconds: Double) {
        let reply: String? = state.withLock { state in
            state.prompts.append(prompt)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        guard let reply else {
            throw VisionActionLoopError.unparseableModelReply("scripted decider ran out of replies")
        }
        return (reply, 0.01)
    }
}

/// Deliberately under 320px wide: the loop's zoom-refinement pass needs a 320px crop, so a smaller
/// image keeps the scripted replies at one per iteration.
private func makeImage(width: Int = 200, height: Int = 150) throws -> CGImage {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

@MainActor
private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 2,
    _ condition: () -> Bool
) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() {
        if Date() > deadline {
            Issue.record("Timed out waiting for \(description).")
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor
private func waitUntilIdle(_ viewModel: AgentViewModel, timeout: TimeInterval = 2) async throws {
    try await waitUntil("the view model to become idle", timeout: timeout) { !viewModel.isRunning }
}

@MainActor
private func makeFixture(root: URL) throws -> (viewModel: AgentViewModel, snippetStore: SnippetStore) {
    let encryption = LocalStorageEncryption(
        keyManager: FixedLocalStorageKeyManager(bytes: Data(repeating: 0x5A, count: 32))
    )
    let snippetStore = SnippetStore(
        fileURL: root.appendingPathComponent("snippets.json"),
        encryption: encryption
    )
    let suiteName = "VisionApprovalCancellationTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    let viewModel = AgentViewModel(
        routineStore: RoutineStore(
            fileURL: root.appendingPathComponent("routines.json"),
            encryption: encryption
        ),
        workspaceStore: WorkspaceStore(
            fileURL: root.appendingPathComponent("workspaces.json"),
            encryption: encryption
        ),
        snippetStore: snippetStore,
        recentArtifactStore: RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json"),
            encryption: encryption
        ),
        shortcutCatalog: EmptyShortcutCatalog(),
        // Hermetic seams (fakes in ProductShellTests.swift, same test target). This test executes a
        // real plan, and hermeticity has to be structural rather than a property of the one command
        // it happens to run — a fixture that grew a URL step is exactly how the suite once opened
        // real pages in the user's browser.
        browserOpener: HermeticBrowserOpener(),
        appOpener: HermeticAppOpener(),
        fileOpener: HermeticFileOpener(),
        mediaOpener: HermeticMediaOpener(),
        runningAppSwitcher: HermeticRunningAppSwitcher(),
        shortcutInvoker: HermeticShortcutInvoker(),
        finderContextReader: HermeticFinderContextReader(),
        documentConverter: HermeticDocumentConverter(),
        zipArchiver: HermeticZipArchiver(),
        shortcutRunHistoryStore: ShortcutRunHistoryStore(
            fileURL: root.appendingPathComponent("shortcuts-run-history.json"),
            encryption: encryption
        ),
        taskHistoryStore: TaskHistoryStore(
            fileURL: root.appendingPathComponent("task-history.json"),
            encryption: encryption
        ),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
            encryption: encryption
        ),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: SilentPasteboardReader(),
            store: ClipboardHistoryStore(
                fileURL: root.appendingPathComponent("clipboard-history.json"),
                encryption: encryption
            ),
            settingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
                encryption: encryption
            )
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        userDefaults: userDefaults
    )
    return (viewModel, snippetStore)
}

private struct FixedLocalStorageKeyManager: LocalStorageKeyManaging {
    let bytes: Data

    func keyData() throws -> Data {
        bytes
    }
}

private struct EmptyShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}

@MainActor
private final class SilentPasteboardReader: PasteboardReading {
    var changeCount = 0

    func typeIdentifiers() -> [String] {
        []
    }

    func stringValue() -> String? {
        nil
    }
}

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacAgentTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
