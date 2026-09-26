import Foundation
import Testing
@testable import MacAgentCore

/// A V2 list file that is there but can't be read is never saved over, and a failed read is not
/// remembered as an empty list.
@Suite(.serialized)
struct UnreadableKernelStoreTests {
    @Test
    func aHistoryFileThatWontDecryptIsKeptAndANewTaskIsNotSavedOverIt() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let kept = finishedTaskSnapshot("Book the dentist")
        try await FinishedTaskStore(fileURL: url, encryption: keyedEncryption(0x42)).record(kept, finishedAt: Date())
        let original = try Data(contentsOf: url)

        let wrongKey = FinishedTaskStore(fileURL: url, encryption: keyedEncryption(0x99))
        await #expect(throws: (any Error).self) { try await wrongKey.all() }
        await #expect(throws: (any Error).self) {
            try await wrongKey.record(finishedTaskSnapshot("Send the invoice"), finishedAt: Date())
        }
        await #expect(throws: (any Error).self) { try await wrongKey.delete(kept.id) }

        #expect(try Data(contentsOf: url) == original)
        let rightKey = FinishedTaskStore(fileURL: url, encryption: keyedEncryption(0x42))
        #expect(try await rightKey.all().map(\.id) == [kept.id])
    }

    @Test
    func aHistoryFileOfGarbageIsKeptAndANewTaskIsNotSavedOverIt() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let garbage = LocalStorageEncryption.fileHeader + Data("not a sealed box".utf8)
        try garbage.write(to: url)

        let store = FinishedTaskStore(fileURL: url, encryption: keyedEncryption(0x42))
        await #expect(throws: (any Error).self) {
            try await store.record(finishedTaskSnapshot("Send the invoice"), finishedAt: Date())
        }

        #expect(try Data(contentsOf: url) == garbage)
    }

    @Test
    func aRoutinesFileThatWontDecryptIsKeptAndANewRoutineIsNotSavedOverIt() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("routines.json")
        let kept = RoutineGoal(name: "Morning", goal: "Open my calendar", schedule: nil, savedAt: Date())
        try await RoutineGoalStore(fileURL: url, encryption: keyedEncryption(0x42)).save(kept)
        let original = try Data(contentsOf: url)

        let wrongKey = RoutineGoalStore(fileURL: url, encryption: keyedEncryption(0x99))
        await #expect(throws: (any Error).self) { try await wrongKey.all() }
        await #expect(throws: (any Error).self) {
            try await wrongKey.save(RoutineGoal(name: "Evening", goal: "Close my apps", schedule: nil, savedAt: Date()))
        }
        await #expect(throws: (any Error).self) { try await wrongKey.delete(kept.id) }

        #expect(try Data(contentsOf: url) == original)
        let rightKey = RoutineGoalStore(fileURL: url, encryption: keyedEncryption(0x42))
        #expect(try await rightKey.all() == [kept])
    }

    /// The Keychain refuses the key while the Mac is locked. Once it answers, the same store reads
    /// the file and a save keeps what was already there.
    @Test
    func aReadThatFailsWhileTheKeyIsUnavailableIsTriedAgainLater() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("routines.json")
        let kept = RoutineGoal(name: "Morning", goal: "Open my calendar", schedule: nil, savedAt: Date())
        try await RoutineGoalStore(fileURL: url, encryption: keyedEncryption(0x42)).save(kept)

        let keychain = LockableKey(Data(repeating: 0x42, count: 32))
        let store = RoutineGoalStore(fileURL: url, encryption: LocalStorageEncryption(keyManager: keychain))
        await #expect(throws: (any Error).self) { try await store.all() }

        keychain.isLocked.value = false
        #expect(try await store.all() == [kept])
        let added = RoutineGoal(name: "Evening", goal: "Close my apps", schedule: nil, savedAt: Date())
        try await store.save(added)
        #expect(try await RoutineGoalStore(fileURL: url, encryption: keyedEncryption(0x42)).all().map(\.name) == ["Evening", "Morning"])
    }

    @Test
    func aMissingFileIsAnEmptyList() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = FinishedTaskStore(fileURL: folder.appendingPathComponent("history.json"), encryption: keyedEncryption(0x42))
        let routines = RoutineGoalStore(fileURL: folder.appendingPathComponent("routines.json"), encryption: keyedEncryption(0x42))

        #expect(try await history.all().isEmpty)
        #expect(try await routines.all().isEmpty)
    }
}

func finishedTaskSnapshot(_ goal: String) -> TaskSnapshot {
    TaskSnapshot(id: TaskID(), goal: goal, origin: .composer, isPrivate: false, phase: .completed(summary: "Done."), progress: nil, actions: [])
}

func keyedEncryption(_ byte: UInt8) -> LocalStorageEncryption {
    LocalStorageEncryption(keyManager: LockableKey(Data(repeating: byte, count: 32), locked: false))
}

private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("unreadable-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A storage key the Keychain refuses while `isLocked` is true.
final class LockableKey: LocalStorageKeyManaging, @unchecked Sendable {
    struct Refused: Error {}

    let bytes: Data
    let isLocked: Shared<Bool>

    init(_ bytes: Data, locked: Bool = true) {
        self.bytes = bytes
        isLocked = Shared(locked)
    }

    func keyData() throws -> Data {
        guard !isLocked.value else { throw Refused() }
        return bytes
    }
}
