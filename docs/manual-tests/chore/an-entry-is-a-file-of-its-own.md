### `chore/an-entry-is-a-file-of-its-own` owes no rows, and here is why (2026-09-16, SONNY-500)

This branch changes no app behaviour, no user-facing string and no server route: nothing under
`Sources/`, `Tests/` or `server/` moves at all, proved by tree-identity check in the branch's
changelog entry. What it changes is where a branch writes its records and what
`scripts/changelog-order` reads, both of which a founder verifies by running the commands rather
than by opening the app.

Nothing for the founder to run here. The two commands a reader now uses are in
`docs/changelog/README.md` and in this directory's `README.md`:

```
scripts/changelog-order read | less
scripts/changelog-order manual-tests | less
```
