import Foundation

/// What one plan step lets Sonny see about the resources it is about to touch.
public struct StepScopedResources: Equatable, Sendable {
    /// Resources knowable from the step itself, before anything runs.
    public let resources: [ScopedResource]
    /// True when the step also touches resources that cannot be named until execution. A step can be
    /// both: a search-driven research note has a knowable output file *and* unknowable source URLs.
    public let isOpaque: Bool

    public init(resources: [ScopedResource], isOpaque: Bool) {
        self.resources = resources
        self.isOpaque = isOpaque
    }

    static let none = StepScopedResources(resources: [], isOpaque: false)

    static func knowable(_ resources: [ScopedResource]) -> StepScopedResources {
        StepScopedResources(resources: resources, isOpaque: false)
    }
}

/// Maps a plan step to the resources a workspace boundary is compared against.
///
/// Classification is **per operation, never per field**, and it includes resources the operation
/// touches implicitly with no plan field naming them at all. A field-driven classifier would report
/// three real capabilities as touching nothing: `convert_docx_to_pdf` AppleScript-controls Microsoft
/// Word from a hardcoded path, the two Finder operations AppleScript-control Finder, and
/// `play_media` opens provider URIs through its own prefix check — none of which resolves through
/// `MacAppCatalog` or `SafeURL`.
public enum PlanScopedResources {
    /// Hacker News' front page, opened by the preset in `WebResearchMarkdownCapabilityAdapter`
    /// (`hackerNewsURL`, opened via `context.browserOpener`). Duplicated as a host here because that
    /// constant is private to the adapter; the API host the same preset fetches
    /// (`hacker-news.firebaseio.com`) is deliberately *not* a scoped resource — see
    /// `infrastructureHostsAreNotResources` below.
    static let hackerNewsHost = "news.ycombinator.com"

    /// Apple Music's and Spotify's own hosts, the ones `NativeMediaOpener` hands to
    /// `NSWorkspace.shared.open` (`music://music.apple.com/…` / `https://music.apple.com/…`, and
    /// `https://open.spotify.com/track|album/…`). Spotify's `spotify:` URIs carry no host at all;
    /// `open.spotify.com` is the same provider's canonical web host and the one form that does.
    static func providerHost(for provider: MediaProvider) -> String {
        switch provider {
        case .appleMusic:
            return "music.apple.com"
        case .spotify:
            return "open.spotify.com"
        }
    }

    /// Finder, as `MacAppCatalog` spells it.
    static let finderAppName = "Finder"

    /// Microsoft Word, as the converter's AppleScript addresses it (`tell application "Microsoft
    /// Word"`). Deliberately not in `MacAppCatalog` — Sonny never opens Word, it automates one that
    /// is already installed.
    static let microsoftWordAppName = "Microsoft Word"

    // Deliberate non-resources, recorded once so the omissions read as decisions rather than gaps:
    //
    // - Service and API hosts. `api.openai.com` (synthesis), `api.tavily.com` (search),
    //   `hacker-news.firebaseio.com` (headlines), `itunes.apple.com` (Apple Music catalog lookup)
    //   and per-source `robots.txt` fetches are infrastructure Sonny uses to do the work, not places
    //   the user is working. Scoping them would make every workspace escalate on `api.openai.com`.
    //   The user-facing destination is the resource; the plumbing behind it is not.
    // - Sonny's own local stores. Routines, workspaces, snippets, clipboard history and recent
    //   artifacts all live in Application Support, which `PathWhitelist` does not even admit. Saving
    //   a routine touches one file inside Sonny's own store, so `save_routine` classifies as no
    //   resources of its own; the routine's steps are scoped when it actually *runs*.
    // - Subprocess binaries. `create_zip` shells to `/usr/bin/zip`. A system CLI has no bundle
    //   identity and no user would ever type it as an app name.

    public static func resources(
        in step: AgentStep,
        searchURLCatalog: AppSearchURLCatalog = .default
    ) -> [ScopedResource] {
        classification(of: step, searchURLCatalog: searchURLCatalog).resources
    }

    public static func isOpaque(
        _ step: AgentStep,
        searchURLCatalog: AppSearchURLCatalog = .default
    ) -> Bool {
        classification(of: step, searchURLCatalog: searchURLCatalog).isOpaque
    }

    /// The single exhaustive switch over `AgentOperation`.
    ///
    /// **There is no `default:` clause, and adding one would be a regression.** A `default: return
    /// []` is a silent hole for every capability added after this branch — the same failure mode
    /// `.claude/rules/macagentcore-conventions.md` already documents for the nested-plan closures,
    /// where using a subset means nested risk silently goes unassessed. With no default, adding an
    /// `AgentOperation` case fails the build here until someone classifies its resources. That
    /// compile error *is* the completeness guarantee.
    public static func classification(
        of step: AgentStep,
        searchURLCatalog: AppSearchURLCatalog = .default
    ) -> StepScopedResources {
        switch step.operation {
        case .scanSelectLargestFiles, .createZip, .scanDocx:
            // A source folder read and a destination written or checked. The folder may have been
            // pinned from the Finder selection by `resolveDefaultOutputs` before assessment runs, so
            // by this point it is a real path either way.
            return .knowable(files(step.inputPath, step.outputPath))

        case .convertDocxToPDF:
            // Microsoft Word is implicit: `DocumentConverter` AppleScript-controls it from a
            // hardcoded `/Applications/Microsoft Word.app`, with no `MacAppCatalog` resolution and no
            // `appName` field on the step. (When Word is not installed the converter falls back to a
            // mock that touches no app; reporting Word anyway is the safe direction — over-reporting
            // escalates, under-reporting silently blesses.)
            return .knowable(files(step.inputPath, step.outputPath) + [.app(microsoftWordAppName)])

        case .openHackerNews, .fetchHNHeadlines:
            return .knowable([.webDomain(hackerNewsHost)])

        case .writeMarkdown:
            // Always the Hacker News digest writer, not a possibility: `isHackerNewsPreset` fires on
            // the mere presence of a `write_markdown` step, and this is the sole adapter registered
            // for the operation — so the preset opens Hacker News and writes the note every time.
            return .knowable([.webDomain(hackerNewsHost)] + files(step.outputPath))

        case .webToMarkdown:
            // The adapter resolves its sources in strict priority order and reads exactly one of
            // the three fields (`webResearchInput(in:)`), so this mirrors that rather than unioning
            // all of them: a step carrying both `sourceURLs` and `targetURL` never visits the target,
            // and reporting it would escalate on a host the run will not touch.
            let sources = webSources(of: step)
            var resources: [ScopedResource]
            switch sources {
            case .urls(let urls):
                resources = urls.compactMap(domain(fromURL:))
            case .searchQuery:
                resources = []
            }
            resources.append(contentsOf: files(step.outputPath))
            return StepScopedResources(resources: resources, isOpaque: sources == .searchQuery)

        case .openApp:
            return .knowable(apps(step.appName))

        case .openAppSearchURL:
            // `appName` here holds a search *target* ("GitHub", "YouTube") — the real resource is the
            // host baked into that template's `buildURL` closure, so the template is asked rather
            // than the field read.
            return .knowable(searchTemplateDomain(in: step, catalog: searchURLCatalog))

        case .openURL:
            return .knowable([domain(fromURL: step.targetURL)].compactMap { $0 })

        case .playMedia:
            // The provider app *and* the provider host: `NativeMediaOpener` opens `music://` /
            // `spotify:` URIs through its own private prefix check, bypassing both `MacAppCatalog`
            // and `SafeURL`. A step with no provider cannot execute at all, so it names nothing.
            guard let provider = step.mediaProvider else {
                return .none
            }
            return .knowable([.app(provider.displayName), .webDomain(providerHost(for: provider))])

        case .getFinderSelection:
            // Finder is implicit: the selection is read with `tell application id "com.apple.finder"`
            // through `osascript`, with no `MacAppCatalog` resolution anywhere in the path. The
            // selected items themselves are read live at execution and no plan field carries them.
            return .knowable([.app(finderAppName)] + files(step.inputPath))

        case .revealInFinder:
            // Same implicit Finder control. When both paths are nil the target is the artifact an
            // earlier step in this same plan produced — already classified from *that* step's output
            // path, so naming nothing here loses no coverage.
            return .knowable([.app(finderAppName)] + files(step.outputPath ?? step.inputPath))

        case .openGeneratedArtifact:
            // No app resource on purpose: the file is handed to `NSWorkspace.shared.open`, so Launch
            // Services picks the handler by file type at run time. Naming a fixed app here would
            // invent a resource. Same chained-artifact reasoning as `reveal_in_finder` for the paths.
            return .knowable(files(step.outputPath ?? step.inputPath))

        case .createLocalDraft:
            return .knowable(files(step.outputPath))

        case .switchRunningApp:
            // Matched against the *running* apps rather than the 12-app catalog, so the name here is
            // often outside `MacAppCatalog` — which is exactly why app matching falls back to a
            // normalized name instead of dropping what it cannot resolve.
            return .knowable(apps(step.appName ?? step.searchQuery))

        case .openWorkspace:
            // Its real resources are the *stored* workspace record's apps and URLs, not the step's
            // fields — and this classifier is pure, with no store to read. Resolving them belongs to
            // the wiring ticket that has the store in hand (SONNY-37). In-scope by construction when
            // the step names the bound workspace, which is the common case.
            return .none

        case .createWorkspace:
            // `workspaceApps` / `workspaceURLs` are contents being *declared*, not resources being
            // touched. Creating a workspace opens nothing.
            return .none

        case .runRoutine:
            // The routine's own steps are the resources, and they are scoped when the nested plan is
            // assessed with this same scope forwarded through `assessNestedPlan` (SONNY-37). Nothing
            // is knowable from this step alone, and nothing is lost by saying so: the nested walk
            // sees the real steps.
            return .none

        case .saveRoutine:
            // Saving writes one file inside Sonny's own store. The routine's steps are scoped when it
            // actually runs — "what it does" rather than "what it will do".
            return .none

        case .invokeShortcut:
            // A black box: Sonny shells to `shortcuts run <name>` and has no visibility into what the
            // Shortcut touches. Never escalates on scope grounds, never eligible for relaxation, and
            // it poisons its plan's roll-up so the plan around it can never be relaxed either.
            return StepScopedResources(resources: [], isOpaque: true)

        case .showPermissionReadiness, .calculateUtility, .lookupClipboardHistory,
             .expandSnippet, .saveSnippet, .lookupRecentArtifacts:
            // Pure computation, or reads and writes confined to Sonny's own encrypted local stores.
            return .none

        case .clarify:
            // Asks the user a question and stops. No side effects by design.
            return .none

        case .unsupported:
            // Never reaches a resource — `AgentActionExecutor.validateSupported` throws before any
            // adapter runs. Classified explicitly because there is no `default:` to fall into, and
            // "it cannot run" is the reason, not an oversight.
            return .none
        }
    }

    private enum WebSources: Equatable {
        /// The URLs the run will actually fetch. Empty when the step names none of the three fields,
        /// which cannot execute at all.
        case urls([String])
        /// The real URLs come back from `webSearchProvider` mid-execution and no plan field carries
        /// them, so the step is opaque.
        case searchQuery
    }

    /// Mirrors `WebResearchMarkdownCapabilityAdapter.webResearchInput(in:)`'s priority exactly:
    /// `sourceURLs` wins, then `targetURL`, then `searchQuery`. Only the third form is opaque —
    /// with either URL field populated the search branch is unreachable and the step is fully
    /// knowable.
    private static func webSources(of step: AgentStep) -> WebSources {
        let listed = (step.sourceURLs ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !listed.isEmpty {
            return .urls(listed)
        }
        let target = (step.targetURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.isEmpty {
            return .urls([target])
        }
        let query = (step.searchQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? .urls([]) : .searchQuery
    }

    private static func searchTemplateDomain(
        in step: AgentStep,
        catalog: AppSearchURLCatalog
    ) -> [ScopedResource] {
        // The template's host does not depend on the query, but `resolve` requires one. A step
        // missing its query cannot execute; probing with a placeholder still names the host it would
        // have gone to, which is the honest answer for a scope check.
        let query = step.searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = (query?.isEmpty == false) ? query : "sonny"
        guard let resolved = try? catalog.resolve(target: step.appName, query: probe),
              let host = resolved.url.host else {
            return []
        }
        return [.webDomain(host)]
    }

    private static func apps(_ rawNames: String?...) -> [ScopedResource] {
        rawNames.compactMap { raw in
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return .app(trimmed)
        }
    }

    private static func files(_ rawPaths: String?...) -> [ScopedResource] {
        rawPaths.compactMap { raw in
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return .fileLocation(trimmed)
        }
    }

    /// A URL the plan carries becomes its host. An unparseable or private-host URL yields nothing:
    /// `SafeURL` rejects it before the step can execute, so there is no resource to be reached.
    private static func domain(fromURL rawURL: String?) -> ScopedResource? {
        guard let url = try? SafeURL.validateWebURL(rawURL), let host = url.host else {
            return nil
        }
        return .webDomain(host)
    }
}
