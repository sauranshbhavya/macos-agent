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

The Plane project is [Sonny](https://app.plane.so/sonny/projects/c61e4035-d3a0-4089-a25a-1fb4f0aa813e/issues/).
API behavior is documented in the [Plane API reference](https://developers.plane.so/api-reference/introduction).
All Plane access goes through `scripts/plane` (run `scripts/plane help` for commands).

One-time setup, both required before this workflow's first use:

1. `scripts/plane auth` — stores the API key in macOS Keychain. Keys never live in the
   repo, in Plane content, or in ticket text.
2. In the Plane project UI, add a custom **Blocked** state — Plane's defaults
   (Backlog/Todo/In Progress/Done/Cancelled) don't include one, and step 6's
   `scripts/plane state SON-12 blocked` fails until it exists. Confirm with
   `scripts/plane states`.

## Who does what

One human (Sauransh) and one kind of agent (Claude Code CLI sessions). There is no
implementer/reviewer agent rotation anymore. Instead:

- **Implementing session** — one CLI session owns one ticket start to finish.
- **Reviewing session** — a *fresh* session, with no implementer context, reviews the
  branch diff against the tickets before merge (see "Review" below).
- **The user** — approves plans, creates/approves tickets, does all manual and visual
  verification in the real app (no agent ever self-verifies GUI behavior — this rule
  survives from v1 verbatim), and performs every merge. Agents never merge.

## 1. Discussion and plan

Start with the problem, the user outcome, constraints, and tradeoffs. Read the relevant
changelog entries and `docs/sonny-founder-design-decisions.md` before proposing anything in
an area you haven't touched this session. Do not begin implementation while important
product behavior is unresolved. The user approves the plan before tickets are created.

## 2. Plane tickets

One ticket = one independently verifiable outcome. A branch groups related tickets. The
ticket is the implementation contract and the context handoff to a session that has never
seen this conversation — write it so that session needs nothing else. Every ticket carries:

- **Context and goal** — who experiences what, and the user-visible outcome.
- **Scoped requirements** — concrete enough to implement without re-deriving decisions.
- **Expected touched areas** — files/modules this work is expected to change.
- **Never-touch list** — files/areas explicitly out of bounds for this ticket. Negative
  scope beats positive scope: sessions drift into adjacent files unless told not to.
- **Non-goals** — what this ticket deliberately does not do.
- **Acceptance criteria** — checkable, not vibes.
- **Required verification** — the exact commands (see step 5) plus any ticket-specific tests.
- **Manual-test items** — what the user must check in the real app; these aggregate into
  the PR's manual checklist.
- **Decisions carried from discussion** — anything that would otherwise live only in chat.

Tickets are created with `scripts/plane create "<title>" <html-file> [priority]` after the
user approves their content. No credentials, secret values, or personal data in Plane —
ticket content is context for future sessions, not a secrets store.

## 3. Claiming and parallelism

Moving a ticket to **In Progress** (`scripts/plane state SON-12 started`) is the claim.
One ticket, one session, one owner — check the state before starting work, and never pick
up a ticket another session has claimed. **The user assigns each session its specific
ticket ID at launch; sessions never self-select "the next ready ticket" from the board** —
the state PATCH has no compare-and-swap, so self-selection is a claim race waiting to
happen. If a claimed ticket's session is confirmed dead (crashed, closed, out of context)
without reaching step 6, the user moves the ticket back to Todo before anyone re-claims
it — a stuck In Progress ticket with no living owner is the user's to reset, no one
else's.

Parallel sessions are allowed under these rules, each of which exists because breaking it
has documented consequences:

- **Only disjoint tickets run in parallel.** Two tickets may run concurrently only if
  their expected-touched-areas don't overlap AND neither depends on the other's outcome —
  including shared *assumptions* (a store contract, a shared type), not just shared files.
  Decided at ticket-creation time, recorded on the tickets, never improvised mid-run.
- **Each parallel session gets its own git worktree** (`claude --worktree <name>`, or
  `git worktree add`), one worktree per ticket. Never two sessions in one checkout. A
  worktree is a fresh checkout: budget a cold `swift build`, and don't share `.build/`
  between worktrees.
- **Cap: 2–3 concurrent sessions.** Review bandwidth is the bottleneck, not execution.
  More parallel output than the user can genuinely review produces rubber-stamped merges.
- **Only one session's build runs as the live app at a time.** Worktrees isolate code,
  not the machine: every `MacAgent.app` instance shares the same Keychain entries, local
  encrypted stores, notification identity, and menu bar. Manual testing is serialized
  through the user anyway; never launch the packaged app from a second worktree while one
  is already running.
- **Merge one branch at a time.** After each merge, other in-flight worktrees rebase onto
  the new `main` before continuing. Never batch-merge parallel branches. The rebase
  rewrites the ticket branch, so the follow-up `git push --force-with-lease` **on the
  session's own ticket branch** is covered by the same standing authorization as regular
  pushes — always `--force-with-lease`, never bare `--force`, and force-pushing any other
  branch (or anything on `main`) is never authorized.
- **Remove the worktree when its ticket's branch merges** (`git worktree remove`), and
  audit occasionally with `git worktree list`.

## 4. Pull the ticket

Before changing code: `scripts/plane pull SON-12`, read the description *and all
comments* — a previously blocked ticket's findings live there. Reconcile any difference
between the ticket and later conversation before implementing. Do not silently expand
scope; if the ticket is wrong or stale, say so and get it corrected first.

## 5. Implement and verify

Implement against the pulled ticket and repository conventions (`CLAUDE.md`, the
changelog's per-branch decisions, `.claude/rules/`). The v1 rigor bar is unchanged:

- Build: `swift build`. Tests: the exact flagged command in `CLAUDE.md` — plain
  `swift test` does not link.
- **Evidence, not assertion.** A ticket is done when its acceptance criteria are
  demonstrated by test output and exit codes, not when the work "looks done."
- **Fix-in-branch rule:** any bug found during a branch's own testing is fixed in that
  branch before merge. Deferring one requires the user's explicit decision and a named
  landing spot, recorded on a ticket — never a silent backlog.
- **Stop-and-report triggers:** the same failure across 3 consecutive fix attempts, or a
  fix that needs files/scope the ticket didn't name. Write findings to the ticket (step 6)
  instead of guessing onward.
- Commits reference the ticket in the title (for example `fix(core): SON-12 ...`), follow
  the repo's commit format, and land on the ticket's branch. Standing authorization:
  sessions commit and push to ticket branches without per-commit approval; opening a PR is
  fine; **merging is the user's, always.**

## 6. Close the ticket

Every ticket gets a closing comment (`scripts/plane comment SON-12 <html-file>`) before
its state changes. This is the context the next session inherits — write it for a reader
with zero conversation history.

**Completed** (`scripts/plane state SON-12 completed`) — the comment records: what was
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
`scripts/plane comment` reports a 400, verify with `scripts/plane comments SON-12` before
retrying — Plane sometimes returns 400 after creating the comment, and blind retries
produce duplicates.

## 7. PR, review, merge

When a branch's tickets are done: open a PR. The description is written once, at open
time, summarizing all tickets (linked by identifier); it is not updated per-ticket. The
changelog entry for the branch is written before the PR opens — tickets hold per-task
history, the changelog holds the durable architectural decisions and pitfalls; both, not
either.

**Fresh-session review:** a new CLI session — given only the diff, the tickets, and the
repo — reviews before merge. It hunts for problems rather than validating: reads the full
diff, reruns the full suite itself, and hand-traces non-trivial logic (date math, state
machines) rather than trusting green tests. Findings go back to the implementing session
(or become fix commits on the branch) before merge.

**When something fails after a ticket closed** — the flow above closes tickets before the
PR opens, so late failures need an explicit path, not improvisation:

- A reviewer finding *within* a ticket's scope: fix commits on the branch, plus a comment
  on that ticket recording the finding and the fix. The ticket stays Completed.
- A reviewer finding *outside* every ticket's scope (including anything that would breach
  a ticket's never-touch list): file a follow-up ticket referencing the original; fix it
  on this branch only if the user agrees it blocks the merge, otherwise it waits for its
  own ticket. Never silently breach a never-touch list to absorb a finding.
- A user manual-test failure: reopen the ticket (`scripts/plane state SON-12 started`)
  with a comment recording the exact failure, fix on the same branch per the fix-in-branch
  rule, close it again with a fresh closing comment. The original implementing session
  need not exist anymore — the ticket's comments are the handoff.

Then: the user runs the aggregated manual checklist in the real packaged app, and merges.
Delete the branch, remove the worktree, confirm the tickets' final states.
