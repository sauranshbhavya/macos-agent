import Foundation

/// The cached entitlement claim and the latest server instant this Mac has ever observed, held
/// together in the Keychain (SONNY-135).
///
/// **Two values in one item, because they are only meaningful together.** The claim is what says
/// what the account may do; the observed instant is what stops a clock the user controls from
/// deciding whether that claim has expired. Writing them separately would let a restore, a partial
/// wipe or a crash leave a claim beside a high-water mark from a different session.
public struct StoredEntitlement: Equatable, Sendable, Codable {
    /// The claim exactly as the gateway signed it. Stored compact rather than decoded, so what is
    /// verified on the way out is the same bytes that were verified on the way in.
    public let compactClaim: String
    /// The latest instant this Mac has ever seen the *server* report, in server time.
    ///
    /// **This is the defence against a clock set backwards, and it is the only one there is.**
    /// `SonnyBackendClient` keeps an offset from the `Date` header on every response (§3.5) and all
    /// expiry arithmetic runs in server time — but that offset is held in memory, so a relaunch with
    /// no network leaves it at zero and server time collapses back onto the local clock. Persisting
    /// the highest server instant ever seen means a claim's expiry can never be undone by moving the
    /// Mac's clock back: the effective now is the later of the two.
    ///
    /// **What it does not defend against, said plainly**: it cannot help a Mac that has never seen a
    /// response, and it cannot make a *forward*-set clock read as earlier — that direction is
    /// absorbed by the grace window and by the claim's own tolerance, and past those it refuses,
    /// which is the fail-closed direction.
    public let observedServerTime: Date?

    public init(compactClaim: String, observedServerTime: Date?) {
        self.compactClaim = compactClaim
        self.observedServerTime = observedServerTime
    }
}

public protocol EntitlementStoring: Sendable {
    func load() throws -> StoredEntitlement?
    func save(_ entitlement: StoredEntitlement) throws
    func clear() throws
}

public enum EntitlementStoreError: Error, Equatable, LocalizedError {
    /// The Keychain held bytes that are not an entitlement this build can read.
    case undecodable(String)

    public var errorDescription: String? {
        switch self {
        case .undecodable:
            return "The stored entitlement could not be decoded."
        }
    }
}

/// The cached claim, in the Keychain, as **a new account on the existing `KeychainSecretStore`**.
///
/// The same pattern and the same reasoning as `KeychainAccountTokenStore`: `any KeychainSecretStoring`
/// with a service and an account, no encryption of its own, and the session's service so that signing
/// out and resetting the encryption identity stay three different actions with three different blast
/// radii. It is its own **account**, not its own service, because it is part of the session: a claim
/// is about the account that is signed in, and it should go when that session goes.
///
/// **It inherits SONNY-304's open finding, and that is recorded rather than fixed here.** Nothing in
/// this repository sets `kSecAttrAccessible`, `kSecUseDataProtectionKeychain`, `kSecAttrSynchronizable`
/// or `kSecAttrAccessControl`, so the protection class of every item this store writes is whatever the
/// platform defaults to for a caller that said nothing — the file-based login keychain, which is
/// carried by Time Machine backups and by Migration Assistant. **A cached claim is a far smaller
/// asset than the refresh token beside it**: it is a public, signed, read-only statement, it grants
/// nothing without the session token that is already in the same keychain, and it stops working
/// within its own grace window. It travels the same way, and SONNY-304 is where that is fixed for
/// both. Naming it here means the next reader meets the fact rather than inferring it from silence.
public struct KeychainEntitlementStore: EntitlementStoring, @unchecked Sendable {
    public static let defaultService = KeychainAccountTokenStore.defaultService
    public static let defaultAccount = "entitlement-v1"

    private let secretStore: any KeychainSecretStoring
    private let service: String
    private let account: String

    /// `secretStore` has no default, deliberately — the same hazard `SonnyBackendClient` records for
    /// its own token store: every packaged build on a Mac shares one Keychain, so a fixture that
    /// inherited a default would read and *delete* the founder's real entitlement.
    public init(
        secretStore: any KeychainSecretStoring,
        service: String = Self.defaultService,
        account: String = Self.defaultAccount
    ) {
        self.secretStore = secretStore
        self.service = service
        self.account = account
    }

    public func load() throws -> StoredEntitlement? {
        guard let data = try secretStore.data(service: service, account: account) else { return nil }
        do {
            return try Self.decoder.decode(StoredEntitlement.self, from: data)
        } catch {
            throw EntitlementStoreError.undecodable(String(describing: error))
        }
    }

    public func save(_ entitlement: StoredEntitlement) throws {
        try secretStore.save(Self.encoder.encode(entitlement), service: service, account: account)
    }

    public func clear() throws {
        try secretStore.delete(service: service, account: account)
    }

    /// `.iso8601` matches every other store's date encoding, so an entitlement written by one build
    /// reads in the next.
    ///
    /// **Whole-second resolution, and the direction it rounds in is the safe one.** The only date
    /// here is the high-water mark, and truncating it makes it at most one second *earlier* — which
    /// is more permissive by a second against a tolerance measured in minutes and a grace window
    /// measured in days. It could never make an expired claim read as live.
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
