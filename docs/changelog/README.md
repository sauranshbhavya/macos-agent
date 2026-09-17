# The changelog, one file per branch

A branch writes its changelog entry here, at `docs/changelog/<branch-name>.md` — a slash in the
branch name is a folder, exactly as `mutation/plans/` already does it, so
`fix/some-name`'s entry is `docs/changelog/fix/some-name.md`. **The file is the entry and nothing
else**: it starts with the `### Branch:` heading and holds no other heading at that level, so the
same text can be read on its own or concatenated with every other branch's without changing a
byte.

Two branches therefore never write to the same file. That is the whole reason this directory
exists. Wave 9 ran thirteen branches as one stack and **no code conflicted anywhere** — 0 of 44
differing paths on PR #244, 0 of 34 on PR #250, 0 of 3 on PR #248 — while every conflict in the
whole wave was one of two documents each branch inserted into, this one and the manual-test
checklist (SONNY-500).

## Reading the history

```
scripts/changelog-order read | less
```

That is the one way to read the branch-by-branch history in order, and it is what replaces
opening a single file. It prints every branch's entry newest-first — whatever has not merged
yet, then each merged branch by its own merge commit — and then
`docs/sonny-v1-implementation-changelog.md` from its `## Entries` line down, which is every entry
written before this directory existed. Order comes from `git log --first-parent --merges main`,
never from a `Date:` line and never from where a file sits: same-day entries cannot be ordered by
date, and a pull request that opens early and merges late lands later on the mainline than its
number suggests (PR #87 and PR #57 are both that shape).

## What the archive is

`docs/sonny-v1-implementation-changelog.md` keeps every word it ever had — 223 entries
(`git show 3bf70677:docs/sonny-v1-implementation-changelog.md | awk '/^## Entries$/,0' | grep -c '^### Branch: '`
→ 223 at `3bf70677`, the commit this directory was cut from; the `awk` is what excludes the
template's own example heading above that line) — plus the roadmap table, the open-decisions
sections and the template preamble, none of which are entries. **It
takes no new entries.** Splitting it into per-branch files was the other option and was not
taken: the entries stay byte-identical where every citation, doc comment and `file:line` pointer
in the tree already points, and its two-era ordering rule stays checkable against a file that can
no longer change. `scripts/changelog-order` still checks that ordering, for the one fault that
can still happen there — a session appending an entry out of habit, which raises no rebase
conflict, so the clean merge is the tell.

## What a branch owes

**One file, whichever way the decision goes.** An entry is owed whenever a branch records a
durable architectural decision, a pitfall discovered, or a correction to the record
(`WORKFLOW.md` step 7 has the boundary, and the three `docs/` branches it uses as the worked
example). A branch that records none of that still writes this file, with one line saying so and
why — because a missing file and a deliberate "none" are the same silence otherwise, and that
silence has already cost this repository one entry nobody noticed was missing until a coordinator
swept for it by hand (PR #124).

`scripts/changelog-order` fails a branch that merged in this era and wrote no file. The era
begins at the merge of the branch named in that script's `DIRECTORY_ERA_BRANCH`; everything
merged before it is the archive's and is not checked for completeness.

## The template

Fill every field — "none" is a valid answer, a blank field is not. Product context, constraints
and non-negotiables already live permanently in the spec (§1–§26); do not restate them here, only
reference section numbers. `Behavior preserved` is marked **(required, no blanket claims)**
because a vague answer there is exactly how a later chat regresses something silently, and the
two marked **(required, write "none" if true)** are there for the same reason. Per-ticket history
— what each ticket did, closing comments, blocked findings — lives on the Plane tickets, not here;
this entry is the branch-level architectural record.

**Every figure in the entry carries the SHA it was measured at, and that SHA is the head that
merges** (`CLAUDE.md`, Claims and evidence). The entry is written before the PR opens, so when a
fix round or an update from `main` moves the head afterwards, re-measure each figure at the new
head or drop it — never carry one forward on the strength of the old head alone. The one thing
that lets a figure cross a moved head is `WORKFLOW.md` step 5's tree-identity proof, covering
every path that figure depends on: with the proof beside it the figure is a measurement *of* the
new head rather than a stale one re-stamped at it. No proof, no carry. Once the entry has merged,
`git merge-base --is-ancestor <sha> origin/main` exits 0 for every SHA it cites; a SHA that fails
that check is a timestamp on a branch, not a tree a reader can fetch.

```
### Branch: feature/<name>
Status: in progress | complete | blocked
Date: YYYY-MM-DD
Tickets: SONNY-<n>, SONNY-<n>, ... (with one-line outcomes)
Reviewed by: fresh session (per WORKFLOW.md step 7) — findings and their resolutions, or "none"

Spec sections covered: (list; flag any left partial and why)
Files changed: (actual list — not "see diff")
Tests: (exact command run, from CLAUDE.md) -> (pass/fail, counts) at <SHA — the head that merges; re-measured if the head moves after this is written>
Mutation plan: mutation/plans/<name>.txt (founder-triggered, not run on this branch)

Behavior added: (one bullet per new capability)
Behavior preserved (required, no blanket claims): (one bullet per EXISTING flow this branch touched, confirming it still works — "everything else still works" is not acceptable, name them)

Architectural decisions / pitfalls discovered (required, write "none" if true): (anything a future chat would get wrong if it only read the spec and not this entry)
Known limitations / deferred scope: (deferrals need the user's explicit decision and a named landing-spot ticket)
Open questions (required, write "none" if true):

Next branch: feature/<name> (per the roadmap in the archive's preamble, or state the reordering and why)
```
