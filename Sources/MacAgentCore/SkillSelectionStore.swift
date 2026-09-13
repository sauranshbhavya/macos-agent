import Foundation

/// One skill the user added on the Skills page, and when.
public struct AddedSkill: Codable, Equatable, Sendable {
    /// A pack's `id`. Kept even when no shipped pack answers to it any more — a pack a later build
    /// drops or refuses is not the user's choice to forget, and the id costs nothing to hold.
    public var id: String
    public var addedAt: Date

    public init(id: String, addedAt: Date = Date()) {
        self.id = id
        self.addedAt = addedAt
    }
}

/// The skills the user has added, encrypted on disk (SONNY-452).
///
/// **The shared pattern, not a variant** (`CLAUDE.md`): a required `fileURL`, a defaulted
/// `encryption:` parameter, AES-GCM behind the `SONNYENC1\n` header, and transparent
/// legacy-plaintext migration on the first successful load.
///
/// **Ids only.** A pack's content ships in the app bundle and is read from there each launch, so
/// this file never holds instructions — only which ones the user chose — and a pack corrected in a
/// later build reaches every user who added it without anything here changing.
///
/// **Uncapped, like allowed apps and unlike the trace stores.** Every entry is a press of Add, bounded
/// by the number of packs that ship, and evicting one would remove a choice silently.
public struct SkillSelectionStore: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    private let encryption: LocalStorageEncryption

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encryption = encryption
    }

    /// Where the shipping app keeps this store.
    ///
    /// The rule that makes this a named call rather than an initializer default is on
    /// `ClipboardHistoryStore.defaultDirectory` (SONNY-350).
    public static func realFileURL(fileManager: FileManager = .default) -> URL {
        ClipboardHistoryStore.defaultDirectory(fileManager: fileManager)
            .appendingPathComponent("added-skills.json")
    }

    /// Every added skill, most recently added first, with the id as the tiebreak so two added inside
    /// one second do not swap places between reads.
    public func loadAll() throws -> [AddedSkill] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode([AddedSkill].self, from: data, decoder: .addedSkillISO8601)
        let skills = decoded.migratingLegacyPlaintext(store: "added skills", write: write)
        return sorted(skills)
    }

    /// Records that the user added this skill.
    ///
    /// - Returns: the entry now held — the new one, or the existing one when it was already added,
    ///   in which case nothing is written, so `addedAt` keeps recording when the user first chose it —
    ///   and `nil` for a blank id, which stores nothing.
    @discardableResult
    public func add(id rawID: String, addedAt: Date = Date()) throws -> AddedSkill? {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            return nil
        }
        var skills = try loadAll()
        if let existing = skills.first(where: { $0.id == id }) {
            return existing
        }
        let added = AddedSkill(id: id, addedAt: addedAt)
        skills.append(added)
        try write(sorted(skills))
        return added
    }

    /// Removes one added skill. An id nothing holds is a no-op, and so writes nothing.
    ///
    /// **A file that will not read is reported, never overwritten** — the load is inside this call,
    /// so an undecryptable store throws here instead of an empty list being written over bytes a key
    /// migration could still recover. The Memory row's Delete is the route through such a file.
    public func remove(id rawID: String) throws {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let skills = try loadAll()
        let remaining = skills.filter { $0.id != id }
        guard remaining.count != skills.count else {
            return
        }
        try write(remaining)
    }

    private func sorted(_ skills: [AddedSkill]) -> [AddedSkill] {
        skills.sorted {
            $0.addedAt == $1.addedAt ? $0.id < $1.id : $0.addedAt > $1.addedAt
        }
    }

    private func write(_ skills: [AddedSkill]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(skills, encoder: .addedSkillPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var addedSkillPrettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var addedSkillISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
