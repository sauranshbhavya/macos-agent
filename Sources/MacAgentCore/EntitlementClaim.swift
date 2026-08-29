import Foundation

/// The signed entitlement claim of `docs/sonny-backend-api-contract.md` §5.3, as this Mac reads it
/// (SONNY-135).
///
/// **The whole point of this type is that answering "is this user allowed" needs no network.** The
/// gateway signs a statement about the account; the Mac verifies it against a public key it holds
/// and then decides locally. A client that had to ask the server "may I" is a client that cannot
/// answer on a plane, and §16.3's guarantee — that free local capabilities keep working when the
/// network is unreachable — is one of the three recorded grounds for this row's whole architecture.
///
/// **This type names no capability and no plan.** `capabilities` is a list of opaque strings and
/// `plan` is an opaque key; which capability gates which feature is row 18's (SONNY-23), and what
/// the plans are is SONNY-212's. Nothing here may acquire either.
public struct EntitlementClaim: Equatable, Sendable {
    /// The payload's schema version. A claim this build does not know the version of is refused
    /// rather than read optimistically — §8 makes new fields additive, but a new *version* is the
    /// server saying the shape changed.
    public static let supportedVersion = 1

    public let version: Int
    /// The Sonny account this claim is about — §5's billable identity, not the provider's user id.
    public let subject: String
    public let plan: String
    public let capabilities: [String]
    public let issuedAt: Date
    public let expiresAt: Date
    /// How long past `expiresAt` this claim may still be honoured. Carried in the claim rather than
    /// compiled in, so the server can change it without an app release (§5.3).
    public let graceSeconds: TimeInterval
    /// How much clock disagreement to absorb when judging the two instants above. Also carried.
    public let skewToleranceSeconds: TimeInterval

    public init(
        version: Int,
        subject: String,
        plan: String,
        capabilities: [String],
        issuedAt: Date,
        expiresAt: Date,
        graceSeconds: TimeInterval,
        skewToleranceSeconds: TimeInterval
    ) {
        self.version = version
        self.subject = subject
        self.plan = plan
        self.capabilities = capabilities
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.graceSeconds = graceSeconds
        self.skewToleranceSeconds = skewToleranceSeconds
    }

    /// The last instant this claim may be honoured at all: expiry, plus the grace window, plus the
    /// tolerance the claim itself carries.
    ///
    /// **The tolerance is added at this edge and not multiplied into it.** Five minutes against a
    /// seventy-two hour grace window is a tenth of a percent, so it cannot meaningfully extend the
    /// window a revoked plan survives in — which is the whole reason a tolerance may be granted here
    /// at all.
    public var honouredUntil: Date {
        expiresAt.addingTimeInterval(graceSeconds + skewToleranceSeconds)
    }

    /// The earliest instant this claim may be honoured: its issue time, less the tolerance.
    ///
    /// **Tolerance is granted in BOTH directions here, which is the opposite of the rule the gateway
    /// applies to an access token, and the reasoning is what inverts.** `server/src/auth/clock.ts`
    /// grants tolerance only to a token that looks *expired*, never to one that looks not-yet-valid,
    /// because a token from the future is either the server's own clock being wrong — which tolerance
    /// cannot fix — or a forged claim, which tolerance must not help. Neither reason holds on this
    /// side. `issuedAt` is **signed by the gateway**, so a forgery cannot choose it; and a claim that
    /// looks not-yet-valid on a Mac means *this Mac's* clock is behind, which is precisely the error
    /// the tolerance exists for. Refusing it outright would lock out a user whose clock is a minute
    /// slow, for no security gained.
    public var honouredFrom: Date {
        issuedAt.addingTimeInterval(-skewToleranceSeconds)
    }

    public func grants(_ capability: EntitlementCapability) -> Bool {
        capabilities.contains(capability.key)
    }
}

/// One capability key, as an opaque string this repository never enumerates.
///
/// **A wrapper rather than a bare `String`, and the reason is the never-touch list.** Row 18
/// (SONNY-23) decides which keys exist and which features they gate. A bare `String` invites a
/// constant here — `static let screenControl = "screen_control"` — which would be that decision taken
/// in this ticket. The type carries no cases and this file names no key; the only keys in the tree
/// are in tests, which say so.
public struct EntitlementCapability: Equatable, Hashable, Sendable {
    public let key: String

    public init(_ key: String) {
        self.key = key
    }
}

/// Why a claim could not be read. Every case is a refusal; none of them is "allowed".
public enum EntitlementClaimDecodingError: Error, Equatable, Sendable {
    /// Not three base64url segments, or a segment that is not the canonical encoding of its bytes.
    case malformed(String)
    /// The header did not say `EdDSA`, or carried a `crit` this build cannot honour.
    case algorithm
    /// No public key is held for the `kid` this claim names.
    case unknownKey(String)
    /// The signature did not verify against the named key.
    case signature
    /// The payload decoded but is not a claim this build can read.
    case payload(String)
}
