import Foundation
import MacAgentCore

/// One boundary change the workspace detail sheet is ready to submit, as data.
///
/// Pairs the two things a dispatch needs and keeps them built in one place, because they have to
/// agree: `request` is what actually happens (it becomes the `edit_workspace` plan), and
/// `displayCommand` is what the user is told happened (it becomes `lastCommand`, the running
/// indicator's label, and the task-history row). A screen that built those independently could show
/// one sentence and perform a different edit, and nothing downstream would notice — the plan and the
/// history row are read by different code that never compares them.
struct WorkspaceScopeEditDispatch: Equatable {
    let request: WorkspaceScopeEditRequest
    /// The sentence the equivalent typed command would have been.
    ///
    /// Deliberately still a sentence rather than something terser. `CompletedTaskRecord.command` is
    /// the only description a history row has, and it is read weeks later next to rows that really
    /// were typed — "Remove Safari" beside "In my Client Alpha workspace, remove the app Safari"
    /// would make picker-dispatched edits look like a different, lesser kind of event than the
    /// identical typed one. It is the same event.
    let displayCommand: String
}

/// Builds the sentence and the request for one boundary change, so both doors — a picker addition
/// and a row's Remove — produce them the same way.
enum WorkspaceScopeEditCommand {
    /// How each dimension is named in the sentence, matching the nouns the sheet's sections already
    /// used when they handed these sentences to the composer. Kept identical on purpose: the wording
    /// is what a user recognises in their own history, and this ticket changes who types the
    /// sentence, not what it says.
    static func noun(for kind: ScopedResourceKind) -> String {
        switch kind {
        case .app:
            return "the app"
        case .webDomain:
            return "the URL"
        case .fileLocation:
            return "the folder"
        }
    }

    static func dispatch(
        workspaceName: String,
        kind: ScopedResourceKind,
        value: String,
        action: WorkspaceScopeEditRequest.Action
    ) -> WorkspaceScopeEditDispatch {
        let verb = action == .add ? "add" : "remove"
        return WorkspaceScopeEditDispatch(
            request: WorkspaceScopeEditRequest(
                workspaceName: workspaceName,
                kind: kind,
                value: value,
                action: action
            ),
            displayCommand: "In my \(workspaceName) workspace, \(verb) \(noun(for: kind)) \(value)"
        )
    }
}

/// Everything the sheet's Add dialog renders for one dimension, computed as data.
///
/// **The catalog is a suggestion source here and nothing more.** `MacAppCatalog`'s twelve apps are
/// the allowlist of what Sonny may *launch*; a workspace may list an app it does not carry, for
/// scope membership only (the decoupling founder decision recorded on SONNY-44). So a picker that
/// offered only those twelve would be strictly narrower than the typed command it replaces — it
/// would quietly remove the ability to put Xcode inside a boundary — which is why the free-entry
/// field is not a fallback for completeness but a first-class half of this dialog, carrying
/// `WorkspaceScopeOnlyApps`' own wording at the moment the name is typed.
///
/// Pure and `Equatable`, per this repo's standard for anything a view renders: there is no SwiftUI
/// view-inspection harness, so a sentence composed inside a `body` is a sentence no test can read.
struct WorkspaceScopeAddPresentation: Equatable {
    struct Entry: Equatable {
        let name: String
        /// True when this workspace already lists this app — asked of `WorkspaceScope` itself rather
        /// than by comparing strings, so "Chrome" and a stored "Google Chrome" are one app here
        /// exactly as they are to the boundary and to the capability's own duplicate check.
        let isAlreadyListed: Bool
        let accessibilityLabel: String
        let dispatch: WorkspaceScopeEditDispatch
    }

    struct Category: Equatable {
        let title: String
        let entries: [Entry]
    }

    /// The words shown in place of a row's Add button when the workspace already lists that app.
    ///
    /// Owned here rather than written into the view body. It was a literal in `WorkspaceScopeAddView`
    /// while that view's own doc comment said none of its copy was — and it is the picker's most
    /// user-visible string, the one a manual item asks the user to read back. (PR #40 review, F7.)
    static let alreadyAddedText = "Already added"

    let title: String
    let kind: ScopedResourceKind
    let workspaceName: String
    /// Empty for every dimension except apps — there is no catalog of URLs or folders to offer, and
    /// inventing one would be inventing product.
    let categories: [Category]
    let freeEntryTitle: String
    let freeEntryPlaceholder: String
    /// The free-entry Add button's accessibility label. Here rather than interpolated in the view
    /// body, for the reason commit 5ef804f moved the section builder's equivalent out of one.
    /// (PR #40 review, F7.)
    let freeEntryAddAccessibilityLabel: String
    /// A standing note about what this dimension accepts, shown before anything is typed. Non-nil
    /// only where a rule exists that a user would otherwise discover by being refused.
    let freeEntryNote: String?

    private let catalog: MacAppCatalog
    /// The evaluator's view of the workspace being edited, kept so the free-entry field can ask the
    /// same "does this already count" question the catalog rows ask.
    private let scope: WorkspaceScope

    /// Fixed grouping of the launch catalog's twelve, by what the app is for.
    ///
    /// Presentational only, and deliberately *not* a new concept in the model: no category is
    /// stored, nothing branches on one, and `MacAppCatalog` is untouched — expanding it is
    /// SONNY-66's, and treating it as anything other than a launch catalog is explicitly forbidden.
    /// Membership is stated by display name and the catalog is filtered by it, so the catalog stays
    /// the single list; an app this table does not name still appears, under `uncategorizedTitle`,
    /// rather than vanishing. `everyCatalogAppAppearsExactlyOnce` pins that.
    private static let categoryOrder: [(title: String, names: [String])] = [
        ("Browsers", ["Safari", "Chrome"]),
        ("Communication", ["Mail", "Messages", "Slack"]),
        ("Productivity", ["Notes", "Calendar", "Finder"]),
        ("Media", ["Apple Music", "Spotify"]),
        ("Developer", ["VS Code", "Terminal"])
    ]

    static let uncategorizedTitle = "More apps"

    init(
        kind: ScopedResourceKind,
        workspace: StoredWorkspace,
        catalog: MacAppCatalog = .default,
        whitelist: PathWhitelist = PathWhitelist()
    ) {
        self.kind = kind
        self.workspaceName = workspace.name
        self.catalog = catalog
        // Built once for every dimension, not only for apps: the free-entry field consults it too.
        // Bound to a local as well, because the category builder below reads it inside closures and
        // `self` is not fully initialized there yet.
        let scope = WorkspaceScope(workspace: workspace, catalog: catalog, whitelist: whitelist)
        self.scope = scope
        freeEntryAddAccessibilityLabel = "Add what you typed to \(workspace.name)"

        switch kind {
        case .app:
            title = "Add an app"
            freeEntryTitle = "Other app"
            freeEntryPlaceholder = "Xcode"
            freeEntryNote = nil
        case .webDomain:
            title = "Add a URL"
            freeEntryTitle = "URL"
            freeEntryPlaceholder = "https://example.com/handbook"
            freeEntryNote = "Sonny only accepts http and https addresses."
        case .fileLocation:
            title = "Add a folder"
            freeEntryTitle = "Folder"
            freeEntryPlaceholder = "~/Documents/Client Alpha"
            freeEntryNote = "The folder has to be inside Desktop or Documents — a workspace can "
                + "narrow where Sonny may work, never widen it."
        }

        guard kind == .app else {
            categories = []
            return
        }

        // The evaluator's own answer to "does this workspace already list this app". Asking
        // `verdict(for:)` rather than searching `workspace.apps` is what keeps this agreeing with
        // the capability's duplicate handling, which folds names through the same `appKey`.
        var placed: Set<String> = []
        var built: [Category] = []
        for group in Self.categoryOrder {
            // Resolved *through* the catalog rather than read off the table, so the catalog stays
            // the source of which apps exist and the table only says where each one goes and in
            // what order. A name the catalog no longer carries produces no row rather than a row
            // for an app that cannot be resolved. The order is the table's, because the table's is
            // authored and the catalog's is incidental — `Finder, Notes, Calendar` is where the
            // catalog happens to have put them, not a grouping anyone chose.
            let members = group.names.compactMap { name in
                catalog.apps.first { $0.displayName == name }
            }
            guard !members.isEmpty else {
                continue
            }
            members.forEach { placed.insert($0.displayName) }
            built.append(
                Category(
                    title: group.title,
                    entries: members.map { Self.entry(for: $0.displayName, workspace: workspace, scope: scope) }
                )
            )
        }
        let leftovers = catalog.apps.filter { !placed.contains($0.displayName) }
        if !leftovers.isEmpty {
            built.append(
                Category(
                    title: Self.uncategorizedTitle,
                    entries: leftovers.map { Self.entry(for: $0.displayName, workspace: workspace, scope: scope) }
                )
            )
        }
        categories = built
    }

    private static func entry(
        for name: String,
        workspace: StoredWorkspace,
        scope: WorkspaceScope
    ) -> Entry {
        let alreadyListed = scope.verdict(for: .app(name)) == .inScope
        return Entry(
            name: name,
            isAlreadyListed: alreadyListed,
            accessibilityLabel: alreadyListed
                ? "\(name) is already in \(workspace.name)"
                : "Add \(name) to \(workspace.name)",
            dispatch: WorkspaceScopeEditCommand.dispatch(
                workspaceName: workspace.name,
                kind: .app,
                value: name,
                action: .add
            )
        )
    }

    /// What the free-entry field would submit, or `nil` when there is nothing to submit.
    ///
    /// Blank is the only thing refused here, and only because `edit_workspace` refuses a step that
    /// names nothing — dispatching one would raise a plan error where the honest answer is that the
    /// button does nothing yet. Every *other* judgment about the value stays with the capability:
    /// a URL that is not http/https, a folder outside the whitelist, an app the catalog cannot
    /// resolve. Re-checking any of those here would be a second rule about the same thing, which is
    /// the divergence this area has already paid for once.
    func dispatch(forTypedValue raw: String) -> WorkspaceScopeEditDispatch? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, alreadyListedNote(forTypedValue: trimmed) == nil else {
            return nil
        }
        return WorkspaceScopeEditCommand.dispatch(
            workspaceName: workspaceName,
            kind: kind,
            value: trimmed,
            action: .add
        )
    }

    /// Why a typed app is not offered: this workspace already lists it. `nil` when it does not, and
    /// always `nil` for URLs and folders — see below.
    ///
    /// **The two halves of this dialog used to disagree.** A catalog row for an app already in the
    /// workspace shows "Already added" and offers no button, because adding it would raise a real
    /// tier-2 approval and resolve to "No change: the workspace already matches this edit" — a
    /// consent asked for nothing. Typing that same app's name into the field beside it did exactly
    /// that. Same question, same answer now. (PR #40 review, F12.)
    ///
    /// **URLs and folders are deliberately excepted, and it is not laziness.** `verdict(for:)`
    /// answers "is this resource inside the boundary", which for those two kinds is deliberately
    /// *coarser* than entry identity: a dot-boundary host suffix and folder containment.
    /// `api.github.com` is `.inScope` under a stored `github.com`, and `~/Documents/Alpha` is
    /// `.inScope` under a stored `~/Documents` — yet both are genuinely new entries that
    /// `edit_workspace` would add, because `entryKey` compares whole URLs and canonicalised paths.
    /// Refusing on the verdict would block legitimate narrowing, which is worse than the duplicate
    /// approval it would prevent. Entry identity for those kinds lives in
    /// `EditWorkspaceCapabilityAdapter`'s private `entryKey`; exporting a second thing is what
    /// `removalUnits` did for a defect that was actually costing something, and this one is not.
    /// Apps are the kind where the two notions coincide — `appKey` equality is both — which is why
    /// this is answerable here at all.
    func alreadyListedNote(forTypedValue raw: String) -> String? {
        guard kind == .app else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, scope.verdict(for: .app(trimmed)) == .inScope else {
            return nil
        }
        return "\(trimmed) is already in \(workspaceName)."
    }

    /// The scope-only disclosure for a name typed into the app field, in the shared wording, or
    /// `nil` when the catalog resolves it (or there is nothing typed yet).
    ///
    /// Shown *before* submitting, which is the point: the capability already appends this same
    /// sentence to its preview and its result, so a user learned it after approving. Reading it from
    /// `WorkspaceScopeOnlyApps` rather than writing a picker-flavoured variant is what stops the two
    /// moments from saying different things about the same app.
    func scopeOnlyDisclosure(forTypedValue raw: String) -> String? {
        guard kind == .app else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return WorkspaceScopeOnlyApps.scopeOnlyNote(
            for: WorkspaceScopeOnlyApps.names(in: [trimmed], catalog: catalog)
        )
    }
}
