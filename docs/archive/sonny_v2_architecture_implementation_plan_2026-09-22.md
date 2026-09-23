> Archived intermediate V2 plan recovered from the local session transcript. This is the detailed plan reviewed before the contributor-workflow simplification; see the current root plan for active direction.

# Sonny v2 Architecture and Implementation Plan

Reviewed against repository HEAD `336959ca` on 2026-09-22. This is a near-term implementation plan for a clean execution-core rewrite; “v2” does not imply a distant release. Existing internals are replaceable. Source links below are relative to this repository. Proposed types and interfaces are design sketches, not existing APIs or compilable patches.

See [the fresh comparison](sonny_v2_architecture_comparison.md) for the tradeoffs against [plan 1](sonny_v2_architecture_implementation_plan_1.md). The inventory below describes reusable evidence, not architecture that must be preserved.

## 1. Outcome and confirmed decisions

Deliver broader arbitrary-app automation using **osascript/native integrations and macOS Accessibility trees**, with the existing visual screen-control path as a fallback. Sonny should understand a goal, prefer semantic operations, verify the result, and minimize cloud calls and disruption to the user's desktop.

Confirmed during this review:

- Arbitrary-app automation is part of the upcoming implementation. Build it on a clean execution core, proving real workflows early rather than completing an abstract framework first.
- Preserve existing user-facing features while freely replacing their internals, with one confirmed exception: remove workspaces from the future UI and runtime. Preserve existing saved workspace data for migration/export.
- Support separate user tasks concurrently, with one agent execution context per task. Optimize for quick tasks; collaborative child agents, recursive delegation and agent teams are out of scope. Concurrent tasks share desktop/resource ownership.
- Consequential actions always require a fresh approval immediately before committing, even if the initial command explicitly requested the action.
- Use reviewed, typed osascript templates and generic AX for unfamiliar apps; do not generate arbitrary scripts.
- M1 with 8 GB RAM, Developer ID distribution, and a local-model sidecar are provisional product assumptions. Do not make a Python sidecar a release dependency.

“Arbitrary app” means no fixed catalog is required to attempt semantic discovery of a non-refused application. It does not promise that every application exposes a useful AX tree, implements scripting, or permits background interaction. Unsupported, ambiguous, and unobservable actions must produce an honest limitation or takeover request.

Preserve the repository's fixed-template boundary: typed osascript adapters for scriptable workflows, generic AX discovery/actions for unfamiliar apps, existing visual fallback when semantics are unavailable. A general script evaluator is outside this plan.

## 2. Current implementation: what to reuse

The original draft described several existing features as greenfield work. This baseline distinguishes implemented behavior from gaps.

| Area | Current repository evidence | v2 change |
|---|---|---|
| App/platform | [Package.swift](../../Package.swift): Swift 6 package, macOS 14 minimum, `MacAgent` executable and `MacAgentCore` library | Keep target boundaries; benchmark provisional hardware separately |
| Orchestration | [AgentViewModel.swift](../../Sources/MacAgent/AgentViewModel.swift): `start`, `performStart`, approval, voice, scheduled runs, follow-ups, workspace scope, history | Replace with a presentation adapter; execution has one explicit owner |
| Run identity | [RunSlot.swift](../../Sources/MacAgent/RunSlot.swift): `RunID`, `RunScope`, `ApprovalTarget`, per-run state and fresh approval tokens | Carry identity through explicit requests; replace UI-focused task-local execution routing |
| Concurrency | Production still has one slot; `addRunSlotForTests()` creates additional slots only in tests | Design task/resource ownership explicitly rather than building on slot forwarding |
| Plans and registry | [AgentPlan.swift](../../Sources/MacAgentCore/AgentPlan.swift), [ToolRegistry.swift](../../Sources/MacAgentCore/ToolRegistry.swift), [DefaultCapabilityAdapters.swift](../../Sources/MacAgentCore/DefaultCapabilityAdapters.swift) | Keep old formats readable at boundaries; replace the internal execution representation |
| Fast paths | [InstantCommandResolver.swift](../../Sources/MacAgentCore/InstantCommandResolver.swift), direct/prebuilt plans, routine/workspace dispatch | Keep zero-model paths; add a backend router beneath validated task intent |
| Execution and approval | [AgentRunner.swift](../../Sources/MacAgentCore/AgentRunner.swift), [AgentActionExecutor.swift](../../Sources/MacAgentCore/AgentActionExecutor.swift), [RiskApproval.swift](../../Sources/MacAgentCore/RiskApproval.swift) | Preserve verified policy behavior; consolidate it into one action gate with exact commit binding |
| Native work | Fixed Finder/Word scripts, file adapters, EventKit, Shortcuts, safe URL/app opening | Wrap and extend these integrations; do not replace EventKit with calendar scripting |
| Visual computer use | [VisionSessionRunner.swift](../../Sources/MacAgentCore/VisionSessionRunner.swift), [VisionSessionCapabilityAdapter.swift](../../Sources/MacAgentCore/VisionSessionCapabilityAdapter.swift), [VisionSessionContainment.swift](../../Sources/MacAgentCore/VisionSessionContainment.swift) | Reuse capture–decide–authorize–act, journal, attention checks, and delegation |
| Capture/input | [ScreenCaptureService.swift](../../Sources/MacAgentCore/ScreenCaptureService.swift), [ScreenActionSynthesizer.swift](../../Sources/MacAgentCore/ScreenActionSynthesizer.swift) | Existing target-window ScreenCaptureKit screenshots and real CGEvents; add semantic AX execution |
| Accessibility | Trust checking exists; generic AX tree traversal, AX actions and AX observers do not | This is the main new execution capability |
| Results | [AgentEvent.swift](../../Sources/MacAgentCore/AgentEvent.swift): `AgentRunResult`; [StoredTaskResult.swift](../../Sources/MacAgentCore/StoredTaskResult.swift); [TaskReceiptView.swift](../../Sources/MacAgent/TaskReceiptView.swift) | Add verified evidence/artifact actions while preserving summary provenance and receipts |
| Persistence/privacy | Encrypted stores, [TaskRecordingPolicy.swift](../../Sources/MacAgentCore/TaskRecordingPolicy.swift), [LocalStoreClassification.swift](../../Sources/MacAgentCore/LocalStoreClassification.swift), resumable task records | New traces/context must honor private mode, memory settings, deletion, and retention |
| Hosted services | [SonnyModelGateway.swift](../../Sources/MacAgentCore/SonnyModelGateway.swift), [SonnyBackendClient.swift](../../Sources/MacAgentCore/SonnyBackendClient.swift), `server/` | Preserve auth, task IDs, retention, metering, request limits, screen-control gates |

The concurrent-run changelog explicitly documents **the first layer only**, not completed multi-run behavior: [more-than-one-run-at-once.md](../../docs/changelog/feature/more-than-one-run-at-once.md). `RunSlot` also lists shared ownership and callback hazards still to resolve.

Current approval is more than a tier table. `RiskApprovalPolicy` combines consequence classifications with Safe/Normal/Power and per-app standing. `VisionConsequenceClassifier` supplies mid-loop classifications. `AgentRunner.execute` reassesses consent before execution. Run/token binding rejects stale answers, but does not yet prove that the exact recipient, content, document, or UI target remains unchanged.

Current results are more than `finalSummary: String`: `AgentRunResult` carries previews, suggestions, provenance and item-job failures; the wider pipeline includes recent-artifact storage, stored results and receipt presentation. `copySummary()` is a small presentation concern, not an architectural prerequisite.

## 3. Architecture and execution order

```text
Widget / voice / direct action / routine / resumed task
                         |
              Task request + explicit identity
                         |
             AgentRuntime / task coordinator
                         |
     instant or prebuilt plan / existing hosted planner
                         |
           Validated typed intent + resource scope
                         |
                 Semantic backend router
                         |
       Existing capability / direct native API
                         |
           Typed osascript app adapter
                         |
         Generic AX tree query and action
                         |
         Existing visual session fallback
                         |
           Reobserve and verify postconditions
```

Every backend action follows this order:

```text
fresh target observation -> policy assessment -> prepare exact action
      -> if consequential: preview + fresh approval
      -> reacquire UI ownership if needed + revalidate exact state
      -> execute once -> verify -> receipt / next bounded action
```

The commit barrier belongs **before** the effect. Verification after execution never substitutes for authorization.

Backend preference is conditional on support, permissions, required effects, scope, and verification quality. An unsupported scripting command should proceed to AX without first executing a speculative script. A denied permission, refusal, scope violation, or ambiguous previous commit must not be treated as permission to try another backend. A script failure after the target may have acted also requires reconciliation before any AX fallback.

Keep planning and backend selection distinct. Existing typed operations already express many useful intents; a cloud planner need not select every AX element or decide which script implementation runs.

## 4. Clean target: one owner of execution authority

Replace the orchestration core. Do not stack `AgentRuntime` permanently on top of `AgentViewModel`, `AgentRunner`, and `AgentActionExecutor` while leaving each responsible for approval and cancellation.

The target has five responsibilities, not necessarily five services or actors:

1. **Presentation:** a thin view model submits requests and renders independent task snapshots. UI focus never selects the execution owner.
2. **Runtime:** `AgentRuntime` owns independent task sessions, admission limits, cancellation, budgets, approval and terminal outcomes. Each task has one agent context; no parent/child agent hierarchy is needed.
3. **Typed intent and action preparation:** validate untrusted requests, resolve exact resources, propose concrete actions, and classify effects.
4. **Automation backends:** native capabilities, reviewed script templates, generic AX and visual proposals behind narrow OS/model boundaries.
5. **Persistence/integrations:** record explicit outcomes and preserve settings, history, routines, account/gateway behavior and retained data contracts.

Use pure functions for backend selection and policy where possible. Introduce a protocol for an OS/model/storage/clock boundary or genuinely interchangeable behavior, not for every helper. `RunState` should start as a value owned by the runtime, not actors with independent lifecycles.

An actor is suitable for runtime bookkeeping if its dependencies have explicit isolation boundaries. AppKit and AX handles remain with their appropriate owner; do not add unchecked `Sendable` conformances to force the design. Actor reentrancy is not a transaction: after an await, recheck state/version before authorizing an action. Blocking OS calls and model requests must not block UI rendering.

Every retained entry point submits the same request contract: composer, voice, instant utility, routine, schedule, follow-up, retry and resume. Voice produces a command, a schedule produces a request, history receives an outcome. None owns another execution loop.

Required states include queued, routing/planning, observing, executing, waiting for permission/clarification/approval, paused, completed, failed, cancelled and outcome-unknown. Terminal states are one-way. Every callback names its task, action when applicable, and state generation. A late reply cannot write into the focused task or revive cancelled work.

A temporary legacy bridge may help move one feature at a time, but it has a named removal gate. New code does not depend on `RunSlot`, `RunScope.current ?? focusedRunID`, or mutable UI properties for authority. Before final cutover, delete the old orchestration paths and duplicate approval owners.

## 5. Typed data: separate intent, authority and persistence

Replace the current mixed planner/runtime representation. `AgentPlan` is a legacy wire/storage DTO at the boundary, not the new core model.

```text
Untrusted PlanDTO / user request / saved routine
                   |
             validate + normalize
                   |
          TaskIntent / typed goal steps
                   |
     resolve current targets and permissions
                   |
              PreparedAction
                   |
     policy + exact approval when required
                   |
            execution + evidence
```

Use small payload types rather than one step containing many unrelated optional fields:

```swift
enum TaskStep {
    case operation(TypedOperation)
    case interaction(InteractionGoal)
}
```

An `InteractionGoal` contains a target app reference, objective, completion criteria, permitted resources/effects and bounded effort. A `PreparedAction` contains the live resolved target, concrete backend action and preconditions. The model can propose an intent, never construct an approval token, trusted app identity or verified result.

Represent native utilities and other retained features as typed operations. Expose one validated generic interaction-goal entry point for unfamiliar apps; do not add a planner tool for every AX role, app, script template or button. Native/script/AX/vision selection stays internal.

Keep old saved routines, history and settings readable through versioned readers or explicit migrations. Compatibility belongs at the edge and must not dictate the internal state model. If planner schema changes, update Swift decoding, gateway validation and fixtures together. A storage reader may remain indefinitely where needed for user data; a second legacy execution engine may not.

Resumed tasks recover remaining intent and re-prepare it. They cannot reuse old AX handles, coordinates, runtime generations or approvals. No data wipe is part of this rewrite.

## 6. Typed osascript integrations

Reuse [FinderContextService.swift](../../Sources/MacAgentCore/FinderContextService.swift), [DocumentConverter.swift](../../Sources/MacAgentCore/DocumentConverter.swift), [AsyncProcessRunner.swift](../../Sources/MacAgentCore/AsyncProcessRunner.swift), and [ShortcutsBridgeService.swift](../../Sources/MacAgentCore/ShortcutsBridgeService.swift).

`osascript` is an execution mechanism, not a semantic API on its own. The backend accepts a typed operation, selects a reviewed script template for a resolved app, passes validated data, executes with a bounded lifetime, and verifies the result. App support is explicit; launching an app does not prove that it implements a scripting dictionary.

Initial adapters:

1. Preserve Finder selection and Word conversion as compatibility cases.
2. Add one useful Mail workflow: create draft, populate exact recipients/body, attach a resolved file, verify draft, and separately approve/send.
3. Add a browser observation/operation adapter where scripting support is demonstrated; retain existing URL-opening behavior for all other cases.

Use native filesystem and EventKit APIs where already supported. Do not duplicate those with AppleScript just to exercise the new backend.

Template arguments must remain data; never concatenate untrusted AX text, filenames, or model text into executable script source without a rigorously tested encoding boundary. Capture structured output and classify permission denial, unsupported operation, timeout, application failure, and uncertain execution separately. Cancellation must not imply rollback of a script already accepted by the target app.

Permission prompts are target-specific. Extend readiness reporting and test the signed application path; a successful Terminal-launched probe is not release evidence. Preserve the hardened-runtime and packaging assumptions documented in [MacAgent.entitlements](../../Packaging/MacAgent.entitlements) and [package-app.sh](../../scripts/package-app.sh).

## 7. Generic Accessibility discovery and execution

Build the missing AX semantic layer as a bounded observe/query/act/verify loop.

### Observation

Start with the resolved target application's focused or selected window, not the entire desktop. Produce immutable snapshots with:

- App bundle ID, process identity, window identity and observation generation/time.
- Element role, subrole, identifier if present, title/description, enabled/focused state.
- Supported actions, settable attributes, bounds, and a redacted value when needed.
- Parent/path hints and a completeness marker when traversal is truncated.

Bound traversal by node count, depth, text budget, and deadline. Lazy or incomplete AX support is an expected result. Permission denial, timeout, stale element, empty tree, and inaccessible content are distinct observations.

Keep `AXUIElement` handles inside the provider's controlled isolation domain. Export snapshot values and opaque references scoped to a process/window/generation; a model-visible ID is not a durable identity or authority to act.

### Candidate generation

Deterministically filter candidates using objective, role, title, supported actions, enabled state, and target scope. Rank a small set before asking a model to choose. Repeated labels, missing labels, or uncertain matches trigger a narrower observation, visual grounding, or clarification.

Treat all AX labels and values as untrusted content. A button labelled “ignore previous instructions” is observation data. It cannot change the user goal, permissions, approval policy, or allowed resources. Reuse [UntrustedContentBoundary.swift](../../Sources/MacAgentCore/UntrustedContentBoundary.swift).

### Actions

Initial actions: query, press, set a supported value, focus/select, and navigate a menu. Check supported actions/settable attributes before invocation. Re-resolve the target and validate its generation immediately before mutation.

A semantic action is not automatically safe: pressing Return, selecting a destructive menu item, changing a shared document, or editing an autosaved field can commit effects. Classify using operation semantics and available local context; uncertain consequential effects stop for approval or takeover. Label heuristics alone cannot prove that arbitrary UI actions are harmless.

Start with on-demand observation. Add `AXObserver` notifications and small caches after the first end-to-end workflow works. Invalidate on process/window changes, navigation, observer loss, permission changes, and user interference. Notifications improve freshness but do not replace pre-action validation.

## 8. Context and screen observation

A lightweight `ContextEngine` composes existing app/focus/Finder/clipboard seams and the new AX provider. Cache cheap metadata first: app/process, window, observation age, permissions, and run ownership.

Selection text, clipboard content, AX values, and screenshots are sensitive task content. Fetch only when needed for the current goal. Existing clipboard concealed/transient filtering and memory preferences must remain effective. Do not silently add continuous text or screen collection.

Snapshots explicitly report freshness, provenance, and unavailable fields. Revalidate expensive or mutable fields before executing; cached context is a routing hint, not commit evidence.

Reuse `ScreenCaptureService` for target-window screenshots. It already implements window selection and live window resolution. Preserve window geometry, display scale and coordinate conversion in `ScreenActionSynthesizer`.

A warm ScreenCaptureKit stream, region capture, and persistent “latest frame” are optional optimizations after profiling. They require bounded memory, idle suspension, permission-loss cleanup, and evidence that they improve latency without unacceptable battery cost. Do not require a warm stream for the first AX release.

All visual egress continues through [LocalRedactionService.swift](../../Sources/MacAgentCore/LocalRedactionService.swift) and [RedactedCaptureEncoder.swift](../../Sources/MacAgentCore/RedactedCaptureEncoder.swift). Crop/resample changes must preserve redaction-before-egress and accurate coordinate mapping. New AX text egress needs its own explicit minimization/redaction path; image redaction does not sanitize semantic text.

## 9. Approval policy and exact commit binding

Implement one effect-based policy authority used by native, osascript, AX, and visual execution. Existing consequence/policy tests provide behavioral requirements, but the `RiskApprovalPolicy` class and tier representation are replaceable. Do not retain both an old and a new authority permanently or create a policy table in each backend.

Preserve Safe mode's stricter floor, app-control standing, per-task resource scope, terminal refusal, unattended-run restrictions, and screen-control entitlement/allowance checks. Power mode must not bypass consequential-action approval.

Use an effect vocabulary that maps to existing escalations: read-only, local reversible change, destructive change, external communication, shared-data mutation, financial commitment, installation/security change, and credential submission. Unknown effects require a conservative decision rather than automatic execution.

`PreparedCommit` extends existing run/token addressing with:

- Run ID, new single-use commit ID, exact operation and effect.
- Exact recipient/account/destination and document/file/attachment identity.
- Content digest and user-visible preview of the actual effect.
- Target process/window/element identity and relevant observed state.
- Scope/permission/consent revision, creation time, and bounded expiry.

Approval is valid for one exact commit only. Before executing, reacquire required ownership, reread relevant state, verify target/content/scope, atomically consume the token, and execute once. Any material change invalidates it and creates a new preview. Token consumption is atomic only within local state, never with the external application effect. A crash or timeout after consumption transitions to outcome-unknown; recovery must not infer success or replay from the token alone. Approval of the whole task is not approval for later sends or deletes.

Avoid fingerprinting irrelevant UI pixels: blinking carets and animations should not repeatedly invalidate a valid draft. Bind to meaningful recipient/content/attachment state, while also confirming the UI target that will receive input. Since another process can change state between inspection and action, minimize that interval and report the residual limitation; fingerprints are not an OS-wide transaction.

Approval UI can change foreground focus. Return to the pinned target, reobserve, and verify before sending input. Never execute against whichever app happens to become frontmost.

## 10. Verification, recovery, and uncertain outcomes

Every meaningful action has preconditions, expected postconditions, a verification method, timeout, and evidence. Use direct/native state before AX and visual evidence where available. Existing verified native adapters are the starting point, not work to discard.

Verification outcomes: satisfied, partially satisfied, failed, and indeterminate. A model saying “done” is not independent evidence. A closed Mail draft or changed screen alone does not prove successful delivery; report “send submitted” versus “sent/confirmed” according to what can actually be established.

Retry rules depend on effect:

- Reads and observations may retry within a small deadline.
- Idempotent writes may retry after checking current state.
- Append, send, purchase, deletion, and other non-idempotent commits must not replay after a timeout merely because success was not observed.
- Before switching backends, reconcile whether the previous action took effect.
- An unknown commit outcome pauses for reconciliation/takeover; a new backend must not duplicate it.

Initial bounded defaults should be explicit configuration: one fresh observation before retry, a small semantic-attempt budget, capped visual iterations/model calls, and at most one bounded replan before asking the user. Choose actual values from baseline measurements rather than treating these as universal constants.

Cancellation stops future actions and unwinds ownership/continuations. It cannot undo an external send or a native operation already committed. Record partial completion and uncertain effects honestly in the receipt.

## 11. Concurrent user tasks and shared desktop ownership

“Multi-agent” in this release means **separate user tasks running concurrently**, each with its own agent context. It does not mean splitting one quick task across collaborating agents. Do not build parent/child run trees, recursive delegation, a team planner or result-merging framework.

```text
Command A -> Task A: plan/observe/prepare -> action proposal -> result A
Command B -> Task B: plan/observe/prepare -> action proposal -> result B
Command C -> Task C: plan/observe/prepare -> action proposal -> result C
                         |
                Shared runtime services
           admission, resources, policy, approval
                         |
             native / script / AX / vision
```

Each task has immutable identity, command, origin, permitted resources, recording policy, usage budget and task-local cancellation/state. UI selection only chooses which task to display. One task's progress, error, approval or completion must never overwrite another's.

Task executors propose typed actions; shared runtime authority validates and dispatches them. A task cannot expand its scope, approve itself, inherit another task's approval or treat model/observed text as user authorization. Use task ID, action ID and commit ID; a separate agent ID is unnecessary while the relationship is one-to-one.

Stop-task cancels only that task's model work, queued resource requests and future actions, invalidates its approval and reconciles any in-flight effect. Other tasks continue. A failed/timed-out task never causes an uncertain commit to replay. Global emergency stop halts desktop input and makes affected task states explicit.

Start with a configurable default of two actively progressing tasks and at most eight unfinished tasks, as provisional implementation defaults to benchmark. Tasks waiting for approval/clarification are parked and release execution slots and resource leases; they still count toward the unfinished limit. Extra admitted tasks queue visibly; beyond the unfinished limit, reject the submission visibly without cancelling existing work. Resuming approval reacquires an execution slot and resources, then revalidates. Apply per-task model/action/time budgets. Round-robin or FIFO bounded action opportunities prevent one long task from starving quick tasks; do not implement a generalized scheduling framework. Scheduling fairness must respect a short indivisible UI sequence when releasing focus between its steps would be unsafe.

Independent planning, network I/O and nonconflicting native operations can progress concurrently. Foreground control remains serialized. This is concurrency across tasks, not simultaneous ownership of a single physical desktop.

### Resource ownership

A shared resource arbiter is the only route to mutation. Initially be conservative:

- One global foreground lease for focus, CGEvents, foreground AX actions and scripts that activate apps/open dialogs.
- Exclusive document/file/draft ownership for conflicting background mutations, even when they do not move the cursor. Use an app-wide lock when the operation depends on shared app state or disjoint targets cannot be established; independent verified targets need not serialize merely because they share an app.
- Concurrent reads only where they are valid under the current resource state; revalidate observations after another task writes.
- Deduplicate retries by exact task/action/commit identity and invalidate competing prepared actions when their resources change. Never merge separate user requests merely because they have similar intent or identical content; each still requires its own authorization.

Background-safe does not mean conflict-free. Two tasks editing the same draft through AppleScript still race. Avoid deadlocks with a single acquisition order or atomic all-required-resource acquisition; bound waits and allow cancellation of queued work.

Release resources while waiting for the user where possible, then reacquire and revalidate before acting. Keep prepared content and version, not a perpetual desktop lock. A lease cannot freeze another application or prevent physical user input, so observations still need freshness checks.

### User interference

Existing vision checks cover lock/sleep/idle/manual pause. Add physical input interference handling without recording keystroke content; distinguish synthetic events where possible. Pause unsafe sequences and reobserve before resuming. Preserve emergency stop, mouse-up on cancellation and explicit ownership cleanup on every exit.

The UI needs separate task progress/results, visible queued desktop access, pending approvals and per-task stop controls. A new composer submission starts a new task; it must not implicitly approve or cancel the selected task. Approval names the exact task/action and works even after selection changes. Follow-up/retry/resume explicitly name their task rather than inferring it from focus. Existing scheduled tasks use the same admission/resource rules and retain unattended-action restrictions.

The ghost cursor remains optional visualization. It does not supply action coordinates, authority or resource ownership.

## 12. Reuse the existing visual fallback

Reuse the existing CUA implementation where it is useful; do not build capture and coordinate handling from scratch. Adapt vision to produce bounded action proposals for the shared runtime gate. Preserve containment behavior, redacted payloads, Safe-mode previews, app pinning and pause/stop, but replace a nested approval/execution loop if it would create a second authority. Transitional delegation to the old vision runner has an explicit removal/consolidation gate.

Fallback is appropriate for absent/incomplete AX semantics, canvas content, or controls unsupported by a reviewed script. It is not a way around terminal refusal, denied authority, missing entitlement, or a failed commit.

Current browser capabilities mostly open URLs; they do not constitute a DOM automation engine. Safari/Chrome, webviews, and Electron need separate coverage. Embedded shells and unknown terminal applications remain a gap in an identity-based deny list; do not claim arbitrary-app automation solves that safety problem. Retain refusal and require takeover where shell-like effects cannot be constrained.

Do not batch Enter/Return with text entry by default. It can send, submit, or accept a dialog. Any action batch must be policy-checked action by action and stop before a consequential boundary or unexpected state transition.

## 13. Results, observability, and retention

Define one task result consumed by UI and persistence, per independent user task, with no cross-task summary overwrite. Existing `AgentRunResult`/`StoredTaskResult` supply useful fields and storage compatibility, but their runtime representation may be replaced. Preserve code/model/outside-authored provenance and the untrusted boundary when results reenter planning.

Build on existing recent-artifact storage and Open/Reveal suggestions; add verification evidence and Copy path where the result identifies a real artifact. Record completed units, partial effects, pending/unknown commits, and the evidence supporting the outcome. Keep `finalSummary` as presentation text, not the sole execution record.

Use existing run/task identities for structured events: route, backend selection, observation, action, approval requested/granted/invalidated, verification, retry, fallback, interference, cancellation and completion. Add timestamps and stage durations. Never log raw credentials, complete clipboard contents, unredacted screenshots, or an entire AX tree as routine telemetry.

Privacy must match the existing system:

- Local stores are encrypted and classified for retention/deletion. New stores join the same classification and wipe behavior; ephemeral context should normally remain memory-only.
- `TaskRecordingPolicy`, private mode, and memory settings apply to traces and resumability too.
- Standard backend retention currently includes request/response content and **redacted screenshots for 30 days**; usage metadata has a different lifetime; training snapshots have a separately consented lifecycle. See [server/README.md](../../server/README.md) and [sonny-backend-api-contract.md](../../docs/sonny-backend-api-contract.md).
- `retention: none` and task/account deletion must cover new content paths and derived training records. Provider non-retention is distinct from Sonny's own retention.
- Do not automatically convert every observation into a training sample. Define eligibility, consent, redaction, lineage, and deletion before dataset collection.

## 14. Hosted contracts and release prerequisites

Keep new model calls behind the existing gateway/client boundaries. Preserve task IDs, explicit retention, auth, usage accounting, screen-control charging/idempotency, payload limits, and cancellation/timeouts.

Relevant server contracts are [model.ts](../../server/src/routes/model.ts), [screen.ts](../../server/src/routes/screen.ts), and [limits.ts](../../server/src/model/limits.ts). AX context or versioned goal schemas need coordinated Swift/server validation tests; do not smuggle new fields into strict request envelopes or bypass the gateway with a new provider SDK.

Production hosting is not established by the presence of server code. At the reviewed revision, `SonnyBackendHost.productionBaseURL` is nil in [SonnyBackendEnvironment.swift](../../Sources/MacAgentCore/SonnyBackendEnvironment.swift), and the deploy script has no working staging/production deployment path. Local development and fixture tests can proceed; a shippable hosted planner/vision workflow requires separately verified deployment.

Developer ID distribution remains provisional for this plan, while the repository's release direction includes signing/notarization. A local development certificate is not distribution evidence. If that route is confirmed, validate the actual signed/notarized bundle, target-specific Automation prompts, Screen Recording relaunch, Accessibility revocation, and any bundled helper on a clean machine. Distinguish user-granted TCC permissions from packaging entitlements: Apple Events has a hardened-runtime entitlement and usage description; Accessibility and Screen Recording are TCC grants, not new entitlement keys.

## 15. Delivery sequence, feature parity and deletion gates

Rewrite the core in vertical slices. Do not wait for a complete abstract framework, preserve old internals merely to keep textual tests green, or leave two execution architectures permanently active.

### Phase 0 — Record behavior and define the cutover boundary

Create a compact feature/parity ledger covering current typed/voice entry, instant utilities, file workflows, research/media, vision, routines/scheduling, follow-ups/resume, artifacts/history, notifications, settings/private mode, permissions and account/gateway integration. Remove workspace UI/launchers and workspace binding from the target feature set; identify saved data and references needing migration/export.

Capture a small set of behavioral acceptance cases and baseline timings. Classify existing tests as behavioral contracts, OS/integration checks or implementation-coupled scans. The latter can change with the design; their underlying requirement must be understood first.

Gate: retained features have an owner and an acceptance case; data formats needing readers/migrations are named. There is a concrete removal list for old execution paths. No mandatory new mutation plans or architecture-wide instrumentation project.

### Phase 1 — Build the clean runtime and one real workflow

Introduce the typed intent/prepared-action distinction, a single lifecycle owner, explicit task identities, shared resource ownership and the exact commit gate. Keep coordinator policy as simple functions until real boundaries justify more objects.

Implement bounded AX discovery/actions and one typed script adapter. Prove a harmless unfamiliar-app task and a Mail draft workflow; enable send only with final approval, target/content revalidation and uncertain-outcome handling already working. Retain native utilities through small adapters while migrating their dispatch.

Gate: UI does not execute the new path; cancellation, stale observation, permission denial, changed recipient, duplicate approval and uncertain commit are tested. A model cannot construct trusted actions or bypass the gate. Resource ownership releases correctly on every exit.

### Phase 2 — Concurrent independent tasks and existing vision fallback

Enable multiple independent task sessions with bounded admission. Route every task action through the same shared gate; the composer can submit new work while another task executes or awaits approval. Port existing visual control as a fallback using its tested capture/input/redaction implementation; consolidate nested approval ownership.

Gate: two user tasks make independent progress; conflicting foreground/app/document mutations serialize; approvals remain bound to one task/action; changing UI selection cannot redirect approval or cancellation; stopping task A leaves task B running; stale proposals cannot execute. No duplicate external effects when a task fails or times out. Demonstrate poor-AX fallback without bypassing policy.

### Phase 3 — Port retained features and remove the old execution core

Move composer, voice, routines, schedules, follow-ups, retry and resume onto the runtime request API. Move history and usage recording to explicit run events/outcomes. Preserve private-mode and data-deletion behavior. Complete the workspace retirement and data migration described below.

During development, unmigrated retained features keep working through the old route behind an explicit dispatch boundary; the new route stays internal/flagged until its acceptance cases pass. Do not ship a feature-parity regression as an intermediate release. Use temporary compatibility adapters only where needed. Each feature switches live execution exactly once; never shadow-execute external effects in old and new engines. Saved-data readers translate to new intent; stored approvals are never migrated as authority.

Gate: retained feature ledger passes, migrations/readers preserve existing user data, and all live entry points use the new runtime. Delete old view-model execution methods, `RunScope`-based routing, superseded runner/executor paths and duplicate approval plumbing. Remove the temporary legacy bridge; old format readers may remain.

### Phase 4 — Simplify tests, process and release surface

Replace obsolete source-layout tests with behavioral checks. Retire mandatory mutation-plan/changelog archaeology from the developer loop; keep specialized tools only where they still provide independent value. Update workflow documents/hooks together so a retired rule does not continue blocking work.

Gate: one documented build/test path per affected half, focused tests for iteration, full relevant suite at cutover, and real signed-app smoke checks for OS interaction. Confirm hosting/distribution and hardware requirements before setting release performance guarantees.

### Later — Optimize only measured bottlenecks

Observer caches, warm capture, ghost cursor, local decision models and training datasets are optional later work. No sidecar, model training pipeline or always-on desktop observer is part of the initial rewrite. Collaborative subagents are out of scope. Consider them only if a later product requirement justifies the latency and complexity.

## 16. Representative coverage and verification

| Fixture | Purpose | Completion evidence |
|---|---|---|
| Finder/files | Preserve current selection/path rules and rename behavior | Resolved file identity and resulting path |
| Word conversion | Existing fixed-script regression case | Output file verification |
| Mail | Typed scripting, attachment, exact send barrier | Verified draft plus strongest available submission/delivery evidence |
| Native AppKit fixture | Stable AX roles, text, menus, disabled controls | Deterministic fixture state |
| Slack or comparable messaging app | AX discovery without a dedicated native adapter | Exact conversation/draft state, approval before send |
| Safari and Chrome | Script support differences, web content, navigation | Bound tab/window and observed result |
| Generic Electron app | Incomplete/lazy AX tree and repeated labels | Unique target resolution or explicit fallback |
| Preview/file picker | Selected document, dialogs and app handoff | Pinned file/document and picker result |
| Canvas/poor-AX fixture | Existing visual fallback integration | Independent observable result or honest indeterminate outcome |

Use existing dependency-injection seams and controlled fixtures. Automated tests must not send real messages, mutate a user's apps, post real HID events, or require live model requests. Manual tests use disposable files/accounts and the packaged app for permission/foreground checks.

Preserve useful behavioral coverage, rewriting tests against the new boundaries where needed. Existing sources of cases include: plan decoder/registry, `AgentRunnerTests`, `AgentActionExecutorTests`, `RiskApprovalTests`, consequence-rule dispatch, vision session/containment, redaction, backend client, task deletion, private mode, and run-summary provenance. Add meaningful AX fixture tests, commit races, stale observations, UI-lease cleanup, app quit/relaunch, window movement, multi-display geometry, permission revocation, and cancellation after possible commit.

Replay records contain sanitized semantic snapshots, candidate sets, expected action/effect, and observed outcomes. Keep held-out evaluations separate from any training corpus.

For implementation changes, use the repository's supported Swift test invocation:

```sh
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Run targeted behavioral tests during development and the full relevant suites at cutover. Replace implementation-coupled assertions when their code disappears; do not preserve obsolete internals solely to satisfy a source scan. If server contracts change, run `npm run build`, `npm run typecheck`, `npm test`, applicable DB-backed tests with an isolated test database, and documented secret checks from `server/`. A skipped DB test is not evidence of a passing DB contract. The current [WORKFLOW.md](../../WORKFLOW.md) documents today’s process; Phase 4 explicitly replaces its unnecessary requirements while preserving practical build/test instructions. Keep the server’s operational checks relevant to changes in that half. This document revision itself requires source/reference and consistency checks, not a claim that the app's test suite has been run.

## 17. Performance criteria

Measure time to first **useful action** separately from immediate UI feedback and total task completion. Record route, planner, AX observation, script execution, capture/encode/upload/inference, verification, approval wait, and commit spans. Separate user wait from processing time.

Report p50/p95 by backend, app/task family, cold/warm state, OS and hardware. Include queue/lease wait and compare isolated versus concurrent tasks so quick-task latency regressions are visible. Track success, first-attempt success, indeterminate outcomes, duplicate-commit prevention, fallback rate, model calls, stale approvals, interference, memory and energy use.

Initial aspirations: feedback within roughly 50 ms, cached metadata/rules in a few milliseconds, and local/native first action within roughly 100–150 ms when the app is already ready. These are hypotheses to validate, not release guarantees. A universal sub-second cloud-planned task or one-call completion target is not justified by this repository. Reduce calls only while preserving verified outcomes.

## 18. Code organization and process simplification

Keep the existing Swift package unless a real dependency boundary requires another module. File movement alone is not a simplification. Organize code around a few owners:

- `MacAgent`: app composition, presentation and native UI integration.
- `MacAgentCore/Runtime`: independent task coordination, typed intent/action/result values and policy/resource ownership.
- `MacAgentCore/Automation`: native operations, script templates, AX and visual backends; keep proven leaf implementations where practical.
- Persistence and gateway integration: separate side-effect boundaries; feature stores do not become dependencies of every action executor.
- Tests: fast contracts around the runtime and backend seams, plus explicit OS and gateway integration suites.

These are logical groupings, not a requirement for a file, protocol and actor per noun. A new backend should implement the narrow automation contract; it should not require editing a giant initializer shared by every unrelated feature.

### Testing and workflow policy for the rewrite

Mutation testing is an optional test-quality tool. Remove mandatory per-change mutation plans; keep a campaign only when it can answer a specific question, such as whether approval tests catch a bypass. Existing mutation batteries already run outside the normal branch loop. Do not rewrite them merely because they are large; remove stale tooling if its remaining benefit does not justify maintenance.

Prefer behavioral tests over source spelling/line-shape assertions. Keep narrow structural checks only for a stated property that cannot reasonably be tested at a better seam. A test count or killed-mutant count is not a product outcome.

The daily loop is build + focused tests + inspect behavior. Before cutover run the full relevant suite and affected OS smoke tests. Cold warning builds, packaging checks and optional mutation campaigns belong in maintenance/release workflows. Do not start a database or run the server battery for an unrelated Swift-only change.

Replace the primary contributor workflow with concise current commands and rules. Move historical decisions and operator procedures out of the daily path. When retiring a process, update associated hooks, configuration and tests in the same change. This plan proposes those changes; it does not itself delete tools or bypass existing checks during implementation.

### Workspace retirement

Remove workspace navigation, creation/edit/open actions, quick-dispatch triggers, planner operations and task-to-workspace binding. New tasks receive resource scope directly from user intent and current permission policy; do not rename workspace machinery to “projects” and carry it forward.

Preserve old encrypted workspace records and make them exportable through a migration/data-management path. Historical tasks with workspace tags remain readable as legacy metadata. Inspect saved routine steps, schedules, recent-context/resumable records and UI preferences for workspace references. Translate only where the same behavior and boundaries can be represented; otherwise show a precise unsupported legacy-item message and offer export/edit. Never silently widen a task's permissions or delete unrelated saved data.

Migration contract: keep existing records encrypted at rest and add a versioned, read-only legacy reader in data management. Provide a user-initiated UTF-8 JSON export containing schema version, workspace IDs/names, apps, URLs and stored preferences; export only the selected records, never credentials or encryption keys. Export is an explicit user action, not an automatic plaintext side file. Existing delete-local-data behavior must also delete preserved legacy stores and quarantine copies; externally saved exports are user-owned files.

For referenced settings, preserve existing explicit routine settings first, then a representable legacy workspace setting, then the current default. Persist the resolved preference with its migration version so future defaults do not silently change it. Unrepresentable workspace-dependent routines/resumable items remain readable/exportable and report the exact unsupported reference. Pause affected schedules and show a repair message instead of running with widened scope or silently disabling unrelated schedules. Acceptance cases cover successful migration, restart/idempotency, corrupt records, export round trip, failed references and deletion.

If callers currently use workspace settings to select a browser or resource boundary, carry any required retained preference into an explicit per-routine/per-task setting. Do not silently change a routine's destination browser or scope when removing the workspace UI. Remove old workspace execution paths after migration/read compatibility is covered; keep data deletion/export support for legacy records.

## 19. Definition of readiness

Sonny can accept a goal for an unfamiliar non-refused app, use typed scripts or AX semantics, fall back to vision, request final approval for the exact consequential action and report a verified or explicitly uncertain outcome.

Separate user tasks run concurrently without competing for desktop authority, consuming each other's approvals or duplicating commits. Existing user-facing features remain supported except workspaces, which are removed. User data survives through versioned readers, migration or export; unrelated routines, schedules and history remain usable.

The cleanup is complete only when every retained entry point uses one execution lifecycle, UI focus has no execution authority, trusted actions cannot be decoded from model text, and obsolete orchestration/compatibility scaffolding has been removed. Smaller files alone, or a new runtime permanently wrapping the old one, do not meet that bar.
