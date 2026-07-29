import CryptoKit
import Foundation
import OSLog

public protocol LocalStorageKeyManaging: Sendable {
    func keyData() throws -> Data
}

public enum LocalStorageEncryptionError: Error, Equatable, LocalizedError {
    case invalidKeyLength(Int)
    case missingCombinedCiphertext

    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength(let length):
            return "Local storage encryption key must be 32 bytes, got \(length)."
        case .missingCombinedCiphertext:
            return "Local storage encryption could not produce combined ciphertext."
        }
    }
}

public struct LocalStorageEncryptionKeyManager: LocalStorageKeyManaging, @unchecked Sendable {
    public static let defaultService = "com.sonny.local-storage"
    public static let defaultAccount = "local-data-encryption-key-v1"

    private let secretStore: any KeychainSecretStoring
    private let service: String
    private let account: String
    private let generateKeyData: @Sendable () -> Data

    public init(
        secretStore: any KeychainSecretStoring = KeychainSecretStore(),
        service: String = Self.defaultService,
        account: String = Self.defaultAccount,
        generateKeyData: @escaping @Sendable () -> Data = {
            SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        }
    ) {
        self.secretStore = secretStore
        self.service = service
        self.account = account
        self.generateKeyData = generateKeyData
    }

    public func keyData() throws -> Data {
        if let existing = try secretStore.data(service: service, account: account) {
            guard existing.count == 32 else {
                throw LocalStorageEncryptionError.invalidKeyLength(existing.count)
            }
            return existing
        }

        let generated = generateKeyData()
        guard generated.count == 32 else {
            throw LocalStorageEncryptionError.invalidKeyLength(generated.count)
        }
        try secretStore.save(generated, service: service, account: account)
        return generated
    }
}

public enum LocalStorageDecoded<Value> {
    case encrypted(Value)
    case legacy(Value)

    public var value: Value {
        switch self {
        case .encrypted(let value), .legacy(let value):
            return value
        }
    }

    public var wasLegacyPlaintext: Bool {
        switch self {
        case .encrypted:
            return false
        case .legacy:
            return true
        }
    }

    /// Opportunistically re-writes a legacy plaintext file as encrypted, returning the decoded
    /// value either way.
    ///
    /// A failed re-encryption is **not** a load failure and must not be reported as one: the
    /// decode succeeded, so the data is intact and usable. Store writes are atomic, so a failed
    /// write leaves the original plaintext file exactly as it was, and the migration simply
    /// retries for free on the next load. Letting the write error propagate out of `loadAll()`
    /// (as every store used to) made callers discard data that had just decoded correctly and
    /// show the "could not be decrypted or decoded" banner, which is wrong on both counts.
    public func migratingLegacyPlaintext(
        store: String,
        write: (Value) throws -> Void
    ) -> Value {
        guard wasLegacyPlaintext else {
            return value
        }

        do {
            try write(value)
        } catch {
            LocalStorageMigrationLog.recordDeferredMigration(store: store, error: error)
        }
        return value
    }
}

public enum LocalStorageMigrationLog {
    private static let logger = Logger(subsystem: "com.sonny.macagent", category: "local-storage")

    static func recordDeferredMigration(store: String, error: Error) {
        logger.warning(
            """
            Deferred plaintext-to-encrypted migration for \(store, privacy: .public): \
            \(error.localizedDescription, privacy: .public). The existing file is intact and \
            the migration retries on the next load.
            """
        )
    }
}

public struct LocalStorageEncryption: @unchecked Sendable {
    public static let shared = LocalStorageEncryption(keyManager: defaultKeyManager())
    public static let fileHeader = Data("SONNYENC1\n".utf8)

    private let keyManager: any LocalStorageKeyManaging
    private let keyCache = LocalStorageEncryptionKeyCache()

    public init(keyManager: any LocalStorageKeyManaging = LocalStorageEncryptionKeyManager()) {
        self.keyManager = keyManager
    }

    public func encode<Value: Encodable>(_ value: Value, encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        let plaintext = try encoder.encode(value)
        let sealedBox = try AES.GCM.seal(plaintext, using: key())
        guard let combined = sealedBox.combined else {
            throw LocalStorageEncryptionError.missingCombinedCiphertext
        }
        var data = Self.fileHeader
        data.append(combined)
        return data
    }

    public func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> LocalStorageDecoded<Value> {
        if data.starts(with: Self.fileHeader) {
            let combined = Data(data.dropFirst(Self.fileHeader.count))
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(sealedBox, using: key())
            return .encrypted(try decoder.decode(type, from: plaintext))
        }

        return .legacy(try decoder.decode(type, from: data))
    }

    private func key() throws -> SymmetricKey {
        let data = try keyCache.keyData {
            let keyData = try keyManager.keyData()
            guard keyData.count == 32 else {
                throw LocalStorageEncryptionError.invalidKeyLength(keyData.count)
            }
            return keyData
        }
        return SymmetricKey(data: data)
    }

    private static func defaultKeyManager() -> any LocalStorageKeyManaging {
        if isRunningTests {
            return EphemeralLocalStorageKeyManager()
        }
        return LocalStorageEncryptionKeyManager()
    }

    private static var isRunningTests: Bool {
        let processInfo = ProcessInfo.processInfo
        let processName = processInfo.processName.lowercased()
        let bundlePath = Bundle.main.bundlePath.lowercased()
        return processName.contains("test")
            || bundlePath.contains(".xctest")
            || bundlePath.contains("packagetests")
            || processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

private final class LocalStorageEncryptionKeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedKeyData: Data?

    func keyData(load: () throws -> Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        if let cachedKeyData {
            return cachedKeyData
        }

        let keyData = try load()
        cachedKeyData = keyData
        return keyData
    }
}

private struct EphemeralLocalStorageKeyManager: LocalStorageKeyManaging {
    private static let bytes = Data(repeating: 0x53, count: 32)

    func keyData() throws -> Data {
        Self.bytes
    }
}
