# Sonny (macos-agent)

AI-native macOS agent platform. Two Swift package targets: `MacAgentCore` (business logic — capability adapters, risk/approval engine, local stores, planner integration, no UI) and `MacAgent` (the executable — SwiftUI app, menu-bar popover + Command Center window sharing one `AgentViewModel`). Read these before assuming anything about current state — they're the source of truth, not this file:

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

## Conventions

- Codex implements, Claude reviews. Claude drafts detailed kickoff/fix prompts for Codex (single fenced block, no nested triple-backtick fences inside it, precise not padded), then independently verifies: read the real diff in full, rerun the real test suite, hand-trace any non-trivial logic (date math, state machines) rather than trusting a passing test suite alone.
- Work happens in small reviewable checkpoints on one feature branch, not one large unreviewed implementation. See the "Feature Branch Checkpoint Workflow" section at the top of the changelog.
- Never commit, push, merge, or open/modify a PR without explicit approval in that exact moment, including on a fresh branch. The user runs `git commit` themselves — give them the message as a single paste-ready `git commit -m "$(cat <<'EOF' ... EOF)"` block (embedded quotes in a plain `-m "..."` break shell parsing), don't run it yourself unless directly told to for that specific commit.
- Any bug found during a branch's own testing gets fixed in that branch before merge, never deferred to backlog.
- Commit message format: title line, then the description as one continuous paragraph, no line breaks.

## Subagent defaults

When spawning any subagent — Agent tool calls, or `agent()` calls inside a Workflow script — explicitly set `model: "sonnet"` and `effort: "high"` by default; don't leave either unset to inherit/default silently. If a task seems to genuinely need more than `high` (`xhigh`/`max`), ask the user before using it rather than escalating on your own judgment. Dropping below `high` needs a clear reason (a trivial, low-stakes lookup, or a workflow stage explicitly designed to be cheap), not just habit.

## Non-obvious gotchas

- All 8 local stores (routines, workspaces, clipboard history + settings, snippets, recent artifacts, Shortcut run history, task history) share one DI/encryption/legacy-plaintext-migration pattern via `LocalStorageEncryption`. A new store should follow it, not invent a variant.
- A local-store *write* failure and a *load* failure are different things with different correct user-facing messages — `recordLocalStorageLoadFailure` is load/decrypt-only wording ("could not be decrypted or decoded"); a write failure needs its own accurate `errorMessage` (see `applyClipboardHistoryNoticeChoice` in `AgentViewModel.swift` for the pattern). Conflating them is a real bug that's happened once already.
- Any Command Center page with the command composer must explicitly render `CommandCenterTaskActivitySurface` behind `viewModel.hasTaskActivity`, or approval prompts for commands started from that page are invisible with no error. Not automatic — add it per page.
- `ViewThatFits` (horizontal candidate with a `minWidth` floor on the label, falling back to vertical) is the fix for label+control settings rows that need to survive a narrow, non-fullscreen window. Reuse `SettingsAdaptiveControlRow`, don't hand-roll a fixed `HStack`.
- Figma MCP is capped at 6 tool calls/month total, shared across every connection to the account. Assume it's exhausted; default to manual SVG export + Figma's "Copy as CSS," which has also proven more precise (exact shadow recipes, exact hex values).
- The full manual test suite requires a human at the actual app — Claude has no way to screenshot or drive the live macOS app itself. Never ask Codex to do this either (it has spiraled into building GUI-automation harnesses via `osascript`/System Events when asked to self-verify; both attempts failed and wasted a full session each). The user does all manual/visual verification.
