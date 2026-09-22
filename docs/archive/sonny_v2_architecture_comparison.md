> Archived V2 comparison from the 2026-09-22 review. It describes earlier drafts and is not the active plan. See [current direction](../../sonny_v2_architecture_implementation_plan.md). Some relative links below were written when this file was at the repository root.

# Sonny architecture: fresh comparison and simplification decision

Reviewed on 2026-09-22 against repository HEAD `336959ca`.

Compared the first repo-aware revision of the implementation plan with [plan 1](sonny_v2_architecture_implementation_plan_1.md). Plan 1 matches the original pre-review draft. The first revision was later replaced by the current root plan; “first revision” below refers to its earlier migration-oriented approach.

## Recommendation

Rewrite the execution core around one explicit runtime owner and typed intents. Preserve user-facing features and durable user data, except for the confirmed retirement of workspaces, while treating existing classes, tests, file organization and process conventions as replaceable implementation choices.

The original draft has a better instinct for the destination. The first revision has a more accurate inventory and better failure semantics. Neither is sufficient unchanged: the original proposes too much infrastructure, while the first revision risks preserving the architecture that needs replacing.

## Direct comparison

| Decision | Plan 1 | First repo-aware revision | Recommended direction |
|---|---|---|---|
| Main strategy | New runtime architecture | Incremental facade over existing execution | New execution core with a bounded transition and explicit deletion gates |
| UI ownership | Thin view model | Extract only what the next feature needs | Thin view model immediately for the new path; all entry points eventually submit to one runtime |
| Plan model | Replace `AgentPlan` with goal units | Retain current plan shape internally at first | Separate untrusted wire DTO, validated intent, resolved action and result; old formats survive only at boundaries |
| Backend routing | Native → scripting → AX → vision | Same preference using existing implementations | Keep this; one selector and one action loop, not a hierarchy of competing engines |
| Arbitrary-app support | AX and later CUA | Add AX while reusing current vision | Generic AX goals without an app allowlist of adapters; typed scripts optimize known workflows |
| Approval | New effect engine and commit barrier | Extend existing policy classes | Preserve required approval behavior; rewrite policy into one effect-based decision path if that is simpler |
| Verification | Expected state and retry ladder | Adds explicit uncertain outcomes and replay restrictions | Keep independent verification and never replay uncertain non-idempotent commits |
| Context | Continuous desktop model and warm frames | Start on demand | On-demand target snapshots; no always-on context subsystem until measurements justify it |
| Concurrency | Runtime/session actors plus UI lane | Grow current `RunSlot` model | Concurrent independent user tasks; one agent context per task, shared resource/foreground ownership, no focused-run fallback |
| Models | Dedicated local decision model/sidecar later | Deferred experiment | Exclude sidecar and training pipeline from this implementation |
| Existing features | Largely omitted from migration details | Preserve existing features and much of their machinery | Preserve features; rehost them as clients of the new core, with temporary edge adapters only |
| Testing/process | Generic unit/integration/replay lists | Inherits existing workflow checks | Outcome-based contracts, focused tests, one full relevant suite at cutover; specialized tooling optional |

## What is actually making this repository difficult

Line counts alone do not prove poor design; these include substantial comments. The responsibilities explain why the size matters. Measurements below were taken from this checkout at the revision above.

| Evidence | Actual issue | Proposed replacement |
|---|---|---|
| [AgentViewModel.swift](../../Sources/MacAgent/AgentViewModel.swift), 9,547 lines | UI, dispatch, lifecycle, approvals, voice, scheduling, history and construction share an owner | Presentation model plus a runtime that exclusively owns execution |
| [AgentActionExecutor.swift](../../Sources/MacAgentCore/AgentActionExecutor.swift), 2,839 lines | Preparation, many feature dependencies, policy, chains and storage are coupled | Intent resolution, backend dispatch and result recording with small boundaries; avoid a class for every helper |
| [AgentPlan.swift](../../Sources/MacAgentCore/AgentPlan.swift), 1,015 lines | Planner DTO is also mutated into trusted runtime state; many unrelated optional fields | Separate DTO/intent/resolved-action types with payloads specific to each case |
| [RunSlot.swift](../../Sources/MacAgent/RunSlot.swift) and view-model forwarding | Task-local lookup can fall back to the currently focused run | Explicit run identity on commands and callbacks; UI focus has no execution authority |
| [MacAgentSourceScan.swift](../../Tests/MacAgentTests/MacAgentSourceScan.swift) and source-scan suites | Some tests couple to spelling, source layout and call placement | Behavioral seams and contract tests; retain only justified structural scans |
| [WORKFLOW.md](../../WORKFLOW.md), 1,592 lines; [CLAUDE.md](../../CLAUDE.md), 501 lines | Day-to-day contributor rules are mixed with historical/process detail | Short current contributor guide; historical decisions and operator procedures outside the inner loop |
| [scripts/mutate](../../scripts/mutate), 4,204 lines; [scripts/mutate-all](../../scripts/mutate-all), 1,754 lines | A specialized test-quality system has a large maintenance surface | Optional maintainer tool; no required mutation artifact for each feature |

There are 33 files matching `mutation/plans/**/*.txt` in this checkout. The current workflow already moved mutation execution to a manually triggered weekly battery. It is inaccurate to say mutations currently run on every change. The remaining concern is mandatory process/artifact overhead and maintaining a large bespoke toolchain.

Mutation testing can catch weak tests. It is not a substitute for testing that a cancelled action never sends input, a changed recipient invalidates approval, or a private task leaves no retained content. Keep useful testing ideas without making the new runtime conform to old text substitutions or source scans.

## Keep, rewrite, retire, defer

**Keep behavior and useful leaf implementations:** deterministic utilities, native file/EventKit/Shortcuts integrations, script templates, screen capture and coordinate handling, redaction, encryption, gateway auth/accounting, final approval, private mode, and user data. These are assets to inspect and port, not classes that must remain unchanged.

**Rewrite:** orchestration, approval ownership, plan resolution, mutable run state, dependency assembly, and the contract between the UI and execution. Consolidate duplicate decision paths rather than wrapping them in another engine.

**Retire after replacement:** old view-model execution methods, task-local execution routing through UI focus, mixed trusted/untrusted runtime plan representation, duplicate policy paths, temporary legacy executors, obsolete source-layout tests, mandatory per-change mutation plans, and obsolete procedural hooks. Remove a test or script only after identifying whether it protects a behavior that still needs a replacement check.

**Defer:** always-on desktop observation, warm screen streaming, local model sidecars, model training datasets, ghost cursor and a new all-encompassing module taxonomy. Existing scheduling and routines stay supported. Workspaces are removed. Separate user tasks run concurrently; collaborative subagents are not part of this release.

## The smallest useful architecture

```text
Widget / voice / routines / schedule / retry
                          |
                   RunRequest(runID)
                          |
                     AgentRuntime
             owns state, cancellation, approval
                          |
                 validated typed intent
                          |
        resolve -> prepare -> approve if required
                          |
           native / typed script / AX / vision
                          |
                    verify -> result
                          |
               presentation + persistence
```

`AgentRuntime` owns a bounded collection of independent `RunState` values, one per user task. Task work progresses concurrently; foreground or conflicting resource actions pass through shared ownership. It does not need a separate actor for `RunSession`, router, context, policy and verifier. Use pure functions for policy and selection; use protocols at actual OS, model, storage and clock boundaries. Keep AppKit/AX isolation explicit rather than pretending every existing object is `Sendable`.

The backend/model may propose an action. It cannot approve itself or directly dispatch an OS event outside the shared gate. One runtime loop owns approval and recovery even when vision supplies the proposed action.

## Feature parity without preserving the mess

The user confirmed that existing user-facing features stay except workspaces, which are removed. Enumerate retained contracts before cutover: typed/voice entry, instant utilities, file workflows, research/media, screen control, routines/scheduling, follow-ups/resume, history/artifacts, notifications, settings/private mode, permissions and accounts/billing integration. Multi-agent support means separate quick user tasks concurrently, not agents collaborating within one task.

Port those features as clients or operations of the new core. A schedule submits a request; it does not own a second runner lifecycle. Voice produces a command; it does not write arbitrary run state. History consumes explicit outcomes; it does not infer completion from UI fields.

Preserve saved routines and other durable data through versioned readers or one-time migrations. Retire workspace UI/operations while preserving old workspace records for export/migration and historical tags for reading. Resolve workspace references in saved/resumable data without widening authority or deleting unrelated data. That does not require preserving the legacy in-memory model. Old resumed tasks must revalidate and request fresh commit approval. Never erase user state to simplify a rewrite.

Use temporary adapters only with a named replacement and removal gate. Do not run both implementations against real external actions for comparison: compare prepared intents or use fakes, then route each live request to exactly one implementation.

## Lean validation and definition of cleanup

The ordinary loop is: build, run focused behavioral tests, inspect the result. At a cutover, run the full relevant suite and signed-app smoke checks for affected OS behavior. Server tests and a database are required when server contracts change, not for every Swift edit. Mutation campaigns and cold-build warning audits belong in optional maintenance/release work.

The rewrite is complete when every feature entry point uses the same lifecycle, no UI object owns execution authority, new operations do not add dependencies to a giant central initializer, trusted actions cannot be decoded from model text, and obsolete runtime paths and their scaffolding have been deleted.

This review changes the plan, not the application or its workflow tooling. Actual code/tool deletion belongs to the implementation work and its parity checks.
