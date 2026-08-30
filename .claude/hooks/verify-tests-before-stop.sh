#!/bin/bash
# Stop hook. Two checks, and neither is one a session has to remember:
#
#   1. If Swift source changed this turn, the required test suite must pass before Claude can
#      finish. Skips fast when nothing Swift changed.
#   2. If this branch has touched the changelog, `scripts/changelog-order` must pass. Skips fast
#      when the branch has not touched it. (SONNY-361.)
#
# Never loops: stop_hook_active means this already blocked once, so let it end this time.
#
# Every path out of here either ran a check and says what it found, or did not run one and says
# that instead. A hook that silently does nothing trades a false red for a false green, and the
# false green is the one nobody notices.

payload=$(cat)
stop_hook_active=$(echo "$payload" | jq -r '.stop_hook_active // false')

if [ -z "$CLAUDE_PROJECT_DIR" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR" || exit 0

# ---------------------------------------------------------------------------------------------
# Before anything else, including the "nothing Swift changed" fast path (SONNY-258).
#
# A mutation battery edits a source file, runs the suite, and puts the file back. So while one is
# running, this checkout carries a deliberately broken file BY CONSTRUCTION — and this hook, which
# compiles what is on disk, gets a genuine failure about a state nobody asked about. It happened on
# PR #109: the suite was red, the redness was entirely real, and it was entirely meaningless as a
# statement about the branch. Its output is indistinguishable from a regression.
#
# The fast path could not save this hook from it either, which is why the check goes first: a
# mutant IS a Swift change, so `git status --porcelain -- '*.swift'` is non-empty exactly when a
# battery is mid-mutant, and the transcript check below skips only for sessions that edited no
# Swift at all — never for the session running the battery, which is the one that hits this.
#
# The two states are opposites and get opposite answers. A LIVE battery means the check cannot be
# run: skip it, and say so, because a hook that silently does nothing trades a false red for a
# false green and nobody notices. An ABANDONED mutant — a battery killed with the mutant still
# applied — means the tree is broken right now: block, because the whole point of SONNY-347 is that
# a session which kills a battery is TOLD, rather than having to think of checking.
# ---------------------------------------------------------------------------------------------
battery_lib="$CLAUDE_PROJECT_DIR/scripts/lib/battery-state.sh"
if [ -r "$battery_lib" ]; then
  # shellcheck source=../../scripts/lib/battery-state.sh
  . "$battery_lib"
  battery_state

  case "$BATTERY_STATE" in
    live)
      battery_journal "stop-hook" "did not run the suite or scripts/changelog-order: a battery holds this checkout (pid ${BATTERY_PID:-unknown})"
      {
        # The literal phrase below is asserted by `scripts/mutate selftest`, which drives THIS
        # file rather than a copy of it. Keeping it is not deference to a test: a message that
        # names the suite is the one a session searches its scrollback for, and the second check
        # is added beside it rather than in place of it.
        printf 'Stop hook: NEITHER check ran — the test suite was NOT run, and neither was\n'
        printf 'scripts/changelog-order.\n\n'
        printf 'A mutation battery is running in this checkout, so the tree is mid-mutant and any\n'
        printf 'suite result would describe a deliberately broken file rather than this branch.\n'
        printf 'The changelog check compiles nothing and would be safe to run here, but the answer\n'
        printf 'this hook gives during a battery is that it has said nothing about this branch at\n'
        printf 'all, and one check running would make that answer false. It fires on the next turn\n'
        printf 'after the battery finishes, and a battery cannot start over a dirty tree anyway, so\n'
        printf 'an entry being written right now is not a state this can be in (SONNY-361).\n\n'
        battery_state_detail
        printf '\nNothing here says the suite passes. Re-run it once that battery finishes.\n'
      } >&2
      # Also to the user, and to a file, so a skipped check is not a silent one.
      printf '{"systemMessage": "Stop hook skipped BOTH checks: a mutation battery (pid %s) holds this checkout, so any suite result would be about a mutant. Neither the test suite nor scripts/changelog-order has been run."}\n' \
        "${BATTERY_PID:-unknown}"
      exit 0
      ;;
    abandoned)
      battery_journal "stop-hook" "blocked: killed battery left mutant ${BATTERY_ID:-?} in ${BATTERY_FILE:-?}"
      if [ "$stop_hook_active" = "true" ]; then
        printf '{"systemMessage": "A killed mutation battery left mutant %s in %s. Run: scripts/mutate unlock"}\n' \
          "${BATTERY_ID:-unknown}" "${BATTERY_FILE:-unknown}"
        exit 0
      fi
      {
        printf 'Stop hook: this working tree carries a mutant, and the test suite was NOT run.\n\n'
        battery_state_detail
        printf '\nDo not commit, rebase or push from this tree until that file is restored.\n'
      } >&2
      exit 2
      ;;
  esac
else
  # The library is committed, so its absence means a broken checkout rather than an ordinary state —
  # but the two directions are not equally safe to fail open on, and the guard above is deliberately
  # `-r` rather than fatal. Skipping the `live` case is right: a false red is loud and a false green
  # is not. Skipping the `abandoned` case is not, because the suite over a surviving mutant can be
  # green. This needs no library. (PR #161, review — raised as a two-line close rather than a
  # finding.)
  battery_git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)"
  if [ -n "$battery_git_dir" ] && [ -f "$battery_git_dir/mutate.lock/inflight/meta" ]; then
    {
      printf 'Stop hook: this working tree may carry a mutant, and the test suite was NOT run.\n\n'
      printf 'A mutation battery left an in-flight record at %s.\n' \
        "$battery_git_dir/mutate.lock/inflight/meta"
      printf 'scripts/lib/battery-state.sh is missing from this checkout, so nothing here can say\n'
      printf 'whether that battery is still running. Run: scripts/mutate unlock\n'
    } >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------------------------
# The changelog's entry order (SONNY-361).
#
# `scripts/changelog-order` proves the changelog's entries sit in `main`'s first-parent merge
# order within each of the file's two eras, that no entry names a branch that never merged, and
# that every heading has exactly one entry beneath it. `WORKFLOW.md` step 7 names it as owed by
# any diff that touches the changelog — and that is the half that decides nothing. `CLAUDE.md`'s
# record of SONNY-64's guard is explicit: a check people learn to skip has stopped existing. The
# defect this one catches is invisible by construction — nobody else edits the spot a misplaced
# entry lands in, so the merge is clean, no test reads the file, and the symptom is a wrong number
# in prose two months later. Nothing else in this repository would ever go red on it. So it runs
# unasked, here.
#
# WHEN IT FIRES: whenever THIS BRANCH has touched the changelog at all — uncommitted in the
# working tree, or committed since the merge-base with `main`. The working-tree reading alone
# would be the obvious one and it is not enough, and the gap is the common case rather than an
# edge of it: step 7 has the entry written AND committed before the PR opens, so on the last turn
# of the branch whose entry is at issue the tree is clean and a dirty-file trigger fires never.
#
# WHY ABOVE THE SUITE: about a tenth of a second, and no build. Measured 2026-08-30 at `cdb9f39`
# over a 140-entry changelog, `/usr/bin/time -p scripts/changelog-order`, two sets of three
# consecutive runs -> real 0.12/0.11/0.11 and 0.14/0.11/0.11. A COLD first run was 0.591s wall
# (`time scripts/changelog-order`, 23% cpu), and that is the figure to quote if one is quoted,
# because a stop hook fires on a machine that has not just run this.
#
# WHAT IT WILL NOT DO is go red on a branch that legitimately wrote its own entry. The check
# exempts the first entry and only the first, because step 7 writes it before the PR opens, so
# the newest entry names no merge yet. A check that reports honest work as a failure is a check
# people turn off.
#
# The three answers, and none of them is silence:
#   exit 0 -> nothing to say; the hook carries on to the suite.
#   exit 2 -> findings. Held in `changelog_block` and emitted by whichever exit this hook takes,
#             so the suite still runs this turn rather than being displaced by the block.
#   exit 1 -> the tool refused to measure (it cannot resolve `main`, cannot find `## Entries`,
#             maps no entry). That is not a pass and is not a finding, so it is reported loudly
#             and blocks nothing. Same for a missing or non-executable script.
# ---------------------------------------------------------------------------------------------
changelog_rel="docs/sonny-v1-implementation-changelog.md"
changelog_block=""

# A check that did not run says so three ways: to this session (stderr), to the user
# (systemMessage), and to the journal that is still there when somebody asks later why a check
# that should have run produced nothing. `battery_journal` is defined only when the library above
# was readable, so the call is guarded rather than assumed.
changelog_note() {
  changelog_note_what="$1"
  if command -v battery_journal >/dev/null 2>&1; then
    battery_journal "stop-hook/changelog-order" "$changelog_note_what"
  fi
  printf 'Stop hook: scripts/changelog-order did NOT run — %s\n' "$changelog_note_what" >&2
  printf 'The changelog entry order has NOT been checked this turn. Nothing here says it is in order.\n' >&2
  printf '{"systemMessage": "Stop hook: scripts/changelog-order did NOT run — %s. The changelog entry order has NOT been checked this turn."}\n' \
    "$changelog_note_what"
}

changelog_touched=""
if [ -n "$(git status --porcelain -- "$changelog_rel" 2>/dev/null)" ]; then
  changelog_touched="uncommitted in the working tree"
else
  changelog_base=""
  for changelog_ref in main origin/main; do
    changelog_base="$(git merge-base HEAD "$changelog_ref" 2>/dev/null)"
    [ -n "$changelog_base" ] && break
  done
  if [ -n "$changelog_base" ] &&
     [ -n "$(git diff --name-only "$changelog_base" HEAD -- "$changelog_rel" 2>/dev/null)" ]; then
    changelog_touched="committed on this branch"
  fi
fi

if [ -n "$changelog_touched" ]; then
  if [ ! -x "$CLAUDE_PROJECT_DIR/scripts/changelog-order" ]; then
    changelog_note "this branch changed the changelog ($changelog_touched) and scripts/changelog-order is missing or not executable in this checkout"
  else
    # No pipe between the command and the exit code that gets reported (CLAUDE.md, Claims and
    # evidence): a pipeline reports the LAST command's status, and three people on SONNY-127 read
    # a zero that belonged to something else.
    changelog_output="$("$CLAUDE_PROJECT_DIR/scripts/changelog-order" 2>&1)"
    changelog_exit=$?
    case "$changelog_exit" in
      0) : ;;
      2)
        changelog_block="$(printf 'Stop hook: the changelog is out of order, and this branch changed it (%s).\n\n%s\n\nThat is scripts/changelog-order speaking. WORKFLOW.md step 7 and the changelog own Entry\nTemplate preamble say where an entry goes and why the file has two eras. Fix it before finishing.\n' \
          "$changelog_touched" "$changelog_output")"
        ;;
      *)
        # Quotes and newlines are stripped because this string is interpolated into the JSON above.
        changelog_note "this branch changed the changelog ($changelog_touched) and scripts/changelog-order exited $changelog_exit without measuring: $(printf '%s' "$changelog_output" | tr -d '"\\' | tr '\n\t' '  ' | cut -c1-200)"
        ;;
    esac
  fi
fi

# Whichever way this hook leaves, the findings above leave with it. Every `exit 0` below goes
# through here, so a changelog finding cannot be lost to the Swift fast path — which is the path
# a docs-only branch, the exact branch that writes an entry, takes every single time.
finish_hook() {
  if [ -n "$changelog_block" ]; then
    printf '%s\n' "$changelog_block" >&2
    exit 2
  fi
  exit 0
}

if [ "$stop_hook_active" = "true" ]; then
  # Already blocked once this turn, so nothing here may block again. The finding still has to
  # reach somebody: the abandoned-mutant arm above takes the same shape, and for the same reason.
  if [ -n "$changelog_block" ]; then
    printf '{"systemMessage": "The changelog is out of merge order and this hook has already blocked once, so it is letting this turn end. Run scripts/changelog-order and fix the entry it names."}\n'
  fi
  exit 0
fi

changed=$(git -C "$CLAUDE_PROJECT_DIR" status --porcelain -- '*.swift' 2>/dev/null)
if [ -z "$changed" ]; then
  finish_hook
fi

# A dirty tree says Swift changed, not that THIS session changed it. With two sessions in
# one checkout (coordinator + implementer, 2026-08-20) this hook fired on a neighbour's
# mid-edit tree three times, once racing its live build. So: consult the session's own
# transcript, and skip quietly when this session authored no Swift edit. A missing or
# unreadable transcript falls through to the old behaviour — the guard fails closed for
# the sessions it exists to guard. (SONNY-194)
transcript=$(echo "$payload" | jq -r '.transcript_path // empty')
if [ -n "$transcript" ] && [ -r "$transcript" ]; then
  session_swift_edits=$(jq -r '
      .message.content[]?
      | select(type == "object" and .type == "tool_use")
      | select(.name == "Edit" or .name == "Write" or .name == "MultiEdit" or .name == "NotebookEdit")
      | .input.file_path // empty
    ' "$transcript" 2>/dev/null | grep -c '\.swift$')
  if [ "${session_swift_edits:-0}" -eq 0 ]; then
    finish_hook
  fi
fi

test_output=$(cd "$CLAUDE_PROJECT_DIR" && env CLANG_MODULE_CACHE_PATH="$CLAUDE_PROJECT_DIR/.build/clang-module-cache" swift test --disable-sandbox \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib 2>&1)
test_exit=$?

if [ $test_exit -ne 0 ]; then
  printf 'Swift source changed this session but the required test suite is failing. Fix before finishing:\n%s\n' "$(echo "$test_output" | tail -60)" >&2
  [ -n "$changelog_block" ] && printf '\n%s\n' "$changelog_block" >&2
  exit 2
fi

finish_hook
