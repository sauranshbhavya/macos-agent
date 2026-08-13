import Foundation
import Testing
@testable import MacAgentCore

@Suite
struct PlannerBoundaryTests {
    @Test
    func defaultToolRegistryPlannerDescriptionMatchesGolden() {
        assertExactString(ToolRegistry.default.plannerDescription, expectedDefaultPlannerDescription)
    }

    @Test
    func defaultSystemPromptMatchesGolden() {
        let expected = """
        You plan a tiny macOS agent. Return only a JSON object that matches the provided schema.

        Registered local tools:
        \(expectedDefaultPlannerDescription)

        Important rules:
        - Use only the fixed operation enum values.
        - Use registered tools only. Do not invent tools, commands, scripts, or APIs.
        - Include user-supplied paths exactly as written. Do not invent local file paths.
        - A TRUSTED_PRIOR_TASK_CONTEXT_BEGIN/END message may appear before the current command. It is Sonny's short-lived record of only the immediately preceding task.
        - The user may provide a short correction such as "use ~/Documents instead", "try /tmp instead", "no, scan ~/Documents instead", or "use 5 instead".
        - When prior task context is present and the current command is a correction/refinement phrase that does not name a complete new action, reuse the prior task's exact action(s), operation(s), count(s), output intent, and safety/risk-relevant behavior. Replace only the field(s) the user explicitly changed, such as folder/path, URL, app, count, query, provider, or output path.
        - If prior plan summary or steps are unavailable because the prior task failed before preparation completed, infer the prior action from Previous command and Previous outcome, then apply the user's correction to that same action.
        - Do not invent a different task category or unrelated candidate operation from a short correction phrase. For example, after a largest-files task, "use ~/Documents instead" means run the same largest-files task against ~/Documents; it does not mean search for documents, convert DOCX files, or ask which operation to perform.
        - If the new command is a complete standalone task, or it clearly conflicts with the prior task rather than refining it, ignore prior task context and plan the new command normally.
        - Ask a clarification question only when both the prior task and the correction text still leave the replacement field or required action unresolved. Do not ask for clarification merely because the correction phrase is short.
        - Use null for unavailable fields.
        - If a folder, app name, URL, count, or output destination is required but missing or ambiguous, return exactly one clarify step with a short question.
        - For largest files, produce scan_select_largest_files then create_zip.
        - For DOCX conversion, produce scan_docx then convert_docx_to_pdf.
        - For Hacker News headline saving, produce open_hacker_news, fetch_hn_headlines, then write_markdown.
        - For summarizing one public web page to Markdown, produce one web_to_markdown step with targetURL and optional outputPath.
        - For comparing multiple public web sources to Markdown, produce one web_to_markdown step with sourceURLs and optional outputPath.
        - For researching a topic/search query to Markdown, produce one web_to_markdown step with searchQuery and optional outputPath.
        - For opening an app, produce one open_app step with appName.
        - For opening an allowlisted app or website search page, produce one open_app_search_url step with appName and searchQuery. Use only supported search targets; do not invent URL templates.
        - For opening a general website, produce one open_url step with targetURL using http or https.
        - For creating a local draft, produce one create_local_draft step with draftTitle, draftContent, and optional outputPath. Do not automate Notes, Mail, Calendar, or any app UI.
        - For opening a generated local artifact after a writing step, add open_generated_artifact with outputPath null so the executor can open the previous produced artifact.
        - For saving a text snippet, produce one save_snippet step with searchQuery holding the trigger and draftContent holding the text it expands to. Use only a trigger and text the user supplied; if either is missing, ask a clarification question. This step may also be nested inside save_routine.
        - For bringing an app that is already running to the front, produce one switch_running_app step with appName holding only the app the user named. A phrase such as "in my research workspace" says where the task belongs, not what to change: never turn a request to switch or focus on an app into edit_workspace or create_workspace. When the thing the user asks to switch or focus on is itself a saved workspace rather than an app, that is an open_workspace request instead. Use open_app when the user asked to open or launch an app that may not be running.
        - For song or album requests, produce one play_media step with mediaProvider, mediaTitle, optional mediaArtist, and targetURL only if the user supplied an exact Apple Music or Spotify result URI. The local executor tries provider-aware playback first, then falls back to opening the provider result or search.
        - If a song or album request is missing the provider or title, ask a clarification question.
        - For Finder context phrases such as "selected folder", "selected files", "this Finder selection", or "the folder selected in Finder", set contextSource to finder_selection and leave inputPath null.
        - For "reveal the result/zip/markdown/PDFs in Finder" after a writing step, add reveal_in_finder with outputPath null so the executor can reveal the previous produced artifact.
        - For permission/readiness requests, produce one show_permission_readiness step.
        - For teaching a routine, produce one save_routine step with routineName and routineSteps containing only registered non-routine steps. Do not put save_routine, run_routine, switch_running_app, clarify, or unsupported inside routineSteps.
        - For running a saved routine, produce one run_routine step with routineName.
        - For creating a workspace, produce one create_workspace step with workspaceName, workspaceApps, and workspaceURLs. Use only explicitly named apps/URLs. If none are provided, ask a clarification question.
        - For changing a workspace the user already saved, produce one edit_workspace step with workspaceName and only the fields the user asked to change: workspaceApps, workspaceURLs, workspaceFileLocations to add, and workspaceAppsToRemove, workspaceURLsToRemove, workspaceFileLocationsToRemove to remove. Never use create_workspace to change an existing workspace, and never put an item in both an add and a remove field.
        - For opening a saved workspace, produce one open_workspace step with workspaceName.
        - For running an existing Apple Shortcut, produce one invoke_shortcut step with shortcutName and optional shortcutInput when simple text input was explicitly supplied.
        - You may produce multi-step chained plans when the user asks for multiple supported actions. Keep steps in execution order.
        - For any unsupported request, return one unsupported step and explain why.
        - Never include shell commands, AppleScript, or code.
        """

        assertExactString(OpenAIPlanner.systemPrompt(toolRegistry: .default), expected)
    }

    @Test
    func responseFormatPreservesStrictAgentPlanSchemaShape() throws {
        let format = AgentPlanSchema.responseFormat()
        #expect(format["type"] as? String == "json_schema")
        #expect(format["name"] as? String == "agent_plan")
        #expect(format["strict"] as? Bool == true)

        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(schema["required"] as? [String] == ["summary", "requiresConfirmation", "steps"])

        let properties = try #require(schema["properties"] as? [String: Any])
        let steps = try #require(properties["steps"] as? [String: Any])
        #expect(steps["type"] as? String == "array")
        #expect(steps["minItems"] as? Int == 1)

        let stepItems = try #require(steps["items"] as? [String: Any])
        #expect(stepItems["type"] as? String == "object")
        #expect(stepItems["additionalProperties"] as? Bool == false)
        #expect(stepItems["required"] as? [String] == [
            "id",
            "operation",
            "description",
            "inputPath",
            "outputPath",
            "count",
            "targetURL",
            "appName",
            "question",
            "mediaProvider",
            "mediaTitle",
            "mediaArtist",
            "contextSource",
            "routineName",
            "routineSteps",
            "workspaceName",
            "workspaceApps",
            "workspaceURLs",
            "workspaceFileLocations",
            "workspaceAppsToRemove",
            "workspaceURLsToRemove",
            "workspaceFileLocationsToRemove",
            "sourceURLs",
            "searchQuery",
            "draftTitle",
            "draftContent",
            "shortcutName",
            "shortcutInput"
        ])

        let stepProperties = try #require(stepItems["properties"] as? [String: Any])
        let operation = try #require(stepProperties["operation"] as? [String: Any])
        #expect(operation["type"] as? String == "string")
        #expect(operation["enum"] as? [String] == AgentOperation.plannerVisibleCases.map(\.rawValue))
        #expect(!(operation["enum"] as? [String] ?? []).contains(AgentOperation.calculateUtility.rawValue))
        #expect(!(operation["enum"] as? [String] ?? []).contains(AgentOperation.lookupClipboardHistory.rawValue))
        #expect(!(operation["enum"] as? [String] ?? []).contains(AgentOperation.expandSnippet.rawValue))
        #expect(!(operation["enum"] as? [String] ?? []).contains(AgentOperation.lookupRecentArtifacts.rawValue))
        #expect((operation["enum"] as? [String] ?? []).contains(AgentOperation.invokeShortcut.rawValue))
        // SONNY-68: in the schema on purpose. Its absence was what left a switch phrasing the
        // instant resolver declined with no truthful operation to become.
        #expect((operation["enum"] as? [String] ?? []).contains(AgentOperation.switchRunningApp.rawValue))
        // SONNY-48: in the schema on purpose, and the nested enum is the same one — which is the
        // point, since the shape that was unauthorable is a save_snippet step inside a routine.
        #expect((operation["enum"] as? [String] ?? []).contains(AgentOperation.saveSnippet.rawValue))

        let routineSteps = try #require(stepProperties["routineSteps"] as? [String: Any])
        #expect(routineSteps["type"] as? [String] == ["array", "null"])
        let nestedItems = try #require(routineSteps["items"] as? [String: Any])
        let nestedProperties = try #require(nestedItems["properties"] as? [String: Any])
        let nestedRoutineSteps = try #require(nestedProperties["routineSteps"] as? [String: Any])
        #expect(nestedRoutineSteps["type"] as? String == "null")
    }

    /// **Both directions of the switch rule, pinned separately from the golden** (PR #39 review,
    /// cycle 1, F1).
    ///
    /// The rule was written to stop one misroute and, as first worded, closed the opposite reading
    /// too: "never turn a switch, focus, or bring-to-front request into … open_workspace" forbids
    /// the one correct plan for "switch me to my Research workspace", where the thing named *is* a
    /// workspace. The intent was then shut at both ends — the resolver captured the phrasing (F1's
    /// blocker) and the planner was told not to express it.
    ///
    /// The golden already pins the sentence character for character, so this test is not about the
    /// text. It is about the two obligations being separable: an edit that quietly drops either one
    /// while rewriting the sentence should fail here with a name that says which half went.
    @Test
    func theSwitchRuleForbidsTheMisrouteWithoutForbiddingAGenuineWorkspaceOpen() {
        let prompt = OpenAIPlanner.systemPrompt(toolRegistry: .default)

        // Direction 1 — the misroute this ticket exists to close.
        #expect(prompt.contains("never turn a request to switch or focus on an app into edit_workspace or create_workspace"))
        // Direction 2 — the reading that must stay available.
        #expect(prompt.contains("is itself a saved workspace rather than an app, that is an open_workspace request"))
        // And the rule must not re-forbid it by naming open_workspace among the operations a switch
        // request may never become.
        #expect(!prompt.contains("into edit_workspace, create_workspace, or open_workspace"))
        // The standalone open_workspace rule is untouched and still there for the planner to use.
        #expect(prompt.contains("For opening a saved workspace, produce one open_workspace step with workspaceName."))
    }

    /// **The agreement that was true by accident until SONNY-68 pinned it.**
    ///
    /// The planner's vocabulary is defined in two places that never referred to each other: the
    /// schema's exclusion list (`AgentOperation.plannerVisibleCases`) and the per-adapter
    /// `plannerTools` arrays that build the prompt. They happened to name the same operations, and
    /// nothing said they had to — so an operation could be dropped from one and left in the other,
    /// producing either a tool the schema forbids or an enum value the prompt never describes.
    ///
    /// Excluding an operation is only defensible when something *else* reaches it, which is the
    /// third leg: every excluded operation must be reachable through the instant resolver. That is
    /// the leg SONNY-68's defect broke — `switch_running_app` was excluded on the assumption the
    /// resolver claimed every switch phrasing, and the phrasings it declined had nowhere truthful
    /// to go. The commands below are the actual front doors, so a resolver change that closed one
    /// fails here rather than silently stranding an operation.
    @Test
    func plannerExclusionsAgreeWithEmptyToolAdaptersAndWithInstantResolverCoverage() throws {
        let excluded = Set(AgentOperation.allCases).subtracting(AgentOperation.plannerVisibleCases)
        let emptyToolOperations = Set(
            CapabilityRegistry.default.metadata
                .filter { $0.plannerTools.isEmpty }
                .flatMap(\.operations)
        )

        #expect(excluded == emptyToolOperations)
        #expect(excluded == [
            .calculateUtility,
            .lookupClipboardHistory,
            .expandSnippet,
            .lookupRecentArtifacts
        ])

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlannerBoundaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snippetStore = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
        try snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "Sent from Sonny"))
        let resolver = InstantCommandResolver(
            snippetStore: snippetStore,
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        )

        let frontDoors: [AgentOperation: String] = [
            .calculateUtility: "calc 2 + 2",
            .lookupClipboardHistory: "clipboard history",
            .expandSnippet: ";sig",
            .lookupRecentArtifacts: "recent artifacts"
        ]
        #expect(Set(frontDoors.keys) == excluded)
        for (operation, command) in frontDoors {
            guard case .plan(let plan)? = resolver.resolve(command: command) else {
                Issue.record("\(operation.rawValue) has no instant-resolver front door: \(command) did not resolve.")
                continue
            }
            #expect(plan.steps.map(\.operation) == [operation], "\(command) must resolve to \(operation.rawValue).")
        }

        // The two operations that left the exclusion set: planner-visible and resolver-reachable at
        // once, which is the point — the resolver answers the fixed command shapes instantly and
        // the planner has a truthful word for everything else. Leaving the set is not leaving the
        // resolver, and asserting both halves is what stops a later change from quietly trading one
        // door for the other.
        for operation in [AgentOperation.switchRunningApp, .saveSnippet] {
            #expect(!excluded.contains(operation))
            #expect(!emptyToolOperations.contains(operation))
        }
        guard case .plan(let switchPlan)? = resolver.resolve(command: "switch to Notion") else {
            Issue.record("switch_running_app must stay reachable through the instant resolver.")
            return
        }
        #expect(switchPlan.steps.map(\.operation) == [.switchRunningApp])
        guard case .plan(let savePlan)? = resolver.resolve(command: "snippet save ;bye = Talk soon") else {
            Issue.record("save_snippet must stay reachable through the instant resolver.")
            return
        }
        #expect(savePlan.steps.map(\.operation) == [.saveSnippet])
    }

    /// **The two app-shaped tools diverge on purpose, and the prompt has to say so** (SONNY-83).
    ///
    /// `open_app` is now an open universe: the model is told there is no supported-apps list, and the
    /// runtime opens anything installed. `open_app_search_url` is the opposite and stays that way —
    /// its five templates are a §7.4-class audited-template boundary, where the authority sits in the
    /// *URL Sonny constructs*, not in the app being named. Widening it would mean building arbitrary
    /// search URLs from model output, which is a different question from launching an installed app
    /// and is not what C12 ratified; non-catalog search targets are reachable through vision instead
    /// (row I).
    ///
    /// Pinned as a *contrast*, not two separate assertions, because the failure mode worth catching
    /// is a later reader applying the dissolution one tool too far.
    @Test
    func openAppIsOpenUniverseWhileOpenAppSearchURLStaysAFixedTemplateSet() throws {
        let openApp = try #require(OpenAppCapabilityAdapter.metadata.plannerTools.first)
        let searchURL = try #require(OpenAppSearchURLCapabilityAdapter.metadata.plannerTools.first)

        // What the model is told.
        #expect(openApp.description.contains("any application installed on this Mac"))
        #expect(openApp.description.contains("Not limited to a fixed list of apps"))
        #expect(!openApp.description.contains("Supported apps:"))
        #expect(searchURL.description.contains("Supported search targets: Google, GitHub, YouTube, Apple Music, Spotify."))

        // And what the runtime does with the same name, which is what makes the divergence real
        // rather than a wording difference.
        #expect(AppSearchURLCatalog.default.templates.count == 5)
        #expect(throws: AppSearchURLCatalogError.searchTargetNotAllowed("Figma")) {
            _ = try AppSearchURLCatalog.default.resolve(target: "Figma", query: "buttons")
        }
        let installed = InstalledAppResolver(
            source: FixedAppSource([
                InstalledApp(
                    displayName: "Figma",
                    bundleIdentifier: "com.figma.Desktop",
                    applicationURL: URL(fileURLWithPath: "/Applications/Figma.app")
                )
            ])
        )
        #expect(installed.resolve("Figma")?.bundleIdentifier == "com.figma.Desktop")
    }

    /// **The whole assembled prompt speaks one vocabulary about apps, and the sweep that proves it
    /// is a test rather than a grep someone remembered to run** (PR #44 cycle-1 review, MEDIUM-2).
    ///
    /// SONNY-83 rewrote `open_app` and left three sibling descriptions still promising a
    /// supported-apps list — `create_workspace`'s "An unsupported app is saved for scope only and
    /// simply is not opened when the workspace opens" was outright false after C12, and the prompt
    /// simultaneously told the model that no such list exists and that apps can be outside it. That
    /// survived because the sweep that caught the *first* vocabulary ("allowlist") never looked for
    /// the one the rename introduced ("supported apps"). **Both are searched here, and any future
    /// third has to be added deliberately.**
    ///
    /// Deliberately run over `OpenAIPlanner.systemPrompt` — the real assembled text, scaffold rules
    /// included — not over the tool descriptions alone, because rule lines carry this vocabulary too.
    /// Markup-tolerant per `CLAUDE.md`'s counting rule: the pattern tolerates emphasis characters,
    /// hyphens and line-wrapping whitespace between words, so `*supported* apps` and `supported-apps`
    /// match as readily as the plain phrase.
    ///
    /// The one survivor is `open_app_search_url`, whose five templates *are* still a fixed
    /// allowlist — a §7.4-class audited-template boundary C12 explicitly did not dissolve. So the
    /// assertion is not "no hits" but "every hit is a search-URL line", which keeps the deliberate
    /// exception legible instead of hiding it behind an exact-count number that means nothing to
    /// whoever reads the failure.
    @Test
    func theAssembledPromptSpeaksOneAppVocabularyOutsideTheSearchURLBoundary() throws {
        let prompt = OpenAIPlanner.systemPrompt(toolRegistry: .default)
        // Three deliberate asymmetries, each paid for by a wrong count during the cycle-1 fix round:
        //
        // 1. A lookbehind rejecting a preceding *letter* before lowercase "allow", because
        //    "sh**allow** **list**ing" otherwise matches — and it does occur, in
        //    `InstalledAppResolver`'s own sweep doc comment. A naive markup-tolerant pattern read 24
        //    where the true count was 23.
        // 2. A separate camelCase alternative for capital "Allow", because a plain `\b` fixes (1)
        //    and then silently drops `OpenAllowlistedAppCapabilityAdapter` — the correction for one
        //    false positive bought a false negative, and the re-measurement read 22.
        // 3. No boundary at all before "support", because "unsupported apps" is exactly the stale
        //    vocabulary worth catching rather than a word to be excluded.
        // Explicit case classes rather than `.caseInsensitive`, because the flag is global and this
        // pattern needs case-*sensitivity* in one alternative and not the others: a case-insensitive
        // engine cannot tell camelCase `OpenAllowlisted` from the "shallow" the lookbehind exists to
        // reject. Written out, each alternative says what it means on its own.
        let pattern = try NSRegularExpression(
            pattern: #"(?<![A-Za-z])[Aa]llow[\W_]{0,3}[Ll]ist\w*|Allow[\W_]{0,3}[Ll]ist\w*|[Ss]upport\w*[\W_]{0,3}[Aa]pps?\b"#,
            options: []
        )

        var offenders: [String] = []
        for line in prompt.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard pattern.firstMatch(in: text, range: range) != nil else {
                continue
            }
            // The deliberate exception, identified by what the line is *about* rather than by
            // position, so reordering the registry cannot silently widen it.
            //
            // Matched on search-URL *markers*, never on the bare word "search". The first draft of
            // this test exempted any line containing "search" and was caught by its own mutation
            // battery: `open_workspace`'s description ends "…or \"get into research mode\" — ask a
            // clarifying question instead", and re-**search** contains it, so the guard exempted
            // precisely the line the cycle-1 review had flagged. A guard whose exception is a
            // substring of ordinary prose is not a guard.
            let lowered = text.lowercased()
            let isSearchURLLine = ["open_app_search_url", "search url", "search target"]
                .contains { lowered.contains($0) }
            if isSearchURLLine {
                continue
            }
            offenders.append(text.trimmingCharacters(in: .whitespaces))
        }

        #expect(
            offenders.isEmpty,
            """
            The assembled planner prompt still promises an app allowlist or a supported-apps list \
            outside the search-URL templates. C12 dissolved the launch allowlist; any surviving \
            mention is telling the model something the runtime will not do:
            \(offenders.joined(separator: "\n"))
            """
        )
        // The exception itself is asserted rather than assumed: if the search-URL tool ever stopped
        // saying this, the loop above would pass vacuously and this test would be pinning nothing.
        #expect(prompt.contains("Open a fixed allowlisted app or website search URL template."))
    }
}

private let expectedDefaultPlannerDescription = """
- scan_select_largest_files: Scan and select largest files
  description: Recursively scan a whitelisted folder, skip symlinks, and select the largest regular files. Defaults to the 3 largest when count is omitted.
  required fields: inputPath
  side effects: none
  dry run: Show the selected files and sizes.
  examples: Find the 3 largest files in ~/Desktop/MacAgentDemo
- create_zip: Create zip archive
  description: Create a timestamped zip archive from the selected largest files.
  required fields: inputPath
  side effects: write file
  dry run: Show the zip path without writing it.
  examples: Zip the selected files
- scan_docx: Scan DOCX files
  description: Recursively find .docx files in a whitelisted folder.
  required fields: inputPath
  side effects: none
  dry run: List conversion targets and skipped existing PDFs.
  examples: Find DOCX files in ~/Documents/MacAgentDocs
- convert_docx_to_pdf: Convert DOCX to PDF
  description: Convert discovered DOCX files to PDFs using Microsoft Word or explicit mock mode.
  required fields: inputPath
  side effects: write files, control Microsoft Word
  dry run: Show conversion pairs without opening Word or writing PDFs.
  examples: Convert all .docx to .pdf in ~/Documents/MacAgentDocs
- open_hacker_news: Open Hacker News
  description: Open Hacker News in the default browser as part of the headline workflow.
  required fields: none
  side effects: open browser
  dry run: Show that Hacker News would open.
  examples: Open Hacker News
- fetch_hn_headlines: Fetch Hacker News headlines
  description: Fetch the top Hacker News headlines from the public API. Defaults to the top 5 when count is omitted.
  required fields: none
  side effects: network request
  dry run: Show the number of headlines that would be fetched.
  examples: Grab the top 5 headlines
- write_markdown: Write Markdown file
  description: Write fetched Hacker News headlines to Markdown in a whitelisted output path.
  required fields: none
  side effects: write file
  dry run: Show the Markdown path without writing it.
  examples: Save to a Markdown file
- web_to_markdown: Web page to Markdown
  description: Fetch one public http/https URL, resolve a topic through a configured search provider, or fetch multiple http/https sourceURLs for comparison, synthesize a research note, and save Markdown in a whitelisted output path. Sources that cannot be retrieved are skipped and listed in the note; the step fails only when every source fails.
  required fields: targetURL, sourceURLs, or searchQuery
  side effects: network request, send fetched public page content to OpenAI, write file
  dry run: Show source URL(s), search query, and Markdown output path without fetching pages or writing files.
  examples: Summarize https://example.com/article and save as Markdown | Compare these source URLs and save a Markdown note | Research Swift concurrency and save a Markdown note
- open_app: Open Mac app
  description: Open any application installed on this Mac, by the human name the user said. Not limited to a fixed list of apps: do not substitute a different app, and do not drop the request because a name looks unfamiliar. The runtime decides whether the app is installed, and the step fails with a clear message when it is not.
  required fields: appName
  side effects: open app
  dry run: Show the app that would open.
  examples: Open Safari | Open Figma | Launch Discord
- open_app_search_url: Open allowlisted search URL
  description: Open a fixed allowlisted app or website search URL template. Supported search targets: Google, GitHub, YouTube, Apple Music, Spotify.
  required fields: appName, searchQuery
  side effects: open browser
  dry run: Show the fixed search URL template result without opening it.
  examples: Search GitHub for Swift concurrency | Search YouTube for Sonny demos
- open_url: Open web URL
  description: Open a safe http or https URL in the default browser.
  required fields: targetURL
  side effects: open browser
  dry run: Show the URL that would open.
  examples: Open GitHub | Open https://gmail.com
- open_generated_artifact: Open generated artifact
  description: Open a specific whitelisted generated file, or open the most recent file produced earlier in the same chain when outputPath is null.
  required fields: none
  side effects: open file
  dry run: Show the file that would open.
  examples: Open the generated Markdown | Open the result
- create_local_draft: Create local draft
  description: Create a local Markdown draft artifact in a whitelisted output path. This does not automate Notes, Mail, Calendar, or any other app UI.
  required fields: draftContent
  side effects: write file
  dry run: Show the draft file path without writing it.
  examples: Create a local draft called Follow-up with this text
- save_snippet: Save snippet
  description: Save a text snippet under a short trigger, so typing the trigger later expands to the text. Put the trigger in searchQuery and the text in draftContent. Use only the trigger and text the user actually supplied; if either is missing, ask a clarification question instead of inventing one. This is also the step to nest inside save_routine when a routine should save a snippet.
  required fields: searchQuery, draftContent
  side effects: write local snippet file
  dry run: Show the trigger and expansion without saving.
  examples: Save a snippet ;sig that expands to my email signature | Teach Sonny a routine called onboarding that saves my welcome snippet
- switch_running_app: Switch to a running app
  description: Bring an app that is already running to the front. Launches nothing: if the named app is not running the step fails by name instead of opening it. Use for switch/focus/bring-to-front phrasings, including ones that also name a workspace; use open_app when the user asked to open or launch an app that may not be running.
  required fields: appName
  side effects: bring a running app to the front
  dry run: Show the running app that would come to the front.
  examples: Switch to Chrome | Bring me back to Slack | Focus VS Code in my Client Alpha workspace
- play_media: Play or open music
  description: Try to play a requested song or album in Apple Music or Spotify through the provider playback seam. If playback is unavailable, open the exact provider result URI when supplied, or open the provider search/result fallback.
  required fields: mediaProvider, mediaTitle
  side effects: play or open music app
  dry run: Show whether Sonny would search, play, transfer playback, or fall back to opening without starting playback or opening an app.
  examples: Play Jimmy Cooks by Drake on Apple Music | Play Bad Habit by Steve Lacy on Spotify
- get_finder_selection: Read Finder selection
  description: Read selected Finder files and folders, validate that every path is inside the Desktop/Documents whitelist, and show them as context.
  required fields: none
  side effects: ask Finder for selection
  dry run: Show selected Finder items without modifying them.
  examples: What is selected in Finder? | Show my Finder selection
- reveal_in_finder: Reveal path in Finder
  description: Reveal a specific whitelisted path in Finder, or reveal the most recent file produced earlier in the same chain when outputPath is null.
  required fields: none
  side effects: open Finder
  dry run: Show the path that would be revealed.
  examples: Reveal the zip in Finder | Show the generated Markdown in Finder
- show_permission_readiness: Show permission readiness
  description: Show readiness for OpenAI key, microphone, hotkey, Finder/Word automation, Desktop/Documents access, Accessibility, and Screen Recording.
  required fields: none
  side effects: none
  dry run: Show permission readiness without requesting new permissions.
  examples: Check Sonny permissions | Show readiness panel
- save_routine: Teach Sonny a routine
  description: Save a named routine made from nested registered routineSteps. Routines are declarative local plans, not scripts.
  required fields: routineName, routineSteps
  side effects: write local routine file
  dry run: Show the routine name and nested steps without saving.
  examples: Teach Sonny a routine called morning setup that opens Safari and Notes
- run_routine: Run saved routine
  description: Load a saved routine by name and execute its registered steps with the same validation and logging as normal plans. Use only when the user names a routine they have actually saved; do not infer a routine name from vague activity phrasing such as "start my day" — ask a clarifying question instead.
  required fields: routineName
  side effects: depends on saved routine
  dry run: Preview the saved routine without executing its steps.
  examples: Run my morning setup routine
- create_workspace: Create workspace launcher
  description: Save a named workspace containing the apps and safe http/https URLs the user names. Include every app the user names, whether or not it is installed on this Mac, because a workspace's apps are also its restriction scope. An app that is not installed is still saved, for scope only, and is skipped when the workspace opens.
  required fields: workspaceName
  side effects: write local workspace file
  dry run: Show the workspace apps and URLs without saving.
  examples: Create a workspace called research with Safari, VS Code, and https://github.com | Create a workspace called drafting with Microsoft Word and Safari
- edit_workspace: Edit workspace
  description: Add or remove apps, safe http/https URLs, and folders on a workspace the user has already saved. A workspace's apps, URLs, and folders are also its restriction scope, so include every app the user names, whether or not it is installed on this Mac. Folders must be inside Desktop or Documents.
  required fields: workspaceName
  side effects: write local workspace file
  dry run: Show the additions and removals without saving.
  examples: Add ~/Documents/ClientAlpha to my Client Alpha workspace | Remove Slack from my research workspace
- open_workspace: Open saved workspace
  description: Open the apps and URLs saved in a named workspace. Use only when the user names a workspace they have actually saved; do not infer a workspace name from vague activity phrasing such as "focus on writing" or "get into research mode" — ask a clarifying question instead.
  required fields: workspaceName
  side effects: open apps, open browser
  dry run: Show apps and URLs that would open.
  examples: Open my research workspace | Start research mode
- invoke_shortcut: Invoke Shortcut
  description: Run an existing named Apple Shortcut. Use shortcutInput only for simple text input explicitly supplied by the user.
  required fields: shortcutName
  side effects: run Shortcut
  dry run: Show the Shortcut name and input without running it.
  examples: Run my Morning Routine shortcut | Run shortcut Resize Image with input ~/Desktop/photo.png
- clarify: Ask clarification
  description: Ask a short question when a required folder, app, count, or output destination is missing or ambiguous.
  required fields: question
  side effects: none
  dry run: Show the question and wait for the user answer.
  examples: Which folder should I scan?
"""

private func assertExactString(_ actual: String, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
    guard actual != expected else {
        return
    }

    let actualScalars = Array(actual.unicodeScalars)
    let expectedScalars = Array(expected.unicodeScalars)
    let mismatch = (0..<min(actualScalars.count, expectedScalars.count)).first {
        actualScalars[$0] != expectedScalars[$0]
    }
    let detail: String
    if let mismatch {
        detail = "Mismatch at scalar \(mismatch): actual \(debugScalar(actualScalars[mismatch])), expected \(debugScalar(expectedScalars[mismatch]))."
    } else {
        detail = "No scalar mismatch before one string ended."
    }
    Issue.record("\(detail) actualCount=\(actualScalars.count), expectedCount=\(expectedScalars.count)", sourceLocation: sourceLocation)
}

private func debugScalar(_ scalar: UnicodeScalar) -> String {
    "\\u{\(String(scalar.value, radix: 16))} (\(String(scalar)))"
}
