### `chore/a-plan-anchors-on-lines-that-exist` owes no rows, and here is why (2026-09-19, SONNY-532)

This branch changes no app behaviour, no user-facing string and no server route. Nothing under
`Sources/`, `Tests/` or `server/` moves, proved by tree identity in the branch's changelog entry.
It re-points three mutants in two mutation plans at lines `main` still holds, so
`scripts/mutate` stops refusing those plans at its pre-flight.

Nothing for the founder to open the app for. What the change is for shows up on the next weekly
battery: `scripts/mutate-all` should list neither `mutation/plans/feature/skills.txt` nor
`mutation/plans/feature/the-widget-minimises-while-sonny-runs.txt` under `SKIPPED (stale)`.
