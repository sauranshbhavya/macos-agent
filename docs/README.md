# Sonny documentation map

For new work, start with the user's requested outcome, [AGENTS.md](../AGENTS.md), and the relevant code. [WORKFLOW.md](../WORKFLOW.md) gives the current lightweight delivery and verification path. The root [V2 plan](../sonny_v2_architecture_implementation_plan.md) states the current architecture direction; [README.md](../README.md) describes the application as it exists today.

The documents below answer narrower questions:

- [Current and V2 architecture diagrams](sonny-architecture-diagrams.md): code-derived map of `main`
  and an implementation-status view of the V2 target against the active Milestone A feature branch.
- [V2 implementation plan](sonny-v2-implementation-plan.md): the ordered work from today's code to the
  gateway/microkernel end state, with the 2026-09-25 decisions it rests on.
- [Design system reference](sonny-design-system-reference.md): visual tokens and surface language for affected UI.
- [Backend API contract](sonny-backend-api-contract.md) and [server/README.md](../server/README.md): hosted behavior and operations; confirm against current code before changing a contract.
- [Founder design decisions](sonny-founder-design-decisions.md) and [v1 major-release spec](sonny-major-release-spec.md): historical product reasoning. Their workspace and former workflow requirements do not override the current V2 plan.
- [V1 implementation changelog](sonny-v1-implementation-changelog.md), [branch records](changelog/README.md), and [manual-test records](manual-tests/README.md): history to consult when a change touches the behavior they describe, not required reading or new artifacts for every edit.
- [Archived plans and contributor notes](archive/README.md): earlier V2 drafts and the retired detailed delivery rules.

A past decision may still explain a current safety or data constraint. Check the current implementation and whether a later decision superseded it before applying it to new work.
