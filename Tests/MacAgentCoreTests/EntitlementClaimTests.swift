import Foundation
import Testing
@testable import MacAgentCore

/// Verifying a signed entitlement claim, and refusing every way one can be wrong (SONNY-135).
///
/// **The fixture at the top is a claim the real gateway signed**, produced by
/// `server/src/entitlement/claim.ts` running under node, and committed with the public half of the
/// key that signed it. That makes this the one test in either half that proves the two languages
/// agree: a TypeScript signer's bytes verified by a Swift `CryptoKit` verifier, with no server
/// running and no network. Everything else here is a forgery derived from it.
@Suite
struct EntitlementClaimTests {
    /// A claim the gateway signed, and the public key it signed with.
    ///
    /// **Committed rather than generated, and it is safe to commit for a reason worth being explicit
    /// about**: this is a *public* key and a *signed statement*. It grants nothing — the private half
    /// was generated for this one command and discarded, the subject is synthetic, and the claim
    /// expired on 2026-08-29. Its only power is to be verified.
    ///
    /// Reproduce it (the private key is new every run, so the strings will differ and the *shape*
    /// will not):
    ///
    ///     cd server && npm run build && node --input-type=module -e "
    ///     import { generateKeyPairSync } from 'node:crypto';
    ///     import { mintEntitlementClaim, entitlementSigningKeyFrom, publicKeyMaterial }
    ///       from './dist/entitlement/claim.js';
    ///     const der = generateKeyPairSync('ed25519').privateKey
    ///       .export({type:'pkcs8',format:'der'}).toString('base64');
    ///     const key = entitlementSigningKeyFrom(der, 'golden-1');
    ///     const claim = mintEntitlementClaim(
    ///       { subject: 'golden-user', plan: 'golden-plan', capabilities: ['golden.capability'] },
    ///       key, new Date('2026-08-28T09:00:00Z'));
    ///     console.log(publicKeyMaterial(key)); console.log(claim.entitlement);"
    static let goldenPublicKey = "m1Wqrrf1k485_34Ub805LvnNTbT7SNNE898gB4ZRg00"
    static let goldenClaim = "eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCIsImtpZCI6ImdvbGRlbi0xIn0."
        + "eyJ2IjoxLCJzdWIiOiJnb2xkZW4tdXNlciIsInBsYW4iOiJnb2xkZW4tcGxhbiIsImNhcGFiaWxpdGllcyI6WyJnb2"
        + "xkZW4uY2FwYWJpbGl0eSJdLCJpc3N1ZWRfYXQiOiIyMDI2LTA4LTI4VDA5OjAwOjAwWiIsImV4cGlyZXNfYXQiOiIy"
        + "MDI2LTA4LTI5VDA5OjAwOjAwWiIsImdyYWNlX3NlY29uZHMiOjI1OTIwMCwic2tld190b2xlcmFuY2Vfc2Vjb25kcy"
        + "I6MzAwfQ._WLOmVAq49absR7UNDlLA2hJei0l0ib958qylJzlIiGoegt2CaayusK4Var8BvNBxhl9fmbvlTH8Kl8Ng"
        + "3HLCA"

    static var goldenKeys: EntitlementKeySet {
        EntitlementKeySet.parsing(["golden-1:\(goldenPublicKey)"])
    }

    // MARK: - The claim the gateway actually signs

    @Test
    func aClaimTheGatewaySignedVerifiesOnThisMacWithNoNetworkAndNoSecret() throws {
        let verdict = EntitlementVerifier.verify(Self.goldenClaim, against: Self.goldenKeys)
        guard case .success(let claim) = verdict else {
            Issue.record("the gateway's own claim did not verify: \(verdict)")
            return
        }
        #expect(claim.version == 1)
        #expect(claim.subject == "golden-user")
        #expect(claim.plan == "golden-plan")
        #expect(claim.capabilities == ["golden.capability"])
        #expect(claim.issuedAt == SonnyISO8601.parse("2026-08-28T09:00:00Z"))
        #expect(claim.expiresAt == SonnyISO8601.parse("2026-08-29T09:00:00Z"))
        // The two values contract §13 assigns to this ticket, as the gateway sets them.
        #expect(claim.graceSeconds == 259_200)
        #expect(claim.skewToleranceSeconds == 300)
        #expect(claim.grants(EntitlementCapability("golden.capability")))
        #expect(!claim.grants(EntitlementCapability("something.else")))
    }

    // MARK: - Forgeries

    @Test
    func aClaimSignedByAnotherKeyIsRefused() throws {
        // The signature is well-formed and verifies against *a* key — just not this one. A verifier
        // that checked shape and not signature would accept it.
        let other = EntitlementKeySet.parsing([
            "golden-1:\(Base64URL.encode(Data(repeating: 7, count: 32)))"
        ])
        #expect(EntitlementVerifier.verify(Self.goldenClaim, against: other).failure == .signature)
    }

    @Test
    func aTamperedPayloadIsRefused() throws {
        // One capability added to the payload and everything else left alone — the forgery that
        // matters, because it is the one that would grant something.
        let segments = Self.goldenClaim.split(separator: ".").map(String.init)
        let original = try #require(Base64URL.decode(segments[1]))
        var payload = try #require(
            try JSONSerialization.jsonObject(with: original) as? [String: Any]
        )
        payload["capabilities"] = ["golden.capability", "everything"]
        let forged = Base64URL.encode(try JSONSerialization.data(withJSONObject: payload))
        let claim = "\(segments[0]).\(forged).\(segments[2])"

        #expect(EntitlementVerifier.verify(claim, against: Self.goldenKeys).failure == .signature)
    }

    @Test
    func aTamperedHeaderIsRefused() throws {
        // Re-encoding the header without changing it would still change the signed input if the
        // encoding differed, so the forgery here changes a value: the `kid` is pointed at the key
        // this build holds while the signature stays the original's.
        let segments = Self.goldenClaim.split(separator: ".").map(String.init)
        let header = Base64URL.encode(Data(#"{"alg":"EdDSA","typ":"JWT","kid":"golden-1","x":1}"#.utf8))
        let claim = "\(header).\(segments[1]).\(segments[2])"
        #expect(EntitlementVerifier.verify(claim, against: Self.goldenKeys).failure == .signature)
    }

    @Test
    func anAlgNoneClaimIsRefusedBeforeAnythingReadsItsPayload() throws {
        // The classic. It asks the verifier to skip the check it is being handed, and it arrives in
        // two spellings: `alg: "none"` with an empty signature segment, and a bare `header.payload`.
        let segments = Self.goldenClaim.split(separator: ".").map(String.init)
        let header = Base64URL.encode(Data(#"{"alg":"none","typ":"JWT","kid":"golden-1"}"#.utf8))

        #expect(EntitlementVerifier.verify("\(header).\(segments[1]).", against: Self.goldenKeys).failure
            == .algorithm)
        #expect(EntitlementVerifier.verify("\(header).\(segments[1])", against: Self.goldenKeys).failure
            == .malformed("expected three segments"))
    }

    @Test
    func anAlgorithmConfusionClaimIsRefused() throws {
        // The second classic: a token declaring a different algorithm, hoping the verifier reaches
        // for a different key type or digest than the one it holds. There is no dispatch to steer —
        // the header's `alg` is compared to one literal.
        for algorithm in ["HS256", "RS256", "EdDSA ", "eddsa", "ES256"] {
            let header = Base64URL.encode(
                Data(#"{"alg":"\#(algorithm)","typ":"JWT","kid":"golden-1"}"#.utf8)
            )
            let segments = Self.goldenClaim.split(separator: ".").map(String.init)
            let claim = "\(header).\(segments[1]).\(segments[2])"
            #expect(
                EntitlementVerifier.verify(claim, against: Self.goldenKeys).failure == .algorithm,
                "alg \(algorithm) was not refused"
            )
        }
    }

    @Test
    func aCritHeaderIsRefusedRatherThanIgnored() throws {
        // RFC 7515 §4.1.11: `crit` names header parameters a verifier MUST understand. This one
        // understands no extensions, so any `crit` at all is a refusal rather than something to skip.
        let header = Base64URL.encode(
            Data(#"{"alg":"EdDSA","typ":"JWT","kid":"golden-1","crit":["exp"]}"#.utf8)
        )
        let segments = Self.goldenClaim.split(separator: ".").map(String.init)
        #expect(
            EntitlementVerifier.verify("\(header).\(segments[1]).\(segments[2])", against: Self.goldenKeys)
                .failure == .algorithm
        )
    }

    @Test
    func aClaimNamingAKeyThisBuildDoesNotHoldIsRefused() throws {
        let elsewhere = EntitlementKeySet.parsing(["other-key:\(Self.goldenPublicKey)"])
        #expect(EntitlementVerifier.verify(Self.goldenClaim, against: elsewhere).failure
            == .unknownKey("golden-1"))
    }

    @Test
    func anEmptyKeySetVerifiesNothing() throws {
        // The shipped state of this build: no gateway exists, so no signing key exists, so the key
        // set is empty and every claim is refused. That is the fail-closed direction and it is what
        // `SonnyEntitlementKeys.shipped` is.
        #expect(SonnyEntitlementKeys.shipped.isEmpty)
        #expect(EntitlementVerifier.verify(Self.goldenClaim, against: SonnyEntitlementKeys.shipped)
            .failure == .unknownKey("golden-1"))
    }

    // MARK: - Shapes

    @Test
    func aNonCanonicalEncodingIsRefusedEvenWhenItDecodesToTheSameBytes() throws {
        // The leniency `server/src/auth/token.ts` closes on its side. A permissive decoder ignores
        // characters outside the alphabet, so a segment can be perturbed without changing what it
        // decodes to — which would let two different strings carry one signature.
        let segments = Self.goldenClaim.split(separator: ".").map(String.init)
        #expect(EntitlementVerifier.verify("\(segments[0])*.\(segments[1]).\(segments[2])",
                                           against: Self.goldenKeys).failure == .malformed("header"))
        // A 4n+1 length has a trailing six-bit quantum that cannot form a byte, so there is no
        // padding that makes it valid.
        #expect(Base64URL.decode("eyJhbGciO") == nil)
        // And the round trip is exact for everything that is valid.
        let bytes = Data((0..<64).map { UInt8($0) })
        #expect(Base64URL.decode(Base64URL.encode(bytes)) == bytes)
    }

    @Test
    func aPayloadThisBuildCannotReadIsRefusedRatherThanReadOptimistically() throws {
        // Each case is one field wrong and everything else right, so the refusal is attributable.
        let base: [String: Any] = [
            "v": 1,
            "sub": "golden-user",
            "plan": "golden-plan",
            "capabilities": ["golden.capability"],
            "issued_at": "2026-08-28T09:00:00Z",
            "expires_at": "2026-08-29T09:00:00Z",
            "grace_seconds": 259_200,
            "skew_tolerance_seconds": 300
        ]
        func decode(_ overrides: [String: Any?]) -> EntitlementClaimDecodingError? {
            var payload = base
            for (key, value) in overrides {
                if let value { payload[key] = value } else { payload.removeValue(forKey: key) }
            }
            let bytes = try? JSONSerialization.data(withJSONObject: payload)
            return EntitlementVerifier.decode(bytes ?? Data()).failure
        }

        #expect(decode([:]) == nil, "the baseline payload must decode, or nothing below means anything")
        // A version this build has never heard of is the server saying the shape changed.
        #expect(decode(["v": 2]) == .payload("unsupported version 2"))
        #expect(decode(["sub": ""]) == .payload("sub"))
        #expect(decode(["sub": nil]) == .payload("sub"))
        // A capability list that is not a list of strings is a refusal, not an empty list: the
        // difference decides whether a paying user is told they have no plan or told the claim could
        // not be read, and only the second is true.
        #expect(decode(["capabilities": [1, 2]]) == .payload("capabilities"))
        #expect(decode(["capabilities": "golden.capability"]) == .payload("capabilities"))
        #expect(decode(["expires_at": "not a date"]) == .payload("expires_at"))
        #expect(decode(["issued_at": nil]) == .payload("issued_at"))
        // Absent grace or tolerance is the same family as `alg: "none"` — dropping a check by
        // omitting its input.
        #expect(decode(["grace_seconds": nil]) == .payload("grace_seconds"))
        #expect(decode(["skew_tolerance_seconds": nil]) == .payload("skew_tolerance_seconds"))
        #expect(decode(["grace_seconds": -1]) == .payload("grace_seconds"))
        // `NSNumber` bridges `true` to `1`, so a boolean would otherwise become one second of grace.
        #expect(decode(["grace_seconds": true]) == .payload("grace_seconds"))
        #expect(decode(["skew_tolerance_seconds": true]) == .payload("skew_tolerance_seconds"))
    }

    @Test
    func aKeySetDropsAPairItCannotParseRatherThanInventingOne() throws {
        // A mistyped key must not become a key that accepts something. Every one of these is dropped.
        let set = EntitlementKeySet.parsing([
            "no-colon",
            ":\(Self.goldenPublicKey)",
            "short:\(Base64URL.encode(Data(repeating: 1, count: 31)))",
            "long:\(Base64URL.encode(Data(repeating: 1, count: 33)))",
            "bad:not*base64url",
            "good:\(Self.goldenPublicKey)"
        ])
        #expect(set.keyIdentifiers == ["good"])
    }
}

private extension Result where Success == EntitlementClaim, Failure == EntitlementClaimDecodingError {
    /// The failure, or `nil` — so an expectation reads as one line rather than as a `guard case`.
    var failure: EntitlementClaimDecodingError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
