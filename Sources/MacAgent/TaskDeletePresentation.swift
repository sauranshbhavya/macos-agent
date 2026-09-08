import Foundation
import MacAgentCore

/// What the task-detail sheet knows about a task's screen record by the time it renders.
///
/// **Resolved before the sheet is presented, not inside it, and that is the whole design.** The
/// rule this ticket has to keep is that a task whose screen record is gone renders exactly like a
/// task that never ran one. If the sheet looked the record up after appearing, that equality would
/// hold only *eventually* — the section and the sheet's own height would settle a frame later, so
/// a task with a screen record would visibly jump. Resolving first makes the two indistinguishable
/// by construction rather than by timing, and leaves the sheet a pure function of its input.
///
/// The lazy read it replaces was deliberate for a reason that still holds — decrypting the journal
/// for every row would make opening an ordinary task's receipt cost a file read it has no use for.
/// This keeps that: the lookup happens once, for the one row the user actually clicked.
enum TaskScreenRecordState: Equatable {
    /// No screen record to show. **Deliberately one case for three different histories**: the task
    /// never ran a screen-control session, its session was deleted, or its session aged out at the
    /// journal's 500-session cap. The product cannot tell the last two apart honestly, and the
    /// no-explanatory-copy rule forbids explaining the difference, so they are one state here
    /// rather than two that a later reader might try to render differently.
    case none
    case present(VisionSessionRecord)
    /// The journal exists but would not read back. **Not folded into `none`**: an unreadable
    /// journal and a deleted one are different things, and the load-failure wording is a real,
    /// visible problem the user is entitled to see.
    case unreadable(String)
}

/// The two delete actions' labels, copy and gating, kept out of the SwiftUI body so they can be
/// tested. This repository has no view-rendering tests, so anything left inside a `body` is guarded
/// only by the manual checklist — everything here is guarded by the suite instead.
enum TaskDeletePresentation {
    // MARK: - Identity

    /// The row's stable identity, replacing the two compound keys the Tasks page used to fake one
    /// from: `TaskLogEntry.id` as `"\(startedAt.timeIntervalSince1970)-\(command)"` and the list's
    /// `ForEach(id: \.startedAt)`. Both collide for two runs of one command started inside the same
    /// second, because the store persists whole-second timestamps — so the sheet could open the
    /// wrong twin and the list could collapse two rows into one.
    ///
    /// The fallback is the old key, and it is deliberately no better than what it replaces: it is
    /// reachable only if SONNY-115's id backfill could not write, and inventing a fresh identity
    /// per render would be worse — the row would lose its selection on every refresh.
    static func rowIdentity(for record: CompletedTaskRecord) -> String {
        record.id ?? "legacy-\(record.startedAt.timeIntervalSince1970)-\(record.command)"
    }

    // MARK: - Labels
    //
    // Under the founder's rule of 2026-08-16, a precise label is not explanation, and the label has
    // to carry the whole meaning because no sentence may sit beside it. Two delete actions near each
    // other must be distinguishable at a glance, so bare "Delete" cannot appear twice with
    // different reach. These are the planning ticket's proposed wording, built and recorded — the
    // founder and Bhavya settle the final words in the UI/UX pass (SONNY-109).

    static let taskActionLabel = "Delete task"

    /// Reuses the section title this sheet already ships, so the object of the verb is literally on
    /// screen beside the action.
    static let screenRecordActionLabel = "Delete what Sonny did on screen"

    static let screenRecordSectionTitle = "What Sonny did on screen"

    // MARK: - Confirmation copy
    //
    // Shape borrowed from the workspace delete (a titled confirmation with a `.destructive` button
    // and a message naming what else the action reaches) rather than inventing a second pattern.

    static func taskConfirmationTitle(for record: CompletedTaskRecord) -> String {
        let command = record.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return "Delete this task?"
        }
        return "Delete “\(truncatedForConfirmation(command))”?"
    }

    /// Named only when there is something extra to name. A task with no screen record gets no
    /// message at all, because the title already says everything the action does.
    static func taskConfirmationMessage(hasScreenRecord: Bool) -> String? {
        hasScreenRecord ? "This also deletes what Sonny did on screen for this task." : nil
    }

    /// From the resolved state, for the detail sheet, which has already paid for the lookup.
    static func taskConfirmationMessage(for state: TaskScreenRecordState) -> String? {
        taskConfirmationMessage(hasScreenRecord: showsScreenRecordSection(state))
    }

    /// From the link alone, for the history row, which has not.
    ///
    /// A row cannot know whether the session still resolves without decrypting the journal, and
    /// doing that for a row the user merely right-clicked is exactly the read the detail sheet's own
    /// comment exists to avoid. `visionSessionID` is free and is the honest question here anyway:
    /// the message names what the delete *reaches*, and a delete of something already gone is a
    /// no-op rather than a lie.
    static func taskConfirmationMessage(for record: CompletedTaskRecord) -> String? {
        taskConfirmationMessage(hasScreenRecord: record.visionSessionID != nil)
    }

    // Sentence case (2026-09-08 UI modernization): every button and label that is not a proper noun
    // reads in sentence case now, this pair included.
    static let taskConfirmButtonLabel = "Delete task"

    static let screenRecordConfirmationTitle = "Delete what Sonny did on screen?"

    /// States what this reaches and what survives — the two facts that distinguish this action from
    /// the other one.
    ///
    /// **The reach is now both halves** (SONNY-404, founder decision 2026-09-05). This press deletes
    /// the task's screenshots from the Mac's own journal *and* from Sonny's servers, through
    /// `DELETE /v1/tasks/{task_id}/screenshots` — a route that exists because §4.6's takes a task's
    /// whole content and this button names one part of it. Saying so is not the app explaining
    /// itself: it is a destructive control naming what it destroys, which is the same thing the
    /// whole wipe's dialog does and the same reason it says "from this Mac".
    static let screenRecordConfirmationMessage =
        "This deletes the screenshots from this Mac and from Sonny's servers. The task stays in your history."

    static let screenRecordConfirmButtonLabel = "Delete screen record"

    // MARK: - Gating

    /// The section renders for a screen record that is there, and for one that would not read back.
    /// It renders nothing at all when there is none — identical to a task that never ran a session,
    /// which is the point.
    static func showsScreenRecordSection(_ state: TaskScreenRecordState) -> Bool {
        switch state {
        case .none:
            return false
        case .present, .unreadable:
            return true
        }
    }

    /// Offered only for a screen record that actually read back. An unreadable journal gets the
    /// load-failure wording and no delete button: the store's delete is a read-modify-write, so it
    /// would fail on exactly the file that could not be read, and offering an action that cannot
    /// work is worse than not offering it.
    static func showsScreenRecordDeleteAction(_ state: TaskScreenRecordState) -> Bool {
        switch state {
        case .present:
            return true
        case .none, .unreadable:
            return false
        }
    }

    /// **The height moved to `TaskDetailPresentation` (row E, SONNY-148).** It used to live here as
    /// `showsScreenRecordSection(state) ? 560 : 320`, and the property that mattered was that it is
    /// keyed on the *resolved* state rather than on `record.visionSessionID` — otherwise a task
    /// whose session is gone opens a 560-tall sheet with a gap where the section used to be, visibly
    /// unlike a task that never ran one, which is the difference row D exists to remove. That
    /// property is unchanged and still tested; a second optional section simply made a two-way
    /// branch the wrong shape, so the height is a sum over the sections that are present.

    // MARK: - Resolution

    static func resolveScreenRecord(
        for record: CompletedTaskRecord,
        journalStore: VisionSessionJournalStore
    ) -> TaskScreenRecordState {
        guard let sessionID = record.visionSessionID else {
            return .none
        }
        do {
            guard let session = try journalStore.record(withID: sessionID) else {
                return .none
            }
            return .present(session)
        } catch {
            return .unreadable(
                "This session's record could not be decrypted or decoded: \(error.localizedDescription)"
            )
        }
    }

    static func truncatedForConfirmation(_ command: String) -> String {
        let limit = 60
        guard command.count > limit else {
            return command
        }
        return command.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension CompletedTaskRecord {
    /// `TaskDeletePresentation.rowIdentity(for:)` as a property, so SwiftUI's `ForEach(id:)` can
    /// take it as a key path. One definition, used by both the list and the detail sheet — two
    /// independently written identities is how the page ended up with two different compound keys
    /// in the first place.
    var taskRowIdentity: String {
        TaskDeletePresentation.rowIdentity(for: self)
    }
}
