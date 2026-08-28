import CryptoKit
import Foundation

/// The public keys this build verifies entitlement claims against, and the verification itself
/// (SONNY-135).
///
/// **Asymmetric, and that is the load-bearing difference from `auth/token.ts`.** The gateway verifies
/// Supabase's access tokens with a shared HS256 secret, which is right there: the process that
/// verifies also has to call the project. It would be exactly wrong here. This claim is verified on
/// every user's Mac, and a symmetric algorithm would mean every copy of the app shipping a key that
/// can **mint** a claim granting any capability to any account. The Mac holds a public key and can
/// only check; only the gateway can sign.
///
/// **The algorithm is pinned as a literal, before anything reads the signature**, for the reason
/// `auth/token.ts` gives at length: a verifier that reads `alg` out of the token is a verifier the
/// attacker configures, and `alg: "none"` plus algorithm confusion are the two forgeries that follow.
/// Here there is no dispatch at all — the header's `alg` is compared to `"EdDSA"` and every other
/// value is a refusal.
public struct EntitlementKeySet: Equatable, Sendable {
    /// `kid` → the raw 32 bytes of an Ed25519 public key.
    private let keys: [String: Data]

    public init(_ keys: [String: Data]) {
        self.keys = keys
    }

    public var isEmpty: Bool { keys.isEmpty }

    public var keyIdentifiers: [String] { keys.keys.sorted() }

    public func key(for identifier: String) -> Data? { keys[identifier] }

    /// A key set from `kid:base64url` pairs, which is the form both the debug override and
    /// `npm run entitlements -- public-key` produce.
    ///
    /// A pair that does not parse — a missing colon, a body that is not base64url, a key that is not
    /// 32 bytes — is **dropped rather than defaulted**, and the result may be empty. An empty key set
    /// verifies nothing, which is the fail-closed direction: a mistyped key must not become a key
    /// that accepts something.
    public static func parsing(_ pairs: [String]) -> EntitlementKeySet {
        var keys: [String: Data] = [:]
        for pair in pairs {
            guard let separator = pair.firstIndex(of: ":") else { continue }
            let identifier = String(pair[pair.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let encoded = String(pair[pair.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !identifier.isEmpty,
                  let material = Base64URL.decode(encoded),
                  material.count == 32 else { continue }
            keys[identifier] = material
        }
        return EntitlementKeySet(keys)
    }
}

/// Strict base64url, decoded only when the input is the canonical encoding of what comes back.
///
/// **The same two leniencies `server/src/auth/token.ts` closes, closed here for the same reasons.**
/// A permissive decoder ignores characters outside the alphabet, so two different strings can carry
/// one signature-bearing header; and it accepts a final quantum whose unused bits are set, so a
/// segment can be perturbed without changing the bytes it decodes to. The alphabet check closes the
/// first and the re-encode comparison closes the second: what is decoded is the only string that
/// encodes to itself.
enum Base64URL {
    private static let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    static func decode(_ value: String) -> Data? {
        guard !value.isEmpty, value.allSatisfy({ alphabet.contains($0) }) else { return nil }
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        // Foundation's decoder wants the padding a JWS omits.
        let remainder = padded.count % 4
        if remainder == 2 { padded += "==" } else if remainder == 3 { padded += "=" } else if remainder != 0 {
            // A 4n+1 length has a trailing six-bit quantum that cannot form a byte. There is no
            // padding that makes it valid, and a decoder that silently dropped it would accept a
            // string that is not the canonical encoding of anything.
            return nil
        }
        guard let data = Data(base64Encoded: padded) else { return nil }
        guard encode(data) == value else { return nil }
        return data
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Verify a compact-serialised entitlement claim, and read it.
///
/// **Nothing here touches the network, and that is the requirement rather than an implementation
/// detail.** The whole type takes a key set and a string.
public enum EntitlementVerifier {
    /// The one algorithm this build accepts, compared as a literal.
    static let algorithm = "EdDSA"

    public static func verify(
        _ compact: String,
        against keys: EntitlementKeySet
    ) -> Result<EntitlementClaim, EntitlementClaimDecodingError> {
        // Exactly three segments. Two is the shape an `alg: "none"` forgery arrives in — JWS allows
        // an empty signature segment, and a bare `header.payload` is the other spelling.
        let segments = compact.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 3 else { return .failure(.malformed("expected three segments")) }
        let (encodedHeader, encodedPayload, encodedSignature) = (segments[0], segments[1], segments[2])

        guard let headerBytes = Base64URL.decode(encodedHeader),
              let header = try? JSONSerialization.jsonObject(with: headerBytes) as? [String: Any] else {
            return .failure(.malformed("header"))
        }
        // **The pin**, before anything reads the signature, so there is no dispatch to confuse.
        guard header["alg"] as? String == algorithm else { return .failure(.algorithm) }
        // RFC 7515 §4.1.11: `crit` names header parameters a verifier MUST understand. This one
        // understands no extensions, so any `crit` at all is a refusal rather than something to skip.
        guard header["crit"] == nil else { return .failure(.algorithm) }
        guard let identifier = header["kid"] as? String, !identifier.isEmpty else {
            return .failure(.malformed("no kid"))
        }
        guard let material = keys.key(for: identifier) else { return .failure(.unknownKey(identifier)) }

        guard let signature = Base64URL.decode(encodedSignature) else {
            return .failure(.malformed("signature"))
        }
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: material) else {
            return .failure(.unknownKey(identifier))
        }
        let signedInput = Data("\(encodedHeader).\(encodedPayload)".utf8)
        guard publicKey.isValidSignature(signature, for: signedInput) else {
            return .failure(.signature)
        }

        // **Read after the signature passes, never before.** A claim this build's key did not sign
        // never reaches the code that decides what it says — the same check order `auth/token.ts`
        // argues for, and for the same reason: a forged claim must not be able to steer anything.
        guard let payloadBytes = Base64URL.decode(encodedPayload) else {
            return .failure(.malformed("payload"))
        }
        return decode(payloadBytes)
    }

    static func decode(_ payloadBytes: Data) -> Result<EntitlementClaim, EntitlementClaimDecodingError> {
        guard let payload = try? JSONSerialization.jsonObject(with: payloadBytes) as? [String: Any] else {
            return .failure(.payload("not a JSON object"))
        }
        guard let version = payload["v"] as? Int else { return .failure(.payload("v")) }
        guard version == EntitlementClaim.supportedVersion else {
            return .failure(.payload("unsupported version \(version)"))
        }
        guard let subject = payload["sub"] as? String, !subject.isEmpty else {
            return .failure(.payload("sub"))
        }
        guard let plan = payload["plan"] as? String else { return .failure(.payload("plan")) }
        // **A capability list that is not a list of strings is a refusal, not an empty list.** The
        // difference decides whether a paying user is told they have no plan or is told the claim
        // could not be read, and only the second is true.
        guard let rawCapabilities = payload["capabilities"] as? [Any] else {
            return .failure(.payload("capabilities"))
        }
        let capabilities = rawCapabilities.compactMap { $0 as? String }
        guard capabilities.count == rawCapabilities.count else {
            return .failure(.payload("capabilities"))
        }
        guard let issuedAtText = payload["issued_at"] as? String,
              let issuedAt = SonnyISO8601.parse(issuedAtText) else {
            return .failure(.payload("issued_at"))
        }
        guard let expiresAtText = payload["expires_at"] as? String,
              let expiresAt = SonnyISO8601.parse(expiresAtText) else {
            return .failure(.payload("expires_at"))
        }
        // **A claim with no grace or no tolerance is refused rather than defaulted to zero.** Absent
        // is the third forgery in the same family as `alg: "none"`: it asks the verifier to drop an
        // input by omitting it. Defaulting to zero would fail *closed* here, which is why this is a
        // shape rule rather than a security one — but a claim missing a field the contract requires
        // is a claim this build does not understand, and reading it optimistically is how a server
        // change becomes a silent client behaviour change.
        guard let graceSeconds = numeric(payload["grace_seconds"]), graceSeconds >= 0 else {
            return .failure(.payload("grace_seconds"))
        }
        guard let skewToleranceSeconds = numeric(payload["skew_tolerance_seconds"]),
              skewToleranceSeconds >= 0 else {
            return .failure(.payload("skew_tolerance_seconds"))
        }
        return .success(EntitlementClaim(
            version: version,
            subject: subject,
            plan: plan,
            capabilities: capabilities,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            graceSeconds: graceSeconds,
            skewToleranceSeconds: skewToleranceSeconds
        ))
    }

    /// A JSON number as a `TimeInterval`, refusing a bool and anything non-finite.
    ///
    /// `NSNumber` bridges `true` to `1`, so a `"grace_seconds": true` would otherwise become one
    /// second of grace — a value nobody sent.
    private static func numeric(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let seconds = number.doubleValue
        return seconds.isFinite ? seconds : nil
    }
}
