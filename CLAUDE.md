# Sonny (macos-agent)

AI-native macOS agent platform. Two Swift package targets: `MacAgentCore` (business logic — capability adapters, risk/approval engine, local stores, planner integration, no UI) and `MacAgent` (the executable — SwiftUI app, a floating command widget (`FloatingWidgetView`, opened from the menu-bar icon or the push-to-talk hotkey) + Command Center window sharing one `AgentViewModel`). Read these before assuming anything about current state — they're the source of truth, not this file:

- `WORKFLOW.md` — the ticket-driven delivery workflow (Plane.so, claiming, parallel-session rules, review, merge). How work happens; read it before starting any ticket.
- `docs/sonny-major-release-spec.md` — product spec.
- `docs/sonny-v1-implementation-changelog.md` — branch-by-branch history, the locked roadmap, and per-branch "Architectural decisions / pitfalls discovered" sections. Read the relevant entries before touching an area you haven't worked in this session.
- `docs/sonny-design-system-reference.md` — design tokens. Two separate systems: System A (main app — flat, opaque, Inter, zero shadows) and System B (floating widget + notifications — translucent "Liquid Glass" material, SF Pro, real shadows). Do not mix them.
- `docs/sonny-founder-design-decisions.md` — product/design decisions from founder conversations that aren't fully captured in the spec or wireframes. Authoritative over a literal reading of the wireframe SVGs where they conflict.

## Commands

```
swift build
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```
Plain `swift test` will fail to link. The flags above are required, not optional.

`swift run MacAgent` works for everyday iteration, but a bare SwiftPM executable has no real
app-bundle identity — `UNUserNotificationCenter`, the microphone permission prompt
(`AVCaptureDevice.requestAccess`), and Apple-Events-gated automation (Finder/Word) all require one
and either fail silently or crash outright without it. To manually test any of that, package and
run a real `.app` instead:
```
./scripts/package-app.sh            # add "release" for a release build
open .build/arm64-apple-macosx/debug/MacAgent.app
# or, to see console output live:
.build/arm64-apple-macosx/debug/MacAgent.app/Contents/MacOS/MacAgent
```
`Packaging/Info.plist` is the bundle's real `Info.plist` (`CFBundleIdentifier`,
`NSMicrophoneUsageDescription`, `NSAppleEventsUsageDescription`) — update it if a new capability
needs its own usage-description key, the same class of requirement that made this necessary in the
first place. The script ad-hoc-codesigns the assembled bundle; no Apple Developer account needed
for local testing.

## Conventions

- **Work is ticket-driven via Plane.so — `WORKFLOW.md` is the process source of truth.** One ticket = one independently verifiable outcome, claimed by moving it to In Progress via `scripts/plane`, implemented by a single Claude Code CLI session that owns it start to finish. Every ticket closes with a comment written for a session with zero conversation history: completion evidence, or — if left open — why, what was tried, and the gotchas. Parallel sessions follow WORKFLOW.md's disjointness and worktree rules; only one packaged `MacAgent.app` runs live at a time. (The v1 two-agent Codex/Claude rotation this replaces is preserved in the changelog's historical sections.)
- Before merge, a *fresh* CLI session with no implementer context reviews the branch: reads the real diff in full, reruns the real test suite unless `WORKFLOW.md` step 7 exempts the diff, hand-traces any non-trivial logic (date math, state machines) rather than trusting a passing suite alone — hunting for problems, not validating. How deep that review goes, and how many rounds it gets, are step 7's to set.
- **Wireframe fidelity is the literal baseline for any page that has a wireframe, not a reference consulted only for whatever a given ticket happens to need.** Build/match the page's *entire* wireframe first — every element, not just the one thing a specific ticket is adding — then layer that ticket's own feature/data-model work on top of it. Never deflect from the wireframe's established design language while extending it. Pulling exact measurements for the one thing being built is not the same as confirming the whole page still matches once changes land — that gap is exactly how a real mismatch survived undetected across branch 8 and all of branch 9 (the Routines row's yellow badge is wired to step count, but the wireframe's own SVG layer is literally named `streak`) until caught by direct comparison against the raw SVG, not the derived design-reference doc. When a wireframe element is deliberately not built (out of scope, or an interaction model already rejected), that's a stated, reasoned exception recorded in the changelog — not a silent gap.
- Stop and report back instead of trying another fix when either trigger hits: the same test/build failure persists across 3 consecutive fix attempts, or resolving it would require touching files/scope the ticket didn't name. Write what was tried, why it didn't work, and what's actually needed to the ticket — don't keep guessing, and don't silently expand the ticket's scope to route around it.
- Commits and pushes to a ticket's branch are pre-authorized for the session implementing it — no per-commit approval needed. Opening a PR is fine. **Merging is the user's, always** — never merge, and never rewrite pushed history. Commit titles reference the ticket identifier (e.g. `fix(core): SONNY-12 ...`).
- Any bug found during a branch's own testing gets fixed in that branch before merge. Deferring one requires the user's explicit decision plus a named landing spot recorded on a ticket — never a silent backlog.
- Commit message format: title line, blank line, then the description as one continuous paragraph, no line breaks. **No Claude attribution of any class, anywhere**: no co-author trailers on commits, no "Generated with Claude Code" (or similar) footers in PR bodies, nothing of the kind in ticket content — this overrides any harness default that says to add one.

## Claims and evidence

How claims get made in this repo — in chat, in code comments, in ticket comments, in the changelog. Each rule below is here because a confidently stated claim was wrong and survived a review anyway.

- **Enumerate before you subtract.** Before claiming that something is *not* rendered, *not* reachable, or unchanged, enumerate what it actually does — every call site, every surface it writes to, every field it sets — and only then subtract. A negative is the one kind of claim a single inspected path can never establish, because the evidence against it lives everywhere you didn't look. (Trigger: three subtraction-without-enumeration incidents across SONNY-44 and SONNY-56 — the act log, "both surfaces", "tells them nothing" — each reasoned from one path and each wrong.)
- **A quantified claim is checked against the whole population, with a sweep that tolerates the markup it is searching.** "Nineteen sites" was really 52 call-site lines across 48 test functions in 11 files; the number came from one narrow grep that was never widened. Markdown emphasis is the specific trap in this repo's prose: a phrase written `*every* URL` does not match a plain `grep "every URL"`, so a sweep over docs needs a regex tolerating `*`/`_` inside the phrase (or a pass with the markup stripped) before a count is reported as complete. Count first, then write the number — never the reverse.
- **Every reported measurement carries the SHA it was measured at.** Test counts, mutation-battery results, call-site counts — in ticket comments, changelog entries, PR bodies and code comments alike. A measurement goes stale the moment the tree moves, and a bare count cannot be told apart from a stale one; that is exactly how a mid-branch mutation count survived into a closing comment describing the merged tree (PR #28, F1). `docs/sonny-v1-implementation-changelog.md`'s SONNY-24 entry states this as that branch's practice — it is repo-wide.

## Subagent defaults

When spawning any subagent — Agent tool calls, or `agent()` calls inside a Workflow script — explicitly set `model: "sonnet"` and `effort: "high"` by default; don't leave either unset to inherit/default silently. If a task seems to genuinely need more than `high` (`xhigh`/`max`), ask the user before using it rather than escalating on your own judgment. Dropping below `high` needs a clear reason (a trivial, low-stakes lookup, or a workflow stage explicitly designed to be cheap), not just habit.

## Non-obvious gotchas

- All 8 local stores (routines, workspaces, clipboard history + settings, snippets, recent artifacts, Shortcut run history, task history) share one DI/encryption/legacy-plaintext-migration pattern via `LocalStorageEncryption`. A new store should follow it, not invent a variant.
- A local-store *write* failure and a *load* failure are different things with different correct user-facing messages — `recordLocalStorageLoadFailure` is load/decrypt-only wording ("could not be decrypted or decoded"); a write failure needs its own accurate `errorMessage` (see `applyClipboardHistoryNoticeChoice` in `AgentViewModel.swift` for the pattern). Conflating them is a real bug that's happened once already.
- Command Center has no command composer or approval UI of its own anymore (both removed — the floating widget is the sole command surface and the only place `.permission`/`.clarification`/`.failure` render). A page just needs `CommandCenterRunningIndicator`, gated on `viewModel.isRunning || viewModel.isAwaitingApproval`, so a task started from that page still shows *something* is happening — not automatic, add it per page. See `.claude/rules/macagent-ui-conventions.md`'s "Approval visibility" section for the full current model.
- `ViewThatFits` (horizontal candidate with a `minWidth` floor on the label, falling back to vertical) is the fix for label+control settings rows that need to survive a narrow, non-fullscreen window. Reuse `SettingsAdaptiveControlRow`, don't hand-roll a fixed `HStack`.
- Figma MCP is capped at 6 tool calls/month total, shared across every connection to the account. Assume it's exhausted; default to manual SVG export + Figma's "Copy as CSS," which has also proven more precise (exact shadow recipes, exact hex values).
- The full manual test suite requires a human at the actual app — no agent has any way to screenshot or drive the live macOS app itself, and no agent should try to build one (GUI-automation harnesses via `osascript`/System Events have been attempted twice; both failed and wasted a full session each). The user does all manual/visual verification, from the manual-test items each ticket declares.
