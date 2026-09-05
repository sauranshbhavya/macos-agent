import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// What `SonnyBackendClient` derives from real responses about this build's version — contract §8's
/// client obligations, driven end to end over the stub transport (SONNY-402).
///
/// **The properties here are the ones the ticket names, and each is a shape that would be invisible
/// without a test.** A `410` that triggers no `/v1/meta` call, a `/v1/meta` call per request, a
/// deprecation header nobody read, and a link the app would open that it should not: every one of
/// them is a client that behaves correctly on the happy path and silently wrongly on the path the
/// section exists for.
@Suite
struct ClientVersionClientTests {
    private static let metaPath = "/v1/meta"
    private static let planPath = "/v1/plan"

    private func planRequest() -> SonnyBackendRequest {
        SonnyBackendRequest(
            method: "POST",
            path: Self.planPath,
            body: Data("{}".utf8),
            authentication: .bearer,
            idempotencyKey: UUID(),
            timeout: SonnyBackendTimeouts.plan,
            isRetrySafe: true
        )
    }

    private func walledOff(upgradeURL: String?) -> BackendStubURLProtocol.Outcome {
        .reply(
            statusCode: 410,
            headers: ["Content-Type": "application/json"],
            body: SonnyBackendFixtures.errorEnvelopeJSON(
                code: "version.unsupported",
                upgradeURL: upgradeURL
            )
        )
    }

    // MARK: - §8.3: on launch and on any 410, never per request

    /// The launch half. One call, and the document is kept where a later state can read it.
    @Test
    @MainActor
    func theLaunchCallReadsTheMetaDocumentAndKeepsIt() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        let requests = RecordedRequests()
        fixture.register { request in
            requests.record(request)
            return .reply(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: SonnyBackendFixtures.metaDocumentJSON(minimumSupportedClient: "1.2.0")
            )
        }

        let document = try #require(await fixture.client.refreshMetaDocument())

        #expect(document.minimumSupportedClient == "1.2.0")
        #expect(await fixture.client.metaDocument() == document)
        #expect(requests.count(path: Self.metaPath) == 1)
        #expect(requests.recorded.first?.httpMethod == "GET")
        // Unauthenticated: §2.2's public route list carries `GET /v1/meta`, because a client that
        // has to sign in before it can be told its build is too old to sign in with is in a loop.
        #expect(requests.recorded.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// "It does not call it per request." Five ordinary requests, zero meta calls.
    @Test
    @MainActor
    func nothingCallsMetaPerRequest() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        let requests = RecordedRequests()
        fixture.register { request in
            requests.record(request)
            return .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        for _ in 0..<5 {
            _ = try await fixture.client.send(planRequest())
        }

        #expect(requests.count(path: Self.planPath) == 5)
        #expect(requests.count(path: Self.metaPath) == 0)
    }

    /// "…and on any `410`." One refusal on an ordinary route, one meta call behind it.
    ///
    /// **And the meta call's own `410` starts nothing further**, which is the property that keeps
    /// this from being an infinite regress: §8.3 requires the gate to refuse `/v1/meta` too, so a
    /// walled-off build gets a refusal there every time. Two requests in total, not two hundred.
    @Test
    @MainActor
    func aRefusalTriggersExactlyOneMetaCallAndTheMetaCallsOwnRefusalTriggersNone() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        let requests = RecordedRequests()
        fixture.register { [self] request in
            requests.record(request)
            return walledOff(upgradeURL: "https://sonny.example.com/download")
        }

        await #expect(throws: SonnyBackendError.self) {
            _ = try await fixture.client.send(planRequest())
        }

        #expect(requests.count(path: Self.planPath) == 1)
        #expect(requests.count(path: Self.metaPath) == 1)
        #expect(requests.recorded.count == 2)
    }

    /// **The arm of the reentrancy guard a battery can reach.** Two callers at once make one
    /// request, which is the same flag that keeps a `410` on the meta request itself from starting
    /// another fetch — and unlike that arm, deleting this one produces a second request rather than
    /// a hang, so it is a property a mutant can be measured against.
    @Test
    @MainActor
    func twoCallersAtOnceMakeOneRequest() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        let requests = RecordedRequests()
        fixture.register { request in
            requests.record(request)
            return .reply(statusCode: 200, headers: [:], body: SonnyBackendFixtures.metaDocumentJSON())
        }

        async let first = fixture.client.refreshMetaDocument()
        async let second = fixture.client.refreshMetaDocument()
        _ = await (first, second)

        #expect(requests.count(path: Self.metaPath) == 1)
    }

    /// Ten concurrent refusals cause one meta fetch, not ten — the single-flight shape the token
    /// refresh already uses, and for the same reason: a walled-off client's requests all fail at
    /// once, and one fetch per failure would be a burst answering one question.
    @Test
    @MainActor
    func concurrentRefusalsCauseOneMetaFetch() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        let requests = RecordedRequests()
        fixture.register { [self] request in
            requests.record(request)
            return walledOff(upgradeURL: "https://sonny.example.com/download")
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { _ = try? await fixture.client.send(self.planRequest()) }
            }
        }

        #expect(requests.count(path: Self.planPath) == 10)
        #expect(requests.count(path: Self.metaPath) < 10)
        #expect(requests.count(path: Self.metaPath) >= 1)
    }

    // MARK: - §8.3: the wall

    @Test
    @MainActor
    func aRefusalPutsTheClientBehindTheWallWithTheLinkTheRefusalCarried() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        fixture.register { [self] _ in walledOff(upgradeURL: "https://sonny.example.com/download") }

        _ = try? await fixture.client.send(planRequest())

        let state = await fixture.client.clientVersionState()
        #expect(state == .tooOld(link: URL(string: "https://sonny.example.com/download")))
    }

    /// **A link the app will not open leaves the state with none, and the message still shows.**
    /// The founder's decision of 2026-09-04, at the level the decision is actually enforced: the
    /// scheme check runs where the value enters, so nothing downstream has to remember it.
    @Test(arguments: ["file:///Applications/Evil.app", "javascript:alert(1)", "sonny://update"])
    @MainActor
    func aRefusalCarryingALinkTheAppWillNotOpenLeavesNoLink(raw: String) async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        fixture.register { [self] _ in walledOff(upgradeURL: raw) }

        _ = try? await fixture.client.send(planRequest())

        #expect(await fixture.client.clientVersionState() == .tooOld(link: nil))
    }

    /// The refusal carried nothing usable, so the kept document answers — which is what §8.3's
    /// launch call buys beyond the refusal's own body.
    ///
    /// **The sequence is the realistic one and it has to be**: this app launched while the
    /// deployment still served it, so the document was read and kept; a founder then raised
    /// `MINIMUM_SUPPORTED_CLIENT` past it, and every route — `/v1/meta` included, which §8.3
    /// requires — has refused since. A fixture serving `/v1/meta` a `200` beside a `410` elsewhere
    /// would be testing a gateway that cannot exist: the version gate is registered on the root
    /// instance and covers every route, so a served `200` is proof this build is above the minimum
    /// and the wall would rightly come down.
    @Test
    @MainActor
    func theKeptDocumentSuppliesTheLinkWhenTheRefusalDoesNot() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        let stillServesThisBuild = ResettableSwitch(isOn: true)
        fixture.register { _ in
            stillServesThisBuild.isOn
                ? .reply(
                    statusCode: 200,
                    headers: [:],
                    body: SonnyBackendFixtures.metaDocumentJSON(
                        upgradeURL: "https://sonny.example.com/from-meta"
                    )
                )
                : .reply(
                    statusCode: 410,
                    headers: [:],
                    // No `upgrade_url` in the body, which is the case this test is about.
                    body: SonnyBackendFixtures.errorEnvelopeJSON(code: "version.unsupported")
                )
        }

        let document = try #require(await fixture.client.refreshMetaDocument())
        #expect(document.upgradeURL == "https://sonny.example.com/from-meta")

        stillServesThisBuild.isOn = false
        _ = try? await fixture.client.send(planRequest())

        #expect(
            await fixture.client.clientVersionState()
                == .tooOld(link: URL(string: "https://sonny.example.com/from-meta"))
        )
        // And the document survived the refusal that followed it.
        #expect(await fixture.client.metaDocument() == document)
    }

    /// A failed meta fetch keeps the document already held rather than clearing it — the refusal
    /// that most often ends that call is the `410` it was started by, and there is nothing for a
    /// cleared document to add.
    @Test
    @MainActor
    func aFailedMetaFetchKeepsTheDocumentAlreadyHeld() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        let servesDocument = OneShotSwitch()
        fixture.register { _ in
            if servesDocument.takeIfArmed() {
                return .reply(statusCode: 200, headers: [:], body: SonnyBackendFixtures.metaDocumentJSON())
            }
            return .reply(statusCode: 503, headers: [:], body: Data("nonsense".utf8))
        }

        let first = try #require(await fixture.client.refreshMetaDocument())
        let second = await fixture.client.refreshMetaDocument()

        #expect(second == first)
    }

    // MARK: - §8.4: the warning

    @Test
    @MainActor
    func theTwoDeprecationHeadersAreReadOnASuccessfulResponse() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        fixture.register { _ in
            .reply(
                statusCode: 200,
                headers: [
                    "Sonny-Deprecation": "true",
                    "Sonny-Deprecation-Info": "https://sonny.example.com/upgrade"
                ],
                body: Data("{}".utf8)
            )
        }

        _ = try await fixture.client.send(planRequest())

        #expect(
            await fixture.client.clientVersionState()
                == .updateAvailable(link: URL(string: "https://sonny.example.com/upgrade"))
        )
    }

    /// §8.4 says "on every response", and the gateway sets them in `onRequest` precisely so they
    /// reach a reply no route handler produced — a `401` from the auth gate, a `404`, a `413`.
    @Test
    @MainActor
    func theHeadersAreReadOnAResponseThatFailed() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        fixture.register { _ in
            .reply(
                statusCode: 404,
                headers: [
                    "Sonny-Deprecation": "true",
                    "Sonny-Deprecation-Info": "https://sonny.example.com/upgrade"
                ],
                body: SonnyBackendFixtures.errorEnvelopeJSON(code: "resource.not_found")
            )
        }

        _ = try? await fixture.client.send(planRequest())

        #expect(
            await fixture.client.clientVersionState()
                == .updateAvailable(link: URL(string: "https://sonny.example.com/upgrade"))
        )
    }

    /// Only `true` is believed. A header this client cannot read says nothing, which is the same
    /// direction §8.3 takes with an unreadable `Sonny-Client-Version` on the other side.
    @Test(arguments: ["false", "1", "yes", "", "TRUE-ish"])
    @MainActor
    func anythingButTrueIsNotADeprecation(flag: String) async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        fixture.register { _ in
            .reply(statusCode: 200, headers: ["Sonny-Deprecation": flag], body: Data("{}".utf8))
        }

        _ = try await fixture.client.send(planRequest())

        #expect(await fixture.client.clientVersionState() == .current)
    }

    /// Case and surrounding whitespace are not what this is about — a proxy that normalises a header
    /// value must not switch the warning off.
    @Test(arguments: ["true", "TRUE", " True "])
    @MainActor
    func theFlagIsReadWithoutCaringAboutCaseOrPadding(flag: String) async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        fixture.register { _ in
            .reply(statusCode: 200, headers: ["Sonny-Deprecation": flag], body: Data("{}".utf8))
        }

        _ = try await fixture.client.send(planRequest())

        #expect(await fixture.client.clientVersionState() == .updateAvailable(link: nil))
    }

    // MARK: - How the states clear, and how they must not

    /// A served response is proof from the deciding party that this build is at or above both
    /// bounds, so it is the one thing that takes the wall down — an operator who lowers the minimum
    /// is believed on the next successful request rather than at the next launch.
    @Test
    @MainActor
    func aServedResponseWithNoHeaderClearsBothStates() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        let refuses = ResettableSwitch(isOn: true)
        fixture.register { [self] _ in
            refuses.isOn
                ? walledOff(upgradeURL: "https://sonny.example.com/download")
                : .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        _ = try? await fixture.client.send(planRequest())
        #expect(await fixture.client.clientVersionState() != .current)

        refuses.isOn = false
        _ = try await fixture.client.send(planRequest())

        #expect(await fixture.client.clientVersionState() == .current)
    }

    /// A `500` from the gateway, or a `503` from a load balancer in front of it, says nothing at all
    /// about which builds this deployment serves. Reading that silence as "current" would clear a
    /// warning on a bad gateway day.
    @Test
    @MainActor
    func aFailingResponseWithNoHeaderChangesNothing() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        let deprecates = ResettableSwitch(isOn: true)
        fixture.register { _ in
            deprecates.isOn
                ? .reply(statusCode: 200, headers: ["Sonny-Deprecation": "true"], body: Data("{}".utf8))
                : .reply(
                    statusCode: 503,
                    headers: [:],
                    body: SonnyBackendFixtures.errorEnvelopeJSON(code: "server.unavailable")
                )
        }

        _ = try await fixture.client.send(planRequest())
        #expect(await fixture.client.clientVersionState() == .updateAvailable(link: nil))

        deprecates.isOn = false
        _ = try? await fixture.client.send(planRequest())

        #expect(await fixture.client.clientVersionState() == .updateAvailable(link: nil))
    }

    /// **§8.4's own rollback: the minimum lowered to at or below this build, the recommendation left
    /// above it — so every response is served *and* carries the header, and the wall comes down to
    /// the warning without the app being quit** (PR #202's review, F1).
    ///
    /// This is the sequence the ladder prescribes for a minimum armed too aggressively, and it is
    /// what the two manual rows walk through. Before the fix the deprecation branch returned on any
    /// response carrying the header while the state was `.tooOld`, so the served-`2xx` rule beneath
    /// it was never reached and there was no header-free `2xx` in this configuration for it to fire
    /// on: a running client stayed walled off, with no dismiss control, until it was quit.
    ///
    /// **Not `.current`, and that is the point of landing on the warning rather than clearing.** The
    /// served response says this build is at or above the minimum; the header says it is still below
    /// the recommendation. Both facts are true at once and the state has to carry both.
    @Test
    @MainActor
    func aServedResponseCarryingTheHeaderTakesTheWallDownToTheWarning() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        let refuses = ResettableSwitch(isOn: true)
        fixture.register { [self] _ in
            refuses.isOn
                ? walledOff(upgradeURL: "https://sonny.example.com/download")
                : .reply(
                    statusCode: 200,
                    headers: [
                        "Sonny-Deprecation": "true",
                        "Sonny-Deprecation-Info": "https://sonny.example.com/upgrade"
                    ],
                    body: Data("{}".utf8)
                )
        }

        _ = try? await fixture.client.send(planRequest())
        #expect(
            await fixture.client.clientVersionState()
                == .tooOld(link: URL(string: "https://sonny.example.com/download")),
            "precondition: the wall has to be up before this test says anything"
        )

        // The operator lowers the minimum to at or below this build and leaves the recommendation
        // above it. Nothing relaunches; the next request is simply served.
        refuses.isOn = false
        _ = try await fixture.client.send(planRequest())

        #expect(
            await fixture.client.clientVersionState()
                == .updateAvailable(link: URL(string: "https://sonny.example.com/upgrade"))
        )
    }

    /// **The four cases the status code and the header make between them, in one table.**
    ///
    /// Written as one parameterized test rather than four because the property is the *pair*: what
    /// decides is the status code, and the header only says which of the two served states it is.
    /// Four separate tests would each pass against a rule that got the pairing wrong in the other
    /// direction, which is how the defect above survived — three of these four were covered and the
    /// fourth was the one the ladder needs.
    @Test(arguments: [
        // Served, header present: the wall comes down to the warning. §8.4's rollback.
        (200, true, ClientVersionState.updateAvailable(link: URL(string: "https://sonny.example.com/upgrade"))),
        // Served, no header: the wall comes down completely.
        (200, false, ClientVersionState.current),
        // Failing, header present: a proxy must not be able to lower the wall, so nothing moves.
        (503, true, ClientVersionState.tooOld(link: URL(string: "https://sonny.example.com/download"))),
        // Failing, no header: says nothing about which builds this deployment serves.
        (503, false, ClientVersionState.tooOld(link: URL(string: "https://sonny.example.com/download")))
    ])
    @MainActor
    func whatOneResponseDoesToAStandingWall(
        statusCode: Int,
        carriesHeader: Bool,
        expected: ClientVersionState
    ) async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        let refuses = ResettableSwitch(isOn: true)
        fixture.register { [self] _ in
            guard !refuses.isOn else { return walledOff(upgradeURL: "https://sonny.example.com/download") }
            let headers = carriesHeader
                ? [
                    "Sonny-Deprecation": "true",
                    "Sonny-Deprecation-Info": "https://sonny.example.com/upgrade"
                  ]
                : [:]
            let body = (200..<300).contains(statusCode)
                ? Data("{}".utf8)
                : SonnyBackendFixtures.errorEnvelopeJSON(code: "server.unavailable")
            return .reply(statusCode: statusCode, headers: headers, body: body)
        }

        _ = try? await fixture.client.send(planRequest())
        let wall = await fixture.client.clientVersionState()
        #expect(
            wall == .tooOld(link: URL(string: "https://sonny.example.com/download")),
            "precondition: the wall has to be up, and it is \(wall)"
        )

        refuses.isOn = false
        _ = try? await fixture.client.send(planRequest())

        #expect(await fixture.client.clientVersionState() == expected)
    }

    /// **A warning cannot lower a wall — on a response that failed.** The gate returns before setting
    /// those headers for an unsupported client, so this pairing cannot come from the gateway; a proxy
    /// in front of it can produce very nearly anything, and turning "nothing works" into "update when
    /// you can" on the strength of a header alone is the direction that must not be reachable.
    ///
    /// **What bounds the proxy is the status code, which is why a served `2xx` carrying the same
    /// header does lower it** — see the test above. Forging a `2xx` is forging the gateway's answer,
    /// and a client that will not believe a served response has no way to be told anything at all.
    @Test
    @MainActor
    func aDeprecationHeaderCannotTakeTheWallDown() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        let refuses = ResettableSwitch(isOn: true)
        fixture.register { [self] _ in
            refuses.isOn
                ? walledOff(upgradeURL: "https://sonny.example.com/download")
                : .reply(
                    statusCode: 502,
                    headers: [
                        "Sonny-Deprecation": "true",
                        "Sonny-Deprecation-Info": "https://sonny.example.com/upgrade"
                    ],
                    body: SonnyBackendFixtures.errorEnvelopeJSON(code: "provider.unavailable")
                )
        }

        _ = try? await fixture.client.send(planRequest())
        #expect(await fixture.client.clientVersionState() != .current)

        refuses.isOn = false
        _ = try? await fixture.client.send(planRequest())

        #expect(
            await fixture.client.clientVersionState()
                == .tooOld(link: URL(string: "https://sonny.example.com/download"))
        )
    }

    // MARK: - How it leaves the client

    /// The stream opens with what the client already holds, so a surface that starts observing after
    /// the launch fetch is late rather than wrong.
    @Test
    @MainActor
    func theStreamDeliversTheStateAlreadyHeldBeforeAnyChange() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        fixture.register { [self] _ in walledOff(upgradeURL: "https://sonny.example.com/download") }

        _ = try? await fixture.client.send(planRequest())

        // Collected under a backstop rather than read with a bare `await next()`, for the reason the
        // test below now carries: a stream that stops yielding does not end, so an unbounded read is
        // a test whose failure signal is a hang. Nothing in this plan makes the first element go
        // missing, and it is written this way anyway — the point of that rule is that the next
        // mutant is the one nobody predicted.
        let collected = CollectedVersionStates()
        let stream = await fixture.client.clientVersionUpdates()
        let collector = Task { for await state in stream { collected.record(state) } }
        defer { collector.cancel() }

        try await HangBackstop.waitOrAbandon(for: "the stream to open with the state already held") {
            !collected.recorded.isEmpty
        }
        #expect(collected.recorded.first == .tooOld(link: URL(string: "https://sonny.example.com/download")))
    }

    /// And then every change, once — a repeat of the same state yields nothing, or a surface
    /// observing a healthy deployment would be woken on every single response.
    ///
    /// **Collected by a task under a backstop rather than read with a bare `await next()`, and that
    /// is a correction rather than a style** (found by this branch's own battery). An `AsyncStream`
    /// that stops yielding does not end, so `await iterator.next()` on a tree where the change never
    /// happens suspends forever: the mutant that stops the deprecation header being read hung this
    /// test, and with it the whole battery, at 0.0% CPU. A test whose failure signal is a hang
    /// cannot be measured — `CLAUDE.md` records that class, and this is an instance of it.
    ///
    /// The mutant is still caught, by the four tests above that read `clientVersionState()`
    /// directly, so the backstop here is a precondition rather than the assertion — which is the
    /// shape SONNY-259's rule asks for.
    @Test
    @MainActor
    func theStreamCarriesEachChangeOnceAndRepeatsNothing() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        let deprecates = ResettableSwitch(isOn: false)
        fixture.register { _ in
            deprecates.isOn
                ? .reply(statusCode: 200, headers: ["Sonny-Deprecation": "true"], body: Data("{}".utf8))
                : .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        let collected = CollectedVersionStates()
        let stream = await fixture.client.clientVersionUpdates()
        let collector = Task { for await state in stream { collected.record(state) } }
        defer { collector.cancel() }

        // Two identical healthy responses, then two identical deprecated ones. The stream should
        // carry exactly one element for the change, and nothing for the repeats.
        _ = try await fixture.client.send(planRequest())
        _ = try await fixture.client.send(planRequest())
        deprecates.isOn = true
        _ = try await fixture.client.send(planRequest())
        _ = try await fixture.client.send(planRequest())

        try await HangBackstop.waitOrAbandon(for: "the stream to carry the change") {
            collected.recorded.count >= 2
        }
        #expect(collected.recorded == [.current, .updateAvailable(link: nil)])
    }
}

/// Every state the stream carried, in order. Lock-guarded because the collecting task and the
/// asserting body are different tasks.
private final class CollectedVersionStates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ClientVersionState] = []

    var recorded: [ClientVersionState] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ state: ClientVersionState) {
        lock.lock()
        values.append(state)
        lock.unlock()
    }
}

/// A flag a stub handler can flip from the test body. `@unchecked Sendable` with a lock, the same
/// shape `RecordedRequests` uses and for the same reason: the handler runs on `URLSession`'s own
/// threads.
private final class ResettableSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(isOn: Bool) {
        value = isOn
    }

    var isOn: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

/// True exactly once, for a handler that must answer differently the first time it is asked.
private final class OneShotSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var spent = false

    func takeIfArmed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if spent { return false }
        spent = true
        return true
    }
}
