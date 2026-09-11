import Foundation
import Testing
import MacAgentCore
@testable import MacAgent

/// SONNY-449. `AgentViewModel.failureMessage(for:)` is what a run's thrown error becomes on the
/// widget and in Command Center: an unreadable local file gains the storage banner's way out, and
/// every other error is its own sentence.
@Suite
struct UnreadableStoreWayOutTests {
    private struct SomeOtherError: Error, LocalizedError {
        var errorDescription: String? { "Sonny couldn't finish this one. Try again." }
    }

    @Test
    func anUnreadableFileEndsWithTheBannersWayOut() {
        let error = LocalStorageEncryptionError.undecodableLocalData(underlying: "CryptoKitError.authenticationFailure")

        let message = AgentViewModel.failureMessage(for: error)

        #expect(message == "A local data file exists but could not be decrypted or decoded. Open Memory in Command Center to clear it.")
        #expect(message.hasSuffix(LocalStorageEncryptionError.unreadableStoreWayOut))
    }

    @Test
    func anyOtherErrorIsItsOwnSentence() {
        #expect(AgentViewModel.failureMessage(for: SomeOtherError()) == "Sonny couldn't finish this one. Try again.")
        #expect(
            AgentViewModel.failureMessage(for: LocalStorageEncryptionError.invalidKeyLength(16))
                == "Local storage encryption key must be 32 bytes, got 16."
        )
    }

    /// The constant is the banner's sentence, held by value so a rewording in one place is a
    /// failing test rather than two surfaces drifting.
    @Test
    func theWayOutIsTheBannersSentence() {
        #expect(LocalStorageEncryptionError.unreadableStoreWayOut == "Open Memory in Command Center to clear it.")
    }
}
