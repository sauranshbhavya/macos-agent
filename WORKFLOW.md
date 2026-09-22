# Delivery workflow

This is the current contributor workflow. [AGENTS.md](AGENTS.md) holds the few standing engineering rules. The previous ticket and review procedure is preserved as [historical context](docs/archive/WORKFLOW-v2-2026-09.md); it is no longer a gate for new work.

## Start with the outcome

For a small change, use the request or PR description to state the problem and expected result. For substantial, coordinated, or risky work, use a Plane issue with the outcome, constraints, and acceptance checks. Do not require a ticket, preapproved file list, mutation plan, or separate planning branch for an ordinary edit. Resolve genuinely unclear product behavior with the user before implementing the dependent part.

Work on a branch. Use a separate worktree when parallel changes might collide. The implementer may commit, push their branch, and open a PR. Founders decide when to merge.

## Verify proportionately

The normal loop is build, run focused behavioral tests for changed behavior, inspect the result, and review the diff. Stop optional verification once there is enough evidence for the change. A feature touching several files does not by itself require the full suite or a second person rerunning the same tests. Run the full relevant suite when a shared execution or safety change affects many features, before a major cutover or release, or to resolve a concrete remaining risk. Automated CI may run it more often without requiring a person to repeat it locally. Do not make a test count or warning count a product acceptance criterion.

The app and server have separate checks:

```sh
swift build
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Use `--filter` on that Swift test invocation while iterating. The extra flags are required on the documented local Command Line Tools installation. For server changes, run the relevant commands from `server/`: `npm run build`, `npm run typecheck`, `npm test`, and DB-backed tests when database contracts change. Follow [server/README.md](server/README.md) for an isolated test database. A Swift-only change does not require starting Postgres or running the server suite.

Run `server/scripts/check-secrets.sh` for changes that add or edit tracked content. Run `scripts/warnings` when checking compiler-warning claims or preparing a release; ordinary builds still surface warnings in the files they compile. Use mutation testing only to answer a specific test-quality question. Existing plans and battery tooling remain available but new per-change plans are optional.

Automated tests do not replace a packaged-app smoke check when behavior depends on macOS permissions, focus, Accessibility, Apple Events, screen capture, or real input. Capture the check in the PR or substantial Plane issue. There is no required per-branch manual-test file.

## Review and record

Review the actual diff. A small docs, copy, or localized change can receive a direct review. Ask for an independent, deeper review of changes that can lose data, spend money, send externally, weaken approval or permissions, alter privacy/retention, or move a trust boundary. Fix defects found in the change before merge, or explicitly record an agreed follow-up.

Use the PR and issue for implementation history. Write a short decision record only for a durable architectural or product choice; put it near the relevant documentation. `docs/changelog/` and `docs/manual-tests/` are historical branch records and no longer need a file for each new branch. `scripts/changelog-order read` and `scripts/changelog-order manual-tests` remain for browsing past work. Its old completeness check still expects a file for every merged branch and is not a gate for new work. The v1 spec and old workflow are references, not current instructions.

At a cutover, verify retained feature behavior and saved-data compatibility, run the full relevant suites, perform affected signed-app smoke checks, and remove replaced execution paths and temporary adapters. A release may need broader packaging, hosting, privacy, and security checks appropriate to its changed surface.
