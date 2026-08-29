import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgent
import MacAgentCore

/// **Spec §16.3's guarantee, driven rather than described** (SONNY-136).
///
/// Row 12 put a backend in the middle of planning, transcription, search and screen control, and
/// the cost the founder accepted on SONNY-16 is that one bad hour then takes Sonny down for every
/// user at once. The thing that keeps that from being a dead product is §16.3: the free local
/// capabilities do not go through it and keep working. That is one of the three recorded grounds
/// for not building §9's server-side agent loop, so it is load-bearing architecture rather than a
/// nicety — and SONNY-136's own decisions-carried section says that a ticket which cannot deliver
/// it should stop and report rather than compromise.
///
/// **What makes this evidence rather than a restatement is the request count.** Each test below
/// asserts that the stub saw *zero* requests, not merely that the command succeeded. "It worked
/// with the network down" is satisfied by a capability that calls the backend, catches the failure
/// and carries on; "it never called" is the property the contract's §5.3.1 actually states, in its
/// own words — "a check that is never made cannot fail closed". `InstantCommandResolver` imports
/// only `Foundation` and returns a plan straight from local stores, and this is that fact reaching
/// the user through the real view model, the real runner and the real executor.
///
/// **The backend here is signed in and dead**, which is the harder of the two shapes. A client with
/// no session refuses before it builds a URL, so a suite using one could not tell "never called"
/// from "called and refused early". `SignedInBackendFixture` puts a token in an in-memory Keychain
/// and points the client at a stub host that answers every request with a transport failure, so a
/// call that happened would be visible in `recorded`.
@Suite
@MainActor
struct BackendOutageTests {
    // MARK: - The five free local capabilities

    @Test
    func anInstantUtilityStillAnswersWithTheBackendUnreachable() async throws {
        let fixture = try makeFixture(networkFailure: URLError(.cannotConnectToHost))
        defer { fixture.tearDown() }

        try await fixture.run("calc 2 + 2 * 3")

        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.finalSummary.contains("8"))
        #expect(fixture.recorded.all.isEmpty, "the calculator reached the network")
    }

    @Test
    func aSavedRoutineStillRunsWithTheBackendUnreachable() async throws {
        let fixture = try makeFixture(networkFailure: URLError(.cannotConnectToHost))
        defer { fixture.tearDown() }
        try fixture.routineStore.save(StoredRoutine(
            name: "Morning Setup",
            steps: [AgentStep(
                id: "step-1",
                operation: .calculateUtility,
                description: "Work out 3 * 7.",
                searchQuery: "3 * 7"
            )]
        ))

        try await fixture.run("run routine Morning Setup")

        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.finalSummary.contains("21"))
        #expect(fixture.recorded.all.isEmpty, "running a routine reached the network")
    }

    @Test
    func aSavedWorkspaceStillOpensWithTheBackendUnreachable() async throws {
        let fixture = try makeFixture(networkFailure: URLError(.cannotConnectToHost))
        defer { fixture.tearDown() }
        try fixture.workspaceStore.save(StoredWorkspace(
            name: "Research",
            apps: ["Safari"],
            urls: ["https://example.com"]
        ))

        try await fixture.run("open workspace Research")

        #expect(fixture.viewModel.errorMessage == nil)
        // The workspace really opened: its app and its URL both reached their hermetic seams, so
        // this is the capability running rather than a plan that was merely built.
        #expect(fixture.appOpener.openedBundleIDs.isEmpty == false)
        #expect(fixture.browserOpener.openedURLs.map(\.absoluteString) == ["https://example.com"])
        #expect(fixture.recorded.all.isEmpty, "opening a workspace reached the network")
    }

    @Test
    func snippetsStillSaveAndExpandWithTheBackendUnreachable() async throws {
        let fixture = try makeFixture(networkFailure: URLError(.cannotConnectToHost))
        defer { fixture.tearDown() }

        try await fixture.run("snippet save addr = 221B Baker Street")
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(try fixture.snippetStore.findExactTrigger("addr")?.expansion == "221B Baker Street")

        // The other half: a saved trigger typed on its own expands, which is the one people use.
        try await fixture.run("addr")
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.finalSummary.contains("221B Baker Street"))
        #expect(fixture.recorded.all.isEmpty, "snippets reached the network")
    }

    @Test
    func clipboardHistoryStillAnswersWithTheBackendUnreachable() async throws {
        let fixture = try makeFixture(networkFailure: URLError(.cannotConnectToHost))
        defer { fixture.tearDown() }

        try await fixture.run("clipboard history")

        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.recorded.all.isEmpty, "the clipboard lookup reached the network")
    }

    // MARK: - The control, and the sentence

    /// **The control that makes the five above mean something.** Without it, a suite in which every
    /// command succeeds is equally consistent with a backend that is quietly fine, and the five
    /// zero-request assertions would be proving the stub was never wired up.
    ///
    /// It also carries SONNY-136's fourth requirement at the surface a user actually reads: a
    /// command that genuinely needs the backend fails with `SonnyBackendCopy`'s sentence and never
    /// with a raw error. `URLError`'s own `localizedDescription` — "Could not connect to the
    /// server." — is what would appear if any layer between here and the transport rendered the
    /// error it caught instead of the one it owns, so it is asserted as an absence.
    @Test
    func aCommandThatNeedsTheBackendFailsWithSonnysOwnSentenceAndNotARawError() async throws {
        let fixture = try makeFixture(networkFailure: URLError(.cannotConnectToHost))
        defer { fixture.tearDown() }

        try await fixture.run("do something no resolver has a pattern for")

        #expect(fixture.viewModel.errorMessage == "Sonny couldn't finish this one. Try again.")
        #expect(fixture.recorded.all.isEmpty == false, "the stub saw no request, so nothing failed")
        let shown = try #require(fixture.viewModel.errorMessage)
        #expect(!shown.contains("Could not connect"))
        #expect(!shown.lowercased().contains("urlerror"))
        #expect(!shown.contains("http"))
    }

    /// The one transport failure that gets its own words, and the reason §7.2 case 7 insists on it:
    /// offline is the only state in which everything local still works, and this sentence is where
    /// the user is told so.
    @Test
    func beingOfflineSaysSoAndSaysThatLocalWorkStillWorks() async throws {
        let fixture = try makeFixture(networkFailure: URLError(.notConnectedToInternet))
        defer { fixture.tearDown() }

        try await fixture.run("do something no resolver has a pattern for")

        #expect(
            fixture.viewModel.errorMessage
                == "You're offline. Everything Sonny does on this Mac still works."
        )

        // And the promise in that sentence is kept in the same process, on the same view model.
        try await fixture.run("calc 40 + 2")
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.finalSummary.contains("42"))
    }

    /// **What a packaged app launched from Finder actually says today**, which is not any of the four
    /// states above and is worth pinning because it is the sentence the founder's manual pass will
    /// meet (SONNY-136).
    ///
    /// `SonnyBackendHost.productionBaseURL` is `nil` until SONNY-192 chooses a host, and a build with
    /// no debug pointer set therefore fails every backend call at `backendNotConfigured` before a URL
    /// is built. That is a fifth state, it has its own sentence, and it must not read as an outage —
    /// telling someone to try again when no host exists is the same defect as telling them to export
    /// a variable nothing reads.
    ///
    /// **The five local capabilities are unaffected by it**, which is the half that makes acceptance
    /// criterion 1 true: a build with no backend at all still does everything it can do.
    @Test
    func aBuildWithNoBackendHostSaysSoAndStillRunsEverythingLocal() async throws {
        let fixture = try makeFixture(
            networkFailure: URLError(.cannotConnectToHost),
            // No environment, exactly as `SonnyBackendHost.resolve()` answers on a release build
            // launched from Finder with nothing exported and no `defaults write` set.
            client: makeHermeticBackendClient()
        )
        defer { fixture.tearDown() }

        try await fixture.run("do something no resolver has a pattern for")
        #expect(fixture.viewModel.errorMessage == "This build has no Sonny account service.")
        // Nothing was sent, because there was nowhere to send it — so this is not the unreachable
        // sentence wearing a different name.
        #expect(fixture.recorded.all.isEmpty)

        try await fixture.run("calc 2 + 2 * 3")
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.finalSummary.contains("8"))
    }

    // MARK: - What the readiness page says while the backend is down

    /// **A dead backend does not sign anyone out, and the readiness row must not say it did**
    /// (SONNY-136). `refreshModelAccessReadiness()` reads the Keychain through the client, which is
    /// a local read behind an actor rather than a network call — that is the whole reason the row
    /// stayed a presence check, and this is the case that makes the choice visible: every request
    /// this fixture makes fails at the transport, and the account row still reports the truth.
    @Test
    func theAccountRowStaysReadyWhileEveryRequestFails() async throws {
        let fixture = try makeFixture(networkFailure: URLError(.cannotConnectToHost))
        defer { fixture.tearDown() }

        await fixture.viewModel.refreshModelAccessReadiness()

        #expect(fixture.viewModel.modelAccessReadiness == .signedIn)
        #expect(fixture.recorded.all.isEmpty, "reading the session reached the network")
    }

    /// The other two answers, from the two things that actually produce them.
    ///
    /// **The undecodable case is the one worth writing.** `SonnyAccountTokenStore` throws
    /// `undecodableStoredSession` for bytes this build cannot read, and the honest answer to that is
    /// "cannot say" rather than "signed out": bytes that will not decode are not evidence that
    /// nobody is signed in, and a red *sign in* row would send a user to the one action that
    /// overwrites the credential this build could not read.
    @Test
    func noSessionReadsAsSignedOutAndUnreadableBytesReadAsUndetermined() async throws {
        let empty = try makeFixture(
            networkFailure: URLError(.cannotConnectToHost),
            client: makeHermeticBackendClient()
        )
        defer { empty.tearDown() }
        await empty.viewModel.refreshModelAccessReadiness()
        #expect(empty.viewModel.modelAccessReadiness == .signedOut)

        let keychain = InMemoryKeychainSecretStore()
        keychain.plant(
            Data("not a session".utf8),
            service: KeychainAccountTokenStore.defaultService,
            account: KeychainAccountTokenStore.defaultAccount
        )
        let damaged = try makeFixture(
            networkFailure: URLError(.cannotConnectToHost),
            client: makeHermeticBackendClient(keychain: keychain)
        )
        defer { damaged.tearDown() }
        await damaged.viewModel.refreshModelAccessReadiness()
        #expect(damaged.viewModel.modelAccessReadiness == .undetermined)
    }

    /// `refreshPermissions()` is what the Settings page calls, and it must end up with the account
    /// row the account state says — including the first pass, which renders before the actor answers.
    @Test
    func refreshingPermissionsRendersTheRowsImmediatelyAndThenTheAccountAnswer() async throws {
        let fixture = try makeFixture(networkFailure: URLError(.cannotConnectToHost))
        defer { fixture.tearDown() }

        fixture.viewModel.refreshPermissions()

        // Synchronously, before the actor has answered: eight rows, and the account one honestly
        // says it has not been asked yet rather than guessing in either direction.
        #expect(fixture.viewModel.permissionItems.count == 8)
        let firstPass = try #require(fixture.viewModel.permissionItems.first { $0.id == "sonny-account" })
        #expect(firstPass.state == .unknown)

        try await waitUntilAccountRow(fixture.viewModel, is: .ready)
        let settled = try #require(fixture.viewModel.permissionItems.first { $0.id == "sonny-account" })
        #expect(settled.detail == "Signed in.")
    }

    /// Waits on the published rows rather than on a clock: the refresh is a `Task` this view model
    /// starts, so the only honest signal is the value it publishes. Nothing is asserted about how
    /// long it took (`CLAUDE.md`, "a test that bets on a wall-clock window does not fail honestly").
    ///
    /// **This was the second hand-rolled loop PR #153's F1/F2 found**, and it carried the sharper
    /// half of F2: its `Issue.record("the account row never became …")` was declared *nowhere*, so
    /// under load it produced an undeclared issue on its own before the cascade even began. It is
    /// `HangBackstop.waitOrAbandon` now, so it cannot record a sentence of its own at all.
    private func waitUntilAccountRow(
        _ viewModel: AgentViewModel,
        is state: PermissionReadinessState
    ) async throws {
        try await HangBackstop.waitOrAbandon(for: "the account row to become \(state)") {
            viewModel.permissionItems.first(where: { $0.id == "sonny-account" })?.state == state
        }
    }

    /// **The row follows the session in both directions, over the one client the process shares**
    /// (PR #153's F4).
    ///
    /// The two halves this joins are held separately — `SignInSurfaceTests` holds that a sign-in and
    /// a sign-out each announce themselves and that a refused code does not, and
    /// `mainJoinsTheSessionHookToTheReadinessRefresh` holds the line in `main.swift` that turns an
    /// announcement into a refresh. What neither can show is that a refresh *arriving* actually
    /// moves the row, because the answer travels through `SonnyBackendClient`'s own token cache:
    /// `hasReadStore` means the client answers `restoredIdentity()` from memory after the first
    /// read, so the row only follows if signing in and out go through the same client the view model
    /// holds. `main.swift` gives it the account model's, and this is that arrangement.
    ///
    /// Driven through `refreshPermissions()` rather than `refreshModelAccessReadiness()` directly,
    /// because that is what the hook calls.
    @Test
    func theAccountRowFollowsASignInAndASignOutThroughTheSharedClient() async throws {
        let stub = BackendStubURLProtocol.makeSession()
        BackendStubURLProtocol.register(host: stub.host) { request in
            if request.url?.path == "/v1/auth/email/start" {
                return .reply(statusCode: 200, headers: [:], body: Data(#"{"request_id":"r","expires_in":600}"#.utf8))
            }
            return .reply(
                statusCode: 200,
                headers: [:],
                body: try! JSONSerialization.data(withJSONObject: [
                    "access_token": "issued-access",
                    "token_type": "Bearer",
                    "expires_in": 3600,
                    "expires_at": "2026-08-28T10:41:07Z",
                    "refresh_token": "issued-refresh",
                    "user": ["id": "acct_7f3c"],
                ])
            )
        }
        defer { BackendStubURLProtocol.unregister(host: stub.host) }

        let client = makeHermeticBackendClient(
            environment: SonnyBackendEnvironment(baseURL: stub.baseURL, source: .production),
            session: stub.session
        )
        let fixture = try makeFixture(networkFailure: URLError(.cannotConnectToHost), client: client)
        defer { fixture.tearDown() }
        let account = SonnyAccountModel(client: client)
        account.sessionDidChange = { [weak viewModel = fixture.viewModel] in viewModel?.refreshPermissions() }

        // Signed out to begin with: nothing is in the Keychain.
        fixture.viewModel.refreshPermissions()
        try await waitUntilAccountRow(fixture.viewModel, is: .needsAction)

        account.emailAddress = "founder@example.com"
        await account.sendCode()
        account.code = "123456"
        await account.verify()
        try #require(account.isSignedIn)
        try await waitUntilAccountRow(fixture.viewModel, is: .ready)
        #expect(
            fixture.viewModel.permissionItems.first { $0.id == "sonny-account" }?.detail == "Signed in."
        )

        await account.signOut()
        try #require(account.isSignedIn == false)
        try await waitUntilAccountRow(fixture.viewModel, is: .needsAction)
        #expect(
            fixture.viewModel.permissionItems.first { $0.id == "sonny-account" }?.detail
                == "Sign in to Sonny in Command Center."
        )
    }

    // MARK: - The readiness tool, through the executor the app builds

    /// **The closure at `AgentViewModel.makeExecutor`'s `modelAccessReadiness:` is the one place the
    /// view model's answer reaches the capability adapter, and it was held by nothing** (PR #153's
    /// F3). Replacing it with `{ .undetermined }` survived the whole suite: every test that read the
    /// account row read it either off `PermissionReadinessService` directly or off
    /// `viewModel.permissionItems`, and neither goes through an executor.
    ///
    /// **Why that is worth a test rather than a comment.** The parameter is defaulted — to
    /// `.undetermined`, deliberately, so a context with no account wiring cannot report readiness
    /// nobody checked — which means a later refactor can *drop the argument* and still compile. The
    /// "show permission readiness" tool would then answer "Sonny checks this when it needs it."
    /// forever, on a signed-in Mac, with a green suite. That is PR #139's F10 in its own words —
    /// readiness that is not readiness — arriving at the one surface SONNY-171 was filed about.
    ///
    /// It reads the adapter's own preview text rather than the item list, because that is what a
    /// user of the tool sees, and it drives it through `viewModel.makeExecutor()` rather than
    /// constructing a context by hand, because a hand-built context is exactly the thing that cannot
    /// catch a dropped argument.
    @Test
    func theReadinessToolReportsTheAccountTheViewModelHolds() async throws {
        let fixture = try makeFixture(networkFailure: URLError(.cannotConnectToHost))
        defer { fixture.tearDown() }

        await fixture.viewModel.refreshModelAccessReadiness()
        try #require(fixture.viewModel.modelAccessReadiness == .signedIn)

        let details = try Self.readinessDetails(from: fixture.viewModel)
        #expect(
            details.contains("Sonny account: Ready - Signed in."),
            "the tool did not carry the view model's answer: \(details)"
        )

        // **The other direction through the same seam**, so the assertion cannot be satisfied by a
        // closure that always answers `.signedIn` either. A second fixture rather than a sign-out on
        // this one: `SonnyBackendClient` caches the Keychain read behind `hasReadStore`, so emptying
        // the store under a client that has already answered would change nothing and the test would
        // pass for the wrong reason.
        let signedOut = try makeFixture(
            networkFailure: URLError(.cannotConnectToHost),
            client: makeHermeticBackendClient()
        )
        defer { signedOut.tearDown() }
        await signedOut.viewModel.refreshModelAccessReadiness()
        try #require(signedOut.viewModel.modelAccessReadiness == .signedOut)
        let whenSignedOut = try Self.readinessDetails(from: signedOut.viewModel)
        #expect(
            whenSignedOut.contains("Sonny account: Needs action - Sign in to Sonny in Command Center."),
            "the tool did not carry the signed-out answer: \(whenSignedOut)"
        )
    }

    /// The `showPermissionReadiness` preview, as the executor the view model builds produces it.
    @MainActor
    private static func readinessDetails(from viewModel: AgentViewModel) throws -> [String] {
        let plan = AgentPlan(
            summary: "Show permission readiness.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "permissions",
                    operation: .showPermissionReadiness,
                    description: "Show readiness"
                )
            ]
        )
        let previews = try viewModel.makeExecutor().preview(plan: plan)
        let readiness = try #require(previews.first { $0.title == "Permission readiness" })
        return readiness.details
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let viewModel: AgentViewModel
        let recorded: RecordedBackendRequests
        let routineStore: RoutineStore
        let workspaceStore: WorkspaceStore
        let snippetStore: SnippetStore
        let appOpener: HermeticAppOpener
        let browserOpener: HermeticBrowserOpener
        let root: URL
        private let backend: SignedInBackendFixture

        init(
            viewModel: AgentViewModel,
            recorded: RecordedBackendRequests,
            routineStore: RoutineStore,
            workspaceStore: WorkspaceStore,
            snippetStore: SnippetStore,
            appOpener: HermeticAppOpener,
            browserOpener: HermeticBrowserOpener,
            root: URL,
            backend: SignedInBackendFixture
        ) {
            self.viewModel = viewModel
            self.recorded = recorded
            self.routineStore = routineStore
            self.workspaceStore = workspaceStore
            self.snippetStore = snippetStore
            self.appOpener = appOpener
            self.browserOpener = browserOpener
            self.root = root
            self.backend = backend
        }

        func tearDown() {
            backend.unregister()
            try? FileManager.default.removeItem(at: root)
        }

        /// Dispatch a command and wait for the run to finish, approving anything it stops on.
        ///
        /// **The approval loop is `start()` again**, which is the app's own door: `start()` routes
        /// to `approvePendingRun()` while `isAwaitingApproval`, so a test that called a private
        /// approve would be exercising a path no surface takes. A saved routine's plan carries
        /// `requiresConfirmation`, so without this the routine test would wait forever on a question
        /// nobody answered.
        ///
        /// **`HangBackstop.waitOrAbandon`, not a hand-rolled wall-clock loop** (PR #153's F1/F2).
        /// This was `while … { if Date() > deadline { Issue.record(…); return } }`, and that shape
        /// failed the *flagged suite* on an unmodified tree in 3 of 6 clean-tree full runs — while
        /// the same eleven tests pass in 0.757 s under `--filter`. Thirty seconds of wall clock buys
        /// a poll loop one or two looks in this process, not thousands, because both targets share
        /// one main actor whose queue is hundreds of jobs deep; `HangBackstop`'s own doc has the
        /// measurements. The two tests here that drive the real planner over the URL stub are the
        /// longest waits in the tree and so the first to starve.
        ///
        /// **`waitOrAbandon` rather than `wait`, and that is the half F2 was about.** Recording an
        /// issue and returning let the test body run on against a precondition that never arrived,
        /// recording ordinary `Expectation failed` assertions that no declaration covers — so a
        /// starved run was indistinguishable from a mutation kill, and was demonstrated coming back
        /// red twice on a mutant neither test touches. Throwing ends the test, which makes the set
        /// of issues these tests can record finite: the backstop's own wording, and the abandonment.
        /// Both are declared.
        ///
        /// The condition presses the pending approval as a side effect, which is deliberate and is
        /// why the wait is not a pure predicate: the question arrives asynchronously, so the only
        /// place that can answer it is the loop that is already looking. `approvePendingRun` guards
        /// on `!isRunning`, which it sets synchronously, so a second press cannot land.
        func run(_ command: String) async throws {
            viewModel.command = command
            viewModel.start()
            try await HangBackstop.waitOrAbandon(for: "the run to finish: \(command)") {
                if viewModel.isAwaitingApproval, !viewModel.isRunning {
                    viewModel.start()
                }
                return !viewModel.isRunning && !viewModel.isAwaitingApproval
            }
        }
    }

    /// A view model whose backend is signed in and whose every request fails at the transport.
    ///
    /// **`makePlanner` is deliberately not passed**, unlike every other `AgentViewModel` fixture in
    /// this target. They inject a stub planner because they are about something else; this suite is
    /// about what happens when the *real* planner cannot reach the gateway, so it takes the default
    /// — `OpenAIPlanner.throughSonnysBackend(client:)` over the dead client — and the control test
    /// above is the one that proves the difference is real.
    private func makeFixture(
        networkFailure: URLError,
        /// A client of the caller's own, for the two readiness tests that need a Keychain in a state
        /// `SignedInBackendFixture` cannot produce — empty, and holding bytes that will not decode.
        /// The stub host is registered either way, so `recorded` still answers for a client that
        /// never reaches it.
        client: SonnyBackendClient? = nil
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackendOutageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let suiteName = "BackendOutageTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)

        let encryption = LocalStorageEncryption(
            keyManager: OutageFixedKeyManager(bytes: Data(repeating: 0x5B, count: 32))
        )
        let backend = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        backend.register { request in
            recorded.append(request)
            return .failure(networkFailure)
        }

        let routineStore = RoutineStore(
            fileURL: root.appendingPathComponent("routines.json"),
            encryption: encryption
        )
        let workspaceStore = WorkspaceStore(
            fileURL: root.appendingPathComponent("workspaces.json"),
            encryption: encryption
        )
        let snippetStore = SnippetStore(
            fileURL: root.appendingPathComponent("snippets.json"),
            encryption: encryption
        )
        let appOpener = HermeticAppOpener()
        let browserOpener = HermeticBrowserOpener()

        let viewModel = AgentViewModel(
            routineStore: routineStore,
            workspaceStore: workspaceStore,
            snippetStore: snippetStore,
            recentArtifactStore: RecentArtifactStore(
                fileURL: root.appendingPathComponent("recent-artifacts.json"),
                encryption: encryption
            ),
            shortcutCatalog: OutageNoShortcuts(),
            browserOpener: browserOpener,
            appOpener: appOpener,
            fileOpener: HermeticFileOpener(),
            finderRevealer: hermeticFinderRevealer,
            mediaOpener: HermeticMediaOpener(),
            runningAppSwitcher: HermeticRunningAppSwitcher(),
            shortcutInvoker: HermeticShortcutInvoker(),
            finderContextReader: HermeticFinderContextReader(),
            documentConverter: HermeticDocumentConverter(),
            zipArchiver: HermeticZipArchiver(),
            shortcutRunHistoryStore: ShortcutRunHistoryStore(
                fileURL: root.appendingPathComponent("shortcut-run-history.json"),
                encryption: encryption
            ),
            taskHistoryStore: TaskHistoryStore(
                fileURL: root.appendingPathComponent("task-history.json"),
                encryption: encryption
            ),
            taskPlanDetailStore: TaskPlanDetailStore(
                fileURL: root.appendingPathComponent("task-plan-details.json"),
                encryption: encryption
            ),
            visionSessionJournalStore: VisionSessionJournalStore(
                fileURL: root.appendingPathComponent("vision-sessions.json"),
                encryption: encryption
            ),
            clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
                encryption: encryption
            ),
            approvedAppStore: ApprovedAppStore(
                fileURL: root.appendingPathComponent("approved-apps.json"),
                encryption: encryption
            ),
            outputLocationStore: OutputLocationStore(
                fileURL: root.appendingPathComponent("output-locations.json"),
                encryption: encryption,
                whitelist: PathWhitelist(roots: [root])
            ),
            resumableTaskStore: ResumableTaskStore(
                fileURL: root.appendingPathComponent("resumable-tasks.json"),
                encryption: encryption
            ),
            clipboardHistoryMonitor: ClipboardHistoryMonitor(
                reader: HermeticPasteboardReader(),
                store: ClipboardHistoryStore(
                    fileURL: root.appendingPathComponent("clipboard-history.json"),
                    encryption: encryption
                ),
                settingsStore: ClipboardHistorySettingsStore(
                    fileURL: root.appendingPathComponent("clipboard-history-settings-2.json"),
                    encryption: encryption
                )
            ),
            localDataDeletionService: LocalDataDeletionService(fileURLs: []),
            backendClient: client ?? backend.client,
            priorTaskContextStore: PriorTaskContextStore(),
            taskUsageRecorder: TaskUsageRecorder(),
            userDefaults: userDefaults,
            whitelist: PathWhitelist(roots: [root])
        )

        return Fixture(
            viewModel: viewModel,
            recorded: recorded,
            routineStore: routineStore,
            workspaceStore: workspaceStore,
            snippetStore: snippetStore,
            appOpener: appOpener,
            browserOpener: browserOpener,
            root: root,
            backend: backend
        )
    }
}

private struct OutageFixedKeyManager: LocalStorageKeyManaging {
    let bytes: Data
    func keyData() throws -> Data { bytes }
}

private struct OutageNoShortcuts: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { [] }
}
