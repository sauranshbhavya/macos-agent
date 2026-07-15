# Sonny

Sonny is an AI-native macOS agent platform for power users. It turns typed or spoken natural-language requests into validated local actions: it plans with OpenAI, assesses risk, previews side effects, executes only registered local capabilities, and streams logs plus a final summary. Sonny has two Mac-native surfaces sharing one state layer — a menu-bar cockpit for fast commands, and a full Command Center window for settings, privacy, history, routines, and workspaces.

See `docs/sonny-major-release-spec.md` for the full product spec and `docs/sonny-v1-implementation-changelog.md` for branch-by-branch implementation history — both are the source of truth for product direction; this file just orients a new contributor to the running app.

## Cool Prototype Demo

https://drive.google.com/file/d/1_tAHM9kTIWMuatAsIjqXQUAeqKZqXCNv/view?usp=sharing

## Uncool Prototype Demo

https://drive.google.com/file/d/12lJnnqiBrbGnua2pGyE2GsYaVBcil0qe/view?usp=sharing

*(Both demos capture the early menu-bar-only prototype. The app has since grown a real Command Center, risk/approval engine, and encrypted local storage — see "What Sonny Can Do" below for current capabilities.)*

## What Sonny Can Do

**Agent loop and safety**
- Plans typed or spoken commands through OpenAI, validates the plan against a strict schema and a registered capability contract, then executes only registered local capabilities — never model-generated code, shell, or AppleScript.
- Every capability declares a default risk tier (0 informational/auto-run, 1 low-impact/auto-run, 2 local modification/lightweight confirmation, 3 external-or-destructive/explicit approval, 4 refused) and can escalate dynamically at validation time — e.g. a zip whose output path already exists, or a routine save that would replace an existing one, escalates to explicit approval before it runs.
- A visible approval panel appears for tier 2+ actions on every Command Center page with a command composer, not just the popover.

**File and document workflows**
- Find the largest files in a whitelisted folder and zip them.
- Convert `.docx` files to `.pdf` with Microsoft Word, or explicit mock mode.
- Reveal generated files and folders in Finder.

**Web research**
- Turn a direct public URL, a comparison of several URLs, or Hacker News's top headlines into a source-linked Markdown note. Fetched web content is wrapped as explicitly delimited untrusted content, structurally separated from the trusted user instruction, before it reaches the model.
- Topic/search-to-Markdown is wired through a protocol seam (`WebSearchProviding`) but has no configured production search provider yet — see the changelog's open questions.

**Apps, URLs, and media**
- Open safe web URLs (`http`/`https` only) and allowlisted Mac apps: Safari, Chrome, Finder, Notes, Calendar, Mail, Messages, Apple Music, Spotify, Slack, VS Code, and Terminal.
- Open a fixed allowlisted search URL template for an app (e.g. "open GitHub issues for this repo").
- Play or queue an exact Spotify/Apple Music track through the provider's API where credentials are configured, diagnosing exactly one blocker (authorization → subscription → active device → catalog match → provider outage) when playback can't start; falls back to opening the provider search/result otherwise. Real Spotify OAuth and Apple Music MusicKit credentials are not yet wired in this environment.
- Use Finder context for selected files or a selected folder inside the Desktop/Documents whitelist.
- Chain multiple supported actions in one request, such as zip files and reveal the result in Finder.

**Instant utilities** (zero network calls, resolve without the planner)
- Calculator and basic unit conversion.
- Clipboard history lookup, with `ConcealedType`/`TransientType` pasteboard items filtered before any content is read.
- Exact-trigger snippet expansion and a typed `snippet save ;trigger = expansion` command.
- Running-app search and switch (activates already-running apps only; does not bypass the app-launch allowlist).
- Recent Sonny-generated artifact lookup and reopening.
- Quick routine/workspace dispatch by saved name — dispatch itself is instant, but a routine's own steps still pass full risk assessment and approval gates.

**Shortcuts, follow-up, usage**
- Invoke an existing named Apple Shortcut via the fixed `/usr/bin/shortcuts run <name>` template; a clean Sonny-observed success history demotes a Shortcut from tier 2 to tier 1 until a later failure clears it.
- Correct a just-completed or in-progress task with a short follow-up ("use ~/Documents instead") without restating the whole command — bounded to 10 minutes, last-task-only, never persistent chat memory.
- See an approximate local usage indicator (reported or estimated token counts) per task; this is local-only, not billing.

**Routines and workspaces**
- Teach and run saved local routines made from registered Sonny tools; a routine cannot contain another routine, a workspace action, or a clarification step.
- Save and open workspace launchers made from allowlisted apps and safe URLs (apps open before URLs).

**Local storage and privacy**
- Eight local stores (routines, workspaces, clipboard history + settings, snippets, recent artifacts, Shortcut run history, task history) are encrypted at rest with AES-GCM; the symmetric key lives in Keychain. Legacy plaintext migrates transparently on next load.
- A destructive "Delete Local Data" action in Settings deletes exactly those eight store files (not generated artifacts, not the Keychain key, not `OPENAI_API_KEY`).
- A permission readiness panel covers API key, microphone, hotkey, Finder/Word automation, and future screen/accessibility surfaces.

**Command Center** (`Tasks` / `Insights` / `Routines` / `Workspaces` / `Settings`)
- Real, non-placeholder Routines and Workspaces list/run/open surfaces.
- An Insights dashboard computing completion count, completion rate, average cycle time, a current streak (with a one-day grace period), a 7-day completion chart, and a recent-activity list from real encrypted task history — no raw screen/audio history involved.
- Settings with a functional pointer-cursor preference and a Dark theme (Light/System are visible placeholders, not yet functional).
- Note (2026-07-14): a post-completion review found the built Command Center pages fall short of the Figma wireframes in content depth and information architecture, and two founder-conversation decisions (task-to-workspace association, real routine scheduling) aren't yet supported by the data model. See `docs/sonny-v1-implementation-changelog.md`'s branch 8 entry and `docs/sonny-founder-design-decisions.md` for the specifics; `feature/v1-strategy-replan` is resolving how this closes.

**Not yet built**: the floating Spotlight-style command widget and system notifications (System B in `docs/sonny-design-system-reference.md`), screen intelligence / screen Q&A, Power Mode (approved-app UI control), hosted backend/billing/accounts, and enterprise features. See the changelog's roadmap table for sequencing.

## Setup

```bash
export OPENAI_API_KEY="sk-..."
export OPENAI_MODEL="gpt-5.5"
export OPENAI_TRANSCRIBE_MODEL="gpt-4o-mini-transcribe"
swift build
swift run MacAgent
```

In the Codex sandbox, use:

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift build --disable-sandbox
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift run --disable-sandbox MacAgent
```

The visible product name is Sonny. The SwiftPM executable is still `MacAgent`.
Sonny's main-app UI (the "System A" design system) uses Inter typography on a near-black, flat, zero-shadow palette (`#090909` background, `#5C84FE` accent) matched to the product's Figma wireframes — see `docs/sonny-design-system-reference.md` for the full token set, including the separate System B tokens reserved for the not-yet-built floating widget.

Typed instant-utility commands (calculator, clipboard, snippets, running-app switch, recent artifacts, quick routine/workspace dispatch) work without `OPENAI_API_KEY`. Non-instant typed commands and voice transcription both require it.

## Permissions

macOS may attribute prompts to Terminal, Codex, or the Swift process.

- Desktop/Documents access for file workflows.
- Automation permission for Microsoft Word DOCX conversion.
- Automation permission for Finder selection context.
- Microphone permission for voice input.
- Keyboard shortcut registration for global push-to-talk. If `Control-Option-Space` is already claimed by another app, Sonny will still work from the `Speak` button.
- Browser/app opening through `NSWorkspace`.
- Apple Music or Spotify may ask to open provider links.
- Keychain access for the local data encryption key (and, on an unsigned development build, may prompt for your login password — see the changelog's branch 7 notes on code-signing).

If a prompt is denied, allow the launching host app in System Settings, then relaunch Sonny.

## Safety Model

- OpenAI receives only the natural-language command, planner instructions, and (for web research) explicitly delimited untrusted page content — never local directory listings or arbitrary file contents.
- The planner prompt is generated from a local `ToolRegistry`; the model can choose registered tools but cannot invent tools.
- Swift validates every plan against strict JSON, a fixed capability-adapter contract, path whitelist rules, URL scheme rules, and the app allowlist.
- Every capability carries a risk tier (0-4) with a defined default approval rule; `AgentRunner` is the sole gate between a validated plan and execution, and a capability adapter can escalate its own tier dynamically (e.g. an overwrite, a name collision, or — for saved routines — a nested step that would independently assess higher) before anything runs.
- Dry run is on by default for typed commands and never writes files, opens apps, or converts documents.
- Tier 0/1 typed and voice commands stay frictionless by design; tier 2+ pauses for a visible approval prompt (lightweight confirmation or explicit approval, depending on tier) on whichever surface started the command.
- Executors use fixed native adapters only: `/usr/bin/zip`, `/usr/bin/osascript`, `/usr/bin/shortcuts`, `NSWorkspace`, `AVFoundation`, and `URLSession`. Sonny never accepts generated AppleScript, shell, or code from the model.
- Routines and workspaces are declarative JSON, not executable scripts; a routine cannot nest another routine, a workspace action, or a clarification step.
- All eight local stores are encrypted at rest (AES-GCM, Keychain-backed key); `OPENAI_API_KEY` remains environment-variable-only.

## DOCX Conversion

Real conversion uses Microsoft Word through a fixed AppleScript template. Existing matching PDFs are skipped.

If Word is unavailable and you only need to exercise the loop:

```bash
export MAC_AGENT_MOCK_DOCX=1
```

Mock mode writes clearly marked `.mock.pdf` placeholders, not real PDFs.

## Tests

```bash
swift test
```

On this local Command Line Tools install, plain `swift test` will fail to link — use the full invocation below (this is the only valid way to run tests in this repo):

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Coverage spans strict plan decoding, the full capability-adapter registry, risk-tier and dynamic-escalation behavior, app allowlisting, URL validation, media provider resolution and failure-precedence, web research extraction plus a prompt-injection red-team fixture, instant-utility resolution, the Shortcuts bridge, follow-up correction, usage recording, encrypted-local-storage round-trips (including raw-byte plaintext-absence checks), and the shared-state Command Center UI. Test count grows with each branch — run the command above for the current total rather than trusting a hardcoded number here.

## Manual Smoke Test

1. Launch Sonny from SwiftPM. The menu-bar `Sonny` item opens the popover; open the Command Center window for Tasks/Insights/Routines/Workspaces/Settings.
2. Typed dry run and real run:
   - `Find the 3 largest files in ~/Desktop/MacAgentDemo and zip them.`
   - `Convert all .docx to .pdf in ~/Documents/MacAgentDocs.`
   - `Open Hacker News, grab the top 5 headlines, save to a Markdown file.`
   - `Summarize https://example.com/article and save as Markdown.`
   - `Open Safari.`
   - `Open https://github.com.`
   - `Open Jimmy Cooks by Drake on Apple Music.`
   - `Open Jimmy Cooks by Drake on Spotify.`
   - `Find the 3 largest files in the selected Finder folder and zip them.`
   - `Find the 3 largest files in ~/Desktop/MacAgentDemo, zip them, then reveal the zip in Finder.`
   - `Teach Sonny a routine called writing setup that opens Notes and Safari.`
   - `Run my writing setup routine.`
   - `Create a workspace called research with Safari, VS Code, and https://github.com.`
   - `Open my research workspace.`
   - `Check Sonny permissions.`
3. Instant utilities (should resolve immediately, no network): `calc 12 * 4`, `clipboard`, `snippet save ;sig = Best, Sonny`, then type `;sig`, `switch to Safari`, `recent artifacts`.
4. `Run my writing setup shortcut` against a real Shortcut you've created in Shortcuts.app, and confirm success/failure reports correctly.
5. Press Enter from the command field to preview typed commands in dry run or execute them when dry run is off. Confirm a tier 2+ action (e.g. saving a routine, zipping to an existing path) shows a visible approval prompt on whichever page you started it from, not just Tasks.
6. Try an incomplete request, such as `Find the 3 largest files and zip them.`, then answer Sonny's clarification. Then try a follow-up like `use ~/Downloads instead` on a just-completed task and confirm it corrects without restating the whole command.
7. Click `Speak`, say `Open Safari`, click `Stop`, and confirm Sonny transcribes and acts without another manual execute click.
8. Hold `Control-Option-Space`, say `Open Notes`, release the keys, and confirm Sonny transcribes and acts automatically.
9. Use generated result buttons such as reveal zip, open Markdown, reveal Markdown, or reveal PDFs.
10. In Command Center > Insights, confirm the stat cards, weekly chart, and recent-activity list reflect real completed tasks. In Settings > Privacy & Permissions, run "Delete Local Data" and confirm the destructive confirmation dialog and the eight-store deletion.

## Architecture

Two Swift package targets:

- **`MacAgentCore`** — business logic only, no UI. Owns the capability-adapter registry (every executable action is a `CapabilityAdapter` with its own `preview`/`assessRisk`/`execute`), the risk/approval engine (`AgentRunner`, `RiskApproval`), the eight encrypted local stores (`LocalStorageEncryption`, `AutomationStores`, `ClipboardHistoryService`, `SnippetStore`, `RecentArtifactStore`, `ShortcutsBridgeService`, `TaskHistoryStore`), planner integration (`OpenAIPlanner`, `OpenAITranscriber`, `ToolRegistry`), web research (`WebResearchService`, `WebResearchSynthesizer`, `WebResearchMarkdownCapabilityAdapter`), media playback resolution (`MediaPlaybackService`), the instant-utility resolver (`InstantCommandResolver`), and the path/URL safety boundary (`PathWhitelist`, `SafeURL`).
- **`MacAgent`** — the executable. `AppDelegate` + `AppWindowCoordinator` manage the menu-bar status item and the Command Center window, both observing one shared `AgentViewModel`. `ContentView` is the popover (and hosts the System A design tokens, `SonnyTheme`/`SonnyType`/`SonnyRadius`); `CommandCenterView` is the Command Center window's five destinations. `AgentActivityPresentation` maps internal operation/phase names to user-facing task-activity copy.

See `.claude/rules/macagentcore-conventions.md` and `.claude/rules/macagent-ui-conventions.md` for the specific patterns each target follows (capability-adapter shape, risk-tier gating discipline, local-store encryption pattern, shared-state rules, design-token boundaries) — those are kept current as the source of truth for contributors; this README stays at the orientation level.
