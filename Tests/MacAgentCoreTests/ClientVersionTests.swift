import Foundation
import Testing
@testable import MacAgentCore

/// Contract §8's client half, at the level where it is pure values (SONNY-402).
///
/// `ClientVersionClientTests` holds what the backend client derives from real responses; this holds
/// the three things underneath it — which server-supplied strings become links, what a `/v1/meta`
/// document decodes to, and what the two surfaces are told to say.
@Suite
struct ClientVersionTests {
    // MARK: - The link (founder decision, 2026-09-04)

    /// The whole of the decision: `http` or `https` opens, everything else does not.
    ///
    /// **The rejections matter more than the acceptances.** This value ends at `NSWorkspace.open`,
    /// and the schemes below are the ones a compromised or misconfigured deployment would reach for
    /// — `file:` to open something on the user's disk, `javascript:` because a browser will run it,
    /// and a custom scheme because it launches whatever app claimed it.
    @Test(arguments: [
        "https://sonny.example.com/download",
        "http://sonny.example.com/download",
        "HTTPS://SONNY.EXAMPLE.COM/download",
        "  https://sonny.example.com/download  ",
        // Deliberately accepted, and it is the difference from `SafeURL.validateWebURL`: a founder's
        // manual pass points at a locally configured gateway, whose `UPGRADE_URL` is very often a
        // loopback or LAN address. That function refuses those because its subject is a URL Sonny
        // itself would fetch; this one is going to the user's browser at the user's press.
        "http://localhost:8080/download",
        "http://192.168.1.20:3000/download"
    ])
    func aWebLinkIsOpenable(raw: String) {
        #expect(ClientUpgradeLink.openable(raw) != nil, "\(raw) should be openable")
    }

    @Test(arguments: [
        "file:///Applications/Something.app",
        "javascript:alert(1)",
        "ftp://sonny.example.com/download",
        "sonny://update",
        "mailto:someone@example.com",
        "data:text/html,<h1>hi</h1>",
        // Scheme and no host: `NSWorkspace.open` on this opens nothing, so a button for it is a
        // control that does nothing rather than a link.
        "https://",
        "not a url at all",
        "",
        "   "
    ])
    func anythingElseIsNotOpenable(raw: String) {
        #expect(ClientUpgradeLink.openable(raw) == nil, "\(raw) should not be openable")
    }

    @Test
    func anAbsentLinkIsNotOpenable() {
        #expect(ClientUpgradeLink.openable(nil) == nil)
    }

    @Test
    func anOpenableLinkKeepsTheAddressItWasGiven() throws {
        let url = try #require(ClientUpgradeLink.openable("https://sonny.example.com/download?v=2"))
        #expect(url.absoluteString == "https://sonny.example.com/download?v=2")
    }

    // MARK: - The meta document (§8.3)

    @Test
    func theMetaDocumentDecodesEveryFieldTheContractPublishes() throws {
        let data = Data("""
        {
          "api_version": "1.0",
          "minimum_supported_client": "1.2.0",
          "recommended_client": "1.4.0",
          "upgrade_url": "https://sonny.example.com/download",
          "server_time": "2026-09-04T09:41:07Z",
          "entitlement_keys": [{"kid": "k1", "alg": "EdDSA", "public_key": "abc"}]
        }
        """.utf8)

        let document = try #require(SonnyMetaDocument.decode(data))
        #expect(document.apiVersion == "1.0")
        #expect(document.minimumSupportedClient == "1.2.0")
        #expect(document.recommendedClient == "1.4.0")
        #expect(document.upgradeURL == "https://sonny.example.com/download")
        // Against a parsed reference rather than an epoch literal: the value under test is that the
        // field is read through the same RFC 3339 parser the rest of this client uses, and a
        // hand-computed number is a second, worse implementation of that parser sitting in a test.
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-09-04T09:41:07Z"))
        #expect(document.serverTime == expected)
    }

    /// §2.1: a client ignores response fields it does not know, so a document that gained one is
    /// still this document. The key set is *deliberately* not decoded here — `EntitlementKeys` owns
    /// which key verifies a claim, and a second reader would be a second answer.
    @Test
    func anUnknownFieldDoesNotStopTheDocumentDecoding() throws {
        let data = Data("""
        {
          "api_version": "1.1",
          "minimum_supported_client": "1.0.0",
          "recommended_client": "1.0.0",
          "upgrade_url": "https://sonny.example.com/download",
          "server_time": "2026-09-04T09:41:07Z",
          "something_added_in_a_later_version": {"nested": true}
        }
        """.utf8)

        let document = try #require(SonnyMetaDocument.decode(data))
        #expect(document.apiVersion == "1.1")
    }

    @Test
    func theTwoOptionalFieldsMayBeAbsent() throws {
        let data = Data("""
        {"api_version": "1.0", "minimum_supported_client": "1.0.0", "recommended_client": "1.0.0"}
        """.utf8)

        let document = try #require(SonnyMetaDocument.decode(data))
        #expect(document.upgradeURL == nil)
        #expect(document.serverTime == nil)
    }

    /// §8.3's own premise is a client that predates whatever changed, so a document whose shape has
    /// moved past this build is an expected outcome rather than an error — and the caller's rule for
    /// it is to keep whatever it already had, which needs this to answer `nil` rather than throw.
    @Test(arguments: [
        "{}",
        "{\"api_version\": \"1.0\"}",
        "not json at all",
        "[]"
    ])
    func bytesThatAreNotTheContractsDocumentDecodeToNothing(raw: String) {
        #expect(SonnyMetaDocument.decode(Data(raw.utf8)) == nil)
    }

    // MARK: - The state

    @Test
    func onlyTheCurrentStateHasNothingToSay() {
        #expect(ClientVersionState.current.isSomethingToSay == false)
        #expect(ClientVersionState.updateAvailable(link: nil).isSomethingToSay)
        #expect(ClientVersionState.tooOld(link: nil).isSomethingToSay)
        #expect(ClientVersionState.current.link == nil)
    }

    // MARK: - The words

    @Test
    func theCurrentStateRendersNoPrompt() {
        #expect(ClientVersionCopy.prompt(for: .current) == nil)
    }

    /// The founder's decision of 2026-09-04, as the surfaces read it: a button when the link parses,
    /// and the message with no button when it does not.
    @Test
    func theUpdateControlIsOfferedExactlyWhenThereIsALinkToOpen() throws {
        let link = try #require(ClientUpgradeLink.openable("https://sonny.example.com/download"))

        let walled = try #require(ClientVersionCopy.prompt(for: .tooOld(link: link)))
        #expect(walled.updateLabel == "Update Sonny")
        #expect(walled.link == link)

        let walledWithoutLink = try #require(ClientVersionCopy.prompt(for: .tooOld(link: nil)))
        #expect(walledWithoutLink.updateLabel == nil)
        #expect(walledWithoutLink.link == nil)
        #expect(walledWithoutLink.message == ClientVersionCopy.tooOldMessage)

        let warned = try #require(ClientVersionCopy.prompt(for: .updateAvailable(link: link)))
        #expect(warned.updateLabel == "Update Sonny")

        let warnedWithoutLink = try #require(ClientVersionCopy.prompt(for: .updateAvailable(link: nil)))
        #expect(warnedWithoutLink.updateLabel == nil)
    }

    /// The wall has no way out but updating; the warning has to be dismissible or it is a permanent
    /// occupant of both surfaces for as long as the deprecation band lasts.
    @Test
    func onlyTheWarningCanBeWavedAway() throws {
        let walled = try #require(ClientVersionCopy.prompt(for: .tooOld(link: nil)))
        #expect(walled.dismissLabel == nil)

        let warned = try #require(ClientVersionCopy.prompt(for: .updateAvailable(link: nil)))
        #expect(warned.dismissLabel == "Not now")
    }

    @Test
    func theTwoStatesSayDifferentThings() throws {
        let walled = try #require(ClientVersionCopy.prompt(for: .tooOld(link: nil)))
        let warned = try #require(ClientVersionCopy.prompt(for: .updateAvailable(link: nil)))

        #expect(walled.title != warned.title)
        #expect(walled.message != warned.message)
        #expect(walled.title == "Update needed")
        #expect(walled.message == "This version of Sonny is too old. Update to carry on.")
        #expect(warned.title == "Update available")
        #expect(warned.message == "A new version of Sonny is out.")
    }

    /// The founder's standing copy rule, applied to this state's five strings: functional labels,
    /// no explanation, nothing about servers or versions-as-a-concept, and never the server's own
    /// sentence.
    @Test
    func noVersionSentenceExplainsHowSonnyWorksOrRepeatsTheServers() {
        let everySentence = [
            ClientVersionCopy.tooOldTitle,
            ClientVersionCopy.tooOldMessage,
            ClientVersionCopy.updateAvailableTitle,
            ClientVersionCopy.updateAvailableMessage,
            ClientVersionCopy.updateLabel,
            ClientVersionCopy.dismissLabel
        ]
        // The gateway's own refusal, verbatim from `server/src/version/gate.ts`. §7.1 makes it a
        // sentence the client never displays.
        let serverSentence = "This client is older than the minimum supported version"
        let banned = [
            "410", "HTTP", "gateway", "server", "endpoint", "API", "minimum", "supported version",
            "Error", "token", "JSON"
        ]
        for sentence in everySentence {
            #expect(!sentence.contains(serverSentence), "\"\(sentence)\" repeats the server's message")
            for word in banned {
                #expect(!sentence.contains(word), "\"\(sentence)\" contains \(word)")
            }
            #expect(sentence.count <= 90, "\"\(sentence)\" is \(sentence.count) characters")
            #expect(sentence == sentence.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        #expect(Set(everySentence).count == everySentence.count, "two of the six say the same thing")
    }

    // MARK: - The wire code stops being unmapped

    /// `version.unsupported` reached `.unexpected` before this ticket — "Sonny couldn't finish
    /// signing you in. Try again." — which invites a retry of the one refusal §9.3 defines as
    /// permanent. It is reachable on the sign-in routes because `server/src/version/gate.ts` is
    /// registered before the auth gate and covers every route.
    @Test
    func aTooOldBuildIsToldSoRatherThanToldToTryAgain() {
        let error = SonnyBackendError.api(SonnyBackendAPIError(
            code: SonnyBackendErrorCode(wire: "version.unsupported"),
            statusCode: 410,
            message: "This client is older than the minimum supported version 2.0.0.",
            requestID: "req_1",
            retryAfter: nil,
            envelopeSaysRetryable: false,
            upgradeURL: "https://sonny.example.com/download"
        ))

        #expect(SignInFailure(error) == .updateRequired)
        #expect(SignInCopy.message(for: .updateRequired) == ClientVersionCopy.tooOldMessage)
        #expect(!SignInCopy.message(for: .updateRequired).contains("Try again"))
        // The four model routes meet the same refusal and must not say something different about it.
        #expect(SonnyBackendCopy.sentence(for: error) == ClientVersionCopy.tooOldMessage)
    }

    /// The envelope's own new field, on the one code that carries it and absent everywhere else.
    @Test
    func theUpgradeURLIsDecodedFromTheRefusalItArrivesOn() {
        let walled = SonnyBackendClient.errorEnvelope(
            SonnyBackendFixtures.errorEnvelopeJSON(
                code: "version.unsupported",
                upgradeURL: "https://sonny.example.com/download"
            ),
            statusCode: 410,
            headerRequestID: nil,
            retryAfterHeader: nil
        )
        #expect(walled.code == .versionUnsupported)
        #expect(walled.upgradeURL == "https://sonny.example.com/download")

        let ordinary = SonnyBackendClient.errorEnvelope(
            SonnyBackendFixtures.errorEnvelopeJSON(code: "server.error"),
            statusCode: 500,
            headerRequestID: nil,
            retryAfterHeader: nil
        )
        #expect(ordinary.upgradeURL == nil)
    }
}
