# Historical planning and contributor records

These files preserve the reasoning and procedures used before the current lightweight workflow. They are useful when a change touches a behavior they discuss, but they are not standing instructions and may describe classes, product features, or process gates that have since changed.

- [Former delivery workflow](WORKFLOW-v2-2026-09.md)
- [Former Claude contributor notes](CLAUDE-contributor-notes-2026-09.md)
- [Former core conventions](macagentcore-conventions-2026-09.md) and [UI conventions](macagent-ui-conventions-2026-09.md)
- [V2 comparison](sonny_v2_architecture_comparison.md), [original V2 draft](sonny_v2_architecture_implementation_plan_1.md), and [recovered intermediate V2 plan](sonny_v2_architecture_implementation_plan_2026-09-22.md)

The tooling the former workflow required was deleted on 2026-09-23 rather than archived: the mutation battery (`scripts/mutate`, `scripts/mutate-all`, `scripts/mutate-untrusted-failures`, `mutation/plans/`), `scripts/warnings`, `scripts/changelog-order`, the test-running stop hook and the one-off attribution-rewrite scripts. `git log --diff-filter=D --oneline -- scripts/mutate` finds the commit that removed them; check out its parent to recover any of them.

Use the root [AGENTS.md](../../AGENTS.md), [WORKFLOW.md](../../WORKFLOW.md), and [V2 direction](../../sonny_v2_architecture_implementation_plan.md) for current work. The historical body text was preserved; relative links inside it may still be written from its former root location.
