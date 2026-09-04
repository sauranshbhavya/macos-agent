import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

/// What the two surfaces do with contract §8's version states (SONNY-402).
///
/// **No wireframe exists for either state** (founder decision, 2026-09-04, recorded on the ticket),
/// so both render through the attention surfaces that already exist — the widget's precedence and
/// `CommandCenterAttentionPanel` — mirrored so the two cannot disagree. That mirroring is the thing
/// most worth holding here: `.claude/rules/macagent-ui-conventions.md` makes it the rule for every
/// attention state, and this one has a sharper reason than most, because a build behind §8.3's wall
/// fails every backend call and a user looking at the surface that did not say so would see only
/// the failures.
@Suite
@MainActor
struct ClientVersionSurfaceTests {
    private static let link = URL(string: "https://sonny.example.com/download")!

    // MARK: - The widget's precedence

    /// **The wall outranks an ordinary failure, and that is the ticket's own sentence for why**:
    /// nothing else can succeed. The failure panel offers Retry, and a `410 version.unsupported` is
    /// the one refusal §9.3 defines as permanent — so the state saying "try again" must not be the
    /// one the user is looking at.
    @Test
    func theWallOutranksAnOrdinaryFailureInTheWidget() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeVersionSurfaceViewModel(root: root)
        let widget = FloatingWidgetView(viewModel: viewModel)

        viewModel.errorMessage = "Sonny couldn't finish this one. Try again."
        guard case .failure = widget.state else {
            Issue.record("expected the failure panel before the wall arrives, got \(widget.state)")
            return
        }

        viewModel.clientVersionDidChange(.tooOld(link: Self.link))

        guard case .tooOld(let prompt) = widget.state else {
            Issue.record("the widget resolved to \(widget.state) with the build behind the wall")
            return
        }
        #expect(prompt.title == ClientVersionCopy.tooOldTitle)
        #expect(prompt.link == Self.link)
        #expect(viewModel.hasVisibleWidgetPanel)
    }

    /// **And it yields to every parked question, all six of them.** Each is a continuation nothing
    /// but the user resolves, a *local* capability parks them without touching the gateway at all,
    /// and a widget that declined to draw one would hang the run. The wall is a report about the
    /// app; a report never takes the surface from a question.
    @Test
    func theWallYieldsToAParkedApprovalAndToAClarification() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeVersionSurfaceViewModel(root: root)
        let widget = FloatingWidgetView(viewModel: viewModel)
        viewModel.clientVersionDidChange(.tooOld(link: Self.link))

        viewModel.clarificationQuestion = "Which folder did you mean?"
        guard case .clarification = widget.state else {
            Issue.record("the wall displaced a parked clarification: \(widget.state)")
            return
        }

        viewModel.clarificationQuestion = nil
        guard case .tooOld = widget.state else {
            Issue.record("the wall did not come back once the question was answered: \(widget.state)")
            return
        }
    }

    /// **The warning is last of all, above nothing but idle.** Everything still works in §8.4's
    /// band, and the band lasts until the user updates — so a warning placed anywhere higher would
    /// hold the resume offer, a result and a failure off screen for weeks.
    @Test
    func theWarningYieldsToEverythingAndSitsJustAboveIdle() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeVersionSurfaceViewModel(root: root)
        let widget = FloatingWidgetView(viewModel: viewModel)

        guard case .idle = widget.state else {
            Issue.record("expected idle before the warning arrives, got \(widget.state)")
            return
        }

        viewModel.clientVersionDidChange(.updateAvailable(link: Self.link))
        guard case .updateAvailable(let prompt) = widget.state else {
            Issue.record("the widget resolved to \(widget.state) with an update available")
            return
        }
        #expect(prompt.title == ClientVersionCopy.updateAvailableTitle)
        #expect(viewModel.hasVisibleWidgetPanel)

        // A finished run's summary is a thing about now; the warning is not.
        viewModel.finalSummary = "Opened Safari."
        guard case .result = widget.state else {
            Issue.record("the warning displaced a result: \(widget.state)")
            return
        }

        // And a failure outranks it too, for the same reason.
        viewModel.finalSummary = ""
        viewModel.errorMessage = "Something failed."
        guard case .failure = widget.state else {
            Issue.record("the warning displaced a failure: \(widget.state)")
            return
        }
    }

    /// The wall outranks the warning, and reaching the wall re-arms a warning the user had waved
    /// away — a dismissal answers the state it was pressed on, and this is a different one.
    @Test
    func theWallOutranksTheWarningAndADismissalDoesNotCarryAcross() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeVersionSurfaceViewModel(root: root)
        let widget = FloatingWidgetView(viewModel: viewModel)

        viewModel.clientVersionDidChange(.updateAvailable(link: Self.link))
        viewModel.dismissUpdateAvailablePrompt()
        #expect(!viewModel.showsUpdateAvailablePrompt)
        guard case .idle = widget.state else {
            Issue.record("a dismissed warning still held the widget panel: \(widget.state)")
            return
        }

        viewModel.clientVersionDidChange(.tooOld(link: Self.link))
        #expect(viewModel.isTooOldForThisBackend)
        guard case .tooOld = widget.state else {
            Issue.record("the wall did not take the surface: \(widget.state)")
            return
        }

        // Back into the band, on a link that is not the one already dismissed: a change is a new
        // thing to say.
        viewModel.clientVersionDidChange(.updateAvailable(link: Self.link))
        #expect(viewModel.showsUpdateAvailablePrompt)
    }

    /// The warning is dismissible and the wall is not, which is the whole reason the two carry
    /// different control sets.
    @Test
    func onlyTheWarningCanBeDismissedAwayFromTheSurfaces() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeVersionSurfaceViewModel(root: root)

        viewModel.clientVersionDidChange(.tooOld(link: Self.link))
        viewModel.dismissUpdateAvailablePrompt()

        #expect(viewModel.isTooOldForThisBackend, "the wall must not be dismissible")
        #expect(!viewModel.showsUpdateAvailablePrompt)
    }

    // MARK: - The link

    /// The founder's decision of 2026-09-04, at the press: the browser is handed the link the state
    /// carries, and a state carrying none opens nothing at all.
    @Test
    func theUpdateControlOpensTheLinkAndOpensNothingWhenThereIsNone() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeVersionSurfaceViewModel(root: root)
        let opened = OpenedLinks()
        viewModel.openUpgradeLink = { opened.record($0) }

        viewModel.clientVersionDidChange(.tooOld(link: nil))
        viewModel.openClientVersionLink()
        #expect(opened.recorded.isEmpty, "a state with no link opened \(opened.recorded)")

        viewModel.clientVersionDidChange(.tooOld(link: Self.link))
        viewModel.openClientVersionLink()
        #expect(opened.recorded == [Self.link])
    }

    /// **The scheme check happens where the value enters, so nothing this app opens ever carried a
    /// scheme it should not** — which is why the press above has no check of its own. Driven
    /// through the state a `410` really produces rather than by handing the view model a `URL`
    /// nothing could have built.
    @Test(arguments: ["file:///Applications/Evil.app", "javascript:alert(1)", "sonny://update"])
    func aLinkTheAppWillNotOpenReachesNeitherSurfaceAsAButton(raw: String) throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeVersionSurfaceViewModel(root: root)
        let opened = OpenedLinks()
        viewModel.openUpgradeLink = { opened.record($0) }

        viewModel.clientVersionDidChange(.tooOld(link: ClientUpgradeLink.openable(raw)))
        viewModel.openClientVersionLink()

        #expect(opened.recorded.isEmpty, "\(raw) reached the browser")
        let prompt = try #require(ClientVersionCopy.prompt(for: viewModel.clientVersionState))
        #expect(prompt.updateLabel == nil, "\(raw) was offered as a button")
        #expect(prompt.message == ClientVersionCopy.tooOldMessage, "the message must still show")
    }

    // MARK: - The two surfaces cannot disagree

    /// **The precedence, compared branch for branch across the two files.**
    ///
    /// The widget's chain is longer by six states Command Center deliberately has no counterpart for
    /// — row I's four and row 13's resume offer and the working/result pair — so what is mirrored is
    /// the *relative order* of the states both surfaces have, not the chains themselves
    /// (`.claude/rules/macagent-ui-conventions.md`). Read out of the two `state` properties by
    /// position, so a branch moved on one side and not the other fails here rather than at a
    /// founder's manual pass.
    @Test
    func bothSurfacesOrderTheSharedAttentionStatesTheSameWay() throws {
        let shared = [
            "viewModel.approvalRequest",
            "viewModel.clarificationQuestion",
            "viewModel.isTooOldForThisBackend",
            "viewModel.errorMessage",
            "viewModel.showsUpdateAvailablePrompt"
        ]

        let widgetChain = try MacAgentSource.region(
            of: MacAgentSource.read("FloatingWidgetView.swift"),
            from: "var state: WidgetState {",
            to: "private var widgetStateKey: Int {"
        )
        let commandCenterChain = try MacAgentSource.region(
            of: MacAgentSource.read("CommandCenterView.swift"),
            from: "private var state: AttentionState? {",
            to: "var body: some View {"
        )

        for chain in [widgetChain, commandCenterChain] {
            let positions = try shared.map { token -> Int in
                let range = try #require(chain.range(of: token), "no branch reads \(token)")
                return chain.distance(from: chain.startIndex, to: range.lowerBound)
            }
            #expect(positions == positions.sorted(), "the branches are out of order: \(positions)")
            // Each token appears once in its chain, so a *second* branch reading the same condition
            // cannot hide behind the first one's position.
            for token in shared {
                #expect(
                    MacAgentSource.count(of: token, inText: chain) == 1,
                    "\(token) is read \(MacAgentSource.count(of: token, inText: chain)) times"
                )
            }
        }
    }

    /// **Neither surface writes a word of its own.** The two views cannot be shared — System B may
    /// not leave the widget and System A may not enter it — so the sentence is what has one owner,
    /// exactly as `ScreenControlSessionPresentation` holds the session line for the same pair of
    /// panels. A hand-written copy on either side is one condition described two ways, and nothing
    /// in either file would catch it.
    @Test
    func bothSurfacesReadTheVersionPromptFromOneOwnerAndNeitherHandWritesIt() throws {
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")
        let commandCenter = try MacAgentSource.read("CommandCenterView.swift")

        for source in [widget, commandCenter] {
            // Twice per file, once per branch, and the count is what makes that checkable: a third
            // reader of this owner arrives at this test rather than joining the population silently.
            #expect(MacAgentSource.count(of: "ClientVersionCopy.prompt(for:", inText: source) == 2)
            for literal in [
                ClientVersionCopy.tooOldTitle,
                ClientVersionCopy.tooOldMessage,
                ClientVersionCopy.updateAvailableTitle,
                ClientVersionCopy.updateAvailableMessage,
                ClientVersionCopy.updateLabel,
                ClientVersionCopy.dismissLabel
            ] {
                #expect(
                    MacAgentSource.count(of: literal, inText: source) == 0,
                    "\"\(literal)\" is written out rather than read from its owner"
                )
            }
        }
    }

    /// Each surface draws both states through one view, so the wall and the warning cannot drift
    /// apart visually — what separates them is the precedence, not the drawing. The controls are
    /// read off the prompt rather than off the state, which is what makes the founder's
    /// button-or-no-button decision a single place.
    @Test
    func eachSurfaceDrawsBothStatesThroughOnePanel() throws {
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")
        let widgetPanel = try MacAgentSource.region(
            of: widget,
            from: "private struct WidgetVersionPanel: View {",
            to: "private struct WidgetFailurePanel: View {"
        )
        #expect(MacAgentSource.count(of: "case .tooOld(let prompt), .updateAvailable(let prompt):", inText: widget) == 1)
        #expect(MacAgentSource.count(of: "WidgetVersionPanel(", inText: widget) == 1)
        #expect(MacAgentSource.count(of: "if let updateLabel = prompt.updateLabel {", inText: widgetPanel) == 1)
        #expect(MacAgentSource.count(of: "if let dismissLabel = prompt.dismissLabel {", inText: widgetPanel) == 1)
        #expect(MacAgentSource.count(of: "onUpdate: { viewModel.openClientVersionLink() }", inText: widget) == 1)
        #expect(MacAgentSource.count(of: "onDismiss: { viewModel.dismissUpdateAvailablePrompt() }", inText: widget) == 1)

        let commandCenter = try MacAgentSource.read("CommandCenterView.swift")
        let commandCenterPanel = try MacAgentSource.region(
            of: commandCenter,
            from: "private func versionContent(_ prompt: ClientVersionPrompt) -> some View {",
            to: "private func failureContent("
        )
        #expect(MacAgentSource.count(of: "case .tooOld(let prompt), .updateAvailable(let prompt):", inText: commandCenter) == 1)
        #expect(MacAgentSource.count(of: "versionContent(prompt)", inText: commandCenter) == 1)
        #expect(MacAgentSource.count(of: "if let updateLabel = prompt.updateLabel {", inText: commandCenterPanel) == 1)
        #expect(MacAgentSource.count(of: "if let dismissLabel = prompt.dismissLabel {", inText: commandCenterPanel) == 1)
        #expect(MacAgentSource.count(of: "viewModel.openClientVersionLink()", inText: commandCenterPanel) == 1)
        #expect(MacAgentSource.count(of: "viewModel.dismissUpdateAvailablePrompt()", inText: commandCenterPanel) == 1)

        // Neither panel reaches for the other's token set — the one rule that is never bent.
        #expect(MacAgentSource.count(of: "SonnyTheme", inText: widgetPanel) == 0)
        #expect(MacAgentSource.count(of: "WidgetTheme", inText: commandCenterPanel) == 0)
    }

    // MARK: - The launch call

    /// §8.3's launch half. `applicationDidFinishLaunching` cannot be called in a test process, so
    /// the wiring is pinned the way `main.swift`'s is — by reading the method's own brace block, so
    /// that a call moved out of it (or into some other method that never runs) fails here.
    @Test
    func theLaunchAsksTheGatewayWhatItServes() throws {
        let launch = try MacAgentSource.braceBlock(
            of: MacAgentSource.read("AppDelegate.swift"),
            openedBy: "func applicationDidFinishLaunching(_ notification: Notification) {"
        )
        #expect(
            MacAgentSource.count(of: "await viewModel.beginWatchingClientVersion()", inText: launch) == 1
        )
    }

    /// And the launch call really does make the request and carry the answer onto the view model —
    /// the half the scan above cannot reach.
    @Test
    func theLaunchCallCarriesTheGatewaysAnswerOntoTheViewModel() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = SignedInBackendFixture()
        defer { backend.unregister() }
        backend.register { _ in
            .reply(
                statusCode: 200,
                headers: [
                    "Sonny-Deprecation": "true",
                    "Sonny-Deprecation-Info": "https://sonny.example.com/download"
                ],
                // §8.3's document, inline: `SonnyBackendFixtures` lives in the other test target.
                body: Data("""
                {
                  "api_version": "1.0",
                  "minimum_supported_client": "1.0.0",
                  "recommended_client": "2.0.0",
                  "upgrade_url": "https://sonny.example.com/download",
                  "server_time": "2026-09-04T09:41:07Z",
                  "entitlement_keys": []
                }
                """.utf8)
            )
        }
        let viewModel = try makeVersionSurfaceViewModel(root: root, backendClient: backend.client)
        defer { viewModel.stopWatchingClientVersion() }

        await viewModel.beginWatchingClientVersion()
        try await HangBackstop.waitOrAbandon(for: "the version state to reach the view model") {
            viewModel.clientVersionState != .current
        }

        #expect(viewModel.clientVersionState == .updateAvailable(link: Self.link))
        #expect(viewModel.showsUpdateAvailablePrompt)
        #expect(viewModel.hasVisibleWidgetPanel)
    }
}

/// Every URL the version surfaces asked the browser to open, in order.
@MainActor
private final class OpenedLinks {
    private(set) var recorded: [URL] = []

    nonisolated init() {}

    func record(_ url: URL) {
        recorded.append(url)
    }
}

@MainActor
private func makeVersionSurfaceViewModel(
    root: URL,
    backendClient: SonnyBackendClient? = nil
) throws -> AgentViewModel {
    let suiteName = "ClientVersionSurfaceTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    return AgentViewModel(
        routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
        workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
        recentArtifactStore: RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json")
        ),
        shortcutCatalog: NoShortcutCatalog(),
        browserOpener: HermeticBrowserOpener(),
        appOpener: HermeticAppOpener(),
        fileOpener: HermeticFileOpener(),
        finderRevealer: hermeticFinderRevealer,
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
        taskPlanDetailStore: TaskPlanDetailStore(
            fileURL: root.appendingPathComponent("task-plan-details.json")
        ),
        visionSessionJournalStore: VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json")
        ),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json")
        ),
        approvedAppStore: ApprovedAppStore(fileURL: root.appendingPathComponent("approved-apps.json")),
        outputLocationStore: OutputLocationStore(
            fileURL: root.appendingPathComponent("output-locations.json")
        ),
        resumableTaskStore: ResumableTaskStore(
            fileURL: root.appendingPathComponent("resumable-tasks.json")
        ),
        pendingServerDeletionStore: PendingServerDeletionStore(
            fileURL: root.appendingPathComponent("pending-server-deletions.json")
        ),
        standingWatcherObserver: UnreachableStandingWatcherObserver(),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: SilentPasteboardReader(),
            store: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard-history.json")),
            settingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings.json")
            )
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        // Hermetic by default, for SONNY-130's reason: this client holds the Keychain session every
        // packaged build on this Mac shares. The one test that needs a gateway passes a stub-backed
        // one instead.
        backendClient: backendClient ?? makeHermeticBackendClient(),
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        userDefaults: userDefaults
    )
}

private struct NoShortcutCatalog: ShortcutCatalogProviding {
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
        .appendingPathComponent("ClientVersionSurfaceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
