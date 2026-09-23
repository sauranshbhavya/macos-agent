# Historical branch records

The entries in this directory document the former one-file-per-branch workflow. Read them directly when a past decision is relevant; `git log --diff-filter=A --date=short --format=%ad --name-only -- docs/changelog` lists them newest first, by the day each landed. The older entries are in [the v1 changelog](../sonny-v1-implementation-changelog.md).

New branches do not need an entry here. Use a PR or substantial Plane issue for implementation history. If a change makes a durable architectural or product decision, write a short decision note near the affected documentation and link it from the PR. The former template and completeness rules are preserved in [the archived workflow](../archive/WORKFLOW-v2-2026-09.md).
