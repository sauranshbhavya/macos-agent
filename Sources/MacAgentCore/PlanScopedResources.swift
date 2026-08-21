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
/// four real kinds of touch as touching nothing: `convert_docx_to_pdf` AppleScript-controls Microsoft
/// Word from a hardcoded path, the two Finder operations AppleScript-control Finder, a
/// selection-driven step of any of the **four** operations that resolve a folder from the Finder
/// selection — `scan_select_largest_files`, `create_zip`, `scan_docx` *and* `convert_docx_to_pdf` —
/// AppleScript-controls Finder to find the folder it runs against (`finderSelectionApp(in:)`), and
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
            // by this point it is a real path either way — and when it was, Finder was driven to
            // find it, which is what `finderSelectionApp(in:)` reports (SONNY-59).
            return .knowable(finderSelectionApp(in: step) + files(step.inputPath, step.outputPath))

        case .convertDocxToPDF:
            // Microsoft Word is implicit: `DocumentConverter` AppleScript-controls it from a
            // hardcoded `/Applications/Microsoft Word.app`, with no `MacAppCatalog` resolution and no
            // `appName` field on the step. (When Word is not installed the converter falls back to a
            // mock that touches no app; reporting Word anyway is the safe direction — over-reporting
            // escalates, under-reporting silently blesses.)
            //
            // Finder is implicit here for the same reason it is on the scan/zip trio above, and this
            // case is on the list for a reason narrower than "it is a file operation":
            // `DocxConversionCapabilityAdapter` pins `[.scanDocx, .convertDocxToPDF]` and its `spec`
            // falls back to `convertStep?.contextSource`, so a convert step is a real selection
            // reader — including on its own, since a plan carrying only this operation still routes
            // to that adapter (`AgentActionExecutor.workflow(for:)`).
            return .knowable(
                finderSelectionApp(in: step)
                    + files(step.inputPath, step.outputPath)
                    + [.app(microsoftWordAppName)]
            )

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
            // through `osascript`, with no `MacAppCatalog` resolution anywhere in the path.
            //
            // Opaque, and no file resource at all. `FinderSelectionCapabilityAdapter` reads Finder's
            // *live* selection through `FinderSelectionResolver.whitelistedSelection` and never looks
            // at `step.inputPath`; it also implements no `resolveDefaultOutputs`, so nothing pins the
            // selection onto the step before assessment either. (Only the zip and docx adapters call
            // `pinningSelectedDirectoryInput`, for their own operations.) The files are therefore
            // whatever the user has highlighted at execution time — anywhere in the whitelist — which
            // is exactly what `.opaque` is for. Emitting `.fileLocation(step.inputPath)` would report
            // a path the adapter ignores; treating the step as knowable would let a plan that reads
            // arbitrary selected files roll up `.inScope`.
            return StepScopedResources(resources: [.app(finderAppName)], isOpaque: true)

        case .revealInFinder:
            // Same implicit Finder control, and the same chained-artifact rule as
            // `open_generated_artifact` below.
            return chainedArtifact(step, alongside: [.app(finderAppName)])

        case .openGeneratedArtifact:
            // No app resource on purpose: the file is handed to `NSWorkspace.shared.open`, so Launch
            // Services picks the handler by file type at run time. **The conclusion stands; one of
            // its original supporting arguments does not.** This comment used to add that the
            // handler was "a handler no workspace could ever list" — SONNY-44 decoupled scope
            // listing from the twelve-app launch catalog, so a user *can* now list Preview or Quick
            // Look, and that argument is dead in its own terms.
            //
            // What survives is the argument that was always doing the work, and it is sufficient on
            // its own: a resource is an app the capability *drives*. Sonny AppleScript-controls
            // Microsoft Word and Finder by name, so those are reported; here nobody chose the app —
            // the user's own file-type defaults did — and the file being opened was already
            // scope-checked. The boundary is about destinations the plan chooses; the system's
            // handler for a file already inside the boundary is not one.
            //
            // **The dead argument is not licence to start reporting the handler.** Listability
            // changed; who chose the app did not. Reporting it would also still cost what it always
            // did — every "produce a file and open it" plan permanently out of scope — only now for
            // a resource that is wrong rather than merely unremediable.
            return chainedArtifact(step, alongside: [])

        case .createLocalDraft:
            return .knowable(files(step.outputPath))

        case .switchRunningApp:
            // The pin is the resource (SONNY-58): `RunningAppSwitchCapabilityAdapter`'s resolve
            // hook runs before every gate reads the plan, so by the time a verdict is computed the
            // step carries the app that will actually be activated — and that identity, not the
            // query string that found it, is what the boundary is answering for. This classifier
            // stays pure: it reads the pin off the step's own fields, it does not resolve anything.
            if let bundleIdentifier = step.resolvedBundleIdentifier {
                return .knowable([
                    .resolvedApp(
                        bundleIdentifier: bundleIdentifier,
                        displayName: step.resolvedAppName ?? bundleIdentifier
                    )
                ])
            }
            // Unpinned — resolution failed (the plan is already failing at that gate) or a caller
            // skipped the resolve phase: the raw name, exactly as before the pin existed. Matched
            // against the *running* apps rather than the 12-app catalog, so the name here is often
            // outside `MacAppCatalog` — which is exactly why app matching falls back to a
            // normalized name instead of dropping what it cannot resolve. Fail-closed: an
            // unresolvable query never earns a verdict a resolved app would have to spend.
            return .knowable(apps(step.appName ?? step.searchQuery))

        case .visionSession:
            // **Opaque, permanently, and not for lack of information about the app.** The pinned
            // target is perfectly knowable — it is right there on the step, same as
            // `switch_running_app` above — and it is reported, so a workspace whose scope excludes
            // the target still escalates through row B's machinery. What is *not* knowable is
            // everything the session goes on to touch: a vision session's whole premise is that the
            // steps are decided one screenshot at a time, by a model, after the run starts. Nothing
            // computed before the run can enumerate the files it opens, the URLs it visits or the
            // records it edits inside that app.
            //
            // That is the exact condition `.opaque` names, and it is why `get_finder_selection`
            // above is opaque too. Reporting the app while staying opaque is the honest pair:
            // over-reporting escalates, under-reporting silently blesses — and a vision session must
            // never roll a plan up to `.inScope`, because "in scope" would be a claim about
            // resources nobody has seen yet.
            if let bundleIdentifier = step.resolvedBundleIdentifier {
                return StepScopedResources(
                    resources: [
                        .resolvedApp(
                            bundleIdentifier: bundleIdentifier,
                            displayName: step.resolvedAppName ?? bundleIdentifier
                        )
                    ],
                    isOpaque: true
                )
            }
            return StepScopedResources(resources: apps(step.appName), isOpaque: true)

        case .openWorkspace:
            // Its real resources are the *stored* workspace record's apps and URLs, not the step's
            // fields — and this classifier is pure, with no store to read. Resolving them belongs to
            // the wiring ticket that has the store in hand (SONNY-37). In-scope by construction when
            // the step names the bound workspace, which is the common case.
            return .none

        case .createWorkspace, .editWorkspace:
            // `workspaceApps` / `workspaceURLs` / `workspaceFileLocations` are contents being
            // *declared*, not resources being touched. Creating or editing a workspace opens
            // nothing, reads nothing, and writes only one file inside Sonny's own store.
            //
            // The edit half is worth stating rather than inferring, because it is the one operation
            // whose plan fields are literally paths. Adding `~/Documents/ClientAlpha` to a workspace
            // does not visit that folder — it writes the string into a list — and removing it does
            // not visit it either. The folder becomes a resource when some *later* task in that
            // workspace touches it, and that task's own steps are what get classified then. Naming
            // it here would escalate configuring a boundary against the boundary being configured.
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
            // Shortcut touches. Never escalates on scope grounds, and it poisons its plan's roll-up.
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

    /// Finder, when a file operation gets its folder from the Finder selection instead of a plan
    /// field (SONNY-59).
    ///
    /// `scan_select_largest_files`, `create_zip`, `scan_docx` and `convert_docx_to_pdf` all resolve
    /// their folder through `FinderSelectionResolver`, which reads the live selection with
    /// `tell application id "com.apple.finder"` through `osascript`
    /// (`AppleScriptFinderContextReader.selectedItems`). That is the same implicit app touch this
    /// file already reports for `get_finder_selection` and `reveal_in_finder`, arriving through a
    /// different door, and the founder decision of 2026-08-06 accepts its consequence: a
    /// selection-driven zip or scan now escalates in any apps-configured workspace that does not
    /// list Finder.
    ///
    /// **Keyed on `contextSource` alone, deliberately — not on "and no `inputPath` was supplied".**
    /// By the time any gate classifies a step, `AgentActionExecutor.resolveDefaultOutputs` has
    /// already run `FinderSelectionResolver.pinningSelectedDirectoryInput`, which writes the
    /// resolved folder into `inputPath` on every matching step. Classification is reached only
    /// through `assessRisk`, whose literal first statement is that resolve (`execute`'s is too;
    /// `prepare` answers a clarification off the raw plan first and can return without resolving,
    /// which is harmless precisely because nothing classifies from there), and `assessNestedPlan`
    /// recurses into `assessRisk`, so a routine's steps are resolved as well. A populated
    /// `inputPath` is therefore evidence the selection *was* read, not evidence it was not — and a
    /// classifier that also required an empty one would fire on no real plan while still passing
    /// unit tests built from unresolved steps.
    ///
    /// **What that costs, and why the resolver rather than this file paid part of it (SONNY-73).**
    /// A step reaching classification with both `contextSource` and a non-empty `inputPath` names
    /// Finder even when `selectedDirectoryPath` returned the supplied path at `:20-25` and never
    /// talked to Finder — present tense, because one form of it is still here; see the third
    /// paragraph below. The form SONNY-73 closed was **cross-step**:
    /// `pinningSelectedDirectoryInput` pools the plan's matching steps, taking `primary` from the
    /// first non-empty `inputPath` among them and `contextSource` from the first non-nil among them
    /// — independently. So a scan carrying an explicit path with no `contextSource`, beside a zip
    /// carrying `contextSource` with no path, resolved from the scan's path with zero Finder
    /// contact, back-filled it into the zip, and the zip was reported as driving Finder. Both steps
    /// individually satisfy `OpenAIPlanner`'s Finder-context rule, so per-step planner compliance
    /// did **not** bound it — an earlier version of this comment claimed it did, and that claim was
    /// wrong. The error was always an extra escalation and never a silent blessing, which is the
    /// direction this file takes everywhere else (`convert_docx_to_pdf` reports Word even when the
    /// converter falls back to its mock); what it cost instead was a false sentence on the
    /// ran-without-asking trace, the one channel the consequence rule relies on to make its
    /// silences legible.
    ///
    /// The pooled form is fixed in `FinderSelectionResolver`, the only place that can know whether
    /// Finder was contacted: when the resolution is satisfied from an explicit path, the pin clears
    /// `contextSource` on **the steps it back-fills**, so this classifier keeps reporting exactly
    /// what the field says and the field has stopped lying about them. Nothing here changed, and
    /// nothing here needed to — which is why that stayed a separate ticket rather than a looser key
    /// on this switch.
    ///
    /// **Back-filled, not every matching step, and the difference is not caution.**
    /// `pinningSelectedDirectoryInput` runs twice over one run — `AgentRunner.prepare` resolves the
    /// plan and `approvalRequest` re-resolves the plan it returned — so on the second pass a genuine
    /// selection-driven plan carries a pinned `inputPath` on every matching step and "satisfied from
    /// an explicit path" is true of a run that had just contacted Finder. Clearing every matching
    /// step therefore deletes the report this function exists to produce; restricted to the steps
    /// each pass back-fills, the second pass back-fills nothing and clears nothing, and the rule is
    /// idempotent. SONNY-73 shipped the wrong version first and the whole suite stayed green.
    ///
    /// **The per-step form of the over-report is closed too, and this switch is what moved**
    /// (SONNY-185). A step carrying `contextSource` together with its own non-empty `inputPath` is
    /// back-filled by nothing, so the clearing above never reached it: it kept its marker and was
    /// still reported as driving Finder. After the first pass such a step is indistinguishable from
    /// a genuine declaring step the pin filled in, so no rule reading `contextSource` and
    /// `inputPath` could separate them — which is why the answer is a second field rather than a
    /// cleverer rule. `AgentStep.resolvedFromFinderSelection` is written by
    /// `pinningSelectedDirectoryInput` on the steps it back-fills, and only on a pass that actually
    /// drove Finder; this function now requires **both** the planner's declaration and that
    /// resolver's fact.
    ///
    /// **An unresolved plan still names Finder, and that is a decision rather than an accident**
    /// (founder, 2026-08-21). Keying on the pin *alone* would have been exact everywhere and would
    /// have been safe today — `classification(of:)` is reached from `WorkspaceScopeEvaluator.evaluate`
    /// alone, whose only caller in `Sources/` is `AgentActionExecutor.scopeFindings`, whose only
    /// caller is `assessRisk`, whose first statement is `resolveDefaultOutputs(in: plan)`, which is
    /// where the pin runs (`git grep -n "PlanScopedResources\." -- Sources/` returns one line
    /// outside this file, and `git grep -n "WorkspaceScopeEvaluator.evaluate" -- Sources/` returns
    /// one, both at `d8cd968`). But "safe because nothing calls it that way" is safe until something
    /// does, and it would have made this the one place the classifier can go *quiet* about a
    /// resource rather than loud. So the second disjunct stands: before resolution Finder is
    /// presumed, after resolution it is known. `aSelectionDrivenStepNamesFinderBeforeAnythingHasPinnedItsFolder`
    /// is unchanged and still pins the first half.
    ///
    /// Reported per step rather than per plan because that is all a step-scoped classifier can see.
    /// The selection is read once for the whole plan, so in a mixed plan the step that declares
    /// itself selection-driven is the one that names Finder. The plan-level roll-up is a maximum, so
    /// the verdict is the same either way.
    private static func finderSelectionApp(in step: AgentStep) -> [ScopedResource] {
        guard step.contextSource == .finderSelection else {
            return []
        }
        // Either the resolver confirmed it drove Finder for this step, or nothing has resolved a
        // path onto it yet and Finder is still the presumptive source. The second disjunct is what
        // keeps this classifier answering the same question on both sides of the resolve phase; it
        // can only ever *add* Finder to a plan that has not been resolved, which is the direction
        // this file takes everywhere. The one shape it excludes is the one SONNY-185 is about: a
        // step that declares itself selection-driven and arrived carrying its own folder, which the
        // resolver never had to read a selection to satisfy.
        let arrivedWithItsOwnFolder = step.inputPath?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return step.resolvedFromFinderSelection == true || !arrivedWithItsOwnFolder
            ? [.app(finderAppName)]
            : []
    }

    /// `reveal_in_finder` and `open_generated_artifact` name their target directly, or name nothing
    /// and take whatever the previous chain segment produced.
    ///
    /// The path-less form is **opaque**, and the reason is narrower than "no field is set". The
    /// chained target is filled in by `AgentActionExecutor.resolvePreviousArtifactPathIfNeeded`
    /// during `previewChain`/`executeChain` — after the gate has already closed — from the previous
    /// segment's `ActionPreview.writes` or its last run suggestion. Those are runtime values: the
    /// docx converter's writes, for one, are destination paths derived from scanning a folder, not
    /// anything a plan field carries. It is *usually* true that the produced file lands inside a
    /// folder some earlier step already named, which is why this looked knowable at first — but that
    /// is an inference about today's capabilities, and inferring a boundary is the failure mode this
    /// whole classifier is shaped to refuse.
    private static func chainedArtifact(
        _ step: AgentStep,
        alongside implicitApps: [ScopedResource]
    ) -> StepScopedResources {
        let named = files(step.outputPath ?? step.inputPath)
        return StepScopedResources(resources: implicitApps + named, isOpaque: named.isEmpty)
    }

    private enum WebSources: Equatable {
        /// The URLs the run will actually fetch. Empty when the step names none of the three fields,
        /// which cannot execute at all.
        case urls([String])
        /// The real URLs come back from `webSearchProvider` mid-execution and no plan field carries
        /// them, so the step is opaque.
        case searchQuery
    }

    /// Mirrors `WebResearchMarkdownCapabilityAdapter.webResearchInput(in:)`'s **priority order**
    /// exactly: `sourceURLs` wins, then `targetURL`, then `searchQuery`, each trimmed and skipped
    /// when empty. Only the third form is opaque — with either URL field populated the search branch
    /// is unreachable and the step is fully knowable.
    ///
    /// What it deliberately does *not* mirror is the adapter's failure behavior on an invalid entry.
    /// `webResearchInput` validates with a throwing `map`, so one bad URL in `sourceURLs` aborts the
    /// whole step and the run touches nothing; `domain(fromURL:)` uses `try?` and keeps the valid
    /// hosts. That makes this an over-report for that shape — a host is named that the run will not
    /// visit — which is the safe direction (it escalates rather than blesses) and the same direction
    /// this file takes everywhere else. Do not "fix" it by dropping the whole list on one bad entry:
    /// a classifier that reports nothing when a plan is malformed is how a real resource goes
    /// unchecked.
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
