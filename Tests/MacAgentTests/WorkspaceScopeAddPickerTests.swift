import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// SONNY-64's picker — the Add dialog that replaced handing the widget composer a half-typed
/// sentence.
///
/// Everything asserted here is a pure function of stored state and the catalog, following the
/// `WorkspaceDetailPresentation` precedent for the same reason: this repo has no SwiftUI
/// view-inspection harness, so a category heading or a disclosure written inside a `body` is one no
/// test can read. That the dialog *renders* these values is a manual item on the ticket.
@Suite
@MainActor
struct WorkspaceScopeAddPickerTests {
    private func workspace(apps: [String] = ["Safari"]) -> StoredWorkspace {
        StoredWorkspace(name: "Client Alpha", apps: apps, urls: [])
    }

    // MARK: - The twelve, and where they go

    /// **Every catalog app appears exactly once.** The drift guard, and the reason the category
    /// table is allowed to exist at all.
    ///
    /// Categories are a presentational table keyed by display name, and the catalog is the real
    /// list — two lists, which is normally how one silently loses an entry. It cannot here: the
    /// categories are built by *filtering the catalog*, and anything the table does not name falls
    /// into "More apps" rather than out of the dialog. SONNY-66 may widen the catalog without
    /// touching this file and nothing will vanish.
    @Test
    func everyCatalogAppAppearsExactlyOnce() {
        let presentation = WorkspaceScopeAddPresentation(kind: .app, workspace: workspace())

        let listed = presentation.categories.flatMap { $0.entries.map(\.name) }
        #expect(listed.sorted() == MacAppCatalog.default.apps.map(\.displayName).sorted())
        #expect(Set(listed).count == listed.count)
        #expect(listed.count == 12)
    }

    /// The five functional groups, in order, with their members — the user-visible taxonomy, pinned
    /// as literal copy because that is what it is.
    @Test
    func theTwelveFallIntoFiveFunctionalGroupsInAFixedOrder() {
        let presentation = WorkspaceScopeAddPresentation(kind: .app, workspace: workspace())

        #expect(presentation.categories.map(\.title)
            == ["Browsers", "Communication", "Productivity", "Media", "Developer"])
        #expect(presentation.categories.map { $0.entries.map(\.name) } == [
            ["Safari", "Chrome"],
            ["Mail", "Messages", "Slack"],
            ["Notes", "Calendar", "Finder"],
            ["Apple Music", "Spotify"],
            ["VS Code", "Terminal"]
        ])
    }

    /// An app the category table has never heard of still appears, under "More apps".
    ///
    /// Exercised with a catalog the table cannot know about, which is the shape SONNY-66's widening
    /// will have. Without this the failure mode is silent: an app Sonny can launch, absent from the
    /// one dialog for adding apps, with nothing anywhere saying so.
    @Test
    func aCatalogAppTheCategoryTableDoesNotNameStillAppearsUnderMoreApps() {
        let catalog = MacAppCatalog(apps: [
            MacApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari"),
            MacApp(displayName: "Linear", bundleIdentifier: "com.linear")
        ])
        let presentation = WorkspaceScopeAddPresentation(
            kind: .app,
            workspace: workspace(),
            catalog: catalog
        )

        #expect(presentation.categories.map(\.title) == ["Browsers", WorkspaceScopeAddPresentation.uncategorizedTitle])
        #expect(presentation.categories.last?.entries.map(\.name) == ["Linear"])
    }

    // MARK: - What each row submits

    /// A picked app submits the same request the equivalent typed command would, and says the same
    /// sentence.
    @Test
    func pickingAnAppSubmitsAnAdditionForThatAppInThisWorkspace() throws {
        let presentation = WorkspaceScopeAddPresentation(kind: .app, workspace: workspace())

        let slack = try #require(presentation.categories.flatMap(\.entries).first { $0.name == "Slack" })
        #expect(slack.dispatch.request == WorkspaceScopeEditRequest(
            workspaceName: "Client Alpha",
            kind: .app,
            value: "Slack",
            action: .add
        ))
        #expect(slack.dispatch.displayCommand == "In my Client Alpha workspace, add the app Slack")
        #expect(slack.accessibilityLabel == "Add Slack to Client Alpha")
    }

    /// **"Already added" is the evaluator's answer, not a string comparison.**
    ///
    /// The workspace stores "Google Chrome"; the catalog row says "Chrome". They are one app to the
    /// boundary and one app to the capability's own duplicate handling, so the dialog has to agree —
    /// offering Add here would produce a run, an approval prompt, and a no-op summary, which is a
    /// consent asked for nothing.
    @Test
    func anAppAlreadyInTheWorkspaceUnderAnAliasIsMarkedAlreadyAdded() throws {
        let presentation = WorkspaceScopeAddPresentation(
            kind: .app,
            workspace: workspace(apps: ["Google Chrome"])
        )

        let entries = presentation.categories.flatMap(\.entries)
        let chrome = try #require(entries.first { $0.name == "Chrome" })
        #expect(chrome.isAlreadyListed)
        #expect(chrome.accessibilityLabel == "Chrome is already in Client Alpha")

        let safari = try #require(entries.first { $0.name == "Safari" })
        #expect(safari.isAlreadyListed == false)
    }

    /// A workspace listing no apps at all marks nothing as already added.
    ///
    /// The trap this pins: an empty apps list makes `WorkspaceScope` answer `.unconstrained` rather
    /// than `.outOfScope`, so any check written as "not out of scope" would mark all twelve as
    /// already present and leave the dialog with nothing to add.
    @Test
    func aWorkspaceWithNoAppsOffersEveryCatalogApp() {
        let presentation = WorkspaceScopeAddPresentation(
            kind: .app,
            workspace: StoredWorkspace(name: "Client Alpha", apps: [], urls: ["https://example.org"])
        )

        #expect(presentation.categories.flatMap(\.entries).allSatisfy { !$0.isAlreadyListed })
    }

    // MARK: - The free-entry half

    /// **An app outside the launch catalog is still addable, and the dialog says what that means
    /// before the user commits.**
    ///
    /// Listing an app Sonny cannot launch is legal and deliberate (the scope/launch decoupling on
    /// SONNY-44), so a picker limited to the twelve would be narrower than the typed command it
    /// replaces. The disclosure is `WorkspaceScopeOnlyApps`' own sentence rather than a
    /// picker-flavoured rewrite, so this moment and the approval that follows cannot say different
    /// things about the same app.
    @Test
    func typingAnAppOutsideTheLaunchCatalogCarriesTheSharedScopeOnlyDisclosure() {
        let presentation = WorkspaceScopeAddPresentation(kind: .app, workspace: workspace())

        #expect(presentation.scopeOnlyDisclosure(forTypedValue: "Xcode")
            == "Xcode isn't an app Sonny can launch — counted for workspace scope only.")
        // Same wording the capability appends to its own preview and summary.
        #expect(presentation.scopeOnlyDisclosure(forTypedValue: "Xcode")
            == WorkspaceScopeOnlyApps.scopeOnlyNote(for: ["Xcode"]))
    }

    /// A name the catalog resolves gets no disclosure — including through an alias, so the dialog
    /// does not accuse "Visual Studio Code" of being unlaunchable.
    @Test
    func aCatalogedNameCarriesNoScopeOnlyDisclosure() {
        let presentation = WorkspaceScopeAddPresentation(kind: .app, workspace: workspace())

        #expect(presentation.scopeOnlyDisclosure(forTypedValue: "Slack") == nil)
        #expect(presentation.scopeOnlyDisclosure(forTypedValue: "Visual Studio Code") == nil)
        #expect(presentation.scopeOnlyDisclosure(forTypedValue: "") == nil)
    }

    /// The disclosure is about apps. URLs and folders have their own rules and neither is a launch
    /// question, so borrowing this sentence there would be nonsense.
    @Test
    func urlAndFolderFieldsCarryNoScopeOnlyDisclosure() {
        for kind in [ScopedResourceKind.webDomain, .fileLocation] {
            let presentation = WorkspaceScopeAddPresentation(kind: kind, workspace: workspace())
            #expect(presentation.scopeOnlyDisclosure(forTypedValue: "anything") == nil)
        }
    }

    /// URLs and folders get no catalog — there is nothing to enumerate — and each states the rule a
    /// user would otherwise discover by being refused.
    @Test
    func urlAndFolderDialogsOfferAFieldAndTheirOwnStandingRule() {
        let urls = WorkspaceScopeAddPresentation(kind: .webDomain, workspace: workspace())
        #expect(urls.categories.isEmpty)
        #expect(urls.title == "Add a URL")
        #expect(urls.freeEntryPlaceholder == "https://example.com/handbook")
        #expect(urls.freeEntryNote == "Sonny only accepts http and https addresses.")

        let folders = WorkspaceScopeAddPresentation(kind: .fileLocation, workspace: workspace())
        #expect(folders.categories.isEmpty)
        #expect(folders.title == "Add a folder")
        #expect(folders.freeEntryNote == "The folder has to be inside Desktop or Documents — a "
            + "workspace can narrow where Sonny may work, never widen it.")

        let apps = WorkspaceScopeAddPresentation(kind: .app, workspace: workspace())
        #expect(apps.freeEntryNote == nil)
    }

    /// Typed values submit for the dimension whose dialog is open, trimmed.
    @Test
    func aTypedValueSubmitsAnAdditionForTheDimensionThisDialogEdits() throws {
        let folders = WorkspaceScopeAddPresentation(kind: .fileLocation, workspace: workspace())

        let dispatch = try #require(folders.dispatch(forTypedValue: "  ~/Documents/Client Alpha  "))
        #expect(dispatch.request == WorkspaceScopeEditRequest(
            workspaceName: "Client Alpha",
            kind: .fileLocation,
            value: "~/Documents/Client Alpha",
            action: .add
        ))
        #expect(dispatch.displayCommand
            == "In my Client Alpha workspace, add the folder ~/Documents/Client Alpha")
    }

    /// Blank submits nothing — the one thing refused here, because `edit_workspace` refuses a step
    /// that names nothing and dispatching one would raise a plan error where the honest answer is
    /// that there is nothing to do yet.
    @Test
    func aBlankFieldSubmitsNothing() {
        let presentation = WorkspaceScopeAddPresentation(kind: .app, workspace: workspace())

        #expect(presentation.dispatch(forTypedValue: "") == nil)
        #expect(presentation.dispatch(forTypedValue: "   \n ") == nil)
    }

    /// **The picker's most-read string and the free-entry button's label are the presentation's, not
    /// the view body's.**
    ///
    /// Both were literals inside `WorkspaceScopeAddView` while that view's own doc comment claimed
    /// none of its copy was. "Already added" is the one a manual item asks the user to read back —
    /// and it is a manual item precisely because no test can see a rendered `Text`, which is the
    /// situation owning the words here exists to limit. (PR #40 review, F7.)
    @Test
    func thePickersOwnUserVisibleCopyLivesInThePresentation() {
        #expect(WorkspaceScopeAddPresentation.alreadyAddedText == "Already added")

        let presentation = WorkspaceScopeAddPresentation(kind: .app, workspace: workspace())
        #expect(presentation.freeEntryAddAccessibilityLabel == "Add what you typed to Client Alpha")
    }

    /// **The free-entry field refuses what the catalog rows above it refuse.**
    ///
    /// Typing the name of an app the workspace already lists used to dispatch an addition, raise a
    /// real tier-2 approval, and resolve to "No change: the workspace already matches this edit" —
    /// verbatim the outcome "Already added" exists to prevent. The two halves of one dialog gave
    /// opposite answers to the same question. Asked of the evaluator, so the alias case behaves the
    /// same way here as it does in the rows. (PR #40 review, F12.)
    @Test
    func typingAnAppTheWorkspaceAlreadyListsIsRefusedJustAsItsCatalogRowIs() {
        let presentation = WorkspaceScopeAddPresentation(
            kind: .app,
            workspace: workspace(apps: ["Google Chrome"])
        )

        #expect(presentation.dispatch(forTypedValue: "Chrome") == nil)
        #expect(presentation.alreadyListedNote(forTypedValue: "Chrome") == "Chrome is already in Client Alpha.")
        // An app it does not list is still addable, so the refusal is specific rather than a
        // blanket one that would break the field's whole purpose.
        #expect(presentation.dispatch(forTypedValue: "Xcode") != nil)
        #expect(presentation.alreadyListedNote(forTypedValue: "Xcode") == nil)
        #expect(presentation.alreadyListedNote(forTypedValue: "") == nil)
    }

    /// **URLs and folders are deliberately excepted from that check, and this pins why.**
    ///
    /// `verdict(for:)` answers containment, not entry identity: `api.github.com` is `.inScope` under
    /// a stored `github.com` and `~/Documents/Alpha` is `.inScope` under a stored `~/Documents` —
    /// yet both are genuinely new entries `edit_workspace` would add. Refusing on the verdict would
    /// block legitimate narrowing, which is worse than the duplicate approval it would prevent.
    /// Apps are the one kind where the two notions coincide, which is why the check is answerable
    /// there and not here.
    @Test
    func aNarrowerURLOrFolderInsideAnExistingEntryIsStillOfferedForAddition() throws {
        let urls = WorkspaceScopeAddPresentation(
            kind: .webDomain,
            workspace: StoredWorkspace(name: "Client Alpha", apps: [], urls: ["https://github.com"])
        )
        #expect(urls.alreadyListedNote(forTypedValue: "https://api.github.com/x") == nil)
        let urlDispatch = try #require(urls.dispatch(forTypedValue: "https://api.github.com/x"))
        #expect(urlDispatch.request.value == "https://api.github.com/x")

        let folders = WorkspaceScopeAddPresentation(
            kind: .fileLocation,
            workspace: StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: ["~/Documents"]
            )
        )
        #expect(folders.alreadyListedNote(forTypedValue: "~/Documents/Alpha") == nil)
        #expect(folders.dispatch(forTypedValue: "~/Documents/Alpha") != nil)
    }

    /// **Validation is not duplicated here, deliberately.**
    ///
    /// A malformed URL still produces a dispatch: `SafeURL` is the one rule about what a URL entry
    /// may be, it lives in the capability, and re-checking it in the dialog would be a second rule
    /// about the same thing — the divergence this area has already paid for. The user learns the
    /// same way they would from the command line, and by the same code.
    @Test
    func aMalformedValueIsStillSubmittedAndLeftForTheCapabilityToRefuse() throws {
        let urls = WorkspaceScopeAddPresentation(kind: .webDomain, workspace: workspace())

        let dispatch = try #require(urls.dispatch(forTypedValue: "ftp://example.com/x"))
        #expect(dispatch.request.value == "ftp://example.com/x")
        // And the capability really does refuse it, so nothing here is relying on being lucky.
        #expect(throws: (any Error).self) {
            _ = try SafeURL.validateWebURL("ftp://example.com/x")
        }
    }
}
