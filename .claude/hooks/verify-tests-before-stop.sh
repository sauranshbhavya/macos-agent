#!/bin/bash
# Stop hook: if Swift source changed this turn, the required test suite must pass
# before Claude can finish. Skips fast when nothing Swift changed. Never loops:
# stop_hook_active means this already blocked once, so let it end this time.

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
      battery_journal "stop-hook" "did not run the suite: a battery holds this checkout (pid ${BATTERY_PID:-unknown})"
      {
        printf 'Stop hook: the test suite was NOT run.\n\n'
        printf 'A mutation battery is running in this checkout, so the tree is mid-mutant and any\n'
        printf 'suite result would describe a deliberately broken file rather than this branch.\n\n'
        battery_state_detail
        printf '\nNothing here says the suite passes. Re-run it once that battery finishes.\n'
      } >&2
      # Also to the user, and to a file, so a skipped check is not a silent one.
      printf '{"systemMessage": "Stop hook skipped the test suite: a mutation battery (pid %s) holds this checkout, so any result would be about a mutant. The suite has NOT been run."}\n' \
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
fi

if [ "$stop_hook_active" = "true" ]; then
  exit 0
fi

changed=$(git -C "$CLAUDE_PROJECT_DIR" status --porcelain -- '*.swift' 2>/dev/null)
if [ -z "$changed" ]; then
  exit 0
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
    exit 0
  fi
fi

test_output=$(cd "$CLAUDE_PROJECT_DIR" && env CLANG_MODULE_CACHE_PATH="$CLAUDE_PROJECT_DIR/.build/clang-module-cache" swift test --disable-sandbox \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib 2>&1)
test_exit=$?

if [ $test_exit -ne 0 ]; then
  printf 'Swift source changed this session but the required test suite is failing. Fix before finishing:\n%s\n' "$(echo "$test_output" | tail -60)" >&2
  exit 2
fi

exit 0
