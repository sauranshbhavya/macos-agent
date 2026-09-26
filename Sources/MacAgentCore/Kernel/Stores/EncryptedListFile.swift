import Foundation
import OSLog

/// One of V2's encrypted list files. Task history and routines each keep theirs in one.
///
/// A missing file is an empty list. A file that is there but can't be read, decrypted or decoded
/// throws instead of reading as empty: an empty answer would let the next save write an empty list
/// plus one new record over the person's real data. The store keeps nothing from a failed read, so
/// the next read tries the file again (the Keychain may have been locked).
struct EncryptedListFile<Element: Codable> {
    /// Nil keeps the list in memory only, for tests.
    let url: URL?
    let encryption: LocalStorageEncryption
    /// What the log calls the file.
    let name: String

    func read() throws -> [Element] {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let decoded = try encryption.decode([Element].self, from: Data(contentsOf: url))
            // V2 writes only encrypted files and reads nothing older (plan decision 1). A plaintext
            // file here isn't V2's, so it isn't read, and it isn't written over either.
            guard case .encrypted(let elements) = decoded else {
                throw LocalStorageEncryptionError.undecodableLocalData(underlying: "The file isn't encrypted.")
            }
            return elements
        } catch {
            encryptedListFileLogger.error(
                "Couldn't read \(name, privacy: .public); it is kept as it is and nothing is saved over it: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    func write(_ elements: [Element]) throws {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encryption.encode(elements).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            encryptedListFileLogger.error("Couldn't save \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

private let encryptedListFileLogger = Logger(subsystem: "com.sonny.macagent", category: "kernel-stores")
