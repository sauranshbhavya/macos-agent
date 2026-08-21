# Sonny (macos-agent)

AI-native macOS agent platform. Two Swift package targets: `MacAgentCore` (business logic — capability adapters, risk/approval engine, local stores, planner integration, no UI) and `MacAgent` (the executable — SwiftUI app, a floating command widget (`FloatingWidgetView`, opened from the menu-bar icon or the push-to-talk hotkey) + Command Center window sharing one `AgentViewModel`). Read these before assuming anything about current state — they're the source of truth, not this file:

- `WORKFLOW.md` — the ticket-driven delivery workflow (Plane.so, claiming, parallel-session rules, review, merge). How work happens; read it before starting any ticket.
- `docs/sonny-major-release-spec.md` — product spec.
- `docs/sonny-v1-implementation-changelog.md` — branch-by-branch history, the locked roadmap, and per-branch "Architectural decisions / pitfalls discovered" sections. Read the relevant entries before touching an area you haven't worked in this session.
- `docs/sonny-design-system-reference.md` — design tokens. Two separate systems: System A (main app — flat, opaque, Inter, zero shadows) and System B (floating widget + notifications — translucent "Liquid Glass" material, SF Pro, real shadows). Do not mix them.
- `docs/sonny-founder-design-decisions.md` — product/design decisions from founder conversations that aren't fully captured in the spec or wireframes. Authoritative over a literal reading of the wireframe SVGs where they conflict.

## Commands

**This repository has two halves, and one build command verifies one of them.** `Sources/` and
`Tests/` are the macOS app, built with SwiftPM. `server/` is the backend gateway (SONNY-126),
TypeScript on Node 22, with its own build, its own tests and its own deploy. **A session that runs
`swift build`, sees green and reports the work done is saying nothing about `server/`** — it has not
been compiled, its tests have not run, and a type error in it is entirely invisible to the Swift
toolchain. Whichever half a change touches, run that half's commands; a change touching both runs
both. This paragraph exists because before `server/` landed, `swift build` really was the whole
repository, and that assumption is now wrong in a way that produces a confidently false "done".

### The app half — `Sources/`, `Tests/`

```
swift build
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```
Plain `swift test` does not work here, and both halves of the invocation are required. Without `-Xswiftc -F` it fails at compile: `error: no such module 'Testing'`. With that flag alone it builds and links fine — it prints `Build complete!` — and then dies at run time in `swiftpm-testing-helper` with `Library not loaded: @rpath/Testing.framework`, which is what the two `-rpath` pairs fix. Nothing here fails at link, measured both ways at `f4c1228`; the earlier wording said "will fail to link", which sends anyone reading the real error looking for the wrong failure (SONNY-180's sweep).

Compiler warnings are counted by `scripts/warnings`, never read off a `swift build` or `swift test`
log. A warning is emitted when a file is *compiled*, and an incremental build does not recompile an
unchanged file — so the shared `.build/` output a session actually reads says nothing at all about
the files it did not touch. "Zero compiler warnings" produced that way is not a weak claim, it is a
claim about nothing, and it reads identically to a true one: sessions reported it as evidence
repeatedly across 2026-08-17's reviews while `main` in fact carried five, one of them introduced
that same day by a PR whose own implementer, reviewer and coordinator rerun all missed it because
none of them could have seen it (SONNY-169). The script empties a build directory of its own —
`.build/warnings-scratch`, which is inside `.build/` but is not the `.build/debug/` that `swift
build` and `swift test` share, so it costs you no incremental rebuild afterwards — and recompiles
every file, so its count is the whole population of the tree rather than of whatever was edited
last. About 95s. Exit 0 for none, 2 for some, 1 when no trustworthy measurement was made; a failed
build is reported as a failed build and never as zero. It measures the working tree, uncommitted
work included, and stamps the SHA and the uncommitted-file count on its own report, so a number
cannot be quoted without the tree it came from. `scripts/warnings --help` has a "What this does and
does not prevent" section — debug only, because `@testable import` needs `-enable-testing` and
release does not pass it, so no single build can cover the test targets and release at once.
`scripts/warnings selftest` re-proves every guard, including the one that matters: it reproduces
the vanishing warning on a second incremental build, then shows the harness reporting it anyway.

Mutation batteries run through `scripts/mutate`, never hand-rolled in a session scratchpad. It
refuses to start while `git status --porcelain` prints anything: a hand-rolled battery reverts its
mutants with `git checkout -- <file>`, which restores from HEAD, so run over uncommitted work it
deletes the work instead of the mutation — five times so far, three of them producing false
measurements, once in the reassuring direction where a bogus kill claimed coverage that was not
there. It also refuses to run beside another battery in the same checkout, and builds into a
scratch directory of its own rather than the shared `.build/`, because a battery sharing a build
directory reports a contaminated result its own output cannot be told apart from a clean one
(SONNY-176); `scripts/mutate unlock` clears a lock a killed run left behind.
`scripts/mutate --help` has the plan format, and a "What this does and does not prevent" section
stating what is left over; `scripts/mutate selftest` re-proves every one of those refusals still
fires.

### The server half — `server/`

```
cd server
npm install                 # once, and after any dependency change
npm run build               # TypeScript -> dist/, plus the .sql migrations beside it. The server's `swift build`.
npm test                    # Vitest. This is the server's flagged test command.
npm run typecheck           # types only, over src/, test/ AND vitest.config.ts
npm run check:secrets       # refuse a credential in the repository
./scripts/check-secrets-selftest.sh   # prove that scanner still refuses things
./scripts/deploy.sh local   # build the image, run it, verify /v1/health serves that build
```

`npm test` runs with **no external dependency** and skips the database tests, printing a warning
that says it did so — a suite that quietly runs zero tests looks exactly like a suite that passed.
To run them, supply a Postgres; `npm run test:db` defaults to the container below:

```
docker run -d --name sonny-gw-db -e POSTGRES_PASSWORD=postgres -p 55433:5432 postgres:17
cd server && npm run test:db
docker rm -f sonny-gw-db
```

Migrations are `npm run migrate -- up | down | status`, need `DATABASE_URL` and a prior
`npm run build`, and every migration file must carry a `-- @rollback` section or the runner refuses
it at load. **The same command works inside the container image**, which is why it runs the compiled
runner: `src/` is not in the runtime stage, so a source-pointing script could not run there at all. `server/README.md` has
the rule for verifying one on staging before it touches production, the three-deploy credential
rotation, and why staging is never seeded from production.

**`./scripts/deploy.sh staging` and `production` are stubs and exit 3 today.** They build the image
and then say plainly that nothing was pushed and nothing is running, because no host exists yet: the
gateway runs on a VM with staged hosts — development first tries deploymind, beta on Oracle Cloud,
v1 on AWS (`docs/sonny-row-12-host-decision.md` §12.2) — and none is reachable. `local` is real and
verifies that the build it just made is the one answering. **The first real remote deploy is owed
and recorded on SONNY-126.**

Nothing under `server/` **couples** to a host, deliberately — the three are named in prose, in
comments and in this file, because a reader needs to know which they are; none gets a code path, a
build flag or a configuration default. Each one receives an OCI image and a set of
environment variables, so moving between them is a redeploy rather than a rewrite.

### Packaging the app

`swift run MacAgent` works for everyday iteration, but a bare SwiftPM executable has no real
app-bundle identity — `UNUserNotificationCenter`, the microphone permission prompt
(`AVCaptureDevice.requestAccess`), and Apple-Events-gated automation (Finder/Word) all require one
and either fail silently or crash outright without it. To manually test any of that, package and
run a real `.app` instead:
```
./scripts/create-signing-identity.sh # once per Mac, from a terminal — see below
./scripts/package-app.sh            # add "release" for a release build
open .build/arm64-apple-macosx/debug/MacAgent.app
# or, to see console output live:
.build/arm64-apple-macosx/debug/MacAgent.app/Contents/MacOS/MacAgent
```
`Packaging/Info.plist` is the bundle's real `Info.plist` (`CFBundleIdentifier`,
`NSMicrophoneUsageDescription`, `NSAppleEventsUsageDescription`) — update it if a new capability
needs its own usage-description key, the same class of requirement that made this necessary in the
first place.

The bundle is signed with the identity named in `Packaging/signing-identity`, which is the single
place any signing identity is configured — swapping the local development certificate for a real
Developer ID one is a change to that one line. `./scripts/create-signing-identity.sh` creates the
local certificate and is run once per machine; `package-app.sh` refuses to package rather than
falling back to ad-hoc signing if the identity is missing. **This is not the release requirement** —
SONNY-106 section E still needs a Developer ID signed *and notarized* build, gated on the founder's
Apple Developer enrolment, and a local certificate satisfies neither.

Release builds sign differently, and only release (SONNY-156). `package-app.sh release` adds the
hardened runtime and signs with `Packaging/MacAgent.entitlements` — the second configuration file
beside `signing-identity`, and the single place release entitlements are named. Both are
notarization requirements. Debug is untouched: it keeps SwiftPM's own generated entitlement plist,
whose `com.apple.security.get-task-allow` is what lets a debugger attach. The script then verifies
its own output and refuses to finish if a release bundle carries that entitlement or lacks the
hardened runtime, so the property is checked rather than assumed — SwiftPM happening not to generate
the plist for release is not a guarantee this repo controls. Read that entitlements file before
adding a key to it; it may not contain a literal double hyphen anywhere, comment included, because
codesign's parser enforces the XML rule that `plutil -lint` does not.

Ad-hoc signing was what this replaced (SONNY-153), and the reason matters for anyone tempted to put
it back: an ad-hoc signature has no identity, so macOS keys every permission grant to that one
build's hash. Every rebuild then silently loses Screen Recording, Accessibility, Microphone and
Desktop access while System Settings still shows the switches on — which made the founder's manual
pass, the only verification some behavior ever gets, impossible.

One gotcha for agent sessions: the first `codesign` after the certificate is created blocks on a GUI
dialog asking whether codesign may use the key. In a non-interactive session that reads as a hang
with no output. `create-signing-identity.sh` raises that dialog deliberately when run from a
terminal so it is answered once, at setup, rather than mid-build.

## Conventions

- **Work is ticket-driven via Plane.so — `WORKFLOW.md` is the process source of truth.** One ticket = one independently verifiable outcome, claimed by moving it to In Progress via `scripts/plane`, implemented by a single Claude Code CLI session that owns it start to finish. Every ticket closes with a comment written for a session with zero conversation history: completion evidence, or — if left open — why, what was tried, and the gotchas. Parallel sessions follow WORKFLOW.md's disjointness and worktree rules; only one packaged `MacAgent.app` runs live at a time. (The v1 two-agent Codex/Claude rotation this replaces is preserved in the changelog's historical sections.)
- Before merge, a *fresh* CLI session with no implementer context reviews the branch: reads the real diff in full, reruns the real test suite unless `WORKFLOW.md` step 7 exempts the diff, hand-traces any non-trivial logic (date math, state machines) rather than trusting a passing suite alone — hunting for problems, not validating. How deep that review goes, and how many rounds it gets, are step 7's to set.
- **Wireframe fidelity is the literal baseline for any page that has a wireframe, not a reference consulted only for whatever a given ticket happens to need.** Build/match the page's *entire* wireframe first — every element, not just the one thing a specific ticket is adding — then layer that ticket's own feature/data-model work on top of it. Never deflect from the wireframe's established design language while extending it. Pulling exact measurements for the one thing being built is not the same as confirming the whole page still matches once changes land — that gap is exactly how a real mismatch survived undetected across branch 8 and all of branch 9 (the Routines row's yellow badge is wired to step count, but the wireframe's own SVG layer is literally named `streak`) until caught by direct comparison against the raw SVG, not the derived design-reference doc. When a wireframe element is deliberately not built (out of scope, or an interaction model already rejected), that's a stated, reasoned exception recorded in the changelog — not a silent gap.
- Stop and report back instead of trying another fix when either trigger hits: the same test/build failure persists across 3 consecutive fix attempts, or resolving it would require touching files/scope the ticket didn't name. Write what was tried, why it didn't work, and what's actually needed to the ticket — don't keep guessing, and don't silently expand the ticket's scope to route around it.
- Commits and pushes to a ticket's branch are pre-authorized for the session implementing it — no per-commit approval needed. Opening a PR is fine. **Merging is the user's, always** — never merge, and never rewrite pushed history. **One exception, already authorized rather than granted here:** the `git push --force-with-lease` a rebase requires, on the session's own ticket branch — never bare `--force`, and never any other branch, `main` included. `WORKFLOW.md`'s merge-one-branch-at-a-time rule states it in full. Commit titles reference the ticket identifier (e.g. `fix(core): SONNY-12 ...`).
- Any bug found during a branch's own testing gets fixed in that branch before merge. Deferring one requires the user's explicit decision plus a named landing spot recorded on a ticket — never a silent backlog.
- Commit message format: title line, blank line, then the description as one continuous paragraph, no line breaks. **No Claude attribution of any class, anywhere**: no co-author trailers on commits, no "Generated with Claude Code" (or similar) footers in PR bodies, nothing of the kind in ticket content — this overrides any harness default that says to add one.

## Claims and evidence

How claims get made in this repo — in chat, in code comments, in ticket comments, in the changelog. Each rule below is here because a confidently stated claim was wrong and survived a review anyway.

- **Enumerate before you subtract.** Before claiming that something is *not* rendered, *not* reachable, or unchanged, enumerate what it actually does — every call site, every surface it writes to, every field it sets — and only then subtract. A negative is the one kind of claim a single inspected path can never establish, because the evidence against it lives everywhere you didn't look. (Trigger: three subtraction-without-enumeration incidents across SONNY-44 and SONNY-56 — the act log, "both surfaces", "tells them nothing" — each reasoned from one path and each wrong.)
- **A quantified claim is checked against the whole population, with a sweep that tolerates the markup it is searching.** "Nineteen sites" was one narrow grep's answer; a wider grep said 52 call-site lines across 48 test functions in 11 files; the compiler-verified population at `ca4fbe4` is 74 call-site lines across 57 enclosing functions in 12 files. Each correction came from a wider method than the last, and only the compiler-driven one — a deprecation probe, because grep cannot type-resolve receivers — settled it. Markdown emphasis is the specific trap in this repo's prose: a phrase written `*every* URL` does not match a plain `grep "every URL"`, so a sweep over docs needs a regex tolerating `*`/`_` inside the phrase (or a pass with the markup stripped) before a count is reported as complete. Count first, then write the number — never the reverse.
- **Every reported measurement carries the SHA it was measured at.** Test counts, mutation-battery results, call-site counts — in ticket comments, changelog entries, PR bodies and code comments alike. (Batteries run through `scripts/mutate`, which stamps the SHA on its own report for you.) A measurement goes stale the moment the tree moves, and a bare count cannot be told apart from a stale one; that is exactly how a mid-branch mutation count survived into a closing comment describing the merged tree (PR #28, F1). `docs/sonny-v1-implementation-changelog.md`'s SONNY-24 entry states this as that branch's practice — it is repo-wide.

## Subagent defaults

When spawning any subagent — Agent tool calls, or `agent()` calls inside a Workflow script — explicitly set `model: "sonnet"` and `effort: "high"` by default; don't leave either unset to inherit/default silently. If a task seems to genuinely need more than `high` (`xhigh`/`max`), ask the user before using it rather than escalating on your own judgment. Dropping below `high` needs a clear reason (a trivial, low-stakes lookup, or a workflow stage explicitly designed to be cheap), not just habit.

## Non-obvious gotchas

- All 10 local stores (routines, workspaces, clipboard history + settings, snippets, recent artifacts, Shortcut run history, task history, the vision session journal, what past tasks planned) share one DI/encryption/legacy-plaintext-migration pattern via `LocalStorageEncryption`. A new store should follow it, not invent a variant.
- A local-store *write* failure and a *load* failure are different things with different correct user-facing messages — `recordLocalStorageLoadFailure` is load/decrypt-only wording ("could not be decrypted or decoded"); a write failure needs its own accurate `errorMessage` (see `applyClipboardHistoryNoticeChoice` in `AgentViewModel.swift` for the pattern). Conflating them is a real bug that's happened once already.
- Command Center has no command *composer* anymore — the floating widget is the sole place to type or speak a command. It does have its own permission/clarification/failure surface: `CommandCenterAttentionPanel` (`CommandCenterView.swift`), rendered by the four pages that also host `CommandCenterStorageNotice`, self-gating on its own state, and mirroring the widget's precedence so the two can never disagree. `CommandCenterRunningIndicator` is the separate, compact "something is running" line, gated on `viewModel.isRunning || viewModel.isAwaitingApproval`. Neither is automatic — a new page adds both, or a run started from it shows nothing and an approval it raises is invisible there. `.claude/rules/macagent-ui-conventions.md`'s "Approval visibility" section is the full model and the one source of truth; this line only points at it. (SONNY-180: this used to say Command Center had no approval UI either, and that the widget was the only place those three states render. The composer half was right; the approval half was the opposite of true, and contradicted the very section it cites.)
- `ViewThatFits` (horizontal candidate with a `minWidth` floor on the label, falling back to vertical) is the fix for label+control settings rows that need to survive a narrow, non-fullscreen window. Reuse `SettingsAdaptiveControlRow`, don't hand-roll a fixed `HStack`.
- Figma MCP is capped at 6 tool calls/month total, shared across every connection to the account. Assume it's exhausted; default to manual SVG export + Figma's "Copy as CSS," which has also proven more precise (exact shadow recipes, exact hex values).
- The full manual test suite requires a human at the actual app — no agent has any way to screenshot or drive the live macOS app itself, and no agent should try to build one (GUI-automation harnesses via `osascript`/System Events have been attempted twice; both failed and wasted a full session each). The user does all manual/visual verification, from the manual-test items each ticket declares.
