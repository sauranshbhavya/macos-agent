import Foundation
import Testing
@testable import MacAgentCore

/// The skills the user added (SONNY-452): encrypted at rest, migrating a legacy plaintext file, and
/// keeping the user's choice exactly as made.
@Suite
struct SkillSelectionStoreTests {
    @Test
    func addedSkillsAreEncryptedAtRestAndSurviveAcrossStoreInstances() throws {
        let root = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("added-skills.json")
        let marker = "skill_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"

        try SkillSelectionStore(fileURL: url, encryption: testEncryption()).add(id: marker, addedAt: Self.fixture)

        try expectEncryptedFile(url, hiding: marker)
        let reopened = try SkillSelectionStore(fileURL: url, encryption: testEncryption()).loadAll()
        #expect(reopened == [AddedSkill(id: marker, addedAt: Self.fixture)])
    }

    @Test
    func aLegacyPlaintextFileDecodesOnceAndIsRewrittenEncrypted() throws {
        let root = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("added-skills.json")
        try Data(#"[{"addedAt":"2023-11-14T22:13:20Z","id":"notion"}]"#.utf8).write(to: url)
        let store = SkillSelectionStore(fileURL: url, encryption: testEncryption())

        #expect(try store.loadAll() == [AddedSkill(id: "notion", addedAt: Self.fixture)])
        try expectEncryptedFile(url, hiding: "notion")
        #expect(try store.loadAll().map(\.id) == ["notion"])
    }

    /// Adding again returns what is held and writes nothing, so `addedAt` keeps meaning when the user
    /// first chose it. Moved an hour back first, because two writes inside one second encode the
    /// same ISO-8601 instant and an unchanged date would prove nothing (`CLAUDE.md`).
    @Test
    func addingASkillAlreadyAddedKeepsTheFirstDateAndWritesNothing() throws {
        let root = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillSelectionStore(fileURL: root.appendingPathComponent("added-skills.json"), encryption: testEncryption())
        let earlier = Date().addingTimeInterval(-3_600)
        try store.add(id: "linear", addedAt: earlier)
        let bytes = try Data(contentsOf: store.fileURL)

        let again = try store.add(id: "linear")

        // ISO-8601 at whole seconds truncates, so the stored instant is the earlier one's whole second.
        #expect(again.map { Int($0.addedAt.timeIntervalSince1970) } == Int(earlier.timeIntervalSince1970))
        #expect(try Data(contentsOf: store.fileURL) == bytes)
    }

    @Test
    func newestFirstAndRemovingOneLeavesTheRest() throws {
        let root = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillSelectionStore(fileURL: root.appendingPathComponent("added-skills.json"), encryption: testEncryption())
        try store.add(id: "notion", addedAt: Self.fixture)
        try store.add(id: "linear", addedAt: Self.fixture.addingTimeInterval(60))
        try store.add(id: "docusign", addedAt: Self.fixture.addingTimeInterval(120))

        #expect(try store.loadAll().map(\.id) == ["docusign", "linear", "notion"])

        try store.remove(id: "linear")
        #expect(try store.loadAll().map(\.id) == ["docusign", "notion"])

        try store.remove(id: "not-added")
        #expect(try store.loadAll().map(\.id) == ["docusign", "notion"])
    }

    @Test
    func aBlankIDStoresNothingAndMintsNoFile() throws {
        let root = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillSelectionStore(fileURL: root.appendingPathComponent("added-skills.json"), encryption: testEncryption())

        #expect(try store.add(id: "  ") == nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// A file that will not read is reported by a Remove rather than overwritten with a shorter list.
    @Test
    func removingFromAnUnreadableFileThrowsAndLeavesTheBytes() throws {
        let root = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("added-skills.json")
        let garbage = LocalStorageEncryption.fileHeader + Data("not a ciphertext".utf8)
        try garbage.write(to: url)
        let store = SkillSelectionStore(fileURL: url, encryption: testEncryption())

        #expect(throws: (any Error).self) { try store.remove(id: "notion") }
        #expect(try Data(contentsOf: url) == garbage)
    }

    @Test
    func theStoresRealLocationIsTheOneTheWipeAndTheClassificationName() {
        #expect(LocalStore.addedSkills.fileURL() == SkillSelectionStore.realFileURL())
        #expect(SkillSelectionStore.realFileURL().lastPathComponent == "added-skills.json")
        #expect(LocalDataDeletionService.defaultStoreFileURLs().contains(SkillSelectionStore.realFileURL()))
    }

    static let fixture = Date(timeIntervalSince1970: 1_700_000_000)

    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillSelectionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
