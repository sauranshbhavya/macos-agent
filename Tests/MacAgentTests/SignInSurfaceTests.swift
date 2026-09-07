import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

/// The sign-in surface's state machine, and the property the whole ticket exists for: the session
/// is on disk before the Screen Recording grant restarts the app, and the app comes back signed in.
@Suite
@MainActor
struct SignInSurfaceTests {
    // MARK: - The headline requirement

    /// **The failure this ticket was written to prevent, run end to end.**
    ///
    /// A user signs in, grants Screen Recording, macOS forces a relaunch
    /// (`ScreenAccessOnboardingModel.relaunchNow()`), and they must not come back signed out. The
    /// relaunch is driven through the product's own `AppRelaunching` seam — not simulated beside it
    /// — and the relauncher reads the Keychain at the moment it is asked to restart, which is the
    /// last instant anything in this process can observe. Then a brand new model over the same
    /// Keychain stands in for the process that comes back.
    @Test
    func theSessionIsAlreadyOnDiskWhenTheScreenRecordingGrantRestartsTheApp() async throws {
        let harness = Harness()
        harness.serveTokenResponse()
        let model = harness.makeModel()
        model.emailAddress = "founder@example.com"
        await model.sendCode()
        model.code = "123456"
        await model.verify()
        #expect(model.isSignedIn)

        // First run continues into the Screen Recording step, which ends in a relaunch.
        let relauncher = KeychainReadingRelauncher(keychain: harness.keychain)
        let onboarding = ScreenAccessOnboardingModel(
            permissionChecker: DeterministicScreenPermissions(screenRecordingGranted: false),
            relauncher: relauncher,
            settingsOpener: { _ in }
        )
        onboarding.requestScreenRecording()
        #expect(onboarding.needsRelaunchGuidance)

        await onboarding.relaunchNow()

        #expect(relauncher.relaunchCount == 1)
        #expect(relauncher.keychainHeldASessionAtRelaunch == true)

        // The process that comes back shares nothing but the Keychain.
        let afterRelaunch = harness.makeModel()
        await afterRelaunch.restore()

        #expect(afterRelaunch.isSignedIn)
        #expect(afterRelaunch.step == .signedIn)
        #expect(afterRelaunch.signedInAddress == "founder@example.com")
        #expect(afterRelaunch.identity?.userID == "acct_7f3c")
    }

    /// **The negative, and the worst thing to get wrong.** If the Keychain write fails, the user is
    /// told sign-in failed. Reporting success on a session no disk holds is exactly how the failure
    /// above happens with nothing to point at.
    @Test
    func aKeychainWriteFailureLeavesTheUserSignedOutWithAMessage() async throws {
        let harness = Harness()
        harness.serveTokenResponse()
        harness.keychain.failWrites(with: InMemoryKeychainFailure.refused)
        let model = harness.makeModel()
        model.emailAddress = "founder@example.com"
        await model.sendCode()
        model.code = "123456"

        await model.verify()

        #expect(model.isSignedIn == false)
        #expect(model.step == .code)
        #expect(model.failure == .unexpected)
        #expect(model.isBusy == false)
        harness.keychain.stopFailing()
        #expect(harness.keychain.contains(
            service: KeychainAccountTokenStore.defaultService,
            account: KeychainAccountTokenStore.defaultAccount
        ) == false)
    }

    // MARK: - Restoring

    @Test
    func restoringWithNothingStoredLeavesTheSurfaceOnTheAddressStep() async {
        let harness = Harness()
        let model = harness.makeModel()

        await model.restore()

        #expect(model.step == .address)
        #expect(model.isSignedIn == false)
        #expect(model.failure == nil)
        #expect(model.isConfigured)
    }

    /// Bytes that are not a session this build can read: the user signs in again, and nothing here
    /// deletes a credential store on the strength of a decode failure.
    @Test
    func anUnreadableStoredSessionAsksForASignInRatherThanBeingDeleted() async {
        let harness = Harness()
        harness.keychain.plant(
            Data("not a session".utf8),
            service: KeychainAccountTokenStore.defaultService,
            account: KeychainAccountTokenStore.defaultAccount
        )
        let model = harness.makeModel()

        await model.restore()

        #expect(model.step == .address)
        #expect(model.isSignedIn == false)
        #expect(model.failure == .signedOut)
        #expect(harness.keychain.contains(
            service: KeychainAccountTokenStore.defaultService,
            account: KeychainAccountTokenStore.defaultAccount
        ))
    }

    /// A build with no backend host says so and disables the controls, rather than offering a
    /// button that silently does nothing. Reachable until SONNY-192 chooses a host.
    @Test
    func aBuildWithNoBackendHostSaysSoAndCannotBeSubmitted() async {
        let harness = Harness()
        let model = harness.makeModelWithNoBackendHost()

        await model.restore()
        model.emailAddress = "founder@example.com"

        #expect(model.isConfigured == false)
        #expect(model.failure == .notConfigured)
        #expect(SignInCopy.message(for: .notConfigured) == "Sign-in isn't available in this build.")
        #expect(model.canSendCode == false)
        #expect(model.canVerify == false)
    }

    // MARK: - The flow

    @Test
    func sendingACodeMovesToTheCodeStepAndConfirmsItWithoutExplainingAnything() async {
        let harness = Harness()
        harness.serve { request in
            guard request.url?.path == "/v1/auth/email/start" else {
                return .reply(statusCode: 404, headers: [:], body: Data())
            }
            return .reply(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"request_id":"req_1","expires_in":600}"#.utf8)
            )
        }
        let model = harness.makeModel()
        model.emailAddress = "  founder@example.com  "

        await model.sendCode()

        #expect(model.step == .code)
        #expect(model.emailAddress == "founder@example.com")
        #expect(model.notice == "Code sent.")
        #expect(model.failure == nil)
        #expect(model.isBusy == false)
    }

    @Test
    func anEmptyAddressCannotBeSubmitted() {
        let harness = Harness()
        let model = harness.makeModel()

        model.emailAddress = "   "
        #expect(model.canSendCode == false)
        model.emailAddress = "founder@example.com"
        #expect(model.canSendCode)
    }

    /// Each of the code failures the server can distinguish gets its own words in the surface, and
    /// none of them is the server's own sentence (§7.1).
    @Test(arguments: [
        ("auth.code_invalid", SignInFailure.codeIncorrect),
        ("auth.code_expired", SignInFailure.codeExpired),
        ("auth.code_used", SignInFailure.codeAlreadyUsed),
        ("limit.rate", SignInFailure.tooManyAttempts)
    ])
    func aRejectedCodeShowsItsOwnMessageAndNeverTheServers(wire: String, expected: SignInFailure) async {
        let serverSentence = "Sign-in code was not accepted."
        let harness = Harness()
        harness.serve { request in
            guard request.url?.path == "/v1/auth/email/verify" else {
                return .reply(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"request_id":"req_1","expires_in":600}"#.utf8)
                )
            }
            let body = try! JSONSerialization.data(withJSONObject: [
                "error": [
                    "code": wire,
                    "message": serverSentence,
                    "retryable": false,
                    "retry_after_seconds": NSNull(),
                    "request_id": "req_1"
                ]
            ])
            return .reply(statusCode: 400, headers: [:], body: body)
        }
        let model = harness.makeModel()
        model.emailAddress = "founder@example.com"
        await model.sendCode()
        model.code = "000000"

        await model.verify()

        #expect(model.failure == expected)
        #expect(model.isSignedIn == false)
        #expect(model.step == .code, "a wrong code keeps the user where they can type another one")
        let shown = SignInCopy.message(for: try! #require(model.failure))
        #expect(shown != serverSentence)
        #expect(!shown.contains(serverSentence))
    }

    /// The manual item: wifi off, open sign-in, the message is human and names the real problem.
    @Test
    func beingOfflineSaysSoRatherThanNamingSonnysBackend() async {
        let harness = Harness()
        harness.serve { _ in .failure(URLError(.notConnectedToInternet)) }
        let model = harness.makeModel()
        model.emailAddress = "founder@example.com"

        await model.sendCode()

        #expect(model.failure == .offline)
        #expect(SignInCopy.message(for: .offline) == "You're offline. Reconnect and try again.")
        #expect(model.step == .address)
    }

    @Test
    func aBackendThatCannotBeReachedIsToldApartFromBeingOffline() async {
        let harness = Harness()
        harness.serve { _ in .failure(URLError(.cannotConnectToHost)) }
        let model = harness.makeModel()
        model.emailAddress = "founder@example.com"

        await model.sendCode()

        #expect(model.failure == .backendUnreachable)
        #expect(SignInCopy.message(for: .backendUnreachable) != SignInCopy.message(for: .offline))
    }

    @Test
    func usingAnotherAddressReturnsToTheAddressStepAndClearsWhatWasShown() async {
        let harness = Harness()
        harness.serveTokenResponse()
        let model = harness.makeModel()
        model.emailAddress = "founder@example.com"
        await model.sendCode()
        model.code = "123456"
        #expect(model.step == .code)

        model.useAnotherAddress()

        #expect(model.step == .address)
        #expect(model.code.isEmpty)
        #expect(model.failure == nil)
        #expect(model.notice == nil)
        // The address is deliberately kept: the commonest reason to be here is a typo in it.
        #expect(model.emailAddress == "founder@example.com")
    }

    // MARK: - Signing out

    @Test
    func signingOutReturnsToTheAddressStepAndForgetsTheSession() async {
        let harness = Harness()
        harness.serveTokenResponse()
        let model = harness.makeModel()
        model.emailAddress = "founder@example.com"
        await model.sendCode()
        model.code = "123456"
        await model.verify()
        harness.serve { _ in .reply(statusCode: 204, headers: [:], body: Data()) }

        await model.signOut()

        #expect(model.isSignedIn == false)
        #expect(model.step == .address)
        #expect(model.notice == nil)
        #expect(model.failure == nil)
        #expect(harness.keychain.contains(
            service: KeychainAccountTokenStore.defaultService,
            account: KeychainAccountTokenStore.defaultAccount
        ) == false)

        // And it comes back signed out, which is the other half of "signed out".
        let afterRelaunch = harness.makeModel()
        await afterRelaunch.restore()
        #expect(afterRelaunch.isSignedIn == false)
    }

    @Test
    func signingOutWhenTheServerCannotBeReachedStillSignsOutAndSaysSo() async {
        let harness = Harness()
        harness.serveTokenResponse()
        let model = harness.makeModel()
        model.emailAddress = "founder@example.com"
        await model.sendCode()
        model.code = "123456"
        await model.verify()
        harness.serve { _ in .failure(URLError(.cannotConnectToHost)) }

        await model.signOut()

        #expect(model.isSignedIn == false)
        #expect(model.step == .address)
        #expect(model.notice == SignInCopy.signedOutLocallyOnly)
        #expect(harness.keychain.contains(
            service: KeychainAccountTokenStore.defaultService,
            account: KeychainAccountTokenStore.defaultAccount
        ) == false)
    }

    /// **Sign-out is not "delete my local data."** The manual item checks routines, workspaces,
    /// snippets and clipboard history all survive; here the same property is checked at the level
    /// that decides it — the key those encrypted files are read with is exactly where it was.
    @Test
    func signingOutLeavesTheLocalStorageEncryptionKeyExactlyWhereItWas() async throws {
        let harness = Harness()
        let key = Data(repeating: 0x53, count: 32)
        harness.keychain.plant(
            key,
            service: LocalStorageEncryptionKeyManager.defaultService,
            account: LocalStorageEncryptionKeyManager.defaultAccount
        )
        harness.serveTokenResponse()
        let model = harness.makeModel()
        model.emailAddress = "founder@example.com"
        await model.sendCode()
        model.code = "123456"
        await model.verify()
        harness.serve { _ in .reply(statusCode: 204, headers: [:], body: Data()) }

        await model.signOut()

        #expect(try LocalStorageEncryptionKeyManager(secretStore: harness.keychain).keyData() == key)
        #expect(harness.keychain.storedKeys.map(\.service) == [LocalStorageEncryptionKeyManager.defaultService])
    }

    // MARK: - Entry point

    /// The surface is reachable, and from exactly one place. A scan rather than a runtime assertion
    /// because this repository has no SwiftUI inspection harness — see `MacAgentSource`'s own doc
    /// for why, and for what a textual scan can and cannot hold.
    @Test
    func commandCenterOpensTheSignInDialogFromTheAccountMenuAndNowhereElse() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")

        #expect(MacAgentSource.count(of: "SignInDialogView(", inText: source) == 1)
        #expect(MacAgentSource.count(of: "isSignInPresented = true", inText: source) == 1)
        // The row that sets it lives in the account menu, beside Profile and Settings.
        let menu = try MacAgentSource.braceBlock(of: source, openedBy: "private var accountMenuContent: some View {")
        #expect(MacAgentSource.count(of: "isSignInPresented = true", inText: menu) == 1)
        #expect(MacAgentSource.count(of: "SignInCopy.signInLabel", inText: menu) == 1)
        // And it is the shared model, not a second one built here.
        #expect(MacAgentSource.count(of: "SonnyAccountModel(", inText: source) == 0)
    }

    /// The one seam that reaches the real Keychain, and the one file allowed to name it — the rule
    /// `AgentViewModel.atItsRealStoreLocations()` already lives under, applied to the store every
    /// packaged build on this Mac shares.
    @Test
    func onlyMainAsksForTheRealKeychain() throws {
        var mentions: [String: Int] = [:]
        for url in try MacAgentSource.appSourceFiles() + MacAgentSource.coreSourceFiles() {
            let count = MacAgentSource.count(
                of: "atItsRealKeychainLocation",
                inText: try MacAgentSource.read(url)
            )
            if count > 0 { mentions[url.lastPathComponent] = count }
        }

        #expect(mentions == ["SignInView.swift": 1, "main.swift": 1], "found \(mentions)")
    }

    /// **The shipping app does not run its backend calls on `URLSession.shared`** (PR #133, F11).
    /// That session is backed by a 20 MB on-disk cache nobody chose, and SONNY-130 and SONNY-134
    /// point authenticated `GET`s at this same client. A scan rather than a runtime check because
    /// the one production site constructs the real Keychain store, which no test may reach.
    @Test
    func theProductionClientDoesNotRunOnTheSharedSession() throws {
        let source = try MacAgentSource.read("SignInView.swift")
        let factory = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "static func atItsRealKeychainLocation() -> SonnyAccountModel {"
        )

        #expect(MacAgentSource.count(of: "session: SonnyBackendSession.forBackendCalls()", inText: factory) == 1)
        #expect(MacAgentSource.count(of: ".shared", inText: factory) == 0)
        // And nowhere else in the app target names a session for this client either.
        #expect(MacAgentSource.count(of: "SonnyBackendClient(", inText: source) == 1)
    }

    // MARK: - Harness

    // MARK: - The session-change hook (SONNY-136, PR #153's F4)

    /// **A sign-in and a sign-out each announce themselves, so the readiness row can follow.**
    ///
    /// The row was stale in both directions and the reason was structural rather than a missed call:
    /// `AgentViewModel.modelAccessReadiness` is refreshed only by `refreshPermissions()`, whose call
    /// sites are all Command Center `onAppear`s and its Refresh button — and sign-in is a *sheet*
    /// over Command Center, so closing it re-fires nothing. This hook is what `main.swift` joins to
    /// that refresh.
    ///
    /// **The negative is the half worth having.** A wrong code must not fire it: `run` swallows the
    /// failure into `failure`, so a hook called from inside `run` would announce a session that was
    /// never created, and the row would go green on a failed attempt.
    @Test
    func aSuccessfulSignInAnnouncesItselfAndAFailedOneDoesNot() async throws {
        let harness = Harness()
        harness.serveTokenResponse()
        let model = harness.makeModel()
        var announcements = 0
        model.sessionDidChange = { announcements += 1 }

        model.emailAddress = "founder@example.com"
        await model.sendCode()
        #expect(announcements == 0, "asking for a code is not a session")

        model.code = "123456"
        await model.verify()
        try #require(model.isSignedIn)
        #expect(announcements == 1)

        // A wrong code, on a fresh model over the same Keychain, announces nothing.
        harness.serve { request in
            guard request.url?.path == "/v1/auth/email/verify" else {
                return .reply(statusCode: 200, headers: [:], body: Data(#"{"request_id":"r","expires_in":600}"#.utf8))
            }
            return .reply(
                statusCode: 401,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":{"code":"auth.code_invalid","message":"no","retryable":false,"request_id":"r"}}"#.utf8)
            )
        }
        let refused = harness.makeModel()
        var refusedAnnouncements = 0
        refused.sessionDidChange = { refusedAnnouncements += 1 }
        refused.emailAddress = "founder@example.com"
        refused.code = "000000"
        await refused.verify()
        #expect(refused.failure == .codeIncorrect)
        #expect(refusedAnnouncements == 0, "a refused code announced a session that was never created")
    }

    /// Signing out announces itself too, **including when the server never confirmed the revoke** —
    /// `SonnyAccountService.signOut` clears this Mac either way, so the session is gone locally
    /// whatever happened upstream, and that is precisely the case where a row still reading "Signed
    /// in." would be worst.
    @Test
    func signingOutAnnouncesItselfOnBothOutcomes() async throws {
        for revokeSucceeds in [true, false] {
            let harness = Harness()
            harness.serveTokenResponse()
            let model = harness.makeModel()
            model.emailAddress = "founder@example.com"
            await model.sendCode()
            model.code = "123456"
            await model.verify()
            try #require(model.isSignedIn)

            var announcements = 0
            model.sessionDidChange = { announcements += 1 }
            if !revokeSucceeds {
                harness.serve { _ in .failure(URLError(.cannotConnectToHost)) }
            }
            await model.signOut()

            #expect(model.isSignedIn == false, "revokeSucceeds: \(revokeSucceeds)")
            #expect(announcements == 1, "revokeSucceeds: \(revokeSucceeds)")
        }
    }

    /// **`main.swift` is where the hook meets the refresh, and nothing else can hold that.**
    ///
    /// It is a top-level file that runs `NSApplication.main`; no test can execute it. The two
    /// halves are checked separately — this suite holds that the hook fires, and
    /// `BackendOutageTests` holds that a refresh moves the row — so what is left is the one line
    /// joining them, and a scan is the only instrument for it. Same shape and same reason as
    /// `onlyMainAsksForTheRealKeychain`, which guards the neighbouring line in the same file.
    ///
    /// **It reads the closure's body, not two tokens anywhere in the file** (cycle 2's C2-F7). The
    /// first version checked `contains("accountModel.sessionDidChange")`, `contains("refreshPermissions()")`
    /// and a count of one — and the reviewer showed that an *empty* hook beside a stray top-level
    /// `agentViewModel.refreshPermissions()` satisfies all three, which is a file that compiles,
    /// refreshes once at launch, and never follows a session again. That is the exact defect this
    /// scan exists to catch, passing. `MacAgentSource.braceBlock(of:openedBy:)` is the instrument
    /// for it and was already in the tree.
    @Test
    func mainJoinsTheSessionHookToTheReadinessRefresh() throws {
        let source = try MacAgentSource.read("main.swift")
        // The hook's own body, by brace matching — so what is asserted is what the closure *does*.
        let hookBody = try MacAgentSource.braceBlock(of: source, openedBy: "accountModel.sessionDidChange = {")
        #expect(
            hookBody.contains("refreshPermissions()"),
            "main.swift's session hook no longer refreshes readiness; its body is: \(hookBody)"
        )
        // And it is one assignment rather than several, so the scan cannot pass on a leftover.
        #expect(MacAgentSource.count(of: "sessionDidChange", inText: source) == 1)
    }

    /// **`main.swift` is also where the readiness row meets the one entitlement source** (SONNY-336),
    /// and a scan is the only instrument for the same reason the test above gives: no test can
    /// execute a file that runs `NSApplication.main`.
    ///
    /// **What breaks without this test, precisely.** `AgentViewModel.entitlementConfirmation` is an
    /// Optional and `refreshPlanReadiness()` maps `nil` to `.undetermined` — which is the honest
    /// answer for a build nobody wired, and is exactly why deleting the wiring line compiles and
    /// leaves a green suite. The account row would then read *"Signed in. Sonny checks your plan
    /// when it needs it."* forever on a Mac whose plan is confirmed. That is PR #153's F3 in its own
    /// words, arriving at the half of the row this ticket added, so it gets F3's own instrument.
    ///
    /// **It reads the closure's body rather than tokens anywhere in the file**, for C2-F7's reason
    /// on the test above: an empty closure beside a stray mention elsewhere would satisfy a
    /// `contains` and wire nothing.
    ///
    /// **And it pins `claimConfirmation()` rather than merely "some entitlement call".** That is the
    /// rule SONNY-336 turns on: `decision(for:)` takes an `EntitlementCapability`, so a row wired to
    /// it would have had to mint a capability key — row 18's (SONNY-23) decision, taken in the wrong
    /// row, and the second notion of entitlement SONNY-136 stopped rather than build. A scan is
    /// where that stays true, because both calls compile.
    @Test
    func mainJoinsTheReadinessRowToTheOneEntitlementSource() throws {
        let source = try MacAgentSource.read("main.swift")
        let body = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "agentViewModel.entitlementConfirmation = {"
        )
        #expect(
            body.contains("claimConfirmation()"),
            "main.swift no longer asks the entitlement service to confirm; its body is: \(body)"
        )
        // The narrower door, and not the one that would need a capability key.
        #expect(
            !body.contains("decision(for:"),
            "the readiness row must not name a capability; its body is: \(body)"
        )
        // It is the account model's shared service, not a second one built here — a second
        // `EntitlementService` would be a second clock anchor and a second refresh guard.
        #expect(
            body.contains("entitlements"),
            "main.swift no longer hands the row the shared service; its body is: \(body)"
        )
        #expect(!body.contains("EntitlementService("), "main.swift built a second entitlement service")
        // One assignment rather than several, so the scan cannot pass on a leftover.
        #expect(MacAgentSource.count(of: "entitlementConfirmation", inText: source) == 1)
    }

    private final class Harness {
        let keychain = InMemoryKeychainSecretStore()
        let session: URLSession
        let baseURL: URL
        let host: String

        init() {
            let stub = BackendStubURLProtocol.makeSession()
            session = stub.session
            baseURL = stub.baseURL
            host = stub.host
        }

        func serve(_ handler: @escaping BackendStubURLProtocol.Handler) {
            BackendStubURLProtocol.register(host: host, handler: handler)
        }

        /// `email/start` answers the uniform 200, `email/verify` and everything else answer a §3.2
        /// token response.
        func serveTokenResponse() {
            serve { request in
                if request.url?.path == "/v1/auth/email/start" {
                    return .reply(
                        statusCode: 200,
                        headers: [:],
                        body: Data(#"{"request_id":"req_1","expires_in":600}"#.utf8)
                    )
                }
                let body = try! JSONSerialization.data(withJSONObject: [
                    "access_token": "issued-access",
                    "token_type": "Bearer",
                    "expires_in": 3600,
                    "expires_at": "2026-08-26T10:41:07Z",
                    "refresh_token": "issued-refresh",
                    "user": ["id": "acct_7f3c"]
                ])
                return .reply(statusCode: 200, headers: [:], body: body)
            }
        }

        @MainActor
        func makeModel() -> SonnyAccountModel {
            makeHermeticAccountModel(
                keychain: keychain,
                environment: SonnyBackendEnvironment(baseURL: baseURL, source: .production),
                session: session
            )
        }

        /// A build with no host at all — what a release build resolves to until SONNY-192 picks one.
        @MainActor
        func makeModelWithNoBackendHost() -> SonnyAccountModel {
            makeHermeticAccountModel(keychain: keychain, environment: nil, session: session)
        }
    }

    /// Stands where `DefaultAppRelauncher` stands, and reads the Keychain at the instant the app
    /// would restart — the last moment anything in this process can observe.
    private final class KeychainReadingRelauncher: AppRelaunching {
        private let keychain: InMemoryKeychainSecretStore
        private(set) var relaunchCount = 0
        private(set) var keychainHeldASessionAtRelaunch: Bool?

        init(keychain: InMemoryKeychainSecretStore) {
            self.keychain = keychain
        }

        @MainActor
        func relaunch() async throws {
            relaunchCount += 1
            keychainHeldASessionAtRelaunch = keychain.contains(
                service: KeychainAccountTokenStore.defaultService,
                account: KeychainAccountTokenStore.defaultAccount
            )
        }
    }
}
