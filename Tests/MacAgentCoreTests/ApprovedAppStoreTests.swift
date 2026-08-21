import Foundation
import Testing
@testable import MacAgentCore

/// The tenth local store (SONNY-140). Nothing gates on it yet — SONNY-143 is what reads it — so
/// everything here is about the store keeping its own promises: encrypted at rest, migrating a
/// legacy plaintext file, refusing to hold a grant the terminal ban refuses, and comparing
/// identifiers the way the rest of the codebase does.
@Suite
struct ApprovedAppStoreTests {
    @Test
    func approvedAppStoreEncryptsRawFileBytesAndRoundTrips() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "Sensitive App \(UUID().uuidString)"
        let store = ApprovedAppStore(
            fileURL: root.appendingPathComponent("approved-apps.json"),
            encryption: testEncryption()
        )

        try store.approve(
            bundleIdentifier: "com.example.\(marker.replacingOccurrences(of: " ", with: ""))",
            displayName: marker,
            approvedAt: .fixture
        )

        try expectEncryptedFile(store.fileURL, hiding: marker)
        let loaded = try store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.displayName == marker)
        #expect(loaded.first?.approvedAt == .fixture)
    }

    /// The point of the store: a grant outlives the process that minted it. Re-read through a
    /// *second* store instance over the same file, because a value cached in the first one would
    /// make an in-memory round trip look like persistence.
    @Test
    func grantsSurviveAcrossStoreInstancesOverTheSameFile() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("approved-apps.json")
        try ApprovedAppStore(fileURL: url, encryption: testEncryption()).approve(
            bundleIdentifier: "com.apple.Notes",
            displayName: "Notes",
            approvedAt: .fixture
        )

        let reopened = try ApprovedAppStore(fileURL: url, encryption: testEncryption()).loadAll()

        #expect(reopened.map(\.bundleIdentifier) == ["com.apple.Notes"])
        #expect(reopened.first?.displayName == "Notes")
        #expect(reopened.first?.approvedAt == .fixture)
    }

    /// Hand-written plaintext, not encoded from the current struct: a fixture produced by encoding
    /// `ApprovedApp` would be exactly what the store writes today and could not catch a real
    /// pre-encryption file.
    @Test
    func aLegacyPlaintextFileDecodesOnceAndIsRewrittenEncrypted() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("approved-apps.json")
        let legacyJSON = """
        [
            {
                "approvedAt": "2023-11-14T22:13:20Z",
                "bundleIdentifier": "com.apple.Notes",
                "displayName": "Notes"
            }
        ]
        """
        try Data(legacyJSON.utf8).write(to: url, options: .atomic)
        #expect(!(try Data(contentsOf: url)).starts(with: LocalStorageEncryption.fileHeader))
        let store = ApprovedAppStore(fileURL: url, encryption: testEncryption())

        let loaded = try store.loadAll()

        #expect(loaded.map(\.bundleIdentifier) == ["com.apple.Notes"])
        #expect(loaded.first?.approvedAt == .fixture)
        // Rewritten encrypted in place, and the plaintext identifier is gone from the bytes.
        try expectEncryptedFile(url, hiding: "com.apple.Notes")
        // And the migration did not lose or duplicate the record on the way through.
        #expect(try store.loadAll().map(\.bundleIdentifier) == ["com.apple.Notes"])
    }

    /// **A grant this store will not hold.** The deny list already refuses at three doors above
    /// this, and the runtime screen check above those — so this is belt and braces, and it exists
    /// because a durable grant outlives the session that minted it. An entry for a listed terminal
    /// sitting in the file would look like permission to anyone who read it later.
    @Test
    func aTerminalOnTheDenyListCannotBeStoredAsAnApprovedApp() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ApprovedAppStore(
            fileURL: root.appendingPathComponent("approved-apps.json"),
            encryption: testEncryption()
        )

        let refused = try store.approve(
            bundleIdentifier: "com.apple.Terminal",
            displayName: "Terminal",
            approvedAt: .fixture
        )

        #expect(refused == nil)
        #expect(try store.loadAll().isEmpty)
        // Nothing was written at all — not an empty list, no file.
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// The refusal reads the production comparison rather than a copy of it, so it inherits the
    /// deny list's own case-insensitivity and its whole membership. Termius is the entry a copy
    /// would most plausibly have got wrong.
    @Test
    func theTerminalRefusalFollowsTheDenyListRatherThanASecondCopyOfIt() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ApprovedAppStore(
            fileURL: root.appendingPathComponent("approved-apps.json"),
            encryption: testEncryption()
        )

        for spelling in ["com.apple.terminal", "com.apple.TERMINAL", "  com.apple.Terminal  "] {
            #expect(try store.approve(bundleIdentifier: spelling, displayName: "Terminal") == nil, "\(spelling)")
        }
        #expect(try store.approve(bundleIdentifier: "com.termius-dmg.mac", displayName: "Termius") == nil)
        #expect(try store.approve(bundleIdentifier: "com.googlecode.iterm2", displayName: "iTerm") == nil)
        #expect(try store.loadAll().isEmpty)

        // And an app that is not on the list is stored, so the assertions above are about the deny
        // list and not about the store refusing everything.
        #expect(try store.approve(bundleIdentifier: "com.apple.Notes", displayName: "Notes") != nil)
        #expect(try store.loadAll().map(\.bundleIdentifier) == ["com.apple.Notes"])
    }

    /// **Stored as given, compared case-folded** — row I's expensive lesson, which cost every
    /// session its first iteration when `ScreenControlVerdict` stored the lowercased form and then
    /// handed it to ScreenCaptureKit.
    @Test
    func theIdentifierIsStoredAsGivenAndMatchedCaseInsensitively() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ApprovedAppStore(
            fileURL: root.appendingPathComponent("approved-apps.json"),
            encryption: testEncryption()
        )

        try store.approve(bundleIdentifier: "  com.apple.Notes  ", displayName: "Notes", approvedAt: .fixture)

        let stored = try #require(try store.loadAll().first)
        // Trimmed, but the bundle's own capitals survive — this string is what macOS is asked with.
        #expect(stored.bundleIdentifier == "com.apple.Notes")
        // Both sides fold at the comparison, the same rule the deny list uses.
        #expect(stored.matches(bundleIdentifier: "com.apple.notes"))
        #expect(stored.matches(bundleIdentifier: "COM.APPLE.NOTES"))
        #expect(stored.matches(bundleIdentifier: " com.apple.Notes "))
        #expect(!stored.matches(bundleIdentifier: "com.apple.notes.helper"))
    }

    /// One user list, per app, forever (founder, 2026-08-16). A second approval of the same app —
    /// under any spelling — neither duplicates the row nor restarts the clock on when the user
    /// actually decided.
    @Test
    func reApprovingAnAppKeepsOneRowAndTheOriginalApprovalTime() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ApprovedAppStore(
            fileURL: root.appendingPathComponent("approved-apps.json"),
            encryption: testEncryption()
        )
        try store.approve(bundleIdentifier: "com.apple.Notes", displayName: "Notes", approvedAt: .fixture)

        let second = try store.approve(
            bundleIdentifier: "COM.APPLE.NOTES",
            displayName: "Notes",
            approvedAt: .fixture.addingTimeInterval(3_600)
        )

        #expect(second?.approvedAt == .fixture)
        let loaded = try store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.bundleIdentifier == "com.apple.Notes")
        #expect(loaded.first?.approvedAt == .fixture)
    }

    @Test
    func aBlankIdentifierStoresNothing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ApprovedAppStore(
            fileURL: root.appendingPathComponent("approved-apps.json"),
            encryption: testEncryption()
        )

        #expect(try store.approve(bundleIdentifier: "   ", displayName: "Nothing") == nil)
        #expect(try store.approve(bundleIdentifier: "", displayName: "Nothing") == nil)
        #expect(try store.loadAll().isEmpty)
    }

    /// Deterministic order, most recently approved first, with the identifier as the tiebreak so
    /// two grants minted in the same second do not swap places between reads.
    @Test
    func grantsLoadMostRecentlyApprovedFirstWithAStableTiebreak() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ApprovedAppStore(
            fileURL: root.appendingPathComponent("approved-apps.json"),
            encryption: testEncryption()
        )

        try store.approve(bundleIdentifier: "com.apple.Notes", displayName: "Notes", approvedAt: .fixture)
        try store.approve(
            bundleIdentifier: "com.apple.Safari",
            displayName: "Safari",
            approvedAt: .fixture.addingTimeInterval(60)
        )
        // Same instant as Notes — the tiebreak is what orders these two.
        try store.approve(bundleIdentifier: "com.apple.Mail", displayName: "Mail", approvedAt: .fixture)

        #expect(try store.loadAll().map(\.bundleIdentifier) == [
            "com.apple.Safari",
            "com.apple.Mail",
            "com.apple.Notes"
        ])
    }

    /// **A load failure is a throw, not an empty list.** Reading a grant file that will not decrypt
    /// as "no grants" would make Sonny ask about every app the user had already allowed, and would
    /// tell them nothing about why.
    @Test
    func anUndecryptableFileThrowsRatherThanReadingAsNoGrants() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("approved-apps.json")
        try ApprovedAppStore(
            fileURL: url,
            encryption: LocalStorageEncryption(
                keyManager: ApprovedAppTestKeyManager(byte: 0x42)
            )
        ).approve(bundleIdentifier: "com.apple.Notes", displayName: "Notes", approvedAt: .fixture)

        let wrongKey = ApprovedAppStore(
            fileURL: url,
            encryption: LocalStorageEncryption(keyManager: ApprovedAppTestKeyManager(byte: 0x99))
        )

        #expect(throws: (any Error).self) {
            _ = try wrongKey.loadAll()
        }
    }

    /// **A write failure propagates.** The store does not swallow one into a silent no-op, because
    /// a caller that cannot tell a stored grant from an unstored one is a caller that will tell the
    /// user their choice was remembered when it was not. What the caller says about it is the
    /// caller's own sentence — never the load banner's "could not be decrypted or decoded", which
    /// describes a different problem entirely.
    @Test
    func aWriteFailurePropagatesInsteadOfLookingLikeASuccessfulGrant() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // A regular file where the store wants its directory, so `createDirectory` cannot succeed.
        let blocked = root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked, options: .atomic)
        let store = ApprovedAppStore(
            fileURL: blocked.appendingPathComponent("approved-apps.json"),
            encryption: testEncryption()
        )

        #expect(throws: (any Error).self) {
            _ = try store.approve(bundleIdentifier: "com.apple.Notes", displayName: "Notes")
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// The default path lands beside the other nine, under Application Support/Sonny, and carries
    /// the filename the wipe's list and `LocalStore` both resolve through this same type.
    @Test
    func theDefaultFileSitsBesideTheOtherStores() {
        let store = ApprovedAppStore()

        #expect(store.fileURL.lastPathComponent == "approved-apps.json")
        #expect(store.fileURL.deletingLastPathComponent().lastPathComponent == "Sonny")
        #expect(LocalStore.approvedApps.fileURL() == store.fileURL)
        #expect(LocalDataDeletionService.defaultStoreFileURLs().contains(store.fileURL))
    }
}

/// The same instant every other store's tests pin to (1_700_000_000). Declared here because the
/// original is `fileprivate` to `LocalStorageSecurityTests.swift`, and a second copy of one constant
/// is cheaper than widening that file's surface.
private extension Date {
    static let fixture = Date(timeIntervalSince1970: 1_700_000_000)
}

private struct ApprovedAppTestKeyManager: LocalStorageKeyManaging {
    let byte: UInt8

    func keyData() throws -> Data {
        Data(repeating: byte, count: 32)
    }
}
