import Foundation
import MacAgentCore

/// A `KeychainSecretStoring` that lives in memory, so a test can exercise the real
/// `KeychainAccountTokenStore` and the real `LocalStorageEncryptionKeyManager` against one store
/// without touching the machine's actual Keychain.
///
/// **Why not the real Keychain.** Every packaged build on a Mac shares one, so a suite that wrote
/// to it would read and delete the founder's own session — the Keychain version of the hazard
/// SONNY-240 removed from the local stores, where a defaulted store parameter had tests writing to
/// `~/Library/Application Support/Sonny/`. It is also the reason `SonnyBackendClient.init` gives its
/// token store no default at all.
///
/// **Keyed on service *and* account, like the real thing.** A fake keyed on the account alone would
/// pass a test asserting that signing out leaves the local-storage encryption key alone while the
/// real store, keyed on both, was the only reason it held.
public final class InMemoryKeychainSecretStore: KeychainSecretStoring, @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public let service: String
        public let account: String

        public init(service: String, account: String) {
            self.service = service
            self.account = account
        }
    }

    private let lock = NSLock()
    private var items: [Key: Data] = [:]
    private var readFailure: Error?
    private var writeFailure: Error?
    private var deleteFailure: Error?
    private var savedKeys: [Key] = []

    public init() {}

    public func data(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let readFailure { throw readFailure }
        return items[Key(service: service, account: account)]
    }

    public func save(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let writeFailure { throw writeFailure }
        let key = Key(service: service, account: account)
        items[key] = data
        savedKeys.append(key)
    }

    public func delete(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let deleteFailure { throw deleteFailure }
        items.removeValue(forKey: Key(service: service, account: account))
    }

    // MARK: - Inspection and fault injection

    public func contains(service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return items[Key(service: service, account: account)] != nil
    }

    public func rawValue(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[Key(service: service, account: account)]
    }

    public func plant(_ data: Data, service: String, account: String) {
        lock.lock()
        items[Key(service: service, account: account)] = data
        lock.unlock()
    }

    public var storedKeys: [Key] {
        lock.lock()
        defer { lock.unlock() }
        return items.keys.sorted { ($0.service, $0.account) < ($1.service, $1.account) }
    }

    /// Every key a `save` ever named, in order — for asserting *when* a write happened, not only
    /// that one did.
    public var writeLog: [Key] {
        lock.lock()
        defer { lock.unlock() }
        return savedKeys
    }

    public func failReads(with error: Error) {
        lock.lock()
        readFailure = error
        lock.unlock()
    }

    public func failWrites(with error: Error) {
        lock.lock()
        writeFailure = error
        lock.unlock()
    }

    public func failDeletes(with error: Error) {
        lock.lock()
        deleteFailure = error
        lock.unlock()
    }

    public func stopFailing() {
        lock.lock()
        readFailure = nil
        writeFailure = nil
        deleteFailure = nil
        lock.unlock()
    }
}

public enum InMemoryKeychainFailure: Error, Equatable {
    case refused
}
