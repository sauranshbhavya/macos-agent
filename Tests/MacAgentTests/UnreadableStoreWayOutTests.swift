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

    /// An item job that could start none of its items reports the first item's failure by its
    /// sentence and not its type (`PlanItemJobError.everyItemUnavailable`), which is how a snippet
    /// job against a poisoned `snippets.json` reached the widget with no door (PR #233's second
    /// review). The way out follows the sentence wherever it travels.
    @Test
    func anItemJobThatFailedOnAnUnreadableFileKeepsTheWayOut() {
        let inner = LocalStorageEncryptionError.undecodableLocalData(underlying: "CryptoKitError.authenticationFailure")
        let wrapped = PlanItemJobError.everyItemUnavailable(inner.localizedDescription)

        let message = AgentViewModel.failureMessage(for: wrapped)

        #expect(message == "A local data file exists but could not be decrypted or decoded. Open Memory in Command Center to clear it.")
    }

    /// The control: a job that failed for any other reason is still its own sentence.
    @Test
    func anItemJobThatFailedForAnotherReasonIsItsOwnSentence() {
        let wrapped = PlanItemJobError.everyItemUnavailable("No file named report.pdf is on the Desktop.")

        #expect(AgentViewModel.failureMessage(for: wrapped) == "No file named report.pdf is on the Desktop.")
    }

    /// A sentence that already ends with the way out is not told twice.
    @Test
    func aSentenceThatAlreadyNamesTheWayOutIsNotToldTwice() {
        let already = PlanItemJobError.everyItemUnavailable(
            "A local data file exists but could not be decrypted or decoded. "
                + LocalStorageEncryptionError.unreadableStoreWayOut
        )

        let message = AgentViewModel.failureMessage(for: already)

        #expect(message.components(separatedBy: LocalStorageEncryptionError.unreadableStoreWayOut).count - 1 == 1)
        #expect(message.hasSuffix(LocalStorageEncryptionError.unreadableStoreWayOut))
    }

    /// The constant is the banner's sentence, held by value so a rewording in one place is a
    /// failing test rather than two surfaces drifting.
    @Test
    func theWayOutIsTheBannersSentence() {
        #expect(LocalStorageEncryptionError.unreadableStoreWayOut == "Open Memory in Command Center to clear it.")
    }
}
