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
