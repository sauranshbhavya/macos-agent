# Sonny

Sonny is a macOS agent. You ask it, typed or spoken, to do something on your Mac, and it does it: it
opens and switches apps, works with your files, reads your calendar and adds reminders, runs your
Shortcuts, drafts and sends email, works inside an app's window by clicking and typing, researches
the web, and runs saved routines on a schedule.

The reasoning happens on Sonny's gateway; **only the Mac acts**. Every action the gateway proposes is
checked, gated and, when it matters, approved on the Mac before it runs, and it runs exactly once.

This README describes the application as it exists today. [AGENTS.md](AGENTS.md) and
[WORKFLOW.md](WORKFLOW.md) are the contributor guidance, and the
[V2 implementation plan](docs/sonny-v2-implementation-plan.md) records the decisions behind the
design. Older plans, specs and the per-branch records under `docs/changelog/` are history.

## What Sonny can do

- **Ask from anywhere.** The floating widget sits above the Dock: type into the composer, or hold
  ⌃⌥Space and speak. The logo in the composer is "Don't save this task": a private task is kept
  neither on the Mac nor, once it ends, on the gateway.
- **Typed operations**, each a reviewed piece of code with typed arguments: open, switch and search
  apps; open URLs; play media; open, reveal, rename and write files; find and zip the largest files in
  a folder; convert `.docx` to `.pdf`; read the calendar; add reminders; run a named Apple Shortcut;
  save snippets; check permissions; watch a page for changes; save a routine; compose and send Mail.
- **Screen control.** For work no typed operation covers, the gateway's screen agent works inside
  one app's window through [cua-driver](https://github.com/trycua/cua), reading its accessibility tree
  and clicking and typing there. Sonny never types into a password or secure field.
- **Research.** The planner searches the web, reads public pages and writes source-linked notes on
  the gateway, then saves them on the Mac.
- **Instant commands**, answered on the Mac with no model and no network: a calculation, clipboard
  history, a saved snippet, recent files, opening or switching to an app.
- **Routines and watchers.** A routine is saved as a goal and planned afresh on every run. A routine
  on a schedule runs unattended: anything that would need your OK is refused and reported. A watched
  page that changes starts a task that says what changed.
- **Follow-ups.** Follow up on a finished task and the gateway picks up where it left off.
- **Command Center.** Tasks (running and finished, with search), Routines (run now, schedule,
  watchers) and Settings (appearance, mode, clipboard history, permissions, allowed apps,
  notifications, history).

## Safety model

- **The Mac is the only thing that executes.** The gateway proposes typed operations and screen
  actions; model output, web pages, screenshots and accessibility text are untrusted and cannot grant
  anything.
- **The model declares each action's effect, and the Mac can only raise it** (observe, navigate,
  edit, create, destructive, external, financial, credential). The gate then decides from the effect,
  the mode (Safe, Normal, Power) and the app's standing whether the action runs, asks, or is refused.
  Anything irreversible, or that reaches someone else, shows its exact effect and waits for you.
- **An approval covers exactly what you saw.** Sonny prepares the action again just before it runs,
  and any change to its target or content voids the approval.
- **Exactly once.** Every action is written to a ledger before it is dispatched. After a crash or a
  relaunch, an action whose end is unknown is never retried; if it mattered, the task pauses and asks
  you to check.
- **Secrets stay on the Mac.** Secure fields and detected secrets are never read out or typed, and
  every screenshot is redacted on the Mac before it leaves.
- **Terminals and script editors are refused**, and an app outside the built-in list asks before
  Sonny acts in it unless you allow it in Settings.

## Setup

The app needs the gateway. For development, run the gateway locally (see
[server/README.md](server/README.md)), then:

```bash
scripts/fetch-cua-driver.sh   # once: the screen-control library, into Vendor/ (not committed)
swift build
swift run MacAgent
```

A packaged, signed `Sonny.app` comes from `scripts/package-app.sh`, which is what permission checks
should run against: macOS attributes prompts to the launching app, so a `swift run` build shows
prompts for Terminal or your editor instead.

On first launch Sonny asks you to sign in and walks you through Screen Recording and Accessibility.
The first V2 launch removes what V1 kept in `Application Support/Sonny`; V2's own data lives in
`Application Support/Sonny/V2`, encrypted with a key in the Keychain.

## Permissions

- Accessibility and Screen Recording, for screen control.
- Microphone, for voice.
- Automation of Mail, Finder and Microsoft Word, for the operations that use them.
- Calendars and Reminders, for reading the calendar and adding reminders.
- Desktop and Documents access, for file operations.

If a prompt is denied, allow Sonny in System Settings › Privacy & Security, then relaunch.

## Tests

The app and the gateway have separate suites; [WORKFLOW.md](WORKFLOW.md) says when to run what.

On the documented Command Line Tools install, plain `swift test` fails with `no such module
'Testing'`. Use this, adding `--filter` while iterating:

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

For the gateway: `cd server && npm run build && npm run typecheck && npm test`, with `DATABASE_URL`
set for the tests that need Postgres.

## Architecture

See [the architecture diagrams](docs/sonny-architecture-diagrams.md) for a visual map.

**The gateway** (`server/`, TypeScript on Node 22) holds one WebSocket session per Mac at
`/v2/session`. Each task lives there as a transcript: the planner decides the next step, a screen
agent works inside one app when the planner hands it a window, and research tools run on the
gateway. Every model call is metered and spends the account's credits by tokens. Skill packs for
popular sites are matched to each task there. Accounts, billing, entitlements, credits and voice
transcription are the gateway's HTTP routes.

**The app** has two Swift targets:

- **`MacAgentCore`**, no UI. `Kernel/` is V2: the wire protocol, the `GatewayConnection`, a
  `TaskRuntime` per task with its `ExecutionLedger`, the `ActionGate` and `ApprovalBroker`, the
  typed operations as `Capability` values (most run a kept V1 adapter body behind typed arguments),
  the `ScreenController` over cua-driver, the instant path, the stores, and `TaskDesk`, which every
  entry point goes through. Around it are the leaves the kernel uses: file inventory and path
  whitelist, capture and redaction, secret detection, app resolution, EventKit, Shortcuts, clipboard
  history, and the backend client for accounts, entitlements and credits.
- **`MacAgent`**, the executable. `SonnyAppModel` is presentation over `TaskDesk`; `WidgetView` and
  `CommandCenterView` are the two surfaces; `AppDelegate` wires the menu bar, hotkeys, first run,
  notifications and windows.
