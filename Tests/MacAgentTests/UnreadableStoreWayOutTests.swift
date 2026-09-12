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
    /// **Every notice-channel site takes the helper, pinned one site at a time** (the delta pass on
    /// PR #233's fix round, F2: eight of the eleven sites were held by no test, and what kept them
    /// right was a sweep written in the entry's prose). Each site is found by its own message
    /// prefix — a marker two sites share would let one stand in for the other — and must occur
    /// once; the text between the notice call's opening parenthesis and the prefix is whitespace,
    /// so the message really is on the notice channel; and the message ends with the helper's
    /// interpolation and never carries the bare `localizedDescription`. Each of the plan's W11 to
    /// W18 puts one of the eight back to the bare sentence, and the cell for that site is what
    /// kills it.
    @Test(arguments: NoticeChannelSite.allCases)
    @MainActor
    func aNoticeChannelSiteTakesTheHelper(site: NoticeChannelSite) throws {
        let source = try MacAgentSource.read("AgentViewModel.swift")
        let marker = "\"" + site.prefix
        #expect(source.components(separatedBy: marker).count - 1 == 1, "\(site): the prefix is not in the source exactly once")
        let range = try #require(source.range(of: marker))
        let lineEnd = source[range.upperBound...].firstIndex(of: "\n") ?? source.endIndex
        let message = String(source[range.upperBound..<lineEnd])
        #expect(message.hasPrefix("\\(Self.failureMessage(for: error))\""), "\(site): the prefix is not followed by the helper: \(message)")
        #expect(!message.contains("localizedDescription"), "\(site): the bare description is back")
        let before = String(source[..<range.lowerBound].suffix(80))
        let call = try #require(before.range(of: "recordLocalStorageWriteFailure(", options: .backwards), "\(site): no notice call precedes the prefix")
        let gapIsWhitespace = before[call.upperBound...].allSatisfy(\.isWhitespace)
        #expect(gapIsWhitespace, "\(site): the prefix is not the notice call's own argument")
    }

    /// **The sweep the entry's prose carried, as a test**: no `setError(` or
    /// `recordLocalStorageWriteFailure(` message interpolates the bare `error.localizedDescription`
    /// except the clipboard setting's save, whose store writes without loading. The two line shapes
    /// are the fresh review's awk — the interpolation on the line after the call's opening
    /// parenthesis, or on the same line as the call.
    @Test
    @MainActor
    func noNoticeOrErrorSiteInterpolatesTheBareDescriptionExceptTheClipboardSetting() throws {
        let source = try MacAgentSource.read("AgentViewModel.swift")
        let lines = source.components(separatedBy: "\n")
        let bare = "\\(error.localizedDescription)\""
        var hits: [String] = []
        var previous = ""
        for line in lines {
            let opensACall = previous.hasSuffix("setError(") || previous.hasSuffix("recordLocalStorageWriteFailure(")
            let sameLine = (line.contains("setError(\"") || line.contains("recordLocalStorageWriteFailure(\"")) && line.contains(bare)
            if (opensACall && line.contains(bare)) || sameLine {
                hits.append(line.trimmingCharacters(in: .whitespaces))
            }
            previous = line.trimmingCharacters(in: .whitespaces)
        }
        #expect(hits.count == 1, "the bare description is interpolated at \(hits.count) sites: \(hits)")
        #expect(hits.first?.contains("clipboard history setting") == true, "the one bare site is not the clipboard setting's save: \(hits)")
    }

    @Test
    func theWayOutIsTheBannersSentence() {
        #expect(LocalStorageEncryptionError.unreadableStoreWayOut == "Open Memory in Command Center to clear it.")
    }
}

/// The eleven notice-channel sites the fresh review of PR #233 enumerated, each by the prefix its
/// message opens with in `AgentViewModel.swift` (the delta pass on the fix round found eight of
/// them held by no test: the plan detail, the unfinished-task record's clear and save, the
/// scheduled run's history row and plan, the pause, the schedule baseline and the run history).
enum NoticeChannelSite: CaseIterable, CustomStringConvertible {
    case routineSchedule
    case appControlGrant
    case taskHistory
    case taskPlan
    case unfinishedTaskClear
    case unfinishedTaskSave
    case scheduledRunHistory
    case scheduledRunPlan
    case schedulePause
    case scheduleBaseline
    case routineRunHistory

    var prefix: String {
        switch self {
        case .routineSchedule: return "Sonny could not save this routine's schedule: "
        case .appControlGrant: return "Sonny could not save that you allowed it to control \\(displayName): "
        case .taskHistory: return "Sonny could not save this task to task history: "
        case .taskPlan: return "Sonny could not save this task's plan: "
        case .unfinishedTaskClear: return "Sonny could not clear the record of a task that has now finished: "
        case .unfinishedTaskSave: return "Sonny \\(what): "
        case .scheduledRunHistory: return "Sonny could not save this scheduled run to task history: "
        case .scheduledRunPlan: return "Sonny could not save what this scheduled run planned: "
        case .schedulePause: return "Sonny could not pause this routine's schedule: "
        case .scheduleBaseline: return "Sonny could not save this routine's schedule state: "
        case .routineRunHistory: return "Sonny could not save this routine's run history: "
        }
    }

    var description: String {
        switch self {
        case .routineSchedule: return "the routine schedule"
        case .appControlGrant: return "the app-control grant"
        case .taskHistory: return "the task-history row"
        case .taskPlan: return "the task's plan"
        case .unfinishedTaskClear: return "the unfinished-task record's clear"
        case .unfinishedTaskSave: return "the unfinished-task record's save"
        case .scheduledRunHistory: return "the scheduled run's history row"
        case .scheduledRunPlan: return "the scheduled run's plan"
        case .schedulePause: return "the schedule pause"
        case .scheduleBaseline: return "the schedule baseline"
        case .routineRunHistory: return "the routine's run history"
        }
    }
}
