# The manual-test checklist, one file per branch

A branch writes its manual-test rows here, at `docs/manual-tests/<branch-name>.md` — a slash in
the branch name is a folder, exactly as `mutation/plans/` already does it. Two branches therefore
never write to the same file, which is the whole reason this directory exists (SONNY-500).

## Reading the checklist

```
scripts/changelog-order manual-tests | less
```

That is the one way to read every manual-test item in order, and it is what replaces opening a
single file. It prints every branch's rows newest-first — whatever has not merged yet, then each
merged branch by its own merge commit — and then all of
`docs/sonny-manual-test-checklist.md`, which holds every row written before this directory
existed, its status tracker, its setup section and its conventions.

## What a branch owes

**Every manual-test item a ticket produces is written here before the ticket closes.** A PR note
or a ticket comment may summarize them, but this directory and the archive are the only places
the founders test from, and an item recorded anywhere else is an item they never see. Not
hypothetical: SONNY-281's **thirteen** items lived only on PR #118 — seven in its body, six more
added by its review rounds' dated notes — until SONNY-292 recovered them, and the first recovery
pass took the six and left the seven.

**A branch that owes no rows still writes this file**, with one line saying so and why each of
its tickets owes none. A missing file and a deliberate "none" are the same silence otherwise.
The archive already carries that shape as a worked example
(`git grep -n 'owes no rows, and here is why' 3bf70677 -- docs/sonny-manual-test-checklist.md`
→ `3003:` at `3bf70677`).

## The conventions that still hold, and where they live

The archive's own convention sections are the live ones and are not repeated here:

- **How to read a `confirmed <date>`** — a confirmation is a snapshot of one moment, not a
  standing guarantee, and a row later found broken has its history corrected in place rather
  than being silently re-checked.
- **Where a manual item lives** — the rule above, in the form it was written in 2026-08-26.

## The shape of a row

```
### <What the founder is checking> (new YYYY-MM-DD, SONNY-<n>)

<setup, if any — the packaged app, a local gateway, a debug entitlement>

- [ ] <one checkable observation, in the founder's own terms>
- [ ] <another>
```

Rows are unchecked when written. The founder ticks them; a row found broken later records the
arc on the row itself — confirmed when, found broken when, fixed by which ticket, re-confirmed
when.
