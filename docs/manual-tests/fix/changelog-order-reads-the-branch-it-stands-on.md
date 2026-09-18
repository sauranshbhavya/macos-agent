### `fix/changelog-order-reads-the-branch-it-stands-on` owes no rows, and here is why (2026-09-17, SONNY-516, SONNY-515)

**SONNY-516** changes what `scripts/changelog-order` asks of a checkout and how its findings are
worded, plus the stop hook's comments and the selftests of both. No app behaviour, no user-facing
string and no server route moves: nothing under `Sources/`, `Tests/`, `Package.swift` or `server/`
changes on this branch, and the branch's changelog entry carries the tree-identity proof. A founder
checks it by running the tool, not by opening the app.

**SONNY-515** was handed back at the ninety-minute stop with its root cause measured and its fix
designed but not built, so this branch changes nothing it would need a row for. The founders routed
it to a branch of its own on 2026-09-18. That branch owes rows only if it changes app behaviour,
and a test-only fix does not.

Nothing for the founder to run in the app here. The one command worth knowing is the one this
branch changed, and it now says on every run which merges it did not ask a checkout about:

```
scripts/changelog-order
```
