import Foundation
import Testing
@testable import MacAgentCore

/// The Memory page's rows and the store deletes it needs to remove one thing rather than
/// everything. V1's `MemorySettingsTests`, minus the parts about stores and switches V2 doesn't keep.
@Suite
struct MemoryCategoryTests {
    // MARK: - The rows

    /// Every row names the thing it counts. A bare "N saved" named no unit, so nothing told a count
    /// of entries apart from a number inside one of them.
    @Test
    func everyMemoryRowsCountNamesTheThingItCounts() {
        for category in MemoryCategory.allCases {
            #expect(category.countedEntries(1) == "1 \(category.singularNoun)", "\(category.title)")
            #expect(category.countedEntries(2) == "2 \(category.pluralNoun)", "\(category.title)")
            // Zero takes the plural, which is the form the empty row renders.
            #expect(category.countedEntries(0) == "0 \(category.pluralNoun)", "\(category.title)")
            #expect(category.singularNoun == category.singularNoun.lowercased(), "\(category.title)")
            #expect(category.pluralNoun == category.pluralNoun.lowercased(), "\(category.title)")
            #expect(category.singularNoun != category.pluralNoun, "\(category.title) is not pluralised")
            for noun in [category.singularNoun, category.pluralNoun] {
                #expect(!noun.contains("saved"), "\(category.title) still infers its unit")
            }
        }
    }

    /// Every row's words by value, as V1 had them: the population test above is blind to a wrong word.
    @Test
    func everyMemoryRowsTitleAndNounAreV1s() throws {
        let expected: [MemoryCategory: (title: String, singular: String, plural: String)] = [
            .routines: ("Routines", "routine", "routines"),
            .taskHistory: ("Task history", "task", "tasks"),
            .recentArtifacts: ("Recent artifacts", "artifact", "artifacts"),
            .clipboardHistory: ("Clipboard history", "copied item", "copied items"),
            .snippets: ("Snippets", "snippet", "snippets"),
            .approvedApps: ("Allowed apps", "app", "apps")
        ]
        #expect(Set(expected.keys) == Set(MemoryCategory.allCases))
        for category in MemoryCategory.allCases {
            let words = try #require(expected[category])
            #expect(category.title == words.title)
            #expect(category.countedEntries(1) == "1 \(words.singular)")
            #expect(category.countedEntries(2) == "2 \(words.plural)")
        }
        #expect(MemoryCategory.taskHistory.countedEntries(184) == "184 tasks")
    }

    /// The page's two groups, in V1's order, covering every row exactly once.
    @Test
    func theCollectionsTwoGroupsCoverEveryMemoryTypeExactlyOnce() {
        let grouped = MemorySection.all.flatMap(\.categories)

        #expect(Set(grouped) == Set(MemoryCategory.allCases))
        #expect(grouped.count == MemoryCategory.allCases.count, "a type appeared in both groups")
        #expect(MemorySection.all.map(\.title) == ["Saved by you", "Recorded as Sonny works"])
        #expect(MemorySection.all[0].categories == [.routines, .snippets, .approvedApps])
        #expect(MemorySection.all[1].categories == [.taskHistory, .recentArtifacts, .clipboardHistory])
    }

    // MARK: - The per-entry deletes

    @Test
    func deletingOneSnippetLeavesTheRest() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"), encryption: testEncryption())
        try store.save(StoredSnippet(trigger: ";sig", expansion: "signature", updatedAt: .memoryFixture))
        try store.save(StoredSnippet(trigger: ";addr", expansion: "address", updatedAt: .memoryFixture))

        try store.delete(trigger: " ;sig ")

        #expect(Set(try store.loadAll().keys) == [";addr"])
        // A trigger nothing holds is a no-op: the person's intent is already true.
        try store.delete(trigger: ";sig")
        #expect(Set(try store.loadAll().keys) == [";addr"])
    }

    @Test
    func deletingOneRecentArtifactLeavesTheRestAndTheFileItself() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("kept.txt")
        let forgotten = root.appendingPathComponent("forgotten.txt")
        try "kept".write(to: kept, atomically: true, encoding: .utf8)
        try "forgotten".write(to: forgotten, atomically: true, encoding: .utf8)
        let store = RecentArtifactStore(fileURL: root.appendingPathComponent("recent-files.json"), encryption: testEncryption())
        try store.record(path: kept.path, recordedAt: .memoryFixture)
        let removed = try #require(try store.record(path: forgotten.path, recordedAt: .memoryFixture))

        try store.delete(id: removed.id, now: .memoryFixture)

        #expect(try store.loadAll(now: .memoryFixture).map(\.path) == [kept.path])
        // The store only held a note about the file, and forgetting the note must not touch it.
        #expect(FileManager.default.fileExists(atPath: forgotten.path))

        try store.delete(id: UUID(), now: .memoryFixture)
        #expect(try store.loadAll(now: .memoryFixture).count == 1)
    }

    @Test
    func deletingOneClipboardItemLeavesTheRest() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard.json"), encryption: testEncryption())
        let later = Date.memoryFixture.addingTimeInterval(60)
        let older = try store.record("older", copiedAt: .memoryFixture)
        try store.record("newer", copiedAt: later)

        try store.delete(id: older.id, now: later)

        #expect(try store.loadAll(now: later).map(\.text) == ["newer"])
        try store.delete(id: UUID(), now: later)
        #expect(try store.loadAll(now: later).count == 1)
    }

    /// A delete that rewrote plaintext would leak what it was asked to remove.
    @Test
    func aPerEntryDeleteLeavesTheStoreStillEncrypted() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "Kept \(UUID().uuidString)"
        let store = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"), encryption: testEncryption())
        try store.save(StoredSnippet(trigger: ";keep", expansion: marker, updatedAt: .memoryFixture))
        try store.save(StoredSnippet(trigger: ";drop", expansion: "dropped", updatedAt: .memoryFixture))

        try store.delete(trigger: ";drop")

        try expectEncryptedFile(store.fileURL, hiding: marker)
    }
}

private extension Date {
    static let memoryFixture = Date(timeIntervalSince1970: 1_700_000_000)
}
