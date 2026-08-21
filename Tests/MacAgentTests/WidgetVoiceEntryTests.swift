import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// SONNY-173. The floating widget's mic button and the push-to-talk hotkey are two doors onto one
/// action, and with no API key exported they answered differently: the hotkey said the key was not
/// set, the button did nothing whatsoever. Nothing was missing — the button carried
/// `.disabled(!viewModel.canUseVoice && ...)`, a disabled SwiftUI button never runs its action, and
/// so the guard that already held the right message could not be reached from the one surface most
/// people press. (That message named the variable when this was written; SONNY-177 made it
/// provider-neutral, and the tests below take it from the constant rather than quoting it.)
///
/// What is pinned here is the split that fixes it, not the API key. `canUseVoice` folded one
/// **actionable** failure the user can go and fix together with five **transient** ones that clear
/// on their own, and only the transient half may ever disable a control. SONNY-136 deletes every
/// provider environment variable, so the actionable half's current contents are temporary; the rule
/// is not. Every test below that needs a configuration failure states one through
/// `voiceConfigurationBlockerOverride` rather than reaching for the key, so these keep meaning the
/// same thing after that lands.
///
/// **Nothing here ever presses the mic with voice actually available.** A press that gets past the
/// guard reaches `AVCaptureDevice.requestAccess`, which a `swift test` process has no bundle
/// identity to survive — a test suite must not raise a microphone prompt, or a privacy-usage crash,
/// on the machine running it. So every press in this file sits behind `try #require(canUseVoice ==
/// false)` rather than `#expect`: a broken gate ends the test on the spot instead of walking the
/// press into the recorder. That is not belt-and-braces — it is the difference between a mutation
/// battery reporting a killed mutant and one taking the machine's microphone with it.
@Suite
@MainActor
struct WidgetVoiceEntryTests {
    /// The bug itself, from the surface that had it, and the sibling surface beside it for
    /// comparison — the point was never that the button was silent, it was that the two disagreed.
    @Test
    func pressingTheMicWithAConfigurationProblemSaysWhatTheHotkeySays() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let button = try makeViewModel(root: root)
        button.voiceConfigurationBlockerOverride = { AgentViewModel.missingAPIKeyVoiceMessage }
        // The press has to reach the action at all before anything else here means anything.
        #expect(button.isVoiceControlDisabled == false)
        // `#require`, not `#expect`: see the note on the suite. If voice were somehow available the
        // press would run, and the test must end here rather than reach the recorder.
        try #require(button.canUseVoice == false)
        button.toggleVoiceRecording(origin: .widget)

        #expect(button.errorMessage == AgentViewModel.missingAPIKeyVoiceMessage)
        #expect(button.errorIsPersistent)
        // Refused before the recorder, so no microphone prompt and no half-started recording.
        #expect(button.isRecordingVoice == false)
        #expect(button.isPreparingVoiceRecording == false)

        let hotKey = try makeViewModel(root: root)
        hotKey.voiceConfigurationBlockerOverride = { AgentViewModel.missingAPIKeyVoiceMessage }
        try #require(hotKey.canUseVoice == false)
        hotKey.beginPushToTalkVoice()

        #expect(hotKey.errorMessage == button.errorMessage)
        #expect(hotKey.errorIsPersistent == button.errorIsPersistent)
        #expect(hotKey.isRecordingVoice == false)
        #expect(hotKey.isPreparingVoiceRecording == false)
    }

    /// The words themselves, once, so a rewrite of the copy is a deliberate act rather than a
    /// silent one. Every other assertion in this file compares against the constant, which would
    /// stay true no matter what the constant said.
    ///
    /// **The last two expectations are the rule rather than the sentence** — SONNY-177, founder
    /// decision 2026-08-19, wording approved the same day. No provider name and no
    /// environment-variable name, because other providers are coming and SONNY-136 deletes the
    /// variable this used to name; and, since dropping that name costs the reader the most specific
    /// thing the message could have told them, the instruction has to survive. The exact-match above
    /// goes stale the next time the copy changes, by design. Those two should not.
    ///
    /// Checking for "relaunch" is a crude stand-in and knowingly so: nothing here can decide whether
    /// a sentence is actionable, only that the half of the instruction most easily lost in a rewrite
    /// is still present.
    @Test
    func theConfigurationMessageNamesNoProviderAndStillSaysWhatToDo() {
        #expect(
            AgentViewModel.missingAPIKeyVoiceMessage
                == "No API key is set up. Add one, then relaunch Sonny."
        )
        // The hint's other variant, pinned in the same place. SONNY-179's wording, given verbatim by
        // the founder; SONNY-177 shipped "Speak your command — or hold Ctrl-Opt-Space anywhere".
        #expect(
            AgentViewModel.micHoverShortcutReminder == "Click to speak or hold Ctrl-Opt-Space."
        )
        // The em dash is the thing the founder asked to be rid of, so it is asserted as an absence
        // and not merely implied by the literal above — a later reword may not quietly bring one
        // back, and neither message may carry one.
        #expect(!AgentViewModel.micHoverShortcutReminder.contains("—"))
        #expect(!AgentViewModel.missingAPIKeyVoiceMessage.contains("—"))
        #expect(!AgentViewModel.missingAPIKeyVoiceMessage.contains("OPENAI"))
        #expect(AgentViewModel.missingAPIKeyVoiceMessage.contains("relaunch"))
    }

    /// SONNY-177. The hover hint is one condition with two answers, and a view may read neither half
    /// of the readiness that picks between them — so the pick happens on the view model, and this is
    /// the resolved value a view actually receives.
    ///
    /// The blocked case states a blocker that is deliberately *not* the API-key message, for the
    /// reason `aConfigurationProblemRefusesVoiceWithoutDisablingTheControl` gives: it proves the
    /// hint's text arrives from the blocker rather than from a literal that happens to sit beside
    /// it, which is what has to keep holding once SONNY-136 changes what the blocker reports.
    @Test
    func theHoverHintRemindsWhenVoiceWorksAndReportsTheProblemWhenItDoesNot() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let working = try makeViewModel(root: root)
        working.voiceConfigurationBlockerOverride = { nil }
        #expect(working.micHoverHintPresentation.message == AgentViewModel.micHoverShortcutReminder)
        #expect(
            working.micHoverHintPresentation.autoDismissDelay == .seconds(3),
            "a reminder that will not leave is nagging — three seconds, and it goes (SONNY-179)"
        )

        let blocked = try makeViewModel(root: root)
        blocked.voiceConfigurationBlockerOverride = { "Sonny has no transcription provider configured." }
        #expect(
            blocked.micHoverHintPresentation.message == "Sonny has no transcription provider configured."
        )
        #expect(
            blocked.micHoverHintPresentation.autoDismissDelay == nil,
            "the message reporting something broken stays for the whole hover"
        )
    }

    /// SONNY-177's structural half. The hover and the press are one condition on one control, and
    /// they say the same thing because they take it from the same place — not because two literals
    /// happen to match today, which is precisely how the mic and the hotkey came to disagree in
    /// SONNY-173.
    @Test
    func hoveringAndPressingTheMicSayTheSameThingWhenVoiceIsUnconfigured() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)
        viewModel.voiceConfigurationBlockerOverride = { "Sonny has no transcription provider configured." }

        let hovered = viewModel.micHoverHintPresentation.message

        // `#require`, not `#expect`: see the note on the suite.
        try #require(viewModel.canUseVoice == false)
        viewModel.toggleVoiceRecording(origin: .widget)

        #expect(viewModel.errorMessage == hovered)
        #expect(viewModel.errorIsPersistent)
    }

    /// The live rule, with no override in the way, in whatever environment the suite is actually
    /// running in. Both branches assert something real, so this is deterministic rather than
    /// conditionally skipped — it is the one test here that does read `hasAPIKey`.
    @Test
    func theLiveRuleReportsAMissingKeyAndOnlyAMissingKey() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)

        if viewModel.hasAPIKey {
            #expect(viewModel.voiceConfigurationBlocker == nil)
        } else {
            #expect(viewModel.voiceConfigurationBlocker == AgentViewModel.missingAPIKeyVoiceMessage)
        }
    }

    /// The half the fix must not have broken. Each of these clears on its own, the user can do
    /// nothing about any of them, and a press during one is correctly swallowed — so the button
    /// stays disabled and nothing is said.
    @Test
    func everyTransientReasonStillDisablesTheMicAndStaysSilent() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let reasons: [(reason: String, apply: (AgentViewModel) -> Void)] = [
            ("a run in flight", { $0.isRunning = true }),
            (
                "an approval waiting",
                {
                    $0.approvalRequest = RiskApprovalRequest(
                        assessment: CapabilityRiskAssessment(defaultTier: .tier2),
                        requirement: .explicitApproval
                    )
                }
            ),
            ("a clarification open", { $0.clarificationQuestion = "Which folder?" }),
            ("the recorder starting up", { $0.isPreparingVoiceRecording = true }),
            ("a transcription in flight", { $0.isTranscribingVoice = true })
        ]

        for (reason, apply) in reasons {
            let viewModel = try makeViewModel(root: root)
            // Configuration is fine, so the transient state is the only thing under test.
            viewModel.voiceConfigurationBlockerOverride = { nil }
            #expect(viewModel.isVoiceTransientlyBusy == false, "\(reason): precondition")
            #expect(viewModel.isVoiceControlDisabled == false, "\(reason): precondition")
            #expect(viewModel.canUseVoice, "\(reason): precondition")

            apply(viewModel)

            #expect(viewModel.isVoiceTransientlyBusy, "\(reason) must count as transient")
            #expect(viewModel.isVoiceControlDisabled, "\(reason) must disable the mic control")
            try #require(viewModel.canUseVoice == false, "\(reason) must refuse voice")

            // A disabled button cannot be pressed, but the hotkey is gated by no view state at
            // all — so this is the one reachable press during a transient refusal, and it must
            // say nothing. Reached only past the `#require` above, which is what keeps a broken
            // gate from walking this press into the recorder.
            viewModel.beginPushToTalkVoice()
            #expect(viewModel.errorMessage == nil, "\(reason) must not explain itself")
            #expect(viewModel.isRecordingVoice == false, "\(reason) must not start recording")
            #expect(viewModel.isPreparingVoiceRecording == (reason == "the recorder starting up"))
        }
    }

    /// The fix, stated as the property it actually is: a configuration failure refuses voice and
    /// leaves the control pressable, so the press is what explains the failure.
    ///
    /// The message deliberately is **not** the API-key one. It proves the text reaches the user
    /// from the blocker rather than from a literal that happens to sit next to the guard — which is
    /// what has to hold once SONNY-136 changes what the blocker reports.
    @Test
    func aConfigurationProblemRefusesVoiceWithoutDisablingTheControl() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)
        viewModel.voiceConfigurationBlockerOverride = { "Sonny has no transcription provider configured." }

        try #require(viewModel.canUseVoice == false)
        #expect(viewModel.isVoiceTransientlyBusy == false)
        #expect(viewModel.isVoiceControlDisabled == false)

        viewModel.toggleVoiceRecording(origin: .widget)

        #expect(viewModel.errorMessage == "Sonny has no transcription provider configured.")
        #expect(viewModel.errorIsPersistent)
    }

    /// The stop half. Once a recording is running the button is Stop, and something transient
    /// landing mid-sentence — an approval from a run started elsewhere — must not disable it and
    /// trap the user in a live microphone.
    @Test
    func aTransientStateArrivingMidRecordingLeavesStopPressable() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)
        viewModel.voiceConfigurationBlockerOverride = { nil }
        viewModel.isRecordingVoice = true

        viewModel.approvalRequest = RiskApprovalRequest(
            assessment: CapabilityRiskAssessment(defaultTier: .tier2),
            requirement: .explicitApproval
        )

        #expect(viewModel.isVoiceTransientlyBusy)
        #expect(viewModel.canUseVoice == false)
        #expect(viewModel.isVoiceControlDisabled == false)
    }

    /// The class guard, half one. `.disabled` is where this bug lives: a term folded into one is a
    /// press the user makes and never hears back about, so no `.disabled` predicate anywhere in the
    /// app may mention the actionable half of voice readiness.
    ///
    /// Same shape as `ShellSurfaceDetectorTests.onlyTheDetectorProducesVerdictsInTheLiveModule` —
    /// a rule a reader would otherwise be the only thing enforcing.
    @Test
    func noDisabledPredicateInTheAppGatesOnAnActionableFailure() throws {
        let forbidden = ["canUseVoice", "hasAPIKey", "voiceConfigurationBlocker"]
        var offenders: [String] = []
        let files = try Self.appSourceFiles()
        // The scan means nothing if it did not really find the module.
        #expect(files.count > 20)

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for predicate in disabledPredicates(in: source) {
                for term in forbidden where predicate.contains(term) {
                    offenders.append("\(file.lastPathComponent): .disabled(\(predicate))")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A control may only be disabled for a transient reason. Gate on \
            `AgentViewModel.isVoiceControlDisabled` (or `isVoiceTransientlyBusy`) and let the guard \
            inside `startVoiceRecording` explain the actionable failure instead: \(offenders)
            """
        )
    }

    /// The class guard, half two. `.disabled` is not the only way to make a press impossible — a
    /// view that branches on voice readiness can hide the control outright and reproduce the same
    /// silence. So the readiness internals stay where they are computed and no view reads them.
    ///
    /// **Two terms, not one, and the second was a hole this guard used to leave open.** Scanning
    /// only for `canUseVoice` let `if viewModel.voiceConfigurationBlocker == nil { micButton }`
    /// through — a view that hides the mic exactly when the user has something to fix, which is
    /// SONNY-173's silence rebuilt out of the actionable half alone, and it touches neither
    /// `.disabled(` nor the composite. It is also the obvious wrong fix someone reaches for.
    /// Filed as residual (a) by PR #73's cycle-1 review and left recorded through cycle 2; closed
    /// here, and the mutant expressing that view is in the branch's battery precisely because it
    /// *survived* this guard before the second term was added.
    ///
    /// Views take `isVoiceControlDisabled`, which is the transient half and nothing else.
    @Test
    func theCompositeVoiceReadinessIsReadInOneFileOnly() throws {
        var readingFiles: Set<String> = []
        let files = try Self.appSourceFiles()
        #expect(files.count > 20)

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("canUseVoice") || source.contains("voiceConfigurationBlocker") {
                readingFiles.insert(file.lastPathComponent)
            }
        }

        #expect(
            readingFiles == ["AgentViewModel.swift"],
            """
            A view may read neither `canUseVoice` — the composite, actionable and transient folded \
            together — nor `voiceConfigurationBlocker`, the actionable half on its own. Branching \
            on either lets a view refuse or hide a press for a reason it never shows. Views take \
            `isVoiceControlDisabled`; both of these stay internal. Found in: \
            \(readingFiles.sorted())
            """
        )
    }

    /// Every `.disabled(...)` argument in `source`, with nesting handled, since these predicates
    /// really do contain parenthesised calls.
    private func disabledPredicates(in source: String) -> [String] {
        var predicates: [String] = []
        var searchStart = source.startIndex

        while let opening = source.range(of: ".disabled(", range: searchStart..<source.endIndex) {
            var depth = 1
            var index = opening.upperBound
            while index < source.endIndex, depth > 0 {
                switch source[index] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                if depth > 0 {
                    index = source.index(after: index)
                }
            }
            if depth == 0 {
                predicates.append(String(source[opening.upperBound..<index]))
            }
            searchStart = opening.upperBound
        }

        return predicates
    }

    private static func appSourceFiles() throws -> [URL] {
        // <package root>/Tests/MacAgentTests/<this file>
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacAgent")
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }
}

@MainActor
private func makeViewModel(root: URL) throws -> AgentViewModel {
    let suiteName = "WidgetVoiceEntryTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    return AgentViewModel(
        routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
        workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
        recentArtifactStore: RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json")
        ),
        shortcutCatalog: VoiceEntryEmptyShortcutCatalog(),
        // Hermetic seams (fakes in ProductShellTests.swift, same test target). Nothing here runs a
        // plan today, but the fixture is hermetic structurally rather than by luck — the same
        // reasoning `CommandCenterAttentionSurfaceTests` records beside its own copy.
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
            fileURL: root.appendingPathComponent("shortcuts-run-history.json")
        ),
        taskHistoryStore: TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json")),
        taskPlanDetailStore: TaskPlanDetailStore(fileURL: root.appendingPathComponent("task-plan-details.json")),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json")
        ),
        approvedAppStore: ApprovedAppStore(fileURL: root.appendingPathComponent("approved-apps.json")),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: VoiceEntryFakePasteboardReader(),
            store: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard-history.json")),
            settingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings.json")
            )
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        // In-memory by construction — this store has no file at all.
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        userDefaults: userDefaults
    )
}

private struct VoiceEntryEmptyShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}

@MainActor
private final class VoiceEntryFakePasteboardReader: PasteboardReading {
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
        .appendingPathComponent("WidgetVoiceEntryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
