import Foundation
import MacAgentCore

/// One approved app, as a list that offers to take it back renders it.
///
/// Identified by the bundle identifier rather than a UUID, for the reason
/// `MemoryEntryPresentation` gives about the same store: a grant is keyed by the app it names and
/// the record carries no id of its own.
struct ApprovedAppRowPresentation: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    /// What a screen reader is told the Remove on this row does. Named per app, because a list of
    /// identical "Remove" buttons is a list of buttons a screen reader cannot tell apart.
    let removeAccessibilityLabel: String
}

/// The words and the rows behind Settings → Security & Access → **Screen Control**'s allowed-apps
/// list (SONNY-144), and behind the Memory section's list of the same store.
///
/// **Two surfaces, one wording, deliberately.** Command Center's Memory section has listed this
/// store since SONNY-208 and Settings lists it now; the store is the same store, so a user reading
/// both must not be shown two different sentences about one grant. ``row(for:now:)`` is what
/// `MemoryEntryPresentation` builds its own rows from, so the title fallback and the detail line
/// exist once.
///
/// **A value rather than literals in the view**, the same call `MemoryDeletionCopy` records: a
/// confirmation that names the wrong thing is worse than one that says nothing, and copy sitting in
/// a `private` SwiftUI view inside a six-thousand-line file is copy no test can read.
enum ApprovedAppRevocationPresentation {
    // MARK: - Rows

    /// The grants a revocation list may render, which is not every grant the file holds.
    ///
    /// **Belt and braces, and the belt is elsewhere.** `ApprovedAppStore.approve` already refuses to
    /// persist an app the terminal deny list refuses, and the deny list refuses again at three doors
    /// above the store — so a terminal cannot become a grant today. This is about the file rather
    /// than about today's code: a stored list outlives the code that filled it, and a revocation
    /// surface offering to take back a grant on Terminal would tell the user they had allowed
    /// something Sonny will never do. Reading `ScreenControlPolicy.verdict` is the production
    /// comparison itself, not a second reading of `terminalBundleIdentifiers`, so this tracks the
    /// list rather than drifting from it.
    ///
    /// A blank identifier is dropped for the same reason the store's write path drops one: there is
    /// no app it can name and nothing a Remove on it could match.
    static func eligible(_ apps: [ApprovedApp]) -> [ApprovedApp] {
        apps.filter { app in
            !app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ScreenControlPolicy.verdict(
                    bundleIdentifier: app.bundleIdentifier,
                    displayName: app.displayName
                ).isEligible
        }
    }

    /// How one grant reads.
    ///
    /// The identifier is shown beside the name rather than instead of it: the name is what the user
    /// recognises, and the identifier is what the grant is actually matched on, so two installed
    /// builds calling themselves the same thing stay distinguishable. `displayName` falls back to
    /// the identifier because a grant whose row is blank is a grant nobody can decide about.
    static func row(for app: ApprovedApp, now: Date = Date()) -> ApprovedAppRowPresentation {
        let title = app.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? app.bundleIdentifier
            : app.displayName
        return ApprovedAppRowPresentation(
            id: app.bundleIdentifier,
            title: title,
            detail: "\(app.bundleIdentifier) · allowed \(TaskHistoryDateFormatter.relativeTimestamp(for: app.approvedAt, now: now))",
            removeAccessibilityLabel: "Remove \(title)"
        )
    }

    static func rows(for apps: [ApprovedApp], now: Date = Date()) -> [ApprovedAppRowPresentation] {
        eligible(apps).map { row(for: $0, now: now) }
    }

    // MARK: - The section's own words

    static let listTitle = "Apps you've allowed"

    static let listDetail = "Each one can be taken back. Sonny asks again the next time it needs that app."

    static let removeLabel = "Remove"

    static let removeAllLabel = "Remove All"

    static let removeAllAccessibilityLabel = "Remove all allowed apps"

    /// **Per-row Remove confirms too, since PR #175's review** (F2). The branch shipped it as a
    /// single press on the reasoning that one Remove costs the user one ask and answering it puts the
    /// grant back. Both halves of that were wrong. `CommandCenterView.swift`'s Memory entries sheet
    /// carries an invariant, written four days after this ticket was: *a misclick here is
    /// unrecoverable — a revoked app grant, a snippet, a copied item — and nothing else in the app
    /// deletes a row on one press*, which names this exact record as its example. And a Remove does
    /// not cost one ask while a session is running: it **stops that session**, which is this branch's
    /// own tested behaviour and the last item on its manual checklist.
    static func removeConfirmationTitle(for row: ApprovedAppRowPresentation) -> String {
        "Remove \(row.title)?"
    }

    static let removeConfirmButtonLabel = "Remove"

    /// The sentence the Memory sheet already uses for removing one of these — one store, two
    /// surfaces, one wording, which is the rule the missing dialog had broken in the first place.
    static var removeConfirmationMessage: String {
        MemoryDeletionCopy.entryMessage(for: .approvedApps)
    }

    static let removeAllConfirmationTitle = "Remove all allowed apps?"

    static let removeAllConfirmButtonLabel = "Remove All"

    /// What Remove All takes and what happens next — the Memory section's sentence for this store,
    /// not a second one written here. Both controls empty the same file, and two sentences about one
    /// consequence is how they start disagreeing.
    static var removeAllConfirmationMessage: String {
        MemoryDeletionCopy.message(for: .approvedApps)
    }

    // MARK: - Whether Remove All is offered

    /// Whether the section offers Remove All, given how many grants the **store** holds.
    ///
    /// **Not `!rows.isEmpty`, and the difference is a route rather than a nicety** (PR #175 review,
    /// F1). ``eligible(_:)`` hides a grant the deny list refuses, so a file holding only ineligible
    /// entries renders no rows — and gating this control on the rendered list hid the one control
    /// that reaches them. Everything else was already shut: the Memory row's Delete is disabled at a
    /// count of zero while the file reads fine, and the entries sheet reads the same filtered array.
    /// The grant was then removable only by Settings → Data's whole-app wipe, which is a regression
    /// against the unfiltered list this branch replaced, and the exact shape `CLAUDE.md` records for
    /// this row — *a control gated on entries existing is disabled exactly when it is needed*.
    ///
    /// So the count comes from before the filter. The visible consequence is that Remove All can
    /// appear above an empty list, which happens **only** in the case the filter exists for: a file
    /// holding grants no surface will show. That is the right moment for the control to be there.
    static func offersRemoveAll(storedGrantCount: Int) -> Bool {
        storedGrantCount > 0
    }

    // MARK: - The states that are not a list

    /// The common case in Safe mode, not an edge one, so it gets a real empty state.
    ///
    /// Both sentences are the Memory section's for this store. `emptyMessage` names the command that
    /// ends the state, which is this repository's empty-state convention and matters more here than
    /// most places: the one thing a user must not conclude from an empty list is that there is an
    /// Add button they have failed to find. There is not one, on purpose — approval happens by being
    /// asked, in the flow.
    static var emptyTitle: String { MemoryDeletionCopy.emptyTitle(for: .approvedApps) }

    static var emptyMessage: String { MemoryDeletionCopy.emptyMessage(for: .approvedApps) }

    static let emptySystemImage = MemoryDeletionCopy.emptyStateSystemImage(for: .readable)

    /// **An unreadable store is not an empty one, and this is exactly where that bites** (SONNY-239's
    /// rule, applied to a new surface). A grants file that will not decrypt loads as zero grants, so
    /// without this the section would tell a user who has allowed apps that they have allowed none —
    /// and offer them nothing to do about it.
    ///
    /// The recovery is Memory's, because Memory's Delete is the one control that sets an unreadable
    /// file aside instead of destroying it. Standing is `.elsewhere`: the reader is in Settings, a
    /// page away from the row being named, so the sentence has to say where to go. This store's own
    /// `MemoryRowDestination` is `.entriesSheet`, which would have named a row that is not on their
    /// screen — the reason the standing is a separate question from the routing.
    static var unreadableTitle: String { MemoryDeletionCopy.unreadableTitle(for: .approvedApps) }

    static var unreadableMessage: String {
        MemoryDeletionCopy.unreadableRecoveryMessage(for: .approvedApps, standing: .elsewhere)
    }

    static let unreadableSystemImage = MemoryDeletionCopy.emptyStateSystemImage(for: .unreadable)

    /// What the list shows instead of rows, whichever of the two states it is in.
    ///
    /// **One function rather than three ternaries in a view body** (PR #175 review, F4, and the
    /// shape PR #110's F7 named). The view had `readability == .readable ?` written three times, once
    /// per field, and a mutant forcing all three to the empty arm survived the whole suite: nothing
    /// asserted the view picks the right one, and a swapped ternary would have left every test green.
    /// `MemoryDeletionCopy.confirmation(for:readability:)` is the same call made for the sheet.
    ///
    /// Only the two states this list can reach. `.partlyUnreadable` needs a count above zero and this
    /// runs only when the list is empty, so it cannot arrive; it takes the unreadable arm if it ever
    /// does, which is the conservative direction — a file that will not open is news and an empty
    /// list is not.
    static func emptyState(
        for readability: MemoryRowReadability
    ) -> (systemImage: String, title: String, message: String) {
        switch readability {
        case .readable:
            return (emptySystemImage, emptyTitle, emptyMessage)
        case .partlyUnreadable, .unreadable:
            return (unreadableSystemImage, unreadableTitle, unreadableMessage)
        }
    }

    // MARK: - Write failures
    //
    // **There is deliberately no wording here.** A Remove in Settings and a Delete on the Memory
    // sheet are the same operation on the same store, so both go through
    // `AgentViewModel.forgetApprovedApp(_:)` and report a failed write in that one sentence. A
    // second message written for this surface would be a second thing the app says about one
    // failure. Remove All has no twin anywhere, so its message lives at its only call site.
    //
    // What neither may do is borrow the *load* failure's words: "could not be decrypted or decoded"
    // is what an unreadable file says, and saying it after a Remove would tell the user Sonny cannot
    // read a list it had just rendered for them (`CLAUDE.md`).
}
