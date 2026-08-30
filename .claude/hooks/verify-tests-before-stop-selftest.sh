#!/usr/bin/env bash
# Re-prove every arm of `.claude/hooks/verify-tests-before-stop.sh` still fires.
#
#     .claude/hooks/verify-tests-before-stop-selftest.sh
#
# Exit 0 when every arm holds, 2 when one does not. About two seconds; it builds a throwaway git
# repository per case and never touches this one.
#
# WHY THIS EXISTS (SONNY-361). A stop hook is the one piece of this repository's automation that
# nothing else exercises: no test imports it, the suite never runs it, and the only signal it
# gives when it has stopped working is silence — which is exactly what a passing run looks like.
# `scripts/warnings selftest` and `scripts/mutate selftest` exist for the same reason and this is
# the third of them. This repository counts a guard only once it has been shown to flag what it
# names, and a hook that fires on nothing is the failure SONNY-361 exists to prevent.
#
# WHAT IT DRIVES is the real hook script, copied into a fixture repository, through its real
# command line and its real stdin payload — never a re-implementation of its logic. The fixture
# carries a real `scripts/changelog-order` and a real `scripts/lib/battery-state.sh`, both copied
# from this checkout, so an arm that passes here is a statement about the shipped files.
#
# WHAT IT DOES NOT COVER, stated rather than implied: the Swift suite arm. Every fixture below is
# Swift-clean, so the hook takes its fast path and never invokes `swift test` — which is the point
# for the arms about the changelog (they prove a finding survives the exact path a docs-only
# branch takes every time), and is a hole in the arms about the suite. Running a real suite from
# here would cost minutes and a build directory. The suite arm has a different guard: it is the
# one arm of this hook that fails loudly and often in ordinary use.

set -u

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/verify-tests-before-stop.sh"
ORDER_SRC="$SRC_ROOT/scripts/changelog-order"
BATTERY_SRC="$SRC_ROOT/scripts/lib/battery-state.sh"
CHANGELOG_REL="docs/sonny-v1-implementation-changelog.md"
BOUNDARY="feature/vision-actions"

for f in "$HOOK_SRC" "$ORDER_SRC" "$BATTERY_SRC"; do
  [ -r "$f" ] || { echo "selftest: cannot read $f" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0
cases=0

# The mainline the fixture's changelog is checked against. Oldest first, so `old/*` merged before
# the era boundary and `new/*` after it — the two eras the real file has.
FIXTURE_MERGES=(3:old/a 4:old/b 5:old/c 50:"$BOUNDARY" 51:new/a 52:new/b 53:new/c)

entry() { printf '### Branch: %s\nStatus: complete\nDate: 2026-01-01\n\nbody\n\n' "$1"; }

# write_changelog <repo> <branch> ...   — one entry per branch, in the order given.
write_changelog() {
  local repo="$1"; shift
  { printf '# fixture changelog\n\n## Entries\n\n'; for b in "$@"; do entry "$b"; done; } \
    > "$repo/$CHANGELOG_REL"
}

# A repository shaped like this one: a `main` whose first-parent history is merge commits in
# GitHub's own subject form, the three real scripts, and a branch off main to stand on.
new_fixture() {
  local repo="$WORK/repo.$RANDOM.$RANDOM"
  mkdir -p "$repo/docs" "$repo/scripts/lib" "$repo/.claude/hooks"
  cp "$HOOK_SRC" "$repo/.claude/hooks/verify-tests-before-stop.sh"
  cp "$ORDER_SRC" "$repo/scripts/changelog-order"
  cp "$BATTERY_SRC" "$repo/scripts/lib/battery-state.sh"
  chmod +x "$repo/.claude/hooks/verify-tests-before-stop.sh" "$repo/scripts/changelog-order"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email selftest@example.invalid
  git -C "$repo" config user.name selftest
  write_changelog "$repo" new/c new/b new/a "$BOUNDARY" old/a old/b old/c
  git -C "$repo" add -A >/dev/null
  git -C "$repo" commit -q -m "seed"
  local spec pr branch
  for spec in "${FIXTURE_MERGES[@]}"; do
    pr="${spec%%:*}"; branch="${spec#*:}"
    git -C "$repo" checkout -q -b "$branch"
    printf 'x\n' > "$repo/${branch//\//_}"
    git -C "$repo" add -A >/dev/null
    git -C "$repo" commit -q -m "work on $branch"
    git -C "$repo" checkout -q main
    git -C "$repo" merge -q --no-ff -m "Merge pull request #$pr from ns/$branch" "$branch"
  done
  git -C "$repo" checkout -q -b docs/fixture-branch
  printf '%s' "$repo"
}

# run_hook <repo> <stop_hook_active> — the real script, real argv, real stdin. No pipe between
# the command and the exit code that gets reported (CLAUDE.md, Claims and evidence).
run_hook() {
  local repo="$1" active="$2"
  printf '{"stop_hook_active": %s}' "$active" > "$WORK/payload.json"
  env CLAUDE_PROJECT_DIR="$repo" bash "$repo/.claude/hooks/verify-tests-before-stop.sh" \
    < "$WORK/payload.json" > "$WORK/out" 2> "$WORK/err"
  HOOK_EXIT=$?
  HOOK_OUT="$(cat "$WORK/out")"
  HOOK_ERR="$(cat "$WORK/err")"
  HOOK_BOTH="$HOOK_OUT
$HOOK_ERR"
}

# assert <name> <expected exit> <must appear, or -> <must not appear, or -> [channel]
#
# `channel` is one of both (default), err, out. It exists because the first draft of this file did
# not have it: every arm matched stdout and stderr as one string, and a mutant that deleted the
# stderr half of a skip notice SURVIVED, because the systemMessage on stdout still carried the same
# words. The hook promises a skip three ways — to the session on stderr, to the user as a
# systemMessage, to the journal on disk — and three channels collapsed into one string can only
# ever prove that one of them worked.
assert() {
  local name="$1" want_exit="$2" want="$3" avoid="$4" channel="${5:-both}" ok=1 why="" haystack
  case "$channel" in
    err) haystack="$HOOK_ERR" ;;
    out) haystack="$HOOK_OUT" ;;
    *)   haystack="$HOOK_BOTH" ;;
  esac
  cases=$((cases + 1))
  [ "$HOOK_EXIT" = "$want_exit" ] || { ok=0; why="exit $HOOK_EXIT, wanted $want_exit"; }
  if [ "$want" != "-" ] && ! printf '%s' "$haystack" | grep -qF -- "$want"; then
    ok=0; why="${why:+$why; }did not say on $channel: $want"
  fi
  if [ "$avoid" != "-" ] && printf '%s' "$HOOK_BOTH" | grep -qF -- "$avoid"; then
    ok=0; why="${why:+$why; }said what it must not: $avoid"
  fi
  if [ "$ok" = 1 ]; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %s — %s\n' "$name" "$why"
    printf '%s\n' "$HOOK_BOTH" | sed 's/^/          /' | head -20
    failures=$((failures + 1))
  fi
}

# assert_journal <name> <repo> <substring>
assert_journal() {
  local name="$1" journal
  journal="$(git -C "$2" rev-parse --absolute-git-dir)/battery-skips.log"
  cases=$((cases + 1))
  if [ -s "$journal" ] && grep -qF -- "$3" "$journal"; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %s — nothing matching %s in %s\n' "$name" "$3" "$journal"
    failures=$((failures + 1))
  fi
}

echo "verify-tests-before-stop selftest"

# ---------------------------------------------------------------------------------------------
# The negative and its positive control, which are one case in two halves. A check that never
# fires and a check that fires on nothing are indistinguishable from each other on a clean tree,
# and the clean tree is what a hook sees on almost every turn.
# ---------------------------------------------------------------------------------------------
repo="$(new_fixture)"
run_hook "$repo" false
assert "a branch that has not touched the changelog is not checked at all" 0 - "changelog-order"

# Same fixture, same branch, one difference: the changelog is now out of order and committed.
write_changelog "$repo" docs/fixture-branch new/b new/c new/a "$BOUNDARY" old/a old/b old/c
git -C "$repo" add -A >/dev/null && git -C "$repo" commit -q -m "entry"
run_hook "$repo" false
assert "a misplaced entry COMMITTED on the branch is caught, with no Swift change in the tree" \
  2 "belongs above" -
assert "  ...and the finding names the changelog and the file it read" 2 "$CHANGELOG_REL" -

# ---------------------------------------------------------------------------------------------
# The exemption that decides whether anyone leaves this hook switched on.
# ---------------------------------------------------------------------------------------------
repo="$(new_fixture)"
write_changelog "$repo" docs/fixture-branch new/c new/b new/a "$BOUNDARY" old/a old/b old/c
git -C "$repo" add -A >/dev/null && git -C "$repo" commit -q -m "entry"
run_hook "$repo" false
assert "a branch that wrote its own unmerged entry, in order, passes silently" 0 - "changelog"

# ---------------------------------------------------------------------------------------------
# The uncommitted reading, which is the one an obvious implementation would have had alone.
# ---------------------------------------------------------------------------------------------
repo="$(new_fixture)"
write_changelog "$repo" docs/fixture-branch new/b new/c new/a "$BOUNDARY" old/a old/b old/c
run_hook "$repo" false
assert "a misplaced entry left UNCOMMITTED is caught" 2 "uncommitted in the working tree" -

# ---------------------------------------------------------------------------------------------
# The loop guard. Already blocked once, so it must not block again — and must not go quiet either.
# ---------------------------------------------------------------------------------------------
run_hook "$repo" true
assert "stop_hook_active does not block a second time" 0 - -
assert "  ...and still says the changelog is out of order" 0 "out of merge order" -

# ---------------------------------------------------------------------------------------------
# The two battery states. Neither is this ticket's work; both are what it had to not break.
# ---------------------------------------------------------------------------------------------
repo="$(new_fixture)"
write_changelog "$repo" docs/fixture-branch new/b new/c new/a "$BOUNDARY" old/a old/b old/c
git -C "$repo" add -A >/dev/null && git -C "$repo" commit -q -m "entry"
lock="$(git -C "$repo" rev-parse --absolute-git-dir)/mutate.lock"
mkdir -p "$lock"
# A live battery: this selftest's own pid, recorded the way the library records one.
( . "$BATTERY_SRC"; battery_write_owner_record "$lock" plan selftest head deadbeef )
run_hook "$repo" false
assert "a live battery skips BOTH checks rather than the suite alone" 0 "skipped BOTH checks" -
assert "  ...and the changelog finding underneath is not reported as if checked" 0 - "belongs above"
assert_journal "  ...and the skip is written to the journal, not only to a terminal" \
  "$repo" "did not run the suite or scripts/changelog-order"

# An abandoned mutant: a pid that is not running, plus the in-flight record a killed run leaves.
printf 'pid 2\nlstart Thu Jan  1 00:00:00 1970\nstarted 1970-01-01 00:00:00\n' > "$lock/owner"
mkdir -p "$lock/inflight"
printf 'id R1\nfile Sources/MacAgentCore/Thing.swift\nsha deadbeef\n' > "$lock/inflight/meta"
run_hook "$repo" false
assert "an abandoned mutant still blocks, ahead of everything else" 2 "carries a mutant" -
rm -rf "$lock"

# ---------------------------------------------------------------------------------------------
# The two ways the check can fail to produce an answer. Neither may read as a pass — a search
# whose engine cannot see the bytes you mean answers a clean zero, and a clean zero is the one
# answer that looks like good news (CLAUDE.md, Claims and evidence).
# ---------------------------------------------------------------------------------------------
repo="$(new_fixture)"
write_changelog "$repo" docs/fixture-branch new/b new/c new/a "$BOUNDARY" old/a old/b old/c
git -C "$repo" add -A >/dev/null && git -C "$repo" commit -q -m "entry"
chmod -x "$repo/scripts/changelog-order"
run_hook "$repo" false
assert "a non-executable scripts/changelog-order is reported to the SESSION, not passed over" \
  0 "did NOT run" - err
assert "  ...and to the USER, as a systemMessage" 0 "systemMessage" - out
assert_journal "  ...and to the journal" "$repo" "stop-hook/changelog-order"
chmod +x "$repo/scripts/changelog-order"

# A changelog the tool refuses to measure: no `## Entries` marker at all. Exit 1, which is
# neither a pass nor a finding.
repo="$(new_fixture)"
printf '# fixture changelog\n\nnothing the tool can map\n' > "$repo/$CHANGELOG_REL"
run_hook "$repo" false
assert "a refusal to measure is reported to the SESSION, and blocks nothing" \
  0 "exited 1 without measuring" - err
assert "  ...and says on stderr, plainly, that the order has not been checked" \
  0 "has NOT been checked" - err
assert "  ...and the user is told the same on stdout" 0 "has NOT been checked" - out
assert_journal "  ...and the journal records which check did not run" \
  "$repo" "stop-hook/changelog-order"

printf 'selftest: %d case(s), %d failure(s)\n' "$cases" "$failures"
[ "$failures" -eq 0 ] || exit 2
