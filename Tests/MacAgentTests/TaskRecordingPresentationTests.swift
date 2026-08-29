import Foundation
import MacAgentCore
import Testing
@testable import MacAgent

/// The name is the mechanism (founder, 2026-08-16), so it gets a test rather than a review comment.
struct TaskRecordingPresentationTests {
    /// **The word the feature is not called.** "Incognito" borrows a promise from browsers this does
    /// not keep — files still get created, apps still open, the command still goes to the provider —
    /// and the 2026-08-14 rule forbids the clarifying sentence that would normally patch an
    /// over-promising name. Reintroducing it would quietly restore the promise.
    @Test
    func noUserFacingStringSaysIncognito() {
        for text in [
            TaskRecordingPresentation.controlLabel,
            TaskRecordingPresentation.activeChipText,
            TaskRecordingPresentation.clearAccessibilityLabel,
            TaskRecordingPresentation.controlAccessibilityValue(isOn: true),
            TaskRecordingPresentation.controlAccessibilityValue(isOn: false)
        ] {
            #expect(!text.lowercased().contains("incognito"), "\(text) must not say incognito")
            #expect(!text.lowercased().contains("private"), "\(text) over-promises: \(text)")
            #expect(!text.lowercased().contains("anonymous"))
        }
    }

    /// The label has to carry the whole meaning, because no sentence may sit beside it.
    @Test
    func theLabelSaysExactlyWhatTheFeatureDoes() {
        #expect(TaskRecordingPresentation.controlLabel == "Don't save this task")
        #expect(TaskRecordingPresentation.activeChipText == "Won't be saved")
        // The on state has its own word, so the chip is not just the label repeated.
        #expect(TaskRecordingPresentation.activeChipText != TaskRecordingPresentation.controlLabel)
        #expect(TaskRecordingPresentation.controlAccessibilityValue(isOn: true) == "On")
        #expect(TaskRecordingPresentation.controlAccessibilityValue(isOn: false) == "Off")
    }

    /// No copy explains how it works — no tooltip, no help text, no disclosure line. Any of those
    /// would be the explanatory copy the 2026-08-14 decision rules out, and the reason the name was
    /// narrowed in the first place.
    @Test
    func noCopyExplainsHowItWorksOrOverPromisesWhatItHides() {
        let all = [
            TaskRecordingPresentation.controlLabel,
            TaskRecordingPresentation.activeChipText,
            TaskRecordingPresentation.clearAccessibilityLabel
        ].joined(separator: " ").lowercased()

        for forbidden in [
            "history", "clipboard", "journal", "store", "disk", "local", "server",
            "because", "which means", "note that", "hidden", "hide", "secret", "trace"
        ] {
            #expect(!all.contains(forbidden), "copy should not mention \"\(forbidden)\": \(all)")
        }
        // Short enough to be a label rather than a sentence.
        #expect(!TaskRecordingPresentation.controlLabel.contains("."))
        #expect(!TaskRecordingPresentation.activeChipText.contains("."))
    }
}
