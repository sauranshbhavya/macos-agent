### `fix/the-content-rules-see-the-whole-flow` owes no rows, and here is why (2026-09-17, SONNY-506, SONNY-508)

Both tickets change what a **skill pack file is allowed to say**, checked when the pack is decoded.
Nothing a founder can open moves: **no pack file, no catalogue row and no view changes on this
branch**, so the Skills page lists the same 473 packs, with the same depths and the same flows, and
every screen renders exactly what it rendered before. The only non-test file outside the two rules is
`Sources/MacAgentCore/SkillGuidance.swift`, and the line it adds is planner prompt text — it reaches
a model and never a person, so there is no surface on which a founder could read it back.

The one thing a person would notice is a pack **refusing to load**, which is a pack lane's
experience while writing one and not a founder's: a refused pack is absent from the Skills page, and
this branch ships no pack that refuses. That path is covered by the suite instead —
`everyShippedPackLoadsAndEveryOneIsARowOfTheCommittedCatalogue` loads all 473 through the real
loader, and `SkillPackTests`' four new tests hold both directions of both rules by value.

The founders' verification of this branch is therefore the suite, exactly as it was for
`chore/a-row-can-say-it-was-read-from-the-site`.
