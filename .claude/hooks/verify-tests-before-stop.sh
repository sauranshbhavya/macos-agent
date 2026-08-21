#!/bin/bash
# Stop hook: if Swift source changed this turn, the required test suite must pass
# before Claude can finish. Skips fast when nothing Swift changed. Never loops:
# stop_hook_active means this already blocked once, so let it end this time.

payload=$(cat)
stop_hook_active=$(echo "$payload" | jq -r '.stop_hook_active // false')

if [ "$stop_hook_active" = "true" ]; then
  exit 0
fi

if [ -z "$CLAUDE_PROJECT_DIR" ]; then
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
