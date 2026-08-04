import Foundation
import Testing
@testable import MacAgentCore

@Suite
struct WorkspaceScopeTests {
    // MARK: - Apps

    @Test
    func anAppListedInTheWorkspaceIsInScope() {
        let scope = makeScope(apps: ["Safari"], urls: ["https://example.com"])

        #expect(scope.verdict(for: .app("Safari")) == .inScope)
    }

    @Test
    func anAppTheWorkspaceDoesNotListIsOutOfScope() {
        let scope = makeScope(apps: ["Safari"], urls: ["https://example.com"])

        #expect(scope.verdict(for: .app("Slack")) == .outOfScope)
    }

    /// The canonicalization requirement: stored app names are raw user strings, so `"Chrome"` and
    /// `"Google Chrome"` both persist as typed. Comparing them raw would make the same app match in
    /// one workspace and not another.
    @Test
    func aStoredChromeMatchesAStepNamingGoogleChrome() {
        let scope = makeScope(apps: ["Chrome"], urls: [])

        #expect(scope.verdict(for: .app("Google Chrome")) == .inScope)
        #expect(scope.verdict(for: .app("chrome")) == .inScope)
    }

    /// Names outside the 12-app catalog still compare, rather than silently falling out of scope
    /// checking: `switch_running_app` matches against the *running* apps, and `convert_docx_to_pdf`
    /// implicitly drives Microsoft Word, neither of which the catalog knows.
    @Test
    func appsOutsideTheCatalogStillCompareConsistentlyOnBothSides() {
        let scope = makeScope(apps: ["Microsoft Word"], urls: [])

        #expect(scope.verdict(for: .app("Microsoft Word")) == .inScope)
        #expect(scope.verdict(for: .app("microsoft word")) == .inScope)
        #expect(scope.verdict(for: .app("Figma")) == .outOfScope)
    }

    // MARK: - Domains

    @Test
    func aDomainListedInTheWorkspaceIsInScope() {
        let scope = makeScope(apps: [], urls: ["https://github.com/sonny"])

        #expect(scope.verdict(for: .webDomain("github.com")) == .inScope)
    }

    @Test
    func aDomainTheWorkspaceDoesNotListIsOutOfScope() {
        let scope = makeScope(apps: [], urls: ["https://github.com/sonny"])

        #expect(scope.verdict(for: .webDomain("example.com")) == .outOfScope)
    }

    /// Subdomains are inside their parent domain.
    @Test
    func aScopedDomainMatchesItsSubdomains() {
        let scope = makeScope(apps: [], urls: ["https://github.com/sonny"])

        #expect(scope.verdict(for: .webDomain("gist.github.com")) == .inScope)
    }

    /// The trap the suffix match exists to avoid: `notgithub.com` *contains* `github.com`, so a
    /// substring comparison would put an unrelated host in scope.
    @Test
    func aHostThatMerelyContainsAScopedDomainIsOutOfScope() {
        let scope = makeScope(apps: [], urls: ["https://github.com/sonny"])

        #expect(scope.verdict(for: .webDomain("notgithub.com")) == .outOfScope)
    }

    @Test
    func hostsAreComparedWithoutCaseWwwOrATrailingDNSRootDot() {
        let scope = makeScope(apps: [], urls: ["https://www.GitHub.com/sonny"])

        #expect(scope.webDomains == ["github.com"])
        #expect(scope.verdict(for: .webDomain("GITHUB.com")) == .inScope)
        #expect(scope.verdict(for: .webDomain("github.com.")) == .inScope)
        #expect(scope.verdict(for: .webDomain("www.github.com")) == .inScope)
    }

    // MARK: - File locations

    @Test
    func aPathInsideAScopedFolderIsInScope() throws {
        let fixture = try FileScopeFixture()
        defer { fixture.tearDown() }
        let scope = fixture.scope(fileLocations: [fixture.client.path])

        #expect(scope.verdict(for: .fileLocation(fixture.client.appendingPathComponent("notes.md").path)) == .inScope)
        #expect(scope.verdict(for: .fileLocation(fixture.client.path)) == .inScope)
    }

    @Test
    func aPathOutsideEveryScopedFolderIsOutOfScope() throws {
        let fixture = try FileScopeFixture()
        defer { fixture.tearDown() }
        let scope = fixture.scope(fileLocations: [fixture.client.path])

        #expect(scope.verdict(for: .fileLocation(fixture.personal.appendingPathComponent("x.txt").path)) == .outOfScope)
    }

    /// The sibling-prefix trap: `ClientAlpha` starts with `Client`, so a bare prefix test would put
    /// a different folder's file inside the scope.
    @Test
    func aSiblingFolderSharingAPrefixIsOutOfScope() throws {
        let fixture = try FileScopeFixture()
        defer { fixture.tearDown() }
        let scope = fixture.scope(fileLocations: [fixture.client.path])

        #expect(
            scope.verdict(for: .fileLocation(fixture.clientAlpha.appendingPathComponent("x.txt").path)) == .outOfScope
        )
    }

    /// Mirrors `PathWhitelistTests.rejectsSymlinkResolvingOutsideRoot`, because it is literally the
    /// same containment code: a link that sits inside the scoped folder but points outside it must
    /// not smuggle the destination into scope.
    @Test
    func aSymlinkInsideAScopedFolderThatResolvesOutsideItIsOutOfScope() throws {
        let fixture = try FileScopeFixture()
        defer { fixture.tearDown() }
        let link = fixture.client.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.personal)
        let existingTarget = fixture.personal.appendingPathComponent("x.txt")
        try Data("x".utf8).write(to: existingTarget, options: .atomic)
        let scope = fixture.scope(fileLocations: [fixture.client.path])

        #expect(scope.verdict(for: .fileLocation(link.path)) == .outOfScope)
        #expect(scope.verdict(for: .fileLocation(link.appendingPathComponent("x.txt").path)) == .outOfScope)
    }

    /// The one shape symlink resolution cannot see through, pinned rather than left to be discovered:
    /// `resolvingSymlinksInPath` only resolves a path that exists, so a *not-yet-created* file
    /// underneath a symlinked folder still reads as inside the scoped root.
    ///
    /// This is `PathWhitelist`'s own inherited behavior, not a divergence — and it is not a bypass,
    /// which the second half of this test proves rather than asserts: the whitelist refuses that
    /// write at execution because the parent it would write through is a symlink. Scope narrows the
    /// whitelist; it never widens it, so an `.inScope` verdict on a path the whitelist rejects grants
    /// nothing.
    @Test
    func aNotYetCreatedFileUnderASymlinkedFolderInheritsTheWhitelistsOwnBlindSpotAndIsStillRefused() throws {
        let fixture = try FileScopeFixture()
        defer { fixture.tearDown() }
        let link = fixture.client.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.personal)
        let unwritten = link.appendingPathComponent("new.md").path
        let scope = fixture.scope(fileLocations: [fixture.client.path])

        #expect(scope.verdict(for: .fileLocation(unwritten)) == .inScope)

        do {
            _ = try fixture.whitelist.validateOutputPath(unwritten)
            Issue.record("Expected the whitelist to refuse a write through a symlinked parent")
        } catch PathValidationError.symbolicLinkRejected {
        } catch {
            Issue.record("Expected symbolicLinkRejected, got \(error)")
        }
    }

    @Test
    func parentTraversalOutOfAScopedFolderIsOutOfScope() throws {
        let fixture = try FileScopeFixture()
        defer { fixture.tearDown() }
        let scope = fixture.scope(fileLocations: [fixture.client.path])
        let traversal = fixture.client.appendingPathComponent("../Personal/x.txt").path

        #expect(scope.verdict(for: .fileLocation(traversal)) == .outOfScope)
    }

    /// Workspace scope narrows the global whitelist and never widens it. A folder the whitelist
    /// rejects can never match, so it is reported at construction instead of pretending to be a
    /// boundary — and a workspace whose *only* folder is inert restricts nothing, which is
    /// `.unconstrained`, not "escalate on everything".
    @Test
    func aFileLocationOutsideTheWhitelistIsReportedInertAtConstruction() throws {
        let fixture = try FileScopeFixture()
        defer { fixture.tearDown() }
        let outside = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }

        let scope = fixture.scope(fileLocations: [outside.path])

        #expect(scope.fileRoots.isEmpty)
        #expect(scope.inertEntries.count == 1)
        #expect(scope.inertEntries.first?.kind == .fileLocation)
        #expect(scope.inertEntries.first?.value == outside.path)
        #expect(scope.verdict(for: .fileLocation(fixture.client.appendingPathComponent("x.txt").path)) == .unconstrained)
    }

    @Test
    func aURLWithNoUsableHostIsReportedInertAtConstruction() {
        let scope = makeScope(apps: ["Safari"], urls: ["http://localhost/board", "not a url"])

        #expect(scope.webDomains.isEmpty)
        #expect(scope.inertEntries.map(\.value).sorted() == ["http://localhost/board", "not a url"])
        #expect(scope.inertEntries.allSatisfy { $0.kind == .webDomain })
        #expect(scope.verdict(for: .webDomain("example.com")) == .unconstrained)
    }

    // MARK: - Unconfigured kinds

    /// Workspace creation requires *at least one* of apps or URLs — `guard !apps.isEmpty ||
    /// !urls.isEmpty` throws only when both are empty — so an apps-only workspace is a normal
    /// persisted state, not a degenerate one.
    @Test
    func anAppsOnlyWorkspaceLeavesEveryDomainUnconstrained() {
        let scope = makeScope(apps: ["Safari"], urls: [])

        #expect(scope.verdict(for: .webDomain("github.com")) == .unconstrained)
        #expect(scope.verdict(for: .webDomain("example.com")) == .unconstrained)
        #expect(scope.verdict(for: .app("Safari")) == .inScope)
    }

    @Test
    func aURLsOnlyWorkspaceLeavesEveryAppUnconstrained() {
        let scope = makeScope(apps: [], urls: ["https://github.com/sonny"])

        #expect(scope.verdict(for: .app("Safari")) == .unconstrained)
        #expect(scope.verdict(for: .app("Slack")) == .unconstrained)
        #expect(scope.verdict(for: .webDomain("github.com")) == .inScope)
    }

    /// No workspace on disk has file locations — the field is new — so every existing workspace must
    /// keep behaving exactly as it does today.
    @Test
    func aWorkspaceWithNoFileLocationsLeavesEveryPathUnconstrained() {
        let scope = makeScope(apps: ["Safari"], urls: ["https://github.com"])

        #expect(scope.fileRoots.isEmpty)
        #expect(scope.verdict(for: .fileLocation("~/Documents/anything.md")) == .unconstrained)
    }

    // MARK: - Step classification

    @Test
    func convertDocxToPDFReportsMicrosoftWordThoughNoPlanFieldNamesIt() {
        let step = AgentStep(
            id: "convert",
            operation: .convertDocxToPDF,
            description: "Convert the drafts.",
            inputPath: "~/Documents/Drafts",
            outputPath: "~/Documents/Drafts"
        )

        let resources = PlanScopedResources.resources(in: step)

        #expect(resources.contains(.app("Microsoft Word")))
        #expect(resources.contains(.fileLocation("~/Documents/Drafts")))
        #expect(PlanScopedResources.isOpaque(step) == false)
    }

    @Test
    func theFinderOperationsReportFinderThoughNoPlanFieldNamesIt() {
        let selection = AgentStep(
            id: "selection",
            operation: .getFinderSelection,
            description: "Read the Finder selection.",
            contextSource: .finderSelection
        )
        let reveal = AgentStep(
            id: "reveal",
            operation: .revealInFinder,
            description: "Reveal the report.",
            outputPath: "~/Documents/report.pdf"
        )

        #expect(PlanScopedResources.resources(in: selection) == [.app("Finder")])
        #expect(
            PlanScopedResources.resources(in: reveal) == [.app("Finder"), .fileLocation("~/Documents/report.pdf")]
        )
    }

    @Test
    func playMediaReportsBothTheProviderAppAndTheProviderHost() {
        let appleMusic = AgentStep(
            id: "music",
            operation: .playMedia,
            description: "Play the album.",
            mediaProvider: .appleMusic,
            mediaTitle: "Blue"
        )
        let spotify = AgentStep(
            id: "spotify",
            operation: .playMedia,
            description: "Play the album.",
            mediaProvider: .spotify,
            mediaTitle: "Blue"
        )

        #expect(PlanScopedResources.resources(in: appleMusic) == [.app("Apple Music"), .webDomain("music.apple.com")])
        #expect(PlanScopedResources.resources(in: spotify) == [.app("Spotify"), .webDomain("open.spotify.com")])
    }

    /// `appName` on this operation holds a search *target* — the real resource is the host baked into
    /// the template, which is why the template is asked rather than the field read.
    @Test
    func openAppSearchURLReportsTheTemplatesHostRatherThanItsAppName() {
        let step = AgentStep(
            id: "search",
            operation: .openAppSearchURL,
            description: "Search GitHub.",
            appName: "GitHub",
            searchQuery: "swift testing"
        )

        #expect(PlanScopedResources.resources(in: step) == [.webDomain("github.com")])
    }

    @Test
    func aShortcutStepIsOpaqueAndNamesNoResources() {
        let step = AgentStep(
            id: "shortcut",
            operation: .invokeShortcut,
            description: "Run the Shortcut.",
            shortcutName: "Daily Digest"
        )

        #expect(PlanScopedResources.isOpaque(step))
        #expect(PlanScopedResources.resources(in: step).isEmpty)
    }

    /// The second opaque case, and a genuinely different one: the output file *is* knowable, only the
    /// source URLs are not — they come back from the search provider mid-execution.
    @Test
    func aSearchDrivenWebToMarkdownStepIsOpaqueButStillNamesItsOutputFile() {
        let step = AgentStep(
            id: "research",
            operation: .webToMarkdown,
            description: "Research the topic.",
            outputPath: "~/Documents/notes.md",
            searchQuery: "swift concurrency"
        )

        #expect(PlanScopedResources.isOpaque(step))
        #expect(PlanScopedResources.resources(in: step) == [.fileLocation("~/Documents/notes.md")])
    }

    /// With either URL field populated the search branch is unreachable, so the step is fully
    /// knowable — the same priority order `webResearchInput(in:)` resolves in.
    @Test
    func aWebToMarkdownStepWithURLsIsNotOpaqueEvenWhenItAlsoCarriesAQuery() {
        let withTarget = AgentStep(
            id: "page",
            operation: .webToMarkdown,
            description: "Summarize the page.",
            outputPath: "~/Documents/notes.md",
            targetURL: "https://example.com/post",
            searchQuery: "ignored because targetURL wins"
        )
        let withSources = AgentStep(
            id: "compare",
            operation: .webToMarkdown,
            description: "Compare the pages.",
            outputPath: "~/Documents/notes.md",
            sourceURLs: ["https://example.com/a", "https://docs.example.org/b"],
            searchQuery: "ignored because sourceURLs win"
        )

        #expect(PlanScopedResources.isOpaque(withTarget) == false)
        #expect(
            PlanScopedResources.resources(in: withTarget)
                == [.webDomain("example.com"), .fileLocation("~/Documents/notes.md")]
        )
        #expect(PlanScopedResources.isOpaque(withSources) == false)
        #expect(
            PlanScopedResources.resources(in: withSources)
                == [
                    .webDomain("example.com"),
                    .webDomain("docs.example.org"),
                    .fileLocation("~/Documents/notes.md")
                ]
        )
    }

    /// The adapter reads exactly one of the three source fields, in a fixed priority order, so a
    /// step carrying both never visits the target URL — naming it would escalate on a host the run
    /// does not touch.
    @Test
    func aWebToMarkdownStepWithSourceURLsIgnoresItsTargetURLTheWayTheAdapterDoes() {
        let step = AgentStep(
            id: "compare",
            operation: .webToMarkdown,
            description: "Compare the pages.",
            outputPath: "~/Documents/notes.md",
            targetURL: "https://never-fetched.example/page",
            sourceURLs: ["https://docs.example.org/a"]
        )

        #expect(
            PlanScopedResources.resources(in: step)
                == [.webDomain("docs.example.org"), .fileLocation("~/Documents/notes.md")]
        )
    }

    @Test
    func unsupportedIsClassifiedAsNoResourcesRatherThanLeftToADefaultClause() {
        let step = AgentStep(id: "nope", operation: .unsupported, description: "Not supported.")

        #expect(PlanScopedResources.resources(in: step).isEmpty)
        #expect(PlanScopedResources.isOpaque(step) == false)
    }

    /// Pins the whole classification table, by **exact resources rather than resource kinds**. The
    /// distinction is the whole value of this test: the probe step populates `inputPath` and
    /// `outputPath` with different values, so a kind-level assertion would pass just as happily if a
    /// case read the wrong path field, dropped one of two, or resolved `outputPath ?? inputPath` the
    /// wrong way round.
    ///
    /// The classifier's exhaustive switch has no `default:` clause, so a new `AgentOperation` fails
    /// the build until it is classified; this test is the other half — it fails when an existing
    /// case is *re*classified without anyone saying so.
    @Test
    func everyAgentOperationIsClassifiedAndTheTableCoversAllThirtyCases() {
        #expect(AgentOperation.allCases.count == 30)

        let input = ScopedResource.fileLocation("~/Documents/Input")
        let output = ScopedResource.fileLocation("~/Documents/Output/out.md")
        let expected: [AgentOperation: [ScopedResource]] = [
            .scanSelectLargestFiles: [input, output],
            .createZip: [input, output],
            .scanDocx: [input, output],
            .convertDocxToPDF: [input, output, .app("Microsoft Word")],
            .openHackerNews: [.webDomain("news.ycombinator.com")],
            .fetchHNHeadlines: [.webDomain("news.ycombinator.com")],
            .writeMarkdown: [.webDomain("news.ycombinator.com"), output],
            // `sourceURLs` wins over `targetURL`, so `example.com` is deliberately absent.
            .webToMarkdown: [.webDomain("docs.example.org"), output],
            .openApp: [.app("GitHub")],
            .openAppSearchURL: [.webDomain("github.com")],
            .openURL: [.webDomain("example.com")],
            .playMedia: [.app("Spotify"), .webDomain("open.spotify.com")],
            .getFinderSelection: [.app("Finder"), input],
            // `outputPath` wins over `inputPath`.
            .revealInFinder: [.app("Finder"), output],
            .openGeneratedArtifact: [output],
            .createLocalDraft: [output],
            .switchRunningApp: [.app("GitHub")],
            .showPermissionReadiness: [],
            .saveRoutine: [],
            .runRoutine: [],
            .createWorkspace: [],
            .openWorkspace: [],
            .calculateUtility: [],
            .lookupClipboardHistory: [],
            .expandSnippet: [],
            .saveSnippet: [],
            .lookupRecentArtifacts: [],
            .invokeShortcut: [],
            .clarify: [],
            .unsupported: []
        ]
        #expect(expected.count == AgentOperation.allCases.count)

        for operation in AgentOperation.allCases {
            let classification = PlanScopedResources.classification(of: .probe(operation))
            #expect(
                classification.resources == expected[operation],
                "\(operation.rawValue) classified as \(classification.resources)"
            )
            // The probe fills every URL field, so `web_to_markdown` takes its direct-URL form here;
            // `invoke_shortcut` is the only case opaque on its own operation alone.
            #expect(classification.isOpaque == (operation == .invokeShortcut), "\(operation.rawValue)")
        }
    }

    /// The `outputPath ?? inputPath` precedence, asserted with both fields populated to different
    /// values — the only shape in which a reversed `??` is visible.
    @Test
    func theChainedArtifactOperationsPreferTheOutputPathOverTheInputPath() {
        let reveal = AgentStep(
            id: "reveal",
            operation: .revealInFinder,
            description: "Reveal the report.",
            inputPath: "~/Documents/Source",
            outputPath: "~/Documents/report.pdf"
        )
        let open = AgentStep(
            id: "open",
            operation: .openGeneratedArtifact,
            description: "Open the report.",
            inputPath: "~/Documents/Source",
            outputPath: "~/Documents/report.pdf"
        )

        #expect(
            PlanScopedResources.resources(in: reveal) == [.app("Finder"), .fileLocation("~/Documents/report.pdf")]
        )
        #expect(PlanScopedResources.resources(in: open) == [.fileLocation("~/Documents/report.pdf")])
    }

    /// When neither path field is set, the target is the artifact an earlier step in the same plan
    /// produced — already classified from *that* step's output path, so naming nothing here is
    /// correct rather than a gap. `open_generated_artifact` names no app either: Launch Services
    /// picks the handler by file type at run time.
    @Test
    func aChainedArtifactStepWithNoPathsNamesOnlyWhatItReallyKnows() {
        let reveal = AgentStep(id: "reveal", operation: .revealInFinder, description: "Reveal it.")
        let open = AgentStep(id: "open", operation: .openGeneratedArtifact, description: "Open it.")

        #expect(PlanScopedResources.resources(in: reveal) == [.app("Finder")])
        #expect(PlanScopedResources.resources(in: open).isEmpty)
    }

    /// `switch_running_app` falls back to `searchQuery` when the planner gave no app name — the
    /// natural-language form of the operation, and the branch that would silently name nothing if
    /// the fallback were dropped.
    @Test
    func switchRunningAppFallsBackToTheSearchQueryWhenNoAppNameIsGiven() {
        let step = AgentStep(
            id: "switch",
            operation: .switchRunningApp,
            description: "Switch to the design tool.",
            searchQuery: "Figma"
        )

        #expect(PlanScopedResources.resources(in: step) == [.app("Figma")])
    }

    /// A resource whose own identifier is blank cannot match anything, and a configured kind must
    /// not quietly wave it through.
    @Test
    func aBlankResourceIdentifierIsOutOfScopeRatherThanUnconstrained() throws {
        let fixture = try FileScopeFixture()
        defer { fixture.tearDown() }
        let scope = fixture.scope(apps: ["Safari"], urls: [], fileLocations: [fixture.client.path])

        #expect(scope.verdict(for: .app("")) == .outOfScope)
        #expect(scope.verdict(for: .app("   ")) == .outOfScope)
        #expect(scope.verdict(for: .fileLocation("   ")) == .outOfScope)
    }

    /// Pitfall 5 in the branch plan, decided rather than left silent: scope inherits
    /// `PathWhitelist`'s case-sensitive containment verbatim. The assertion that matters is not the
    /// verdict on its own but that scope and the whitelist give the *same* answer — case-folding in
    /// one and not the other is the divergence the shared containment exists to prevent. The
    /// direction is also fail-safe: a case-variant path prompts, it is never quietly let in.
    @Test
    func fileMatchingInheritsTheWhitelistsCaseSensitivityRatherThanDivergingFromIt() throws {
        let fixture = try FileScopeFixture()
        defer { fixture.tearDown() }
        // A folder that does not exist, so nothing on disk can case-correct either side.
        let root = fixture.root.appendingPathComponent("Unwritten", isDirectory: true)
        let caseVariant = fixture.root.appendingPathComponent("unwritten/notes.md").path
        let scope = fixture.scope(fileLocations: [root.path])

        let scopeSaysInside = scope.verdict(for: .fileLocation(caseVariant)) == .inScope
        let whitelistSaysInside = (try? PathWhitelist(roots: [root]).validateInsideWhitelist(caseVariant)) != nil

        #expect(scopeSaysInside == whitelistSaysInside)
        #expect(scope.verdict(for: .fileLocation(caseVariant)) == .outOfScope)
        #expect(scope.verdict(for: .fileLocation(root.appendingPathComponent("notes.md").path)) == .inScope)
    }

    // MARK: - Plan roll-up

    @Test
    func aPlanWhoseResourcesAllMatchRollsUpInScope() throws {
        let fixture = try FileScopeFixture()
        defer { fixture.tearDown() }
        let scope = fixture.scope(apps: ["Safari"], urls: ["https://github.com"], fileLocations: [fixture.client.path])
        let plan = AgentPlan(
            summary: "Work in the client folder.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "a", operation: .openApp, description: "Open Safari.", appName: "Safari"),
                AgentStep(
                    id: "b",
                    operation: .openURL,
                    description: "Open the repo.",
                    targetURL: "https://gist.github.com/sonny"
                ),
                AgentStep(
                    id: "c",
                    operation: .createLocalDraft,
                    description: "Write the draft.",
                    outputPath: fixture.client.appendingPathComponent("draft.md").path
                )
            ]
        )

        let evaluation = WorkspaceScopeEvaluator.evaluate(plan: plan, scope: scope)

        #expect(evaluation.findings.count == 3)
        #expect(evaluation.findings.allSatisfy { $0.verdict == .inScope })
        #expect(evaluation.planVerdict == .inScope)
    }

    /// The test that stops a Shortcut being relaxed by association: every other resource matches, and
    /// the plan still must not roll up in scope, because Sonny never saw what the Shortcut touches.
    @Test
    func aPlanContainingAShortcutNeverRollsUpInScopeEvenWhenEverythingElseMatches() throws {
        let scope = makeScope(apps: ["Safari"], urls: ["https://github.com"])
        let plan = AgentPlan(
            summary: "Open the repo, then run the Shortcut.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "a", operation: .openApp, description: "Open Safari.", appName: "Safari"),
                AgentStep(
                    id: "b",
                    operation: .openURL,
                    description: "Open the repo.",
                    targetURL: "https://github.com/sonny"
                ),
                AgentStep(
                    id: "c",
                    operation: .invokeShortcut,
                    description: "Run the Shortcut.",
                    shortcutName: "Daily Digest"
                )
            ]
        )

        let evaluation = WorkspaceScopeEvaluator.evaluate(plan: plan, scope: scope)

        #expect(evaluation.planVerdict != .inScope)
        #expect(evaluation.planVerdict == .opaque)
        let opaque = try #require(evaluation.findings.first { $0.verdict == .opaque })
        #expect(opaque.resource == nil)
        #expect(opaque.stepID == "c")
        #expect(evaluation.findings.filter { $0.verdict == .inScope }.count == 2)
    }

    @Test
    func oneOutOfScopeResourceOutranksBothOpacityAndEveryMatch() {
        let scope = makeScope(apps: ["Safari"], urls: ["https://github.com"])
        let plan = AgentPlan(
            summary: "Mixed plan.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "a", operation: .openApp, description: "Open Safari.", appName: "Safari"),
                AgentStep(
                    id: "b",
                    operation: .openURL,
                    description: "Open somewhere else.",
                    targetURL: "https://example.com/page"
                ),
                AgentStep(
                    id: "c",
                    operation: .invokeShortcut,
                    description: "Run the Shortcut.",
                    shortcutName: "Daily Digest"
                )
            ]
        )

        let evaluation = WorkspaceScopeEvaluator.evaluate(plan: plan, scope: scope)

        #expect(evaluation.planVerdict == .outOfScope)
        #expect(evaluation.outOfScopeFindings.map(\.stepID) == ["b"])
    }

    /// A match plus untouched dimensions is still a match: the roll-up requires that *at least one*
    /// resource matched and none is out of scope, not that every kind was configured.
    @Test
    func matchesMixedWithUnconstrainedKindsStillRollUpInScope() {
        let scope = makeScope(apps: ["Safari"], urls: [])
        let plan = AgentPlan(
            summary: "Open Safari, then a page.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "a", operation: .openApp, description: "Open Safari.", appName: "Safari"),
                AgentStep(
                    id: "b",
                    operation: .openURL,
                    description: "Open a page.",
                    targetURL: "https://example.com/page"
                )
            ]
        )

        let evaluation = WorkspaceScopeEvaluator.evaluate(plan: plan, scope: scope)

        #expect(evaluation.findings.map(\.verdict) == [.inScope, .unconstrained])
        #expect(evaluation.planVerdict == .inScope)
    }

    @Test
    func aPlanThatTouchesNoScopedResourceRollsUpUnconstrained() {
        let scope = makeScope(apps: ["Safari"], urls: ["https://github.com"])
        let plan = AgentPlan(
            summary: "Do the arithmetic.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "a",
                    operation: .calculateUtility,
                    description: "Add the numbers.",
                    searchQuery: "2 + 2"
                )
            ]
        )

        let evaluation = WorkspaceScopeEvaluator.evaluate(plan: plan, scope: scope)

        #expect(evaluation.findings.isEmpty)
        #expect(evaluation.planVerdict == .unconstrained)
    }

    @Test
    func everyFindingNamesItsStepAndOperation() throws {
        let scope = makeScope(apps: ["Safari"], urls: [])
        let plan = AgentPlan(
            summary: "Open Safari.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "step-1", operation: .openApp, description: "Open Safari.", appName: "Safari")]
        )

        let evaluation = WorkspaceScopeEvaluator.evaluate(plan: plan, scope: scope)
        let finding = try #require(evaluation.findings.first)

        #expect(finding.stepID == "step-1")
        #expect(finding.operation == .openApp)
        #expect(finding.resource == .app("Safari"))
        #expect(finding.kind == .app)
        #expect(finding.verdict == .inScope)
    }

    @Test
    func theScopeCarriesTheWorkspaceNameForWhoeverWordsTheEscalation() {
        let scope = makeScope(name: "Client Alpha", apps: ["Safari"], urls: [])

        #expect(scope.workspaceName == "Client Alpha")
    }

    // MARK: - Helpers

    private func makeScope(
        name: String = "Research",
        apps: [String],
        urls: [String],
        fileLocations: [String]? = nil
    ) -> WorkspaceScope {
        WorkspaceScope(
            workspace: StoredWorkspace(name: name, apps: apps, urls: urls, fileLocations: fileLocations)
        )
    }
}

/// Two sibling folders inside one whitelist root — `Client` and `ClientAlpha` — which is the shape
/// every file-scope case needs. Real directories rather than string arithmetic, because the symlink
/// case has to resolve for real.
private struct FileScopeFixture {
    let root: URL
    let client: URL
    let clientAlpha: URL
    let personal: URL
    let whitelist: PathWhitelist

    init() throws {
        root = try makeDirectory()
        client = root.appendingPathComponent("Client", isDirectory: true)
        clientAlpha = root.appendingPathComponent("ClientAlpha", isDirectory: true)
        personal = root.appendingPathComponent("Personal", isDirectory: true)
        for url in [client, clientAlpha, personal] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        whitelist = PathWhitelist(roots: [root])
    }

    func scope(apps: [String] = [], urls: [String] = [], fileLocations: [String]) -> WorkspaceScope {
        WorkspaceScope(
            workspace: StoredWorkspace(name: "Client Alpha", apps: apps, urls: urls, fileLocations: fileLocations),
            whitelist: whitelist
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension AgentStep {
    /// Every field an operation could read, populated at once, so the classification table test
    /// exercises each case's real field wiring rather than a step shaped to suit it.
    static func probe(_ operation: AgentOperation) -> AgentStep {
        AgentStep(
            id: "probe",
            operation: operation,
            description: "Probe step.",
            inputPath: "~/Documents/Input",
            outputPath: "~/Documents/Output/out.md",
            count: 3,
            targetURL: "https://example.com/page",
            appName: "GitHub",
            question: "Which one?",
            mediaProvider: .spotify,
            mediaTitle: "Blue",
            mediaArtist: "Joni Mitchell",
            contextSource: .finderSelection,
            routineName: "Morning",
            routineSteps: nil,
            workspaceName: "Research",
            workspaceApps: ["Safari"],
            workspaceURLs: ["https://github.com"],
            sourceURLs: ["https://docs.example.org/a"],
            searchQuery: "swift",
            draftTitle: "Draft",
            draftContent: "Body",
            shortcutName: "Daily Digest",
            shortcutInput: "input"
        )
    }
}
