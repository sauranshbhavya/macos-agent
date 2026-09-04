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

    /// **A warning cannot lower a wall.** The gate returns before setting those headers for an
    /// unsupported client, so this pairing cannot come from the gateway — but a proxy in front of it
    /// can produce very nearly anything, and turning "nothing works" into "update when you can" is
    /// the one direction that must not be reachable.
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

        var iterator = await fixture.client.clientVersionUpdates().makeAsyncIterator()
        let first = await iterator.next()

        #expect(first == .tooOld(link: URL(string: "https://sonny.example.com/download")))
    }

    /// And then every change, once — a repeat of the same state yields nothing, or a surface
    /// observing a healthy deployment would be woken on every single response.
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

        var iterator = await fixture.client.clientVersionUpdates().makeAsyncIterator()
        #expect(await iterator.next() == .current)

        // Two identical healthy responses, then two identical deprecated ones. The stream should
        // carry exactly one element for the change, and nothing for the repeats.
        _ = try await fixture.client.send(planRequest())
        _ = try await fixture.client.send(planRequest())
        deprecates.isOn = true
        _ = try await fixture.client.send(planRequest())
        _ = try await fixture.client.send(planRequest())

        #expect(await iterator.next() == .updateAvailable(link: nil))
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
