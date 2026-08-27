import Foundation

/// The signed-in session, as it is held on this Mac.
///
/// **The two token strings are `internal` on purpose.** `MacAgent` — every view, every view model,
/// the whole app target — imports `MacAgentCore` and therefore cannot name them at all, so the
/// compiler is what keeps a token out of a log line, a `UserDefaults` value or a debug print rather
/// than a convention somebody has to remember. Nothing in the app needs a token; it needs to know
/// who is signed in, and `identity` is that.
///
/// **The access token is never parsed.** Contract §3.1: it is a Supabase JWT, and "the client must
/// not decode, inspect or make any decision from it" — a contract obligation this client keeps
/// rather than one the encoding keeps for it, since the encoding stopped enforcing it when the
/// token stopped being opaque. Expiry comes from `expires_in` and `expires_at` in the response body
/// (§3.2), which is why `accessTokenExpiresAt` is stored beside the token instead of read out of it.
public struct SonnyAccountTokens: Equatable, Sendable, Codable {
    let accessToken: String
    let refreshToken: String
    public let accessTokenExpiresAt: Date
    public let refreshTokenExpiresAt: Date?
    public let userID: String
    /// The address the user typed. The token response carries only `user.id` (§3.2), so this is the
    /// one thing that lets the account row name who is signed in after a relaunch.
    public let emailAddress: String?

    init(
        accessToken: String,
        refreshToken: String,
        accessTokenExpiresAt: Date,
        refreshTokenExpiresAt: Date?,
        userID: String,
        emailAddress: String?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.userID = userID
        self.emailAddress = emailAddress
    }

    public var identity: SonnyAccountIdentity {
        SonnyAccountIdentity(userID: userID, emailAddress: emailAddress)
    }
}

/// Redacted in both string conversions, so neither `print(tokens)` nor string interpolation nor a
/// debugger's `po` prints a credential. The compiler already stops the app target reading the
/// fields; this stops `MacAgentCore` itself leaking them by accident.
extension SonnyAccountTokens: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "SonnyAccountTokens(userID: \(userID), accessToken: <redacted>, refreshToken: <redacted>)"
    }

    public var debugDescription: String { description }
}

/// Who is signed in, for surfaces that must not be able to see a token.
public struct SonnyAccountIdentity: Equatable, Sendable {
    public let userID: String
    public let emailAddress: String?

    public init(userID: String, emailAddress: String?) {
        self.userID = userID
        self.emailAddress = emailAddress
    }
}

public protocol SonnyAccountTokenStoring: Sendable {
    func loadTokens() throws -> SonnyAccountTokens?
    func saveTokens(_ tokens: SonnyAccountTokens) throws
    func clearTokens() throws
}

public enum SonnyAccountTokenStoreError: Error, Equatable, LocalizedError {
    /// The Keychain held bytes that are not a session this build can read.
    case undecodableStoredSession(String)

    public var errorDescription: String? {
        switch self {
        case .undecodableStoredSession:
            return "The stored sign-in could not be decoded."
        }
    }
}

/// The session, in the Keychain, as **a new account on the existing `KeychainSecretStore`**.
///
/// Contract §3.1 and this ticket both say the same thing about what this must not become: it is not
/// a new store and not a variant of the pattern. So it takes `any KeychainSecretStoring` with a
/// service and an account, exactly as `LocalStorageEncryptionKeyManager` does, and it adds no
/// encryption of its own — the Keychain is the protected store, and wrapping it in
/// `LocalStorageEncryption` would key a credential to a key that itself lives one Keychain item
/// away.
///
/// **The service is deliberately not `com.sonny.local-storage`.** Signing out deletes this item;
/// the local-data encryption key lives under the other service and must survive that, because
/// sign-out, "delete my local data" and "reset the encryption identity" are three different actions
/// with three different blast radii (§3.3, and branch 7's decision that local data deletion leaves
/// the Keychain encryption key alone). Two services means the delete cannot reach the wrong item
/// even if the account names ever collide.
///
/// **One item, not three.** The whole session is one JSON blob under one account, so a write is a
/// single Keychain operation and cannot leave an access token from one sign-in beside a refresh
/// token from another. That atomicity is what makes the relaunch requirement checkable: whatever is
/// there after a crash is a session or nothing.
public struct KeychainAccountTokenStore: SonnyAccountTokenStoring, @unchecked Sendable {
    public static let defaultService = "com.sonny.account"
    public static let defaultAccount = "backend-session-v1"

    private let secretStore: any KeychainSecretStoring
    private let service: String
    private let account: String

    public init(
        secretStore: any KeychainSecretStoring = KeychainSecretStore(),
        service: String = Self.defaultService,
        account: String = Self.defaultAccount
    ) {
        self.secretStore = secretStore
        self.service = service
        self.account = account
    }

    public func loadTokens() throws -> SonnyAccountTokens? {
        guard let data = try secretStore.data(service: service, account: account) else {
            return nil
        }
        do {
            return try Self.decoder.decode(SonnyAccountTokens.self, from: data)
        } catch {
            throw SonnyAccountTokenStoreError.undecodableStoredSession(String(describing: error))
        }
    }

    public func saveTokens(_ tokens: SonnyAccountTokens) throws {
        try secretStore.save(Self.encoder.encode(tokens), service: service, account: account)
    }

    public func clearTokens() throws {
        try secretStore.delete(service: service, account: account)
    }

    /// `.iso8601` matches every local store's date encoding, so a session written by one build
    /// reads in the next. Whole-second resolution is fine here and is nowhere near the tolerances
    /// token expiry is judged at (§3.5's skew tolerance is thirty seconds).
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
