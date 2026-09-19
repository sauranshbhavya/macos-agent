### `fix/a-wait-is-a-poll-not-a-threshold` owes no rows, and here is why (2026-09-18, SONNY-515, SONNY-418)

**Both tickets change tests and nothing else.** SONNY-515 changes how the test harness waits on the
stub backend and how a mutation battery reads a wait that gave up; SONNY-418 moves four test
fixtures onto the machine's own time zone. Nothing under `Sources/`, `Package.swift` or `server/`
changes on this branch (`git diff --name-only 30ef8c12 HEAD -- Sources Package.swift server`,
against the `main` it was rebased onto, prints nothing), so there is no app behaviour for a
founder to check in the app.

What a founder can run instead, if they want to see SONNY-418's property for themselves, is the
routine suites under a zone that is not Eastern. They failed there before this branch and pass on
it:

```
TZ=Asia/Kolkata env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  --filter 'ScheduledRoutineRunTests|MemoryCommandCenterTests|ResumableTaskRunTests|BackendTaskIdentityTests'
```
