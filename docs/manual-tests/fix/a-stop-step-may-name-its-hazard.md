### `fix/a-stop-step-may-name-its-hazard` owes no rows, and here is why (2026-09-19, SONNY-534, SONNY-536)

Both tickets change what a **skill pack file is allowed to say**, checked when the pack is decoded.
Nothing a founder can open moves: **no pack file, no catalogue row and no view changes on this
branch** — `Sources/MacAgent/Resources/SkillPacks` and `docs/sonny-skill-sites.tsv` are each one
hash at `856bb7ee` and at this branch's head — so the Skills page lists the same 473 packs, with
the same depths and the same flows.

SONNY-534 makes the credential rule refuse a flow that creates a key or a token. What a person
would notice is a pack **refusing to load**, which is a pack lane's experience while writing one
and not a founder's, and this branch ships no pack that refuses: all 473 load, held by
`everyShippedPackLoadsAndEveryOneIsARowOfTheCommittedCatalogue`.

SONNY-536 adds an optional `stops` field to a flow. **No shipped pack uses it yet** — the pack
files belong to other lanes this wave — so no planner prompt changes for any command a founder can
type today. When a pack does carry a stop, the lines it adds are planner prompt text, which reaches
a model and never a person. The first pack to use `stops` owes the manual row: run that flow up to
the hazard and see Sonny stop and say why.

The founders' verification of this branch is therefore the suite, as it was for
`fix/the-content-rules-see-the-whole-flow`.
