### Branch: chore/a-plan-anchors-on-lines-that-exist
Status: complete
Date: 2026-09-19
Tickets: **SONNY-532** — three mutants whose `from` block matched nothing on `main` are re-pointed at the lines that now hold their properties, and every mutant in every plan is shown to match exactly once. The ticket named two, U3 and U6 in `mutation/plans/feature/skills.txt`. The third, P1 in `mutation/plans/feature/the-widget-minimises-while-sonny-runs.txt`, was recorded in the ticket's comment as untriaged, was found again by this branch's own check, and landed here by the founder's decision on 2026-09-19.
Reviewed by: not yet reviewed when this was written.

Spec sections covered: none. Mutation plans only.

Files changed, 4 (`git diff --name-only origin/main HEAD | wc -l` → 4 at the head carrying this file): the two plan files above, this file, and `docs/manual-tests/chore/a-plan-anchors-on-lines-that-exist.md` (no rows owed, and why).

Tests: none run, and none can see this diff. It touches nothing under `Sources/`, `Tests/` or `server/`, and `Package.swift` did not move, so neither half's suite compiles or reads a changed byte. Proved by tree identity between this branch's base `856bb7ee` and `7bb61ba7`, reading each side's exit code with `git rev-parse --verify --quiet <commit>:<path>`: `Sources`, `Tests`, `server` and `Package.swift` each print one hash twice, `mutation` prints two (the control that the loop can say MOVED), and a path that exists in neither tree is refused rather than compared (the control for the echo trap `CLAUDE.md` records). What this diff does owe is below.

The population check, at `7bb61ba7`, the last commit to touch `mutation/plans/` on this branch:

```
find mutation/plans -type f -name '*.txt' | LC_ALL=C sort | while IFS= read -r plan; do scripts/mutate "$plan" --check; done > check.log 2>&1
grep -cE '  1 match$' check.log                                    → 418
grep -cE '(REFUSED|NO SUCH FILE)$' check.log                       → 0
grep -c -- '--check: every selected mutant matches' check.log      → 33
```

So 418 mutants checked in 33 plans, 0 mismatched, and all 33 plans pass `scripts/mutate`'s own pre-flight. The `find` is the one `scripts/mutate-all` enumerates plans with, and `--check` is the step it runs on each plan first, so this is the weekly battery's own reading rather than a lookalike. **The control that this can report a non-zero:** the same loop and the same three greps on this branch's base `856bb7ee`, before any edit, answered 415, 3 and 31, naming U3, U6 and P1; at `8dabcfa1`, with U3 and U6 fixed and P1 not, it named P1 alone. A second instrument agreed at all three commits: a standalone script that parses every plan with `scripts/mutate`'s grammar and counts each `from` block as literal bytes in its target, reading plans and targets with `git show <commit>:<path>` so the working tree is never consulted (3 of 418, then 1 of 418, then 0 of 418). It lives in no tracked file, so the loop above is the one a reader re-runs.

Other checks owed by every branch, at the head carrying this file: `server/scripts/check-secrets.sh` exit 0, `scripts/no-attribution history` and `tree` exit 0, `scripts/changelog-order` exit 0. The closing comment on SONNY-532 carries each with its SHA.

Mutation plan: none. This branch changes no behaviour. It edits two existing plans, and nothing was run against either: batteries are founder-triggered.

Behavior added: none.
Behavior preserved (required, no blanket claims):
- U3 still breaks the property its id has always named, an action verb beside a money object refusing. It patches `if let action = actionVerbs.first(in: units) {` in `SkillPackMoneyRule.violation`, with the same added clause (`, units.isEmpty`) the original put on the `guard let` that SONNY-506 replaced. Its note is widened, because under it the purchase acts and a priced purchase control that SONNY-506 added also still refuse, not only the money-only verbs.
- U6 still breaks a flow's start page having to be on the pack's own site, and nothing else. It patches the guard in `SkillPackDecoder.decodeFlow`, with the same added clause (`|| !startHost.isEmpty`).
- P1 still breaks a run starting minimising the widget, with the same one-word change, now inside `isRunning`'s setter. The two tests its plan's header names as killers both still exist in `Tests/MacAgentTests/WidgetMinimiseTests.swift`.
- Every other mutant in both plans is byte-identical to `main`'s.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- **U6 anchors on the guard that calls `isOnSite`, not on `isOnSite`'s return line, and the ticket suggested the second.** The helper has three callers (`grep -rn 'isOnSite(' Sources | grep -v 'static func' | wc -l` → 3 at `7bb61ba7`, and 4 with that stage dropped, the fourth being the declaration): `decodeFlow`, and two in `SkillPackStartPages.swift` that `mutation/plans/fix/a-flow-starts-where-the-work-starts.txt` already mutates at their own call sites. A mutant inside the helper breaks the start-page rule as well, so a start-page test could kill it with both flow-start tests gone, and U6 would read as covered by tests that are not about it. The guard is where this one property is decided, and it is the guard the original mutant patched before SONNY-510 moved the comparison out of it.
- **A stale plan does not stop the weekly battery, and the ticket said it would.** `scripts/mutate-all` runs `--check` on each plan first and, on a stale one, prints `SKIPPED — stale`, continues to the next plan, and ends in exit 3 or 2 with the plan named (`scripts/mutate-all:531-540` at `7bb61ba7`, and its `--help`). What a stale plan costs is quieter than a dead run: all of that plan's mutants go unmeasured that week, the healthy ones included, which here was 30 in the skills plan and 11 in the widget plan (the `1 match` lines in each plan's own `--check` output at `7bb61ba7`).
- **Nothing tells a branch that it broke another branch's plan, and that is how all three went stale.** Each was anchored correctly when written, and each was broken by a later branch restructuring the line: SONNY-506 for U3, SONNY-510 for U6, SONNY-456 for P1. A branch checks its own plan and has no reason to open anyone else's. The loop above costs about a minute, needs no build, and is the check that would have caught each one on the branch that caused it. Whether a branch that touches `Sources/` or `Tests/` should owe it is a process question for the founders, asked below rather than decided here.

Known limitations / deferred scope: `--check` proves a mutant still applies, not that its killers still cover what they once did. `scripts/mutate-all --help` says the same of itself, and `WORKFLOW.md` step 5's four conditions are the test for that. The three re-pointed mutants have not been run and are first measured by the founders' next weekly battery.
Open questions (required, write "none" if true): should a branch whose diff touches `Sources/`, `Tests/` or `server/` owe the population loop above before it pushes, so the branch that moves an anchored line is the one that finds out? It is a founders' decision about `WORKFLOW.md` step 5 and is raised on SONNY-532's closing comment. Nothing on this branch depends on the answer.

Next branch: none named. The board's next lanes are the coordinator's to assign.
