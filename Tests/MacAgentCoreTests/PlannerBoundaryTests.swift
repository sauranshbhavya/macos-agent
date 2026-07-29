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
        - For song or album requests, produce one play_media step with mediaProvider, mediaTitle, optional mediaArtist, and targetURL only if the user supplied an exact Apple Music or Spotify result URI. The local executor tries provider-aware playback first, then falls back to opening the provider result or search.
        - If a song or album request is missing the provider or title, ask a clarification question.
        - For Finder context phrases such as "selected folder", "selected files", "this Finder selection", or "the folder selected in Finder", set contextSource to finder_selection and leave inputPath null.
        - For "reveal the result/zip/markdown/PDFs in Finder" after a writing step, add reveal_in_finder with outputPath null so the executor can reveal the previous produced artifact.
        - For permission/readiness requests, produce one show_permission_readiness step.
        - For teaching a routine, produce one save_routine step with routineName and routineSteps containing only registered non-routine steps. Do not put save_routine, run_routine, clarify, or unsupported inside routineSteps.
        - For running a saved routine, produce one run_routine step with routineName.
        - For creating a workspace, produce one create_workspace step with workspaceName, workspaceApps, and workspaceURLs. Use only explicitly named apps/URLs. If none are provided, ask a clarification question.
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
        #expect(!(operation["enum"] as? [String] ?? []).contains(AgentOperation.saveSnippet.rawValue))
        #expect(!(operation["enum"] as? [String] ?? []).contains(AgentOperation.switchRunningApp.rawValue))
        #expect(!(operation["enum"] as? [String] ?? []).contains(AgentOperation.lookupRecentArtifacts.rawValue))
        #expect((operation["enum"] as? [String] ?? []).contains(AgentOperation.invokeShortcut.rawValue))

        let routineSteps = try #require(stepProperties["routineSteps"] as? [String: Any])
        #expect(routineSteps["type"] as? [String] == ["array", "null"])
        let nestedItems = try #require(routineSteps["items"] as? [String: Any])
        let nestedProperties = try #require(nestedItems["properties"] as? [String: Any])
        let nestedRoutineSteps = try #require(nestedProperties["routineSteps"] as? [String: Any])
        #expect(nestedRoutineSteps["type"] as? String == "null")
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
- open_app: Open allowlisted Mac app
  description: Open an app from the local allowlist by human app name. Supported apps: Safari, Chrome, Finder, Notes, Calendar, Mail, Messages, Apple Music, Spotify, Slack, VS Code, Terminal.
  required fields: appName
  side effects: open app
  dry run: Show the allowlisted app that would open.
  examples: Open Safari | Open Spotify | Launch Apple Music
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
  description: Load a saved routine by name and execute its registered steps with the same validation and logging as normal plans.
  required fields: routineName
  side effects: depends on saved routine
  dry run: Preview the saved routine without executing its steps.
  examples: Run my morning setup routine
- create_workspace: Create workspace launcher
  description: Save a named workspace containing allowlisted apps and safe http/https URLs.
  required fields: workspaceName
  side effects: write local workspace file
  dry run: Show the workspace apps and URLs without saving.
  examples: Create a workspace called research with Safari, VS Code, and https://github.com
- open_workspace: Open saved workspace
  description: Open every app and URL saved in a named workspace.
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
