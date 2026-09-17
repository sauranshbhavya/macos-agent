### `chore/a-row-can-say-it-was-read-from-the-site` owes no rows, and here is why (2026-09-17, SONNY-501)

SONNY-501 changes a column in `docs/sonny-skill-sites.tsv`, the test that validates it, and two
pieces of prose. **Nothing under `Sources/MacAgent/` moves, and the one file it touches under
`Sources/` is a doc comment**: every changed line in `Sources/MacAgentCore/SkillPack.swift` begins
with `///`, so no app behaviour, no user-facing string and no shipped pack changes. The ticket's own
Manual-test items field says "None — no product surface changes", and the founders' verification of
this branch is the suite rather than the app.

The one thing a founder could see — a skill pack getting deeper, so Sonny knows a site's task flows
— deliberately does not happen here. **No pack's depth changes on this branch**: 473 packs, 0 depths
moved, proved in the changelog entry. This branch opens the door and the pack lanes (SONNY-502
onward) walk through it, and their rows are where the founders will meet the difference.
