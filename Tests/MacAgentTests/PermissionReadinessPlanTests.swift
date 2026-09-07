import CryptoKit
import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

/// **The entitled half of the Settings account row** (SONNY-336).
///
/// `PermissionReadinessModelAccessTests` holds what the row *says* for each pair of answers; this
/// holds where the answer comes from. The distinction is the whole ticket: SONNY-136 built the
/// signed-in half and deliberately stopped rather than invent a second notion of entitlement, and
/// what makes this the first half rather than the second is that every value below originates in
/// `EntitlementService.claimConfirmation()` and nothing here computes one.
@Suite
@MainActor
struct PermissionReadinessPlanTests {
    /// **Every decision the one source can give, mapped and published — and nothing else.**
    ///
    /// The mutant this is aimed at is the cheap one: `refreshPlanReadiness()` assigning `.confirmed`
    /// unconditionally, or dropping the refusal on the floor and publishing a bare "unconfirmed".
    /// Both leave a row that looks plausible, and the second one is the quieter of the two — it
    /// would collapse "connect once" and "fix your Mac's clock" into one sentence for a user who
    /// could have acted on either.
    @Test
    func theRowPublishesTheOneSourcesAnswerAndCarriesTheRefusalWhole() async throws {
        let fixture = try PlanReadinessFixture()
        defer { fixture.cleanUp() }

        fixture.viewModel.entitlementConfirmation = { .entitled }
        await fixture.viewModel.refreshPlanReadiness()
        #expect(fixture.viewModel.planReadiness == .confirmed)

        // Every refusal, by name, so a mapping that answered the same thing for all of them fails.
        for refusal: EntitlementRefusal in [
            .notSignedIn, .noClaim, .unreadableClaim, .claimIsForAnotherSession,
            .clockUnusable, .lapsed, .notEntitled
        ] {
            fixture.viewModel.entitlementConfirmation = { .refused(refusal) }
            await fixture.viewModel.refreshPlanReadiness()
            #expect(
                fixture.viewModel.planReadiness == .unconfirmed(refusal),
                "\(refusal) did not survive the hop"
            )
        }

        // And back, on the same view model: a refusal is not sticky.
        fixture.viewModel.entitlementConfirmation = { .entitled }
        await fixture.viewModel.refreshPlanReadiness()
        #expect(fixture.viewModel.planReadiness == .confirmed)
    }

    /// **Nothing wired reports `.undetermined`, never a refusal and never `.confirmed`.**
    ///
    /// Both wrong answers are worth naming. `.confirmed` would be a green row acquired by omission,
    /// which is the direction SONNY-136 refused to build in. A *refusal* is the subtler error: it
    /// would tell a user Sonny could not check their plan when nothing had tried to, which is a
    /// sentence about a failure that did not happen.
    @Test
    func nothingWiredReportsUndeterminedRatherThanConfirmedOrRefused() async throws {
        let fixture = try PlanReadinessFixture()
        defer { fixture.cleanUp() }

        #expect(fixture.viewModel.entitlementConfirmation == nil, "the fixture wired something")
        await fixture.viewModel.refreshPlanReadiness()
        #expect(fixture.viewModel.planReadiness == .undetermined)

        // The row that follows from it is not ready, which is the property the default exists for.
        fixture.viewModel.refreshPermissions()
        try await HangBackstop.waitOrAbandon(for: "the account row to settle") {
            fixture.viewModel.permissionItems.contains { $0.id == "sonny-account" }
        }
        let row = try #require(fixture.viewModel.permissionItems.first { $0.id == "sonny-account" })
        #expect(row.state != .ready)
    }

    /// **The whole path, through a real `EntitlementService` and a claim that really is expired.**
    ///
    /// Every other test here hands `refreshPlanReadiness()` a decision, which means the call that
    /// produces one — `claimConfirmation()`, its store read, its signature check, its clock defence
    /// — is never on the path a sample takes. `CLAUDE.md`'s held-sample gotcha is exactly that
    /// shape: an assertion that is specific, non-vacuous, correct, and upstream of nothing. So one
    /// test drives the real actor, and it drives it in **both** directions in one run: the same
    /// signer, the same store, the same service, one claim inside its life and one long past its
    /// grace. Asserting only the expired direction would pass just as warmly against a service that
    /// refuses everything, which is what makes the pair rather than the case the evidence.
    @Test
    func anExpiredClaimIsNotAConfirmedPlanAndACurrentOneIs() async throws {
        let fixture = try PlanReadinessFixture()
        defer { fixture.cleanUp() }
        let signer = PlanClaimSigner()
        let backend = SignedInBackendFixture()
        defer { backend.unregister() }
        // Offline: the answer must come from the cached claim, which is §16.3's guarantee and the
        // reason a readiness row may ask this at all.
        backend.register { _ in .failure(URLError(.notConnectedToInternet)) }

        let store = KeychainEntitlementStore(secretStore: InMemoryKeychainSecretStore())
        let service = EntitlementService(client: backend.client, store: store, keys: signer.keys)
        fixture.viewModel.entitlementConfirmation = { await service.claimConfirmation() }
        // The session half, from the fixture's own signed-in client. Both halves are needed for
        // `.ready`, which is the row's rule — asserting the plan alone would be asserting against a
        // row that can never be green whatever the plan says.
        await fixture.viewModel.refreshModelAccessReadiness()
        try #require(fixture.viewModel.modelAccessReadiness == .signedIn)

        // A claim issued now and alive for a day: confirmed.
        try store.save(StoredEntitlement(compactClaim: signer.claim(), observedServerTime: nil))
        await fixture.viewModel.refreshPlanReadiness()
        #expect(fixture.viewModel.planReadiness == .confirmed, "a current claim did not confirm")
        #expect(try Self.accountRow(fixture.viewModel).state == .ready)

        // The same claim shape, issued far enough in the past that its life and its 72-hour grace
        // are both spent. Nothing else changes — same signer, same store, same service.
        let longAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        try store.save(
            StoredEntitlement(compactClaim: signer.claim(issuedAt: longAgo), observedServerTime: nil)
        )
        await fixture.viewModel.refreshPlanReadiness()
        #expect(
            fixture.viewModel.planReadiness == .unconfirmed(.lapsed),
            "an expired claim answered \(fixture.viewModel.planReadiness)"
        )
        // And the row that follows says so: not ready, and not claiming a confirmed plan.
        let lapsedRow = try Self.accountRow(fixture.viewModel)
        #expect(lapsedRow.state != .ready)
        #expect(!lapsedRow.detail.contains("your plan is confirmed"))
    }

    /// **A claim signed by a key this build does not hold is refused, not believed.**
    ///
    /// The forged-claim direction of the same wiring, and the one that would matter most if it were
    /// wrong: a row is a surface a user believes, and `EntitlementService`'s rule is that every
    /// failure — including the ones that are this build's own fault — is a refusal rather than an
    /// assumption. This is that rule reaching the row.
    @Test
    func aClaimSignedByAnotherKeyIsNotAConfirmedPlan() async throws {
        let fixture = try PlanReadinessFixture()
        defer { fixture.cleanUp() }
        let backend = SignedInBackendFixture()
        defer { backend.unregister() }
        backend.register { _ in .failure(URLError(.notConnectedToInternet)) }

        // The claim is minted by one signer and the service is given a different one's key set, so
        // the bytes are well formed and the signature belongs to nobody this build trusts.
        let minted = PlanClaimSigner()
        let trusted = PlanClaimSigner()
        let store = KeychainEntitlementStore(secretStore: InMemoryKeychainSecretStore())
        try store.save(StoredEntitlement(compactClaim: minted.claim(), observedServerTime: nil))
        let service = EntitlementService(client: backend.client, store: store, keys: trusted.keys)
        fixture.viewModel.entitlementConfirmation = { await service.claimConfirmation() }

        await fixture.viewModel.refreshPlanReadiness()
        #expect(fixture.viewModel.planReadiness != .confirmed)
        #expect(try Self.accountRow(fixture.viewModel).state != .ready)

        // The control: the identical claim under its own signer's key set does confirm, which is
        // what says the refusal above is the signature and not the fixture.
        let matched = EntitlementService(client: backend.client, store: store, keys: minted.keys)
        fixture.viewModel.entitlementConfirmation = { await matched.claimConfirmation() }
        await fixture.viewModel.refreshPlanReadiness()
        #expect(fixture.viewModel.planReadiness == .confirmed)
    }

    /// **`refreshPermissions()` refreshes both halves, and this test exists to be *attributable*.**
    ///
    /// The property is that the Settings page's own door does not refresh the session and skip the
    /// plan. Two existing tests already fail when it does — but both fail by *waiting* for a row
    /// state that never arrives, so their only signal is a `HangBackstop` timeout, and every wording
    /// that type emits is declared untrustworthy in `scripts/mutate-untrusted-failures` because a
    /// wait that times out may only be reporting the shared main actor's queue depth. A mutant whose
    /// sole opposition is those two therefore comes back `UNATTRIBUTED` on a run where the tests
    /// failed for exactly the right reason — `CLAUDE.md` records this as the mechanism working
    /// rather than a seam, and says the remedy is the caller's. This is that remedy, in the form
    /// that suited this property: the mutant was reported unattributed by the battery at
    /// `230d4dae`, and this test is what makes it a named kill.
    ///
    /// **The wait is on a precondition the mutant does not break**, which is the whole trick. The
    /// row's detail leaves its never-asked sentence at the *final* recompute, which happens whether
    /// or not the plan half was refreshed — so the wait completes either way and every assertion
    /// below it is a plain one. A backstop can still fire here, but only if the refresh Task never
    /// ran at all, which is a different failure and an honest one.
    @Test
    func refreshingPermissionsRefreshesThePlanHalfAndNotOnlyTheSession() async throws {
        let fixture = try PlanReadinessFixture()
        defer { fixture.cleanUp() }
        let asked = EntitlementAskCounter()
        fixture.viewModel.entitlementConfirmation = {
            await asked.record()
            return .entitled
        }

        fixture.viewModel.refreshPermissions()
        try await HangBackstop.waitOrAbandon(for: "the account row to leave its never-asked state") {
            fixture.viewModel.permissionItems
                .first { $0.id == "sonny-account" }?
                .detail.hasPrefix("Signed in") == true
        }

        // Plain assertions from here: a refresh that skipped the plan half leaves both false.
        // The count is read out of the actor first — `#expect`'s autoclosure cannot `await`.
        let asks = await asked.count
        #expect(asks == 1, "the plan half was asked \(asks) times")
        #expect(fixture.viewModel.planReadiness == .confirmed)
        // And the row the page renders carries it, rather than the plan being refreshed into a
        // value nothing re-reads.
        let row = try #require(fixture.viewModel.permissionItems.first { $0.id == "sonny-account" })
        #expect(row.state == .ready)
        #expect(row.detail == "Signed in, and your plan is confirmed.")
    }

    /// The row the app renders, from the view model's own recompute — the same function
    /// `refreshPermissions()` calls, so the `planAccess:` argument inside it is on the path rather
    /// than reproduced here. Synchronous, because both readiness values are already published by the
    /// time a caller asks; the awaits belong to the refreshes above it, not to the render.
    private static func accountRow(_ viewModel: AgentViewModel) throws -> PermissionReadinessItem {
        viewModel.recomputePermissionItems()
        return try #require(viewModel.permissionItems.first { $0.id == "sonny-account" })
    }
}

/// Mints claims that verify, on the pattern `BillingPortalSurfaceTests.Signer` established.
///
/// Its own copy rather than a shared one, deliberately: that suite's is nested in a type on this
/// project's never-touch list for this lane, and a shared signer would couple two suites that
/// happen to need the same four lines of JWT encoding. Both are ten lines and neither is a rule.
struct PlanClaimSigner {
    let keyID = "readiness-test-key"
    private let privateKey = Curve25519.Signing.PrivateKey()

    var keys: EntitlementKeySet {
        EntitlementKeySet.parsing(["\(keyID):\(Self.base64url(privateKey.publicKey.rawRepresentation))"])
    }

    /// `subject` is the user `SignedInBackendFixture` puts in the Keychain — a claim about anyone
    /// else is refused as `claimIsForAnotherSession`, which is a different property.
    func claim(
        subject: String = "test-user",
        issuedAt: Date = Date(),
        lifetime: TimeInterval = 24 * 60 * 60
    ) -> String {
        let header: [String: Any] = ["alg": "EdDSA", "typ": "JWT", "kid": keyID]
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        let payload: [String: Any] = [
            "v": 1,
            "sub": subject,
            "plan": "paid",
            "capabilities": ["screen_control"],
            "issued_at": format.string(from: issuedAt),
            "expires_at": format.string(from: issuedAt.addingTimeInterval(lifetime)),
            "grace_seconds": 72 * 60 * 60,
            "skew_tolerance_seconds": 300
        ]
        let head = Self.base64url(try! JSONSerialization.data(withJSONObject: header))
        let body = Self.base64url(try! JSONSerialization.data(withJSONObject: payload))
        let signature = try! privateKey.signature(for: Data("\(head).\(body)".utf8))
        return "\(head).\(body).\(Self.base64url(signature))"
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A view model with a signed-in hermetic client and no store it can reach.
///
/// **The client is signed in because the row's two halves compose**: an entitled plan on a
/// signed-out Mac is not a state the row reports, so a fixture that could not be signed in could
/// not reach `.ready` at all. `UnreachableLocalStores` supplies the rest — this suite asks nothing
/// of any local store, and CLAUDE.md's rule is that a fixture which does not care about a store
/// must still not be handed the real one.
@MainActor
struct PlanReadinessFixture {
    let root: URL
    let backend: SignedInBackendFixture
    let viewModel: AgentViewModel

    init(backend: SignedInBackendFixture? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlanReadinessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backend = backend ?? SignedInBackendFixture()
        self.backend = backend

        let suiteName = "PlanReadinessTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)

        viewModel = AgentViewModel(
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces(),
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            shortcutCatalog: PlanReadinessNoShortcuts(),
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
            shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory(),
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
            resumableTaskStore: ResumableTaskStore(fileURL: root.appendingPathComponent("resumable-tasks.json")),
            pendingServerDeletionStore: UnreachableLocalStores.pendingServerDeletions(),
            standingWatcherObserver: UnreachableStandingWatcherObserver(),
            clipboardHistoryMonitor: ClipboardHistoryMonitor(
                reader: FakePasteboardReader(),
                store: UnreachableLocalStores.clipboardHistory(),
                settingsStore: ClipboardHistorySettingsStore(
                    fileURL: root.appendingPathComponent("clipboard-history-settings.json")
                )
            ),
            localDataDeletionService: LocalDataDeletionService(fileURLs: []),
            backendClient: backend.client,
            priorTaskContextStore: PriorTaskContextStore(),
            taskUsageRecorder: TaskUsageRecorder(),
            userDefaults: userDefaults,
            whitelist: PathWhitelist(roots: [root])
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct PlanReadinessNoShortcuts: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { [] }
}

/// This suite's own, on the convention every other suite in this target already follows: each keeps
/// a private copy rather than sharing one, because the type is five lines and a shared fake would
/// couple suites that only happen to need the same nothing.
private final class FakePasteboardReader: PasteboardReading {
    var changeCount = 0

    func typeIdentifiers() -> [String] {
        []
    }

    func stringValue() -> String? {
        nil
    }
}

/// Counts how many times the readiness refresh asked the one source. An actor because the seam is
/// `@Sendable`, and a count rather than a Bool because "asked twice" is its own defect.
actor EntitlementAskCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
