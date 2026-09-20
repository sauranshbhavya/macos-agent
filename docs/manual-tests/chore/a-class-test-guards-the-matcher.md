### `chore/a-class-test-guards-the-matcher` owes no rows, and here is why (2026-09-19, SONNY-539)

SONNY-539 adds a test, the table it reads, the script that generates the table, and a mutation plan.
**Nothing under `Sources/` moves**, so no app behaviour, no user-facing string and no shipped pack
changes, and the rule the test guards decides exactly what it decided before: the branch's changelog
entry has the tree-identity check. The founders' verification of this branch is the suite rather than
the app.

Nothing for a founder to run in the app. The one command worth knowing is the one that shows the held
table is still what `main`'s matcher answered, about a minute, from the repository root:

```
scripts/account-creation-class-table --check
```
