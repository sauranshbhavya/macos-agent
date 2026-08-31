# Delivery Workflow (v2)

The repeatable workflow for all Sonny product and engineering changes, effective 2026-08-02.
It replaces the v1 two-agent (Codex/Claude) checkpoint rotation recorded in
`docs/sonny-v1-implementation-changelog.md`; that document remains the durable record of
architectural decisions and pitfalls, and every rule in it that isn't about agent rotation
(wireframe fidelity, fix-in-branch, stop-and-report, store conventions) still applies.

```text
discussion -> agreed plan -> Plane tickets -> claim ticket -> worktree -> implement
-> verify -> commit -> close ticket -> PR -> fresh-session review -> manual test -> merge
```

The repository is
[exploringthroughbuilding/macos-agent](https://github.com/exploringthroughbuilding/macos-agent). It
moved there from a personal account on 2026-08-26, after PR #123, when the founders' organisation
took it over. A merge subject records the namespace that was current when the PR merged, not the one
current now, so all 116 on `main` today still read `from sauranshbhardwaj/...`
(`git log --first-parent --merges --format='%s' main | grep -c 'from sauranshbhardwaj/'` → 116 at
`781fa4c`) — §8's log excerpt among them. None of those is stale, and none is anyone's to rewrite.

The Plane project is [Sonny](https://app.plane.so/sonny/projects/c61e4035-d3a0-4089-a25a-1fb4f0aa813e/issues/).
API behavior is documented in the [Plane API reference](https://developers.plane.so/api-reference/introduction).
All Plane access goes through `scripts/plane` (run `scripts/plane help` for commands).

One-time setup, both required before this workflow's first use:

1. `scripts/plane auth` — stores the API key in macOS Keychain. Keys never live in the
   repo, in Plane content, or in ticket text.
2. In the Plane project UI, add a custom **Blocked** state — Plane's defaults
   (Backlog/Todo/In Progress/Done/Cancelled) don't include one, and step 6's
   `scripts/plane state SONNY-12 blocked` fails until it exists. Confirm with
   `scripts/plane states`.

## Who does what

Two humans (the founders) and one kind of agent (Claude Code CLI sessions). There is no
implementer/reviewer agent rotation anymore. Instead:

- **Implementing session** — one CLI session owns one ticket start to finish.
- **Reviewing session** — a *fresh* session, with no implementer context, reviews the
  branch diff against the tickets before merge (see "Review" below).
- **Coordinating session** (*the coordinator*, in steps 4 and 5) — adjudicates a review's
  findings, writes the kickoff and fix prompts that launch other sessions, and records the
  decisions those carry; it never implements or reviews a branch itself.
- **The user** — whichever founder is running the work; the two are interchangeable in
  every rule below, and no rule here distinguishes them. Approves plans, approves ticket
  content (batched per branch at planning time; sessions create their own discovery
  tickets per step 5, subject to user triage), assigns every ticket, does all manual and
  visual verification in the real app (no agent ever self-verifies GUI behavior — this
  rule survives from v1 verbatim), and performs every merge — either founder, depending on
  who is working, with no rule against merging a branch you ran yourself. Agents never
  merge.

## 1. Discussion and plan

Start with the problem, the user outcome, constraints, and tradeoffs. Read the relevant
changelog entries and `docs/sonny-founder-design-decisions.md` before proposing anything in
an area you haven't touched this session. Do not begin implementation while important
product behavior is unresolved. The user approves the plan before tickets are created.

## 2. Plane tickets

One ticket = one independently verifiable outcome. The ticket is the implementation
contract and the context handoff to a session that has never seen this conversation —
write it so that session needs nothing else. Every ticket carries:

- **Branch** — the first line of the description: the exact git branch this ticket's work
  lands on. Five prefixes are in use — `feature/`, `fix/`, `docs/`, `chore/` and `refactor/`.
  **A sixth exists on the mainline and is deliberately not one of the five: `hermes/`**, which is
  PR #2 of 2026-07-03, the oldest merge there is, used once and not again in the 161 merges since.
  It is history, not a convention, and it is named here so that five-against-161 does not read as a
  count that lost one. This named `feature/...` alone until SONNY-290 counted the merged population
  on 2026-08-26, and said four until SONNY-362 recounted it on 2026-08-30 (the counts, the
  exclusion and the commands that produced them are in the changelog's second line). Sequential
  tickets
  may share a branch; tickets running in parallel each get their own (git forbids one branch
  checked out in two worktrees).
- **Context and goal** — who experiences what, and the user-visible outcome.
- **Scoped requirements** — concrete enough to implement without re-deriving decisions.
- **Expected touched areas** — files/modules this work is expected to change.
- **Never-touch list** — files/areas explicitly out of bounds for this ticket. Negative
  scope beats positive scope: sessions drift into adjacent files unless told not to.
- **Non-goals** — what this ticket deliberately does not do.
- **Acceptance criteria** — checkable, not vibes.
- **Required verification** — the exact commands (see step 5) plus any ticket-specific tests.
- **Manual-test items** — what the user must check in the real app. Before the ticket
  closes, these are added to `docs/sonny-manual-test-checklist.md` as unchecked rows naming
  the ticket; a PR note or ticket comment may summarize them, but the checklist file is the
  only place the founders test from, and an item recorded anywhere else is an item they
  never see. This bullet used to end "these aggregate into the PR's manual checklist", and
  SONNY-281's session followed that sentence exactly — its thirteen items sat on PR #118,
  seven in the body and six more in its review rounds' dated notes, until SONNY-292
  recovered them (2026-08-26).
- **Decisions carried from discussion** — anything that would otherwise live only in chat.

Tickets are created with `scripts/plane create "<title>" <html-file> [priority]` after the
user approves their content — approval is batched: one round trip approving a branch's
whole ticket set during planning, not one ask per ticket. (Discovery tickets, step 5, are
the deliberate exception: created without prior approval, triaged by the user after.)
Created tickets are then attached to their deliverable group's **module** with
`scripts/plane module-add "<module>" SONNY-<n>` (one module per roadmap row / deliverable
group, named after the row — e.g. "A — manual-pass follow-ups"; `module-create` once per
group). The module is the board-level grouping; the ticket's Branch: line names the actual
git branch. No credentials, secret values, or personal data in Plane — ticket content is
context for future sessions, not a secrets store.

**A ticket's number is never predicted — read it back from the `sequence_id` the create
call returns.** Plane assigns numbers at creation and reserves nothing in advance, so a
`module-add`, a cross-reference, or a `state` call written against a guessed identifier
silently targets whichever ticket really holds that number, and the API accepts every one
of them. (Trigger: a hardcoded `SONNY-50` in a `module-add` issued before its create had
returned, and a state change on a guessed number that demoted an already-Done ticket.)

**Future branches get one planning ticket each, never pre-written implementation
tickets.** A branch whose planning phase hasn't run cannot have an honest implementation
contract yet, and a stub contract invites a session to implement from vibes. The planning
ticket's deliverable is real today: run steps 1–2 for that branch, record the decisions,
spawn the implementation tickets, attach them to the module.

## 3. Claiming and parallelism

Moving a ticket to **In Progress** (`scripts/plane state SONNY-12 started`) is the claim.
One ticket, one session, one owner — check the state before starting work, and never pick
up a ticket another session has claimed. **The user assigns each session its specific
ticket ID at launch; sessions never self-select "the next ready ticket" from the board** —
the state PATCH has no compare-and-swap, so self-selection is a claim race waiting to
happen. The user may pre-assign a *sequence* at launch ("SONNY-14, then SONNY-15"): a
session continuing to the next ticket in its own assigned sequence is still assignment,
not self-selection. If a claimed ticket's session is dead (crashed, closed, out of
context) without reaching step 6, the user moves the ticket back to Todo before anyone
re-claims it. **Only the user ever determines a session is dead** — a session never infers
another's death from elapsed time or a quiet branch, and never resets or urges a reset on
that basis; a stuck In Progress ticket with no living owner is the user's to reset, no one
else's.

Parallel sessions are allowed under these rules, each of which exists because breaking it
has documented consequences:

- **Only disjoint tickets run in parallel.** Two tickets may run concurrently only if
  their expected-touched-areas don't overlap AND neither depends on the other's outcome —
  including shared *assumptions* (a store contract, a shared type), not just shared files.
  Decided at ticket-creation time, recorded on the tickets, never improvised mid-run.
  **No recorded disjointness note means serial** — absence of the note is never permission
  to parallelize; to parallelize an unmarked pair, the analysis gets done and recorded on
  both tickets first.
- **Each parallel session gets its own git worktree** (`claude --worktree <name>`, or
  `git worktree add`) — one per *session*, not one per ticket: a session pre-assigned a
  sequence keeps the same worktree across every ticket in it, switching branches inside it
  as each ticket's branch begins. Never two sessions in one checkout. A worktree is a fresh
  checkout: budget a cold `swift build`, and don't share `.build/` between worktrees.
- **Cap: about five concurrent heavy threads, reviewers counted.** The constraint this
  expresses is the machine's, not a human's. A heavy thread is anything holding a build — an
  implementing lane, and equally a reviewing session running the full suite,
  `scripts/warnings`, or a mutation battery. Reviewers are not free, and a wave that counts
  only implementers is already over the cap. Past roughly five, every lane slows every other
  one: during the 2026-08-27/28 wave the flagged suite went from about 40s to about 200s and
  `scripts/warnings` from about 120s to about 460s. **Those four figures are that wave's own
  observations, carried here from the coordinator's record of it and not re-measured for this
  line** — they set the cap's order of magnitude, they are not benchmarks, and a session that
  needs one as evidence measures it again (`CLAUDE.md`, Claims and evidence). **This read
  "Cap: 2–3 concurrent sessions", justified by review bandwidth being the bottleneck rather
  than execution, and that premise moved on 2026-08-22**: the founders stopped reading every
  diff and fresh review sessions took that over (step 7), so the human ceiling the old number
  expressed stopped being the binding one. The old reasoning is superseded rather than wrong
  — more parallel output than a *reviewer* can genuinely absorb still produces rubber-stamped
  merges, and what holds that now is step 7's review-depth rules rather than a lower session
  count. (Corrected 2026-08-29, SONNY-340.)
- **Only one session's build runs as the live app at a time.** Worktrees isolate code,
  not the machine: every `MacAgent.app` instance shares the same Keychain entries, local
  encrypted stores, notification identity, and menu bar. Manual testing is serialized
  through the user anyway; never launch the packaged app — or a bare `swift run MacAgent`,
  which hits the same shared local stores despite lacking bundle identity — from a second
  worktree while any instance is running.
- **Merge one branch at a time, and rebase once — at merge time, never after each merge.**
  Never batch-merge parallel branches: they land one at a time, in an order the user sets,
  because two branches merged together is how a conflict resolution nobody read reaches
  `main`. **What a lane does while it waits is finish on its base, push, and hold.** It does
  not hop onto each new `main` as the wave merges around it. When it is genuinely next —
  which the user says, either by naming it or because every branch ahead of it has landed —
  it does exactly one hop, re-verifies once on the merged base under step 5's rules, and
  merges. **Zero hops is better than one** and is the right answer when the merge is clean
  and step 5's tree-identity proof covers every path the branch's figures depend on; the hop
  is for when a conflict, or a dependency the merged range moved, makes the branch's
  verification untrue of the tree it is about to land on. **This bullet said the opposite
  until 2026-08-29** — "After each merge, other in-flight worktrees rebase onto the new
  `main` before continuing" — and one lane followed it for five hops, paying a full
  re-verification at each, which is hours of work nobody read. Each hop also re-opens step
  5's mutant question and re-stamps every figure the changelog entry carries, so the cost
  compounds rather than adding up. **The cost of holding instead, stated rather than left to
  be found:** a branch that sits through a long wave meets a bigger conflict at its one hop
  than it would have met at any single earlier one. That is one conflict resolved once
  against N resolved N times, and it is the trade the instruction makes. (Founder
  instruction 2026-08-28; written here 2026-08-29 by SONNY-351.) The hop rewrites the ticket
  branch, so the follow-up `git push --force-with-lease` **on the session's own ticket
  branch** is covered by the same standing authorization as regular pushes — always
  `--force-with-lease`, never bare `--force`, and force-pushing any other branch (or
  anything on `main`) is never authorized.
- **Worktree lifecycle differs by role.** An implementing session's worktree lives for its
  whole assigned ticket sequence and is removed once the last of those branches merges
  (`git worktree remove`); audit occasionally with `git worktree list`. A reviewing
  session's worktree is created *detached* at the SHA under review
  (`git worktree add --detach <path> <sha>`), so the review reads a tree that cannot move
  under it, and the user removes it after that terminal closes —
  **a reviewer never removes its own worktree.** (Trigger: the SONNY-44 round-1 reviewer
  removed the directory it was running in, and the session's stop hook then fired from a
  path that no longer existed.)

**A long lane is a coordination failure before it is a session's.** The five levers that keep
lanes short are all the coordinator's, and they sit in three different steps because that is
where each one bites: the concurrency cap and the rebase-timing rule above, step 5's scoped
post-rebase battery re-runs, and step 7's right-sizing and its limit on what one round
carries. Step 5's ninety-minute stop is the one a session owns, and it is a backstop for when
the five were got wrong rather than a substitute for them. (Founder
instruction 2026-08-28, at the tail of the 2026-08-27/28 wave, after three lanes ran one to
five hours each: *"terminals running for unnecessarily long times is a clear dead route for
the speedy execution and hence we cannot afford to do such mistakes."* Three of the five were
written into this file by SONNY-340 on 2026-08-29 and the remaining two by SONNY-351 the same
day. This paragraph is the frame both of those were missing: without it the five read as
unrelated economies rather than as one instruction, and a session reading only the
ninety-minute stop concludes that lane length is its own discipline problem, which is the
opposite of what was said.)

## 4. Pull the ticket

Before changing code: `scripts/plane pull SONNY-12`, read the description *and all
comments* — a previously blocked ticket's findings live there. Reconcile any difference
between the ticket and later conversation before implementing. Do not silently expand
scope; if the ticket is wrong or stale, say so and get it corrected first.

**The prompt that launched the session is context; the description is the contract.** Where
a kickoff or fix prompt conflicts with the pulled description, the description wins — a
prompt is written quickly, from a coordinator's memory of the plan, and it is not the
artifact the user approved. Say which way the conflict was resolved rather than resolving
it silently. The one case that is not a judgment call is a contract conflicting with
*itself*: a description whose requirements cannot all hold is a stop-and-report (step 5),
not an invitation to pick the likelier reading. (Trigger: SONNY-37's kickoff framed the
ticket as relaxing prompting when its description contracted the opposite, escalation-only
behavior; the session built the description's version and was right to.)

## 5. Implement and verify

Implement against the pulled ticket and repository conventions (`CLAUDE.md`, the
changelog's per-branch decisions, `.claude/rules/`). The v1 rigor bar is unchanged:

- Build: `swift build`. Tests: the exact flagged command in `CLAUDE.md` — plain
  `swift test` fails at compile with "no such module 'Testing'", and neither half of the
  flag set is optional. CLAUDE.md's Commands section says which flag fixes which failure.
- Warnings: `scripts/warnings`, and never a count read off `swift build` or `swift test`.
  Those build incrementally against the shared `.build/`, an unchanged file is not
  recompiled, and a file that is not recompiled emits no warnings — so their output is
  silent about everything the ticket did not touch, and "zero compiler warnings" taken
  from it is a claim about nothing that reads exactly like a true one. It was written as
  evidence repeatedly on 2026-08-17 while `main` carried five. The closing comment carries
  the script's count and the SHA it stamped, the same way it carries the test count.
- **Which half you verify is the half you touched.** The three commands above are the app
  half (`Sources/`, `Tests/`). A change under `server/` is verified by the server's own
  commands — `npm run build`, `npm test`, `npm run typecheck`, `npm run check:secrets`
  (CLAUDE.md's Commands section, "The server half") — and `swift build` / `scripts/warnings`
  say nothing about it: `scripts/warnings` measures a Swift compile a `server/` diff cannot
  alter, so it would report zero over a server change while never compiling what changed. A
  change touching both halves runs both halves' commands; neither substitutes for the other,
  and green on the wrong half is not evidence (SONNY-193).
- **Evidence, not assertion.** A ticket is done when its acceptance criteria are
  demonstrated by test output and exit codes, not when the work "looks done."
  `CLAUDE.md`'s claims-and-evidence conventions bind every claim made under this workflow —
  a reviewer's and a coordinator's as much as an implementer's.

**Verification economy: keep every check, cut the repeated work around it.** Nothing below
removes a check — the flagged suite, `scripts/warnings`, the mutation battery and the
fresh-session review all stay, and the battery stays in particular because it is where most
of the 2026-08-27/28 wave's real findings came from. What these rules remove is work a
session has already proved unnecessary. (Founder instruction 2026-08-28, widened later the
same day and again on 2026-08-29. Written here by SONNY-340 on 2026-08-29; until then it
lived only in the coordinator's kickoff prompts, which is a place no session can look
something up.)

- **Carry what provably did not move; re-measure everything else.** A figure may be carried
  across a rebase or a docs-only commit only with a tree-identity proof beside it covering
  **every path the figure depends on** — a diff restricted to those paths printing nothing,
  or the equivalent hash check on each of them. **The scope of the proof is the rule; a
  particular command is only an instance of it**, and the instance is the part that goes
  wrong. `git rev-parse <old>:Sources <new>:Sources` printing one hash twice proves
  `Sources/` and nothing else, so it is sufficient only for a figure measured over
  `Sources/` alone. Name the paths before writing the command:
  - a **flagged-suite test count** depends on `Tests/` and `Package.swift` as well as
    `Sources/` — a test the merged range added changes the count without touching a source
    file, and a target the manifest gained changes what runs at all;
  - a **`scripts/warnings` count** depends on `Sources/` **and** `Tests/`, because the
    script builds with `--build-tests` (`git grep -n 'swift build --build-tests' def8c3a --
    scripts/warnings` → the invocation at `:545` and the line its own report prints at
    `:604`) and the debug build covers the test targets — which is the reason `--help` gives
    for the tool being debug-only;
  - a **mutation verdict** depends on more than a path list, which is the next bullet.

  A session that proves `Sources/` unchanged and carries a suite count across a rebase has
  done exactly what this rule forbids while believing it complied: the proof was real, and it
  was about the wrong tree. With a proof of the right scope, carry the figure rather than
  re-running; without one, re-measure exactly as before. This is not an exception to
  `CLAUDE.md`'s rule that a number taken before a rebase is re-measured and never
  re-stamped: that rule's own distinguishing question is "whether the tree moved, not
  whether the SHA did", and the proof is what answers it. So a carried figure carries the
  proof, not merely the new SHA. (Several sessions in the 2026-08-27/28 wave held the proof
  and re-ran anyway. That re-run is the waste this removes — the rule is untouched.)
- **Mutate the property, not the diff.** A battery covers the behaviour the ticket claims to
  protect and every test whose name claims a guarantee — not one mutant per changed file. A
  reviewer runs the shapes its own findings are about, plus any the implementer's plan
  missed, and reads the implementer's killers by name rather than re-running the whole plan.
- **After a rebase, a mutant is carried only when four things hold; otherwise it is re-run.**
  Its target file did not move in the merged range; its killing test's file did not move; the
  killer does not scan a population the range changed; and the killer does not drive a helper
  or fixture the range changed. If all four cannot be established cheaply, re-run it.
  **The fail-safe wording is the rule rather than decoration.** This was first written as file
  identity alone, and SONNY-137's lane computed both versions against a real merged range the
  same day: the sole killer of three mutants drove `HermeticBackendClient.swift`, which had
  changed, and awaited `restore()` through `SonnyBackendClient.swift`, which had also changed,
  while a fourth killer scanned a `Sources/MacAgentCore/` population that had grown from 130
  to 137 files. The file-level intersection said carry all seventeen; four verdicts in fact
  depended on moved code. A killing test can read changed code without its own file changing,
  which is the whole reason the last two conditions exist. The saving is real on docs-only
  merges and genuinely disjoint areas and evaporates on a merge touching shared fixtures —
  that is the rule working, not failing. (Trigger: three tail-end lanes of the 2026-08-27/28
  wave each re-ran a whole 17-to-19-mutant battery, 45 to 90 minutes under load, because
  *some* file in the merged range had changed.)
  **The check is per mutant against these four, never per round against the diff — and they
  govern any movement under a battery's evidence, a fix round as much as a rebase.** "What this
  round changed" is the substitute a session reaches for, because it is visible from inside the
  round and these four conditions are not: a round that edits a file *other* mutants target
  leaves every one of those carrying a verdict measured before that file moved, and nothing in
  the round's own diff says so. It happened twice on one branch, one round apart, the second
  time inside the round that recorded the first, and that second one was a fix round rather
  than a rebase. `CLAUDE.md`'s mutation section carries the measurement that settles it,
  including the part that makes this hard to catch by instinct: the stale verdict
  *understated* coverage, so mis-scoping does not fail in the reassuring direction reliably —
  it produces an unmeasured number, wrong in whichever direction the tree moved. A carry you
  have argued is worth less than a number you have measured. (SONNY-391.)
- **Long runs go to a file in the background and are read once**, when the result is next
  needed. No chains of sleep-and-poll waiters: they cost wall-clock, produce stale
  notifications, and twice in the 2026-08-27/28 wave reported results that had already been
  collected.
- **Run the whole flagged suite once, before you push, and iterate under `--filter`.** The
  full run is what the closing comment's count and SHA come from; the filtered runs are how
  you get there.
- **Start a Postgres container only if the diff touches `server/`.** A Swift-only lane starts
  none. **A server lane's container name and port are derived, not typed**, and the documented
  setup now does that for you (SONNY-355 — `CLAUDE.md`'s server half, `server/README.md`, the
  manual-test checklist, and the banner `server/test/global-setup.ts` prints all carry the same
  block): `$LANE` is the worktree's own directory name, so the container name cannot
  collide, and `-p 0:5432` asks Docker for any free host port which `docker port` then reads
  back into `DATABASE_URL`. Nothing in it is a placeholder, deliberately — a name or a port a
  reader is expected to fill in is one fixed pair again the first time it is pasted unedited,
  which is what the setup here used to be (`--name sonny-gw-db`, `-p 55433:5432`, in every
  place it was written down). **Wait for the database before you run anything against it**:
  the documented setup does that with `pg_isready` because `docker run -d` returns long
  before Postgres accepts a connection — 11 to 38 seconds of `initdb` on one Mac, measured
  twice on 2026-08-29. **The symptom names nothing on its own, which is the reason it is still written
  down here, and TWO different things produce it**: a suite-wide connection failure — `Test
  Files 11 failed | 20 passed` with `Connection terminated unexpectedly`, and a fresh
  `initdb` in a container log inside that run's window. Neither is a defect in the branch
  under test. If the `initdb` is in *your own* container at the start of your run, the
  database was still starting and you skipped the readiness wait; if it is in a container you
  did not start, or appears in yours part-way through a run that had been working, it is
  another lane's. Observed between two lanes on 2026-08-29, and that run was discarded. The test
  side is one knob as well (`server/test/support/database.ts`, **SONNY-352**), and
  `npm run test:db` still falls back to `localhost:55433` when `DATABASE_URL` is unset — right
  for a lone session, and the collision itself the moment a second lane runs.
- **Past about ninety minutes, stop at the next point where the tree is green and the work is
  coherent, and hand the rest back from there** — what is done, what is left, and what the
  remainder needs. **A lane cannot stop and report with a red tree**, so ninety minutes starts
  the search for a stopping point rather than ending the work where it stands: a session that
  downs tools mid-refactor leaves an uncompilable tree and a handover nobody can act on. Two
  lanes hit that on 2026-08-29, one of them with the tree uncompilable when the ninety minutes
  passed. A long lane holds a merge slot and slows every other lane on the machine (step 3's
  cap), so splitting the remainder onto a follow-up ticket is the right answer rather than
  pushing through. This is a third stop-and-report trigger beside the two below, and unlike
  those two it is not a failure — a lane can be going perfectly well and still be the wrong
  shape.

- **Fix-in-branch rule:** any bug found during a branch's own testing is fixed in that
  branch before merge. Deferring one requires the user's explicit decision and a named
  landing spot, recorded on a ticket — never a silent backlog.
- **Stop-and-report triggers:** the same failure across 3 consecutive fix attempts, or a
  fix that needs files/scope the ticket didn't name — and the elapsed-time trigger in the
  verification-economy block above. Write findings to the ticket (step 6) instead of
  guessing onward.
- **Discovered work: file it, don't do it, don't drop it.** Work discovered outside the
  ticket's own scope — an adjacent bug, missing coverage, a wart worth fixing — must
  become a ticket (`scripts/plane create`), not a scope breach and not a chat remark that
  dies with the session. A discovery ticket carries: what was found, evidence (file:line),
  why it's outside the current ticket's scope, a suggested landing branch/module (attach
  it, or leave unattached when unclear), and the originating ticket's identifier. It lands
  in **Backlog, untriaged** — creation is memory, assignment is authority: the user
  triages and assigns; a session never implements a ticket it created for itself. A
  blocker inside the ticket's *own* acceptance criteria is not a discovery ticket — that's
  the stop-and-report path above. **The boundary is intent, not enumeration**: anything a
  reasonable reading of the ticket's stated outcome requires is in scope even if the
  acceptance criteria don't itemize it — an unhandled edge case in the feature being built
  is your work, not a discovery. When genuinely unsure which side of the line something
  sits on, ask in the ticket's comments and wait; never file-and-move-on to dodge in-scope
  work. The closing comment lists every ticket the work spawned.
- **A never-touch exception is an intent-over-letter question, and the user's to answer.**
  When the ticket's own stated outcome appears to require a file its never-touch list
  forbids, stop before editing it: name the file and the exact change, and get explicit
  user ratification recorded on the ticket, with discharge conditions narrow enough to be
  checkable ("this file, copy only", "this file, one signature"). Everything else on the
  list stands. Without that ratification the letter of the list wins — the item goes to the
  ticket as a stop-and-report if the ticket's outcome genuinely depends on it, or becomes a
  discovery ticket if it does not. (Precedent: SONNY-37's one-line signature propagation
  into `UnattendedTrustAdvisory.swift`, and SONNY-31's copy-only amendment to the same file
  — both asked for, both bounded to one file, both recorded on the ticket.)
- Commits reference the ticket in the title (for example `fix(core): SONNY-12 ...`), follow
  the repo's commit format, and land on the ticket's branch. Standing authorization:
  implementing sessions commit and push to ticket branches without per-commit approval;
  opening a PR is fine; **merging is a founder's, always** — either of them, depending on
  who is working, and never a session. (Reviewing sessions are outside this authorization
  entirely — step 7.)
- The standing authorization is repo policy; the Claude Code permission system still
  prompts per session. The user approves git prompts with "always allow" at session start
  so the authorization is real in practice. A session whose git call is denied by the
  harness surfaces that and hands the user a paste-ready block — it does not work around
  the denial.

## 6. Close the ticket

Every ticket gets a closing comment (`scripts/plane comment SONNY-12 <html-file>`) before
its state changes. This is the context the next session inherits — write it for a reader
with zero conversation history.

**Completed** (`scripts/plane state SONNY-12 completed`) — the comment records: what was
done and how it differs from the description (if at all), files actually touched,
decisions made while implementing, verification evidence (test count, suites, the command
run), and the manual-test items the user still owes.

**Blocked / left open** — the comment records: why it's open, what was tried and why each
attempt failed, gotchas discovered (the things that would burn the next session), and what
the ticket actually needs (a decision, a prerequisite ticket, missing information). Move
it to the Blocked state so it's visually distinct from untouched work. An unexplained
open ticket is a workflow violation — the next session should never have to re-derive
your dead ends.

Comments are append-only history; never rewrite `description_html` to add findings. If
`scripts/plane comment` reports a 400, verify with `scripts/plane comments SONNY-12` before
retrying — Plane sometimes returns 400 after creating the comment, and blind retries
produce duplicates.

## 7. PR, review, merge

When a branch's tickets are done: open a PR. The description is written once, at open
time, summarizing all tickets (linked by identifier); it is not updated per-ticket. One
exception: when a post-open fix commit changes user-visible behavior the description
names, append a short dated note (never rewrite) before the user's merge read. The
changelog entry for the branch is written before the PR opens, by the session that closes
the branch's last ticket — tickets hold per-task history, the changelog holds the durable
architectural decisions and pitfalls; both, not either. **Its figures are measured at the
head that merges.** The entry is written before the head stops moving, so when a fix round
or a rebase moves it, every figure the entry cites is re-measured at the new head or
dropped — never carried forward on the strength of the old head alone — and once merged,
`git merge-base --is-ancestor <sha> origin/main` exits 0 for every SHA the entry cites
(`CLAUDE.md`, Claims and evidence; the mechanism is in §8). The one thing that lets a figure
cross a moved head is step 5's tree-identity proof: `git rev-parse <old>:<path> <new>:<path>`
printing one hash twice makes the figure a measurement *of* the new head rather than a stale
one re-stamped at it, and the entry carries the proof beside the figure. No proof, no carry.

**A diff that touches the changelog runs `scripts/changelog-order`, and its exit code goes in
the closing comment beside the suite's.** It is a second or two, it needs no build, and it is
owed by exactly the diffs that can break it — every branch writing an entry, and nothing else.
It checks three things: that the entries are in `main`'s first-parent merge order within each
of the file's two eras, that no entry names a branch that never merged, and that every heading
has exactly one entry under it. That last arm is not about ordering at all and is the reason
the tool exists rather than a rule in prose: at `85bdccb` the file held a heading with no entry
beneath it and a second heading glued to the end of the previous entry's last line by a lost
newline, so no line-anchored search could see it — and the entry's own self-verifying `awk`
command, pointed at that invisible heading, had been answering a number nobody read for two
merges (SONNY-329). **A misplaced entry raises no rebase conflict, because nobody else is
editing that spot, so a clean merge is the tell** — five have been recorded that way.

**It also runs unasked, from the `.claude/` stop hook** (SONNY-361). Whenever the branch has
touched the changelog — uncommitted, or committed since the merge-base with `main` — the hook runs
it before it considers the Swift suite, and a finding blocks the turn. The committed half of that
reading is the half that matters: step 7 has the entry written *and committed* before the PR opens,
so on the last turn of the branch whose entry is at issue the tree is clean, and a
dirty-file-only trigger would fire never. The hook does not fire on a branch that legitimately
wrote its own entry — the check exempts the first entry and only the first — it skips during a live
mutation battery and says so, and when it cannot run at all (the script missing, or the tool
refusing to measure) it says that too rather than passing quietly.
`.claude/hooks/verify-tests-before-stop-selftest.sh` re-proves every one of those arms.

**Naming it here is still the load-bearing half, and the hook does not retire it.** `CLAUDE.md`'s
Non-obvious gotchas record what happened to SONNY-64's guard: a check people learn to skip has
stopped existing. What keeps `scripts/warnings` and `scripts/mutate` alive is that step 5 names
them as owed verification, not that they are good tools. A hook fires inside one session's
checkout and leaves nothing behind that a reviewer or a zero-context reader can check — it cannot
be quoted, and a session whose hook never fired looks exactly like a session whose hook passed. So
this is owed by a named population too, and a session that writes an entry and does not report its
exit code has not finished step 7.

**Not every branch owes one, and what decides it is what the branch recorded, not what it
touched.** An entry is owed whenever a branch records anything of the kind the sentence above
names — a durable architectural decision, a pitfall discovered, or a correction to the record;
the first two are that sentence's own words, the third is what #122's and #123's entries are —
and a bookkeeping branch that records none of that writes no entry at all. The prefix does not
decide it: `docs/` is no exemption, and eleven `docs/` branches have entries
(`grep -n '^### Branch: docs/' docs/sonny-v1-implementation-changelog.md`, at `bb7ce39`). Nor
does the template's `Architectural decisions / pitfalls discovered` field: its "write none if
true" governs a field inside an entry already owed, and does not make one owed.

The five `docs/` branches that merged on 2026-08-26 are the data points, and that same command
shows which three the changelog does not hold. **#122** and **#123** corrected the record across
the tracked files and wrote entries, rightly. **#125** — step 2's manual-test-items bullet, plus
the checklist rows SONNY-281's items had been stranded off — and **#126** — ticks and dated notes
on checklist rows — recorded nothing of that kind and rightly wrote none. **#124** is where the
line actually runs, and it is the reason this paragraph names branches rather than prefixes: it
was mostly process wording, this file's "Who does what" rewritten for two founders, but it also
added `CLAUDE.md`'s gotcha about `git grep`'s ERE engine not honouring `\b`, a pitfall its own
work turned up (`git diff b23f448^1 b23f448 -- CLAUDE.md` prints all three edits) — so it owed an
entry and wrote none. **No back-entry is written for #124, #125 or #126** (founder decision
2026-08-26, SONNY-298). #124's gap is recorded here rather than papered over, and the gotcha
itself was never lost: it is in `CLAUDE.md`, which is where a session reads it.

**Fresh-session review:** the user launches a new CLI session, giving it only the branch
name and its ticket identifiers — no implementer context. It hunts for problems rather
than validating:

- **Step 0, before any finding: state the head SHA under review.** `git fetch`, then
  `git rev-parse origin/<branch>`, print it, and review that tree. If the remote head moves
  before the findings are filed, stop and re-anchor at the new SHA rather than filing —
  findings written against a tree that has moved are part already-fixed and part aimed at
  code that no longer exists, and separating the two costs more than re-reading. (Trigger:
  PR #26, where the reviewer's read and the implementer's push landed 14 seconds apart.)
  While anchored there, run `git merge-base --is-ancestor <sha> <head>` on every SHA the
  branch's changelog entry cites: one that exits 1 was stamped at a head a rebase has since
  replaced, and its figure is re-measured or dropped before merge (§8).
- Reads the full diff, and pulls every ticket's complete history *including closing
  comments* — verifying each comment's claims (files touched, decisions, evidence)
  against the real diff. A confident closing comment is a claim to check, not a fact.
- Maps every acceptance criterion on every ticket to the specific test(s) exercising it,
  and checks those tests assert concrete values and state — not merely no-throw, not-nil,
  or happy-path-only. Test quality is explicitly the reviewer's job, not a courtesy.
- Reruns the full suite itself, and `scripts/warnings` with it, and hand-traces
  non-trivial logic (date math, state machines) rather than trusting green tests. One
  exception covers both reruns: a diff provably confined to docs/comments may skip them —
  anything touching `Sources/` or `Tests/` never skips, and no session invents its own
  threshold beyond that line. A reviewer that reruns only the suite cannot see a warning
  the implementer introduced, which is how one merged on 2026-08-17. **A server-only diff is
  the symmetric case, and it is not the docs/comments exemption:** it touches neither
  `Sources/` nor `Tests/`, so the Swift suite and `scripts/warnings` provably cannot see it
  (Package.swift declares five targets, every one of them with a `path:`, and all five name
  `Sources/…` or `Tests/…` —
  `grep -cE '\.(target|testTarget|executableTarget)\(' Package.swift` → 5 and
  `grep -cE 'path: "(Sources|Tests)/' Package.swift` → 5, both at `2564273` — so
  nothing under `server/` reaches a Swift target. **This said *four* until 2026-08-27, and it
  was true when it was written**: the commit that wrote it, `505ef8a`, has four
  (`git show 505ef8a:Package.swift | grep -cE '\.(target|testTarget|executableTarget)\('` → 4),
  and the fifth arrived two and a half minutes later in a parallel lane — SONNY-172's
  `MacAgentTestSupport`, `a0f249e`, which `git merge-base --is-ancestor a0f249e 505ef8a`
  rejects with exit 1 because neither session could see the other. A count taken about a file
  another lane is editing is stale before the branch merges, and nothing re-reads it;
  SONNY-308), and rerunning them proves nothing about it — rerun the
  server's own commands (`npm run build`, `npm test`, `npm run typecheck`) instead, and the
  Swift reruns are owed only when the diff actually touches the app half. A diff touching
  both halves reruns both. PR #85's reviewer reran the full Swift suite for a server-only
  diff for want of this branch (SONNY-193).
- Posts findings to the affected tickets (or the PR) carrying the same evidentiary bar as
  implementers: the literal command run and the tail of its output (exit code, test
  counts). Its "all green" is a spot-checkable record, not an assertion to trust.

Findings go back to a session that owns the ticket — as ticket comments, as fix commits on
the branch, or both — before merge.

**Reviewers never implement, commit, or push.** A review produces findings; the fix belongs
to a session that owns the ticket. So a fix prompt names the session it is meant for, and
every post-close round — a re-check, a late finding, a manual-test failure — is routed by
the user to exactly one session. (Trigger: two mis-pasted prompts landed fix instructions
in reviewer terminals, which then implemented and pushed duplicate rounds of the same work.)

**A test a reviewer writes is a finding, not a fix, and it travels with its own run line.**
Handing a probe to an implementing lane is a move this process began making routinely in the
2026-08-29 wave; it fits the bullet above rather than breaking it, because the reviewer supplies
the scenario and the evidence and the session that owns the ticket writes the version that lands.
The evidence includes the runner's own pass/skip count for that probe. A skipped test reads
exactly like a passing one: PR #164's cycle-2 test was offered as proven with a log reading
`1 passed | 1 skipped`, so its assertions had never executed, and they asserted the wrong value
besides — the right one was in the same session's own trace output. The implementer re-proves the
probe in the branch instead of transcribing it, and a probe that will not reproduce is a finding to
hand back rather than a test to make pass. (`CLAUDE.md`'s Claims and evidence section carries the
general rule.)

**Review cycles are capped at three: the initial review, one fix round, one re-check.** The
re-check is the last word **on finding things**; what may continue past it is verification of
a named fix, under the scoped-round rule below. Anything still outstanding below the bar of
user-visible impact or correctness — wording, test-name precision, a claim that is imprecise
rather than wrong — is recorded on the ticket and left there, and is never a reason for another
round. The cap bounds rounds of *review*, not the fix-in-branch rule: a defect found at any
point is still fixed in the branch before merge. What the cap ends is the search for more.
(Set by the user 2026-08-05, after SONNY-44's review ran five rounds whose tail kept finding
smaller things.)
The cap is a ceiling, not a quota: three cycles are the most a review may run, never a
number it must reach — a cycle runs only when the one before it leaves that cycle something
to do.

- A clean cycle 1 — no findings above the recorded-residual bar — ends the review. No fix
  round, no re-check.
- A fix round confined to records, docs, or mechanical edits is verified directly by the
  coordinator — against the real diff, with the usual evidence bar — and the lane closes;
  no third-cycle reviewer session.
- The full cycle-3 re-check stays reserved for fix rounds that could themselves introduce
  defects: production-code changes, test-integrity rebuilds (vacuous-test rewrites),
  rebases carrying conflict resolutions.

The ceiling itself does not move, and the fix-in-branch rule is untouched either way — nor
does the scoped verification round below move it, because what that bounds is verification
rather than the search. This composes with the depth scaling below: depth scales to the diff, cycle count to what the
cycles actually find. (Decided by the user 2026-08-06, after full third-cycle reviewer
sessions ran over mechanical fix rounds on PRs #30 and #31.)

**Cap what a round carries.** A fix round routes what blocks the merge plus what is genuinely
cheap; everything else is proposed for its own ticket. Eight or nine findings in one round is
a long round by construction — the fix session works them one at a time, each one is verified,
and the branch holds a merge slot for the whole of it (step 3's cap, and the lane-length frame
beside it). The cap above bounds how many rounds a review may run; this bounds how much any
one of them is asked to carry, and a round can be entirely above the recorded-residual bar and
still be too big, which is why that bar alone was never enough.

**It creates no power to defer a defect, and reading it as one inverts the oldest rule in this
repository.** Three filters run in order and only the middle one is this rule's:

- Below the recorded-residual bar — wording, test-name precision, a claim imprecise rather
  than wrong — recorded on the ticket and left, exactly as the cap's paragraph above already
  says.
- Above the bar and blocking, or above the bar and cheap enough that filing a ticket costs
  more than the fix — this round takes it. That is the whole of the lever.
- Above the bar, not blocking, not cheap — the only case where anything moves, and what moves
  it is not this rule but the fix-in-branch rule's own deferral clause: the user's explicit
  decision plus a named landing spot recorded on a ticket (step 5). The coordinator *proposes*
  that split when it routes the round; the user's decision is what discharges fix-in-branch.
  Without that decision the finding stays in the round.

**The cap is on what the round carries, never on what the review reports.** A reviewer files
everything it found, at step 7's evidence bar; a reviewer that trims its own findings to keep a
round small has stopped being adversarial, which is the one thing a review is for. **That covers
a reviewer's probe explicitly**, since the paragraph above makes one a finding rather than a fix:
a probe is routed by the three filters like any other finding, and a probe demonstrating a defect
above the bar is that defect's evidence, so it travels with the fix rather than being the cheap
half left out of the round. Nothing here licenses reporting one fewer probe because the round is
already full. (Founder instruction 2026-08-28, the fifth of the lane-length levers in step 3;
written here 2026-08-29 by SONNY-351.)

**A round past the cap is available to verify a named fix, and to do nothing else — the scoped
verification round.** It exists because the cap was exempted on **every branch reviewed under the
2026-08-17 ruling**, three for three, always for the same reason. What follows is the record of
those three, then the rule they produced; the record is first because a rule derived from
incidents reads differently from one derived from taste, and this one was exempted into existence.

- **PR #65** (`fix/docx-conversion-defects`, SONNY-76 and SONNY-79). The cycle-3 re-check found
  **F5**: the same-source skip introduced by the **F1** fix was keyed on the source alone, so a
  later unit wanting the same document in a *different output folder* was silently suppressed and
  the user told a PDF already existed where none did. Granted, fixed at `4268797` (code
  `18c38ab`) by keying on the document-and-folder pair, and the granted re-check at that head
  returned fixed with the folder-key reasoning surviving attack, searching for nothing outside F5.
- **PR #67** (`feature/task-history-controls`). The cycle-3 re-check found **two defects inside
  F4's own fix**: clicking the finished-task notification opened nothing unless Command Center
  already sat on the Tasks page, and it left the request stranded so navigating there afterwards
  did not open it either. Granted, fixed, and the narrow re-check at `6596a42` — a pre-rebase head
  the ancestry check now rejects; the branch merged as `8942195` — found three things wrong in the
  record or the test rather than in the code, all fixed before merge.
- **PR #70** (`chore/sonny-75-mutation-harness`, SONNY-75). The cycle-3 re-check found **G1**: the
  selftest's fault-injection seam sat before any mutant was applied, so the only death it could
  inject arrived while nothing was mutated and the mid-mutant restore property could never fail —
  in the branch whose entire thesis is that an unwatched guard is not a guard. Granted, scoped to
  G1 and G2, fixed at `6ea303b`, and the cycle-4 re-check verified it by running both orderings on
  copies: shipped, exit 0 with 58 passes; reversed, exit 1 with 5 failures, three in the
  internal-error group and two in the byte-for-byte group.

**"Three in one day" is the ruling's day rather than the rounds', and the difference is worth
having straight** since the incidents are the evidence. The ruling was given once, on 2026-08-17,
in response to the third instance, and all three grants are dated 2026-08-17 by the coordinator
comments that record them. The rounds themselves span **2026-08-17 22:41 to 2026-08-18 18:18**
(−04:00, from those comments' own timestamps): PR #65's ran and merged on the 17th, PR #67's and
PR #70's ran on the 18th under a ruling given the day before.

**The trigger was identical all three times, and it is structural rather than drift.** Two rules
meet at the cap and disagree about what happens next. This section bounds review rounds at three.
`CLAUDE.md`'s fix-in-branch rule requires any bug found during a branch's own testing to be fixed
in that branch before merge, with no exception for when it was found. So a defect found in cycle 3
*must* be fixed — and the fix is then production code, a test-integrity rebuild, or a rebase
carrying a conflict resolution that nothing has read, which is exactly the list the third bullet above
reserves the full re-check for. The rule described a case it had no cycles left to serve, so it had
to be exempted every time that case arrived.

**The founder's ruling, 2026-08-17, stated generally because he stated it generally:** *"in such
cases if the three cycle review is done, we can make it 4/5 review cycle because it was an
exception."* Reaffirmed on SONNY-170 on 2026-08-21: if the cap is genuinely exceeded because a real
defect is still being found, do one more cycle — the cap is a target, not a wall, and a defect above
the bar is fixed before merge regardless of which cycle finds it.

**What that authorizes, in terms a session can apply to its own behaviour:**

- **The trigger is narrow and checkable**: a fix round at or past the cap *left or introduced* a
  defect above the user-visible-impact-or-correctness bar, in production code, in a test's
  integrity, or in a rebase's resolution. A wording nit, a test-name imprecision, or a claim that is
  imprecise rather than wrong is not a trigger — it is recorded on the ticket and left, exactly as
  before. A session cannot self-certify its way into another round for one of those.
- **Authorization is standing for the first such round**, so it needs no founder round-trip: that is
  what the 2026-08-17 ruling settled, and it is what the three grants above were each doing by hand,
  three times in under twenty hours. **A second consecutive scoped round is the founder's to grant**,
  and that is what ends the sequence — the chain cannot extend itself twice without a human deciding
  the trigger is real. (Nothing has needed a second yet: each of the three above ran once, and PR
  #70's cycle-4 round, the only one that could have asked, explicitly escalated nothing.)
- **The round verifies named changes and searches for nothing.** It names what it is verifying before
  it starts. Anything it notices outside that scope is recorded and left, **whatever its severity**;
  a belief that something outside the scope blocks the merge is a **stop-and-report to the founder**,
  not an extension of the round. That property is the whole reason the cap survives being extended,
  and all three rounds above had it.
- **The wrong outcome is a cap of five, and this is not one.** Three was set on 2026-08-05 after
  SONNY-44's review ran five rounds whose tail kept finding progressively smaller things, and a
  numeric raise restores exactly that. Reviews may not run four or five cycles hunting; what
  continues past three is verification of what the previous round changed, never the search the cap
  ended.

**So the ceiling on the search does not move, and only the ceiling on verification does.** The
fix-in-branch rule is untouched in every direction, and so is the depth scaling below. (Recorded by
SONNY-170 on 2026-08-28, from the three branches' own ticket comments and pull requests rather than
from the rule — which is what the ticket asked for, since the rule is what had already been written
three times and exempted three times.)

**Interim reviews are scaled to what the ticket touched.** A ticket may be reviewed as it
closes rather than only at PR time, by a fresh session under the same rules. A
behavior-touching ticket gets the full treatment above; a ticket whose diff is confined to
documentation or user-facing strings gets a light pass — read the whole diff, check the
closing comment's claims against it, and stop there, with no criterion-to-test mapping and
no hand-tracing. Which one a ticket is comes off its diff, not off the implementing
session's word for it. That is a depth setting, not a second rerun exemption: a strings-only
diff still touches `Sources/`, and tests that assert copy really do break on it. The
branch's own pre-merge review happens either way. (Same origin as the cap: SONNY-44's tail
rounds ran the full treatment over changes that were entirely copy.)

**Trivial fast path:** the user may tag a ticket trivial at creation — single file, small
diff, no logic-branch changes (docs, copy, constants). A trivial ticket keeps the full
contract, the evidence requirement, and the user-merge gate, but the user reviews the
diff directly instead of launching a fresh-session reviewer. Only the user classifies a
ticket trivial; sessions never do.

**Right-size the review to the ticket.** Small tickets — records, docs, copy, mechanical
edits, a one-line fix — do not get the full three-cycle adversarial review. They are verified
directly by the coordinator against the real diff, at the usual evidence bar, and the lane
closes; no fresh-session reviewer is launched. Repeating a full review over a small change is
the waste this removes. (Founder directive 2026-08-21, given by both founders and recorded on
SONNY-170. Written here 2026-08-29 by SONNY-340; for the eight days between, its only written
homes were that one ticket comment and a single changelog `Reviewed by:` line, which is to say
a session could not find it.
`git grep -n -i 'right-size' def8c3a -- WORKFLOW.md CLAUDE.md` exits 1 with nothing on
stdout and nothing on stderr, and the positive control proving that pattern and those paths
can find anything at all is `git grep -c -i 'review' def8c3a -- WORKFLOW.md` →
`def8c3a:WORKFLOW.md:45`.)

- **What earns the deep multi-cycle treatment is substantive or safety-critical work.** The
  founder's own three examples on 2026-08-21 were the approval/risk engine, the account and
  session concurrency system, and anything touching security or user data; the 2026-08-28
  restatement of the same directive drew that boundary as security, money, data loss and
  boundary code. Read them together: a diff that can lose a user's data, spend their money,
  weaken a permission or an approval, or move a trust boundary gets the adversarial pass. A
  docs, records or copy branch does not — and does not get two review cycles either.
- **This is the coordinator's judgment at review time; the trivial fast path above is the
  user's classification at ticket creation.** Two different doors to a similar outcome, and a
  session should know which one it is standing at. The fast path is decided before any code
  exists, by the only person allowed to decide it, and it hands the diff to the *user*
  instead of a reviewer; sessions never classify a ticket trivial. Right-sizing is decided
  after the diff exists, by the coordinator, off what the diff turned out to be, and it hands
  the diff to the *coordinator* instead of a reviewer. A ticket the user never tagged trivial
  can still be right-sized, and a ticket the user did tag trivial needs no right-sizing.
- **It composes with the depth scaling above rather than replacing it.** The interim-review
  scaling sets how deep a review reads; this sets whether a fresh-session review is launched
  at all; the cap above sets how many cycles it may run once it is. All three read the diff,
  never the implementing session's word for what the diff is.
- **What is removed is the fresh-session round, not a check.** A right-sized lane still fixes
  in branch every defect it finds, still carries the evidence bar of step 5, still owes its
  manual-test rows, and is still merged by a founder and never by a session. The coordinator
  reads the real diff in full; a right-sized review is a shorter route to the same reading,
  not a lighter one.
- **The other half of the same 2026-08-21 comment is already written above.** If the cap is
  genuinely exceeded because a real defect is still being found, one more cycle is allowed —
  that is the scoped verification round, written by SONNY-170 on 2026-08-28. The depth half
  sat unwritten a week longer than the cycle-count half, which is the reason both halves now
  carry the date and the decision that produced them: a founder decision recorded only in a
  ticket comment is one forgotten grep away from being lost, and this comment lost its second
  half exactly that way.

**When something fails after a ticket closed** — the flow above closes tickets before the
PR opens, so late failures need an explicit path, not improvisation:

- A reviewer finding *within* a ticket's scope: the session that owns the ticket — its
  implementing session, or the successor the user routes the round to — makes the fix
  commits on the branch, plus a comment on that ticket recording the finding and the fix.
  The ticket stays Completed.
- A reviewer finding *outside* every ticket's scope (including anything that would breach
  a ticket's never-touch list): file a follow-up ticket referencing the original; fix it
  on this branch only if the user agrees it blocks the merge, otherwise it waits for its
  own ticket. Never silently breach a never-touch list to absorb a finding.
- A user manual-test failure: reopen the ticket (`scripts/plane state SONNY-12 started`)
  with a comment recording the exact failure, fix on the same branch per the fix-in-branch
  rule, close it again with a fresh closing comment. The original implementing session
  need not exist anymore — the ticket's comments are the handoff.

Then: the user runs the aggregated manual items — the unchecked rows in
`docs/sonny-manual-test-checklist.md` — in the real packaged app, and merges — at
GitHub's control with "Create a merge commit", never the squash the page may offer first (§8).
Delete the branch, remove the worktree if its session's sequence ends here (step 3's
lifecycle rule — a session with tickets still ahead of it keeps the same one), confirm the
tickets' final states.

## 8. Merge strategy, and the history rewrite of 2026-08-24

**Pull requests are merged with a merge commit, never a squash.** Decided by Sauransh on
2026-08-23, after noticing the strategy had drifted without anyone writing it down: `main`
carried merge commits through PR #94 and then **sixteen consecutive squashes**, after which #110
and #112 were merged with merge commits again. (The squashes themselves are no longer readable —
the pre-rewrite head they sat on went with the archive namespace, below — but their order is,
because the rewrite kept it: `git log --first-parent --merges --format='%h %s' 98b4668..20a180e`
prints the eighteen replacements in the order the originals merged.) Neither this file nor `CLAUDE.md`
stated a strategy, so no session could have known which was intended — which is why it is
stated here rather than left to be inferred from `git log`, the way it was found.

**At GitHub's merge control that means "Create a merge commit" — never "Squash and merge", never
"Rebase and merge".** All three are enabled on the repository
(`gh api repos/{owner}/{repo} --jq '{allow_merge_commit,allow_squash_merge,allow_rebase_merge}'`
→ each `true`, read 2026-08-26), so nothing greys the wrong ones out, and the control does not
come up on the right one by itself: on 2026-08-25 it came up on Squash and merge and was pressed,
which is how PR #118 landed as a squash and had to be reverted and re-merged — the last subsection
of this section is that record. Rebase and merge is the other wrong answer, and the worse one: it
keeps the commits but gives every one a new SHA as it lands, so every stamp the branch's entry
carries goes non-ancestral at once, with nothing to revert.

**The run is #96 through #109 and #111 — and also #87, which is easy to miss and is why the
count is sixteen rather than fifteen.** #87 opened long before the others and merged late, so it
sits between #102 and #103 on the mainline despite the lower number. Ordering a set of PRs by
number and reading off a range silently drops it. Merge order is the only ordering that answers
this correctly, here and in the changelog's entry order.

**Why merge commits.** Two reasons, and the second is specific to how this repository works.

- **They give both views; a squash gives only the coarse one.** `git bisect --first-parent`
  walks the mainline one step per ticket, which is exactly what a squash offers, while a plain
  `git bisect` descends into a branch's own commits when a finer answer is wanted, and
  `git blame` lands on the commit that actually introduced a line instead of on a
  thousand-line squash.
- **A squash orphans every SHA this repository cites.** `CLAUDE.md`'s *Claims and evidence*
  rule requires every measurement to carry the commit it was taken at, and the changelog alone
  carries **500** distinct SHA-shaped strings at `2ceb530`
  (`git show 2ceb530:docs/sonny-v1-implementation-changelog.md | grep -o -E '\b[0-9a-f]{7,40}\b' | sort -u | wc -l`
  → 500, and the same answer from perl and from python's `re`; that pattern also catches the odd tree
  hash, so read it as an upper bound). **This said 501 until 2026-08-26 (SONNY-290), and the extra one
  is worth keeping rather than quietly dropping**, because it is this section's own subject matter in
  miniature. The figure was measured on a working tree, not on the commit it was stamped with: the same
  command over the file as `4d4bfb6` committed it — the commit that *wrote this bullet*, six minutes
  after `2ceb530` and directly on top of it — answers 501, and the one token separating the two sets is
  the string `2ceb530` itself, which `4d4bfb6` added to the changelog's verification paragraph
  (`comm -13` over the two sorted sets prints that token and nothing else). So both numbers were honest
  readings of a real file, and the stamp named the tree that had one fewer.
  A squash makes each one non-ancestral the moment it merges — and `git show` still prints a
  commit for it, so it reads as checkable while proving nothing about `main`. A reader who
  checks it sees a real tree, stops, and has verified nothing. Merge commits keep those stamps
  genuinely checkable, which is the whole point of stamping them.

**The cost, stated rather than left to be found:** a few intermediate commits inside a rebased
branch do not compile — PR #111 reported four — so a `git bisect` that descends past the
mainline can land on a commit that does not build. `git bisect skip` handles it. That cost was
judged smaller than losing the granularity.

### The 2026-08-24 rewrite

`main` was rewritten so the previously-squashed pull requests appear as merge commits with
their own commits intact, matching the PR merges that already did — **89** of them
(`git rev-list --first-parent --merges --count 98b4668`). **Two counts of that are both right
and differ by one**: 89 is PR merges on the mainline, and `git rev-list --merges --count 98b4668`
answers **90**, because one reachable merge is not a PR merge at all — `008c8b0`, a
`Merge remote-tracking branch 'origin/main' into feature/ui-ux-wireframe-fidelity` made inside a
branch. Say which of the two a figure is before comparing it with another. **No code changed** — the
file tree was verified identical at all eighteen steps and again at the end. Eighteen commits of
`main` were replaced: the sixteen squashes — #87, #96 through #109, and #111 — plus #110 and
#112, which were already merge commits and changed SHA only because the ancestry beneath them
did.

None of the replaced SHAs is an ancestor of `main`, so anything citing one needed repointing
(SONNY-271 did that pass); since the archive namespace was deleted they resolve from no published
ref either, and this table is the record of them. Old commit on the left, the merge commit that
replaced it on the right:

```
#96   c4d9680 -> 385de7a      #105  961b9c2 -> 98c50c8
#97   b278209 -> ff17b71      #106  30dfc44 -> f3162c6
#98   9bf36d1 -> 7255551      #107  cf3fa76 -> 971713e
#99   8917a76 -> f755622      #108  31c2aed -> effbb43
#100  2b14312 -> 76db3c3      #109  896035d -> dcca54d
#101  187e46f -> 0c1e8ff      #110  ee84994 -> 56c8cf7
#102  3036b34 -> 5f32f19      #111  2f22076 -> 70c024e
#103  744eccf -> eb40294      #112  dc21d89 -> 20a180e
#104  fb8420c -> e7732a9      #87   2c5804a -> 6cfd3ab
```

**Each pair holds the same tree**, so repointing a citation renames the tree rather than
restating the measurement — `git rev-parse <old>^{tree} <new>^{tree}` printed one SHA twice for
all eighteen pairs, checked on 2026-08-24 while the old commits were still published. It cannot
be re-run from a fresh clone now, which is why the result is written here rather than left as a
command. That distinction is load-bearing and is the opposite of what a *rebase*
does: a rebase replays a branch onto a moved base, so its new commit holds different content
and a figure measured at the old one has to be **re-measured, never translated**. Renaming
across the rewrite is safe for exactly the reason renaming across a rebase is not.

### What the archive held, and why it is gone

Until 2026-08-24 the commits the rewrite replaced, and the original copies of the branch commits
it re-parented — **190** of them, meaning non-merge commits inside today's eighteen-entry range
(`git rev-list --no-merges --count 98b4668..20a180e`) — were published under a non-default
namespace, `refs/archive/*`: `pre-rewrite-main`, the old head of `main` at `dc21d89`, and
seventeen `pr-<N>` refs holding the original head of each squashed branch — #87, and #95 through
#109 and #111 (#95 closed *unmerged* by founder decision and was kept for its analysis; #110 and
#112 needed none, being real merges reachable from the old head). Eighteen refs, outside the
refspec a clone configures, so no clone ever fetched them without asking. **SONNY-270's figure of
144 is a different measurement, not a superseded one**: it counted the commits made unreachable
across the fourteen PRs archived on 2026-08-23, before #110 and #112 existed and over a smaller
set of refs. Neither number is wrong; they answer different questions, and a figure of this kind
is worth naming rather than quoting.

**The namespace was deleted entirely, by founder decision on 2026-08-24 (SONNY-274), rather than
made clone-reachable.** The question had been whether to publish tags so a fresh clone could
resolve pre-rewrite SHAs; measuring what actually needed them changed the answer. Of every
hex-shaped token in the tracked files at `a10ff01`, 529 name a commit, and **161 of those name a
commit that no published ref reaches — 153 of them in the changelog** — and not one of the 161 is
a pre-rewrite `main` commit. They are branch-only commits that were never on `main`: measurement
heads that a later rebase on the same branch replaced. A fresh clone never resolved them, before
the rewrite or after it, and no archive could have helped. (Measured in a clone that still held
the archive, since the split needs it: `git ls-files -z | xargs -0 grep -I -ohE
'\b[0-9a-f]{7,40}\b' | sort -u` → 975 tokens; the 529 are those `git rev-parse --verify
<token>^{commit}` accepts; each is then looked up in `git rev-list` over `refs/remotes/origin/*`
and, separately, over `refs/archive/*` — **300** reachable from an `origin` branch, **68** from the
archive alone, **161** from neither; the changelog's share is `git grep -l -w <token> --
docs/sonny-v1-implementation-changelog.md` over the 161. With the archive gone, the same
commands answer 229 from nothing published, the 68 having joined the 161; that is the expected
answer now, not a regression.)

Nothing the archive uniquely held is lost, and that was verified by patch identity rather than
reasoned about. Of the 161, **124** have patch-identical content on `main` (`git show --format=
<sha> | git patch-id --stable`, matched against the same over `git rev-list --no-merges
origin/main`, at `a10ff01`); the other **37** are two kinds, neither of them lost work —
superseded intermediate versions (a branch writes an entry, a later commit on the same branch
moves or restamps it, so the intermediate patch never lands while the final one does) and
deliberately unmerged work (the SONNY-69/80 CUA experiment, and PR #95's chip-row branch), all
reachable from GitHub's own `refs/pull/<N>/head`, which GitHub keeps and this project does not
manage. The one thing reachable from nothing else was the rollback anchor, `pre-rewrite-main`,
and its one remaining use was a single command proving the rewrite faithful. That proof was run
before the ref went, and is the record that survives it:

```
pre-rewrite (dc21d89) tree: dc3f3ed0ffbe63abce5a76393c13adbb988e2801
rewritten   (20a180e) tree: dc3f3ed0ffbe63abce5a76393c13adbb988e2801
git diff --stat dc21d89 20a180e  ->  empty, exit 0
commits: 734 -> 893
```

Identical trees, an empty diff, at the rewritten head before PRs #113 and #114 added real
content on top. Keeping the ref beyond that would have preserved only the ability to roll back
to squashed history, which is what the rewrite was performed to remove. The mapping table above
stays: it is a record of the rewrite, not a set of pointers to follow, and it is useful after the
objects are gone. Its left column resolves nowhere now, which is what the convention below says
to expect.

### The convention, and the rule that stops the count growing

**A branch SHA in this repository records *when* a measurement was taken, not a tree a reader is
expected to fetch.** It resolves in the clone that made it and is not expected to resolve
anywhere else. That has always been true; it was never written down, which is why its
consequences read as a defect — 161 unresolvable citations looked like something the archive
should have fixed, when the archive never held them. On a founder's Mac every worktree shares
one object store, so a rebased-away head keeps resolving there for as long as that store lives;
a fresh clone never sees it; neither is wrong. What a reader can rely on is the *ancestry* check
in `CLAUDE.md`'s Claims and evidence: a SHA that `git merge-base --is-ancestor <sha> origin/main`
accepts is on `main` for as long as `main` exists, and one it rejects — or one that does not
resolve at all — is a timestamp on a branch, and the figure beside it is read as "true of that
branch at that moment" and nothing more. The pre-rebase heads several entries stamp — `c85572d`,
`10b8df0`, `b705b99`, `ec4393c`, `5b4731c` among them — were never published, never on `main`,
and were never going to be. That is the convention working, not a gap in the archive.

**The figures an entry ships with are measured at the head that merges.** `CLAUDE.md` states
this in full, beside the SHA-stamping rule it completes; it is repeated here because the
mechanism is a property of merge commits, which is what this section is about. A branch head
that merges is preserved on `main` forever as the merge commit's second parent — #113's
`b5d80d1` and #114's `e02c4a6` both pass the ancestry check today — and so is every commit
beneath it. A head a later rebase replaced is preserved nowhere: #113's `064f387`, #112's
`714606f` and #110's `9fe7ace` are each orphaned exactly that way, and they are how the 161
accumulated. So when a branch's head moves after its entry is written — a fix round, a rebase
onto a merged neighbour — an earlier figure is restated at the new head or dropped, never carried
forward and never re-stamped. The check, once the entry has merged: `git merge-base --is-ancestor
<sha> origin/main` exits 0 for every SHA the entry cites, read with nothing between the command
and `$?`. Before the merge, the reviewer runs the same check against the branch head under
review (step 7, "Step 0"), and a rebase after that review re-runs it.

### The squash of 2026-08-25: PR #118, PR #120, PR #121

`main` between #116's merge (`140829b`) and #119's (`bb7857c`) does not read as one merge per
pull request, and the reason is recorded here because the three GitHub pages it would otherwise
be reconstructed from each hold a third of it:

```
git log --first-parent --format='%h  tree %t  %s' 140829b..c6bc2a2      (at bb7857c)

c6bc2a2  tree c503515  Merge pull request #121 from sauranshbhardwaj/fix/clarified-command-reaches-the-planner-whole
48f5fb7  tree 9686035  Revert "SONNY-281 — a clarified command reaches the resolver that asked, and …" (#120)
dca98e1  tree c503515  SONNY-281 — a clarified command reaches the resolver that asked, and a sum may end with = (#118)
```

**What happened, in the order it happened** (times are the commits' own, −04:00; GitHub's
`mergedAt` shows the same instants in UTC, dated 2026-08-26). PR #118 — SONNY-281, head
`496fa0f`, ten commits above `140829b` (`git rev-list --count 140829b..496fa0f` → 10) — was
merged at 23:05:33 with **Squash and merge**. That produced `dca98e1`: one commit with one
parent, and the ten commits reachable from nothing on `main`. **GitHub records #118 as Merged
with `dca98e1` as its merge commit, and will keep saying so** — the squash is what that pull
request merged, and a revert does not reopen one. The squash was reverted 47 seconds later
through **PR #120**, GitHub's own revert button; its one commit, `7ff2024`, was merged as
`48f5fb7` by the same squash control (one parent, and the squash title's `(#120)` suffix), which
for a single-commit revert changes nothing. The branch was then opened again as **PR #121** — the
same head `496fa0f`, no new work, no rebase — and merged at 23:13:04 with a merge commit,
`c6bc2a2`, whose second parent is `496fa0f`. The ten commits are on `main` intact, and every SHA
SONNY-281's entry stamps passes the ancestry check.

**What was verified before #121 was opened, re-run for this record at `bb7857c`.** The revert
was complete: `git rev-parse 48f5fb7^{tree} 140829b^{tree}` prints
`9686035726068d35736bae300ed8cd97a3f7998f` twice, and `git diff --stat 48f5fb7 140829b` prints
nothing. The re-merge was proved clean before it ran: `git merge-tree --write-tree 48f5fb7
496fa0f` exits 0 with no conflict section and prints `c5035151a546b85b8a8f42992b77b6783cc515da`,
which is `git rev-parse 496fa0f^{tree}` — the merge could produce exactly the branch's content,
and did: `git rev-parse c6bc2a2^{tree}` is the same hash. (#121's description writes the command
as `git merge-tree --write-tree origin/main 496fa0f`; `origin/main` was `48f5fb7` when it ran.)
One fact the checks imply is worth stating: `git rev-parse dca98e1^{tree}` is also `c503515…`.
The squash lost no content. What it lost was the ten commits, and with them every SHA the entry
had stamped — the second reason above, arriving exactly as written.

**What it cost, and what was left alone.** Two commits on the mainline that are not merges —
`git rev-list --first-parent --no-merges --count 20a180e..bb7857c` → 2, and they are `dca98e1`
and `48f5fb7`, the only such commits since the rewrite. `git log --first-parent --merges` skips
both, so a PR-merge count stays one per ticket, and `git bisect --first-parent` steps through
them as a pair that together change nothing. `main` was not rewritten to remove them: a rewrite
is what this section records doing once, for sixteen squashes whose replacements needed a
repointing pass of their own (SONNY-271), and two commits that orphan nothing are not that case.
Nothing needed repointing, because no figure is stamped at `dca98e1` —
`git grep -n 'dca98e1' -- docs CLAUDE.md WORKFLOW.md` finds PR #119's entry, SONNY-281's Status
line and this record, each naming it as history. And the three commits GitHub's control made —
`dca98e1`, `48f5fb7`, `c6bc2a2` — carry the author email
`66620598+sauranshbhardwaj@users.noreply.github.com` rather than `sbhardwaj1418@gmail.com`; the
founder decided on 2026-08-26 to leave them as they are. That address is not a mark of the
squash, and those three are not the population: it is what GitHub's web control stamps on every
commit it makes — 96 on `main` at `bb7857c` (`git log --format='%ae' bb7857c | grep -c
'users.noreply.github.com'` → 96, every one with `GitHub <noreply@github.com>` as committer,
#119's own `bb7857c` among them) — while every commit made from the terminal carries the
founder's address, the rewrite's eighteen merges included.

**The rule for the person at the control**, since the decision at the top of this section says
"merge commit" and the page offers three buttons: **Create a merge commit**, chosen by hand,
every time — the page does not hold the rule, and on 2026-08-25 it came up on the squash. A
squash is undone the way this record shows, with a revert and a re-merge, at the cost of two
harmless commits; a rebase-and-merge cannot be undone that way at all, because there is nothing
to revert — the commits land, each under a new SHA, and every stamp beneath the branch's entry
goes non-ancestral in one step.
