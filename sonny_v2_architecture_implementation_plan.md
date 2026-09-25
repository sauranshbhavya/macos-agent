# Sonny v2 Architecture and Implementation Plan

Reviewed against repository HEAD `336959ca` on 2026-09-22; updated after the workflow simplification, on 2026-09-23 with the founders' decisions, and on 2026-09-25 with the gateway-reasoning/Mac-execution boundary. This is the detailed working plan for a cleaner execution core, not a frozen architecture or a requirement to implement every section before the first useful delivery. Existing internals are replaceable. Source links below are relative to this repository. Proposed types, interfaces, phase names and examples are design sketches, not existing APIs or mandatory class/file layouts. Revisit them after each real workflow exposes what works.

See [the comparison](docs/archive/sonny_v2_architecture_comparison.md) and [original draft](docs/archive/sonny_v2_architecture_implementation_plan_1.md) for earlier tradeoffs. The [recovered intermediate plan](docs/archive/sonny_v2_architecture_implementation_plan_2026-09-22.md) preserves the version before this update. The inventory below describes reusable evidence, not architecture that must be preserved.

## Current phase, decisions and rules (2026-09-23)

The sections after this one are the detailed design. This section is what holds right now.

**Phase.** New features are frozen until Milestone A lands. No features, capabilities or improvements go onto the current execution path; the only exception is a fix for a defect that loses data, breaks security or blocks everyday use, approved by a founder each time.

**Milestone A's workflow.** WhatsApp (the native Mac app, `net.whatsapp.WhatsApp`) with a draft-only goal: open the chat the user names and leave the message they asked for in its composer, never sent. Notes stays available as the controlled fixture if WhatsApp's Accessibility tree turns out to be poor. What that choice means for the first slice is under Milestone A in §15.

**On hold.**

- Skill-pack work is off hold (founders, 2026-09-24, reversing the 2026-09-23 decision): the packs are finished before this plan resumes from Milestone A. The work is the pack groups SONNY-545 to SONNY-552, plus the sites SONNY-537 already has in flight. Only sites in the Chrome UX Report top 10,000 get deep packs; niche sites stay shallow.
- The Jev local decision model. The original draft's Laya/Jev section stays in the [archive](docs/archive/sonny_v2_architecture_implementation_plan_1.md) for when it comes back.
- Two small UX fixes found in the 2026-09-23 review wait for the freeze to lift: `AgentViewModel.copySummary()` exists but no control calls it, and the floating widget's result text is not selectable although Command Center's and the receipt's are.

**Verification.** There is no CI for now. How each change is built, tested and reviewed is in [WORKFLOW.md](WORKFLOW.md); this plan does not restate it.

**Rules that always hold.** Every milestone keeps these; the section in brackets has the detail.

1. Each task has one owner of execution authority. UI focus never selects what runs or which approval is answered (§4).
2. Model output, web content, Accessibility text and screenshots are untrusted. They can propose an action but never approve it, name a trusted app, or mark a result verified (§5, §7).
3. A consequential effect gets a fresh approval of the exact effect immediately before it commits, and any material change voids that approval (§9).
4. An action executes once. A non-idempotent action whose outcome is unknown is never replayed, and a possible earlier commit is reconciled before switching backends (§3, §10).
5. A denied permission, refusal or scope violation is never a reason to try another backend (§3, §12).
6. Scripts come only from reviewed, typed osascript templates, and template arguments are data, never script source (§6).
7. All visual egress goes through local redaction, and Accessibility text sent off the machine needs its own minimization (§8).
8. Private mode, memory settings, retention and deletion cover every new store, trace and context path (§13).
9. Saved user data stays readable, nothing is wiped, and a stored approval never carries forward as authority (§5, §15).
10. New model calls go through the existing gateway, and the Swift and server schemas change together (§14).
11. Proprietary reasoning, planning, model routing, Visual Action Agent state and model history live on the gateway. The Mac is the sole execution authority through a local microkernel; the gateway can only request observations and propose typed actions (§3, §4, §14).

**Hosted prerequisite.** Milestone A uses gateway-hosted reasoning and therefore requires a working authenticated deployment and persistent outbound Mac session. `SonnyBackendHost.productionBaseURL` is currently nil and the staging and production deploys are stubs, so deployment is on the milestone's critical path (§14). Exact deterministic zero-model paths may continue to execute locally without that session.

## 1. Outcome and confirmed decisions

Deliver broader arbitrary-app automation using **native APIs, reviewed osascript integrations, and one generic screen controller combining macOS Accessibility trees with redacted screenshots**. Sonny should understand a goal, prefer the most reliable eligible operation, verify the result, and minimize cloud calls and disruption to the user's desktop.

Confirmed during this review:

- Arbitrary-app automation is part of the upcoming implementation. Prove one useful unfamiliar-app workflow early rather than completing an abstract framework first. A smaller first delivery is acceptable.
- Preserve existing user-facing features at eventual cutover while freely replacing their internals. The planned exception is retiring workspaces from the future UI and runtime; preserve existing saved workspace data for migration/export. The first slice does not need full feature parity if the old path continues to serve unmigrated features safely.
- Separate user tasks progressing concurrently is a later product goal, with one execution context per task. It is not a prerequisite for the first single-task slice. Optimize for quick tasks; collaborative child agents, recursive delegation and agent teams are out of scope. When concurrency is added, tasks must share desktop/resource ownership.
- Consequential actions always require a fresh approval immediately before committing, even if the initial command explicitly requested the action.
- Use reviewed, typed osascript templates and generic AX for unfamiliar apps; do not generate arbitrary scripts.
- Keep the core screen-control runtime app-agnostic. An app used by a milestone is a fixture, not a runtime mode: app-specific setup, labels, folder recovery or success wording do not belong in the execution loop.
- Keep model routing separate from execution routing. Select a model tier by reasoning purpose, required modality, difficulty, latency and budget; select native, script or screen control independently by support, permission and verification quality. Exact local commands keep a zero-model path.
- Treat AX semantics and redacted screenshots as cooperating inputs to one generic screen controller, not independent execution authorities. Every mutation from either path crosses the same local action gate.
- Keep proprietary prompts, workflow decomposition, model-tier selection, Visual Action Agent reasoning and task reasoning history on the gateway. The Mac ships generic capabilities and a compact execution microkernel, not the agent's workflow logic.
- The Mac opens a persistent authenticated outbound session; it does not expose an inbound control port. Every gateway proposal is untrusted, scoped, sequenced and locally revalidated.
- Local model inference is outside this architecture. Exact deterministic zero-model paths remain local; adding a local decision model later requires a separate architecture decision and never grants execution authority.
- M1 with 8 GB RAM and Developer ID distribution remain provisional product assumptions.

“Arbitrary app” means no fixed catalog is required to attempt semantic discovery of a non-refused application. It does not promise that every application exposes a useful AX tree, implements scripting, or permits background interaction. Unsupported, ambiguous, and unobservable actions must produce an honest limitation or takeover request.

Preserve the repository's fixed-template boundary: typed osascript adapters for scriptable workflows and generic AX/screenshot discovery and actions for unfamiliar apps. Add only the backend support a chosen workflow needs. A general script evaluator is outside this plan.

## 2. Current implementation: what to reuse

The original draft described several existing features as greenfield work. This baseline distinguishes implemented behavior from gaps.

| Area | Current repository evidence | v2 change |
|---|---|---|
| App/platform | [Package.swift](Package.swift): Swift 6 package, macOS 14 minimum, `MacAgent` executable and `MacAgentCore` library | Keep target boundaries; benchmark provisional hardware separately |
| Orchestration | [AgentViewModel.swift](Sources/MacAgent/AgentViewModel.swift): `start`, `performStart`, approval, voice, scheduled runs, follow-ups, workspace scope, history | Replace with a presentation adapter; execution has one explicit owner |
| Run identity | [RunSlot.swift](Sources/MacAgent/RunSlot.swift): `RunID`, `RunScope`, `ApprovalTarget`, per-run state and fresh approval tokens | Carry identity through explicit requests; replace UI-focused task-local execution routing |
| Concurrency | Production still has one slot; `addRunSlotForTests()` creates additional slots only in tests | Design task/resource ownership explicitly rather than building on slot forwarding |
| Plans and registry | [AgentPlan.swift](Sources/MacAgentCore/AgentPlan.swift), [ToolRegistry.swift](Sources/MacAgentCore/ToolRegistry.swift), [DefaultCapabilityAdapters.swift](Sources/MacAgentCore/DefaultCapabilityAdapters.swift) | Keep old formats readable at boundaries; replace the internal execution representation |
| Fast paths | [InstantCommandResolver.swift](Sources/MacAgentCore/InstantCommandResolver.swift), direct/prebuilt plans, routine/workspace dispatch | Keep zero-model paths; add a backend router beneath validated task intent |
| Execution and approval | [AgentRunner.swift](Sources/MacAgentCore/AgentRunner.swift), [AgentActionExecutor.swift](Sources/MacAgentCore/AgentActionExecutor.swift), [RiskApproval.swift](Sources/MacAgentCore/RiskApproval.swift) | Preserve verified policy behavior; consolidate it into one action gate with exact commit binding |
| Native work | Fixed Finder/Word scripts, file adapters, EventKit, Shortcuts, safe URL/app opening | Wrap and extend these integrations; do not replace EventKit with calendar scripting |
| Visual computer use | [VisionSessionRunner.swift](Sources/MacAgentCore/VisionSessionRunner.swift), [VisionSessionCapabilityAdapter.swift](Sources/MacAgentCore/VisionSessionCapabilityAdapter.swift), [VisionSessionContainment.swift](Sources/MacAgentCore/VisionSessionContainment.swift) | Reuse capture–decide–authorize–act, journal, attention checks, and delegation |
| Capture/input | [ScreenCaptureService.swift](Sources/MacAgentCore/ScreenCaptureService.swift), [ScreenActionSynthesizer.swift](Sources/MacAgentCore/ScreenActionSynthesizer.swift) | Existing target-window ScreenCaptureKit screenshots and real CGEvents; add semantic AX execution |
| Accessibility | Trust checking exists; generic AX tree traversal, AX actions and AX observers do not | This is the main new execution capability |
| Results | [AgentEvent.swift](Sources/MacAgentCore/AgentEvent.swift): `AgentRunResult`; [StoredTaskResult.swift](Sources/MacAgentCore/StoredTaskResult.swift); [TaskReceiptView.swift](Sources/MacAgent/TaskReceiptView.swift) | Add verified evidence/artifact actions while preserving summary provenance and receipts |
| Persistence/privacy | Encrypted stores, [TaskRecordingPolicy.swift](Sources/MacAgentCore/TaskRecordingPolicy.swift), [LocalStoreClassification.swift](Sources/MacAgentCore/LocalStoreClassification.swift), resumable task records | New traces/context must honor private mode, memory settings, deletion, and retention |
| Hosted services | [SonnyModelGateway.swift](Sources/MacAgentCore/SonnyModelGateway.swift), [SonnyBackendClient.swift](Sources/MacAgentCore/SonnyBackendClient.swift), `server/` | Extend from stateless model forwarding to gateway-owned reasoning sessions, model routing, planning, Visual Action Agent state and sequenced typed proposals |

The concurrent-run changelog explicitly documents **the first layer only**, not completed multi-run behavior: [more-than-one-run-at-once.md](docs/changelog/feature/more-than-one-run-at-once.md). `RunSlot` also lists shared ownership and callback hazards still to resolve.

Current approval is more than a tier table. `RiskApprovalPolicy` combines consequence classifications with Safe/Normal/Power and per-app standing. `VisionConsequenceClassifier` supplies mid-loop classifications. `AgentRunner.execute` reassesses consent before execution. Run/token binding rejects stale answers, but does not yet prove that the exact recipient, content, document, or UI target remains unchanged.

Current results are more than `finalSummary: String`: `AgentRunResult` carries previews, suggestions, provenance and item-job failures; the wider pipeline includes recent-artifact storage, stored results and receipt presentation. `copySummary()` is a small presentation concern, not an architectural prerequisite.

## 3. Architecture and execution order

```text
MAC CLIENT                                      GATEWAY / SERVER

Widget / voice / routine / resume
              |
     TaskRequest + local identity
        /                    \
zero-model exact path        persistent authenticated outbound session
        |                                      |
        |                           task reasoning state
        |                           model router / planner
        |                           Visual Action Agent
        |                                      |
        |                     typed proposal / observation request
        |                                      |
        +-----------> Mac execution microkernel <-----------+
                              |
             validate proposal and capability
             resolve live target, scope and TCC
                              |
             native / typed script / screen tools
                              |
              local action gate + exact approval
                              |
                execute once and verify locally
                              |
                  structured outcome / evidence
                              |
                  outbound session -> gateway
```

Every backend action follows this order:

```text
fresh target observation -> policy assessment -> prepare exact action
      -> if consequential: preview + fresh approval
      -> reacquire UI ownership if needed + revalidate exact state
      -> execute once -> verify -> receipt / next bounded action
```

The commit barrier belongs **before** the effect. Verification after execution never substitutes for authorization.

Backend preference is conditional on support, permissions, required effects, scope, and verification quality; the diagram is not a ladder every action must traverse. An unsupported scripting command may proceed to AX without first executing a speculative script. A denied permission, refusal, scope violation, or ambiguous previous commit must not be treated as permission to try another backend. A script failure after the target may have acted also requires reconciliation before any AX fallback.

Keep model selection, planning and local capability selection distinct. Existing typed operations already express many useful intents; the gateway planner need not select every AX element or decide which local implementation runs. The gateway model router chooses the cheapest eligible configured tier for a reasoning request and may escalate only on bounded signals such as unresolved ambiguity, invalid structured output, insufficient grounding or lack of progress. Provider failover is availability handling, not difficulty routing. A stronger model receives no additional authority. The Mac validates every proposed operation against its current capability manifest, permissions, scope and verification quality before selecting a local backend.

## 4. Clean target: one owner of execution authority

Replace the orchestration core. Do not stack a gateway agent runtime and Mac microkernel permanently on top of `AgentViewModel`, `AgentRunner`, and `AgentActionExecutor` while leaving the legacy types responsible for approval and cancellation.

The target has six responsibilities, not necessarily six services or actors:

1. **Presentation on the Mac:** a thin view model creates a local task identity, submits requests and renders task snapshots. UI focus never selects what executes or which approval is answered.
2. **Gateway reasoning runtime:** owns proprietary prompts, task reasoning state, planning state, model history, model-tier routing, Visual Action Agent context, reasoning budgets and future-step cancellation. It can request an observation or propose an action but has no execution authority.
3. **Persistent session boundary:** the Mac opens one authenticated outbound session carrying task requests, capability metadata, ordered proposals, minimized observations, cancellation and structured outcomes. Reconnect uses explicit reconciliation rather than replay.
4. **Mac execution microkernel:** is the sole execution authority. It validates untrusted proposals, resolves live resources, checks TCC and scope, prepares actions, classifies effects, owns approval state, prevents replay, dispatches capabilities, verifies effects and records uncertain outcomes.
5. **Automation capabilities on the Mac:** native APIs, reviewed script templates, and generic AX/visual screen tools behind narrow typed contracts. They cannot be invoked except through the microkernel.
6. **Split persistence:** the gateway retains reasoning/session state under server retention policy; the Mac retains user data, execution receipts, approval/commit state, privacy settings and local evidence under local retention policy.

Use pure functions for local capability selection and policy where possible. Introduce a protocol for a session, OS, storage or clock boundary or genuinely interchangeable behavior, not for every helper. Gateway reasoning state and Mac execution state are separate values with a shared immutable task identity; neither side treats the other's mutable state as authority.

Actors are suitable for gateway session bookkeeping and Mac execution bookkeeping if their dependencies have explicit isolation boundaries. AppKit and AX handles remain on the Mac with their appropriate owner; do not add unchecked `Sendable` conformances to force the design. Actor reentrancy and a network round trip are not transactions: after either, the Mac rechecks state/version before authorizing an action. Blocking OS calls, session traffic and model requests must not block UI rendering.

Every retained entry point creates the same local request contract: composer, voice, instant utility, routine, schedule, follow-up, retry and resume. Exact zero-model operations may resolve locally; every model-backed request enters the same gateway reasoning session. Voice produces a command, a schedule produces a request, and history receives an outcome. None owns another execution loop.

The eventual lifecycle must distinguish queued, connecting, routing/planning, observing, executing, waiting for permission/clarification/approval, paused, completed, failed, cancelled and outcome-unknown where those states are reachable. Gateway cancellation stops future reasoning; Mac cancellation stops future local actions, invalidates local approvals and reconciles in-flight effects. Terminal states are one-way and a late or replayed proposal cannot revive cancelled work. Every session message names its task, session, proposal sequence and action when applicable.

A temporary legacy bridge may help move one feature at a time, but it has a named removal gate. New code does not depend on `RunSlot`, `RunScope.current ?? focusedRunID`, or mutable UI properties for authority. Before final cutover, delete the old orchestration paths and duplicate approval owners.

## 5. Typed data: separate intent, authority and persistence

Replace the current mixed planner/runtime representation. `AgentPlan` is a legacy wire/storage DTO at the boundary, not the new core model.

```text
GATEWAY                                  MAC EXECUTION MICROKERNEL

user request / saved routine
          |
proprietary planning + reasoning
          |
untrusted TaskIntent / next-step proposal ---> validate schema and task/session scope
                                                    |
                                      resolve live targets and permissions
                                                    |
                                             PreparedAction
                                                    |
                                      local policy + exact approval
                                                    |
                                         execution + local evidence
                                                    |
structured outcome <---------------------- minimized result / evidence
```

Use small payload types rather than one step containing many unrelated optional fields:

```swift
enum TaskStep {
    case operation(TypedOperation)
    case interaction(InteractionGoal)
}
```

An `InteractionGoal` contains a requested app reference, objective, completion criteria, requested resources/effects and bounded effort. The gateway can propose it, but the Mac validates and normalizes it against the locally established task scope. A `PreparedAction` is constructed on the Mac and contains the live resolved target, concrete capability action, effect classification, preconditions, postconditions and retry semantics. The gateway can never construct an approval token, trusted app/process/file identity, authoritative effect classification or verified result.

Represent native utilities and other retained features as typed operations. Expose one generic interaction-goal contract to the gateway for unfamiliar apps; do not add a planner tool for every AX role, app, script template or button. The gateway may recommend an execution surface, but native/script/AX/visual capability selection and validation remain local to the microkernel.

Keep old saved routines, history and settings readable through versioned readers or explicit migrations. Compatibility belongs at the edge and must not dictate the internal state model. If planner schema changes, update Swift decoding, gateway validation and fixtures together. A storage reader may remain indefinitely where needed for user data; a second legacy execution engine may not.

Resumed model-backed tasks re-establish an authenticated gateway session, recover permitted reasoning state under retention policy, and re-prepare every local action. They cannot reuse old AX handles, coordinates, session sequences, runtime generations or approvals. A disconnect after a possible commit reconciles locally before the gateway may continue. No data wipe is part of this rewrite.

## 6. Typed osascript integrations

Reuse [FinderContextService.swift](Sources/MacAgentCore/FinderContextService.swift), [DocumentConverter.swift](Sources/MacAgentCore/DocumentConverter.swift), [AsyncProcessRunner.swift](Sources/MacAgentCore/AsyncProcessRunner.swift), and [ShortcutsBridgeService.swift](Sources/MacAgentCore/ShortcutsBridgeService.swift).

`osascript` is an execution mechanism, not a semantic API on its own. The backend accepts a typed operation, selects a reviewed script template for a resolved app, passes validated data, executes with a bounded lifetime, and verifies the result. App support is explicit; launching an app does not prove that it implements a scripting dictionary.

Candidate adapters, chosen by the first useful workflow rather than all required up front:

1. Preserve Finder selection and Word conversion as compatibility cases.
2. A Mail workflow could create a draft, populate exact recipients/body, attach a resolved file, verify the draft, and separately approve/send. It is a later example, not a first-slice gate.
3. Add a browser observation/operation adapter where scripting support is demonstrated; retain existing URL-opening behavior for all other cases.

Use native filesystem and EventKit APIs where already supported. Do not duplicate those with AppleScript just to exercise the new backend.

Template arguments must remain data; never concatenate untrusted AX text, filenames, or model text into executable script source without a rigorously tested encoding boundary. Capture structured output and classify permission denial, unsupported operation, timeout, application failure, and uncertain execution separately. Cancellation must not imply rollback of a script already accepted by the target app.

Permission prompts are target-specific. Extend readiness reporting and test the signed application path; a successful Terminal-launched probe is not release evidence. Preserve the hardened-runtime and packaging assumptions documented in [MacAgent.entitlements](Packaging/MacAgent.entitlements) and [package-app.sh](scripts/package-app.sh).

## 7. Generic screen control: Accessibility and visual CUA

Build one app-agnostic screen-control capability in the Mac microkernel as the local half of a bounded observe/request/propose/act/verify loop. Accessibility snapshots and redacted target-window screenshots are cooperating tools. The gateway-hosted Visual Action Agent chooses AX, screenshot, or both again on each iteration according to the goal and evidence it still needs; there is no task-wide screen-control mode selected before the loop. AX may identify and mutate a semantic field while a screenshot supplies surrounding context; a visually located control may still use AX to confirm the pinned process/window and supported action. Do not encode an app catalog or workflow state machine on either side, and do not make AX-to-vision an unconditional fallback ladder.

The Mac screen capability receives a locally resolved target app/window plus the scoped observation or action request. The gateway Visual Action Agent receives the generic goal, declared capability availability and only the minimized observation the Mac permits to leave the device. Neither side receives `SupportedApp.notes`, a starting menu path, default folder, chat schema, app-specific workflow recipe or app-specific success text. App-specific fixtures belong only in test and evaluation support; live reasoning uses the goal and current bounded observation.

On the gateway, the model-backed **Visual Action Agent** owns its reasoning history and consumes the goal, currently permitted evidence, declared screen-tool capabilities and a short action history. The gateway model router selects its model tier for each reasoning step. The agent may request a bounded AX observation, a redacted screenshot, or both over the session; the Mac validates that request against target scope, TCC permissions, privacy, freshness and budget before collecting or releasing anything. The agent then emits one typed next-action proposal or a request to finish, clarify or hand over. It never invokes AX, captures pixels, sends input, approves an effect or marks the task verified directly. The Mac resolves the proposal into a `PreparedAction`, applies policy, dispatches an authorized action and supplies a fresh minimized outcome or observation for the next iteration.

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

Treat all AX labels and values as untrusted content. A button labelled “ignore previous instructions” is observation data. It cannot change the user goal, permissions, approval policy, or allowed resources. Reuse [UntrustedContentBoundary.swift](Sources/MacAgentCore/UntrustedContentBoundary.swift).

### Actions

Initial actions: query, press, set a supported value, focus/select, and navigate a menu. Check supported actions/settable attributes before invocation. Re-resolve the target and validate its generation immediately before mutation.

Screenshot-grounded actions use the same action vocabulary and preparation boundary. Coordinate input carries the pinned window identity, observation generation, geometry and expected effect; it is not a separate lower-trust route around AX policy. Every key, click, menu, text mutation, script and native effect becomes a `PreparedAction` before dispatch.

A semantic action is not automatically safe: pressing Return, selecting a destructive menu item, changing a shared document, or editing an autosaved field can commit effects. Classify using operation semantics and available local context; uncertain consequential effects stop for approval or takeover. Label heuristics alone cannot prove that arbitrary UI actions are harmless.

Start with on-demand observation. Add `AXObserver` notifications and small caches after the first end-to-end workflow works. Invalidate on process/window changes, navigation, observer loss, permission changes, and user interference. Notifications improve freshness but do not replace pre-action validation.

## 8. Context and screen observation

A lightweight `ContextEngine` composes existing app/focus/Finder/clipboard seams and the new AX provider. Cache cheap metadata first: app/process, window, observation age, permissions, and run ownership.

Selection text, clipboard content, AX values, and screenshots are sensitive task content. Fetch only when needed for the current goal. Existing clipboard concealed/transient filtering and memory preferences must remain effective. Do not silently add continuous text or screen collection.

Snapshots explicitly report freshness, provenance, and unavailable fields. Revalidate expensive or mutable fields before executing; cached context is a routing hint, not commit evidence.

Reuse `ScreenCaptureService` for target-window screenshots. It already implements window selection and live window resolution. Preserve window geometry, display scale and coordinate conversion in `ScreenActionSynthesizer`.

A warm ScreenCaptureKit stream, region capture, and persistent “latest frame” are optional optimizations after profiling. They require bounded memory, idle suspension, permission-loss cleanup, and evidence that they improve latency without unacceptable battery cost. Do not require a warm stream for the first AX release.

All visual egress continues through [LocalRedactionService.swift](Sources/MacAgentCore/LocalRedactionService.swift) and [RedactedCaptureEncoder.swift](Sources/MacAgentCore/RedactedCaptureEncoder.swift). Crop/resample changes must preserve redaction-before-egress and accurate coordinate mapping. New AX text egress needs its own explicit minimization/redaction path; image redaction does not sanitize semantic text.

## 9. Approval policy and exact commit binding

Implement one effect-based policy authority used by native, osascript, AX, and visual execution. Existing consequence/policy tests provide behavioral requirements, but the `RiskApprovalPolicy` class and tier representation are replaceable. Do not retain both an old and a new authority permanently or create a policy table in each backend.

Preserve Safe mode's stricter floor, app-control standing, per-task resource scope, terminal refusal, unattended-run restrictions, and screen-control entitlement/allowance checks. Power mode must not bypass consequential-action approval.

Use an effect vocabulary that maps to existing escalations: read-only, local reversible change, destructive change, external communication, shared-data mutation, financial commitment, installation/security change, and credential submission. Unknown effects require a conservative decision rather than automatic execution.

Minimize interruption by resolving effects before involving the user. Prefer native or typed-script metadata where it establishes semantics; otherwise gather another bounded AX or redacted visual observation, or ask the gateway to clarify the proposal. Auto-run known nonconsequential actions. Ask once only when the exact consequential effect is prepared. If the target or effect remains unknown after bounded evidence gathering, stop or offer takeover rather than presenting a vague approval that would not authorize a real effect.

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

## 11. Later milestone: concurrent user tasks and shared desktop ownership

When this milestone is built, “multi-agent” means **separate user tasks running concurrently**, each with gateway reasoning state and corresponding Mac execution state. It does not mean splitting one quick task across collaborating agents. This section records the hazards to solve then; it is not required infrastructure for the first delivery. Do not build parent/child run trees, recursive delegation, a team planner or result-merging framework.

```text
GATEWAY REASONING                         MAC EXECUTION

Task A reasoning ----\                 /-> Task A execution state
Task B reasoning ----- authenticated ----> Task B execution state
Task C reasoning ----/    sessions      \-> Task C execution state
                                               |
                                  shared local microkernel
                             admission, resources, policy, approval
                                               |
                                  native / script / AX / visual
```

Each task has immutable shared identity, command, origin, permitted resources and recording policy. Gateway state owns reasoning context, model history and reasoning budget; Mac state owns execution phase, leases, prepared actions, approvals, commit status, verification and uncertain outcomes. UI selection only chooses which task to display. One task's progress, error, approval or completion must never overwrite another's.

Gateway task runtimes propose typed actions; the shared Mac microkernel validates and dispatches them. A task cannot expand its scope, approve itself, inherit another task's approval or treat model/observed text as user authorization. Use task ID, session ID, proposal sequence, action ID and commit ID; a separate agent ID is unnecessary while the relationship is one-to-one.

Stop-task tells the gateway to cancel that task's future reasoning and tells the Mac to cancel queued resource requests and future actions, invalidate local approval and reconcile any in-flight effect. Either side must honor cancellation independently if the session is interrupted. Other tasks continue. A failed/timed-out task never causes an uncertain commit to replay. Global emergency stop is local, halts desktop input immediately and makes affected task states explicit.

Choose bounded admission and fairness limits from observed use when concurrency is implemented; two active/eight unfinished from the earlier draft are examples, not defaults to encode now. Tasks waiting for approval/clarification should release execution slots and resource leases where safe, but still count toward whatever unfinished limit is chosen. Extra admitted tasks queue visibly; a full queue rejects a new submission without cancelling existing work. Resuming approval reacquires an execution slot and resources, then revalidates. Apply per-task model/action/time budgets. A simple fair action order should prevent one long task from starving quick tasks without introducing a generalized scheduling framework. Fairness must respect a short indivisible UI sequence when releasing focus between its steps would be unsafe.

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

## 12. Fold the existing visual path into generic screen control

Reuse the existing CUA implementation where it is useful; do not build capture and coordinate handling from scratch. Adapt the Mac vision path to provide bounded redacted observations and controlled input inside the same local screen capability used for AX; action proposals come from the gateway Visual Action Agent. Preserve containment behavior, redacted payloads, Safe-mode previews, app pinning and pause/stop, but replace the old vision runner's nested reasoning/approval/execution loop so it cannot become a second authority. Transitional delegation has an explicit removal/consolidation gate.

Visual grounding is appropriate for absent/incomplete AX semantics, canvas content, or controls unsupported by a reviewed script. The controller may combine it with AX within one step; it is not a way around terminal refusal, denied authority, missing entitlement, or a failed commit.

Current browser capabilities mostly open URLs; they do not constitute a DOM automation engine. Safari/Chrome, webviews, and Electron need separate coverage. Embedded shells and unknown terminal applications remain a gap in an identity-based deny list; do not claim arbitrary-app automation solves that safety problem. Retain refusal and require takeover where shell-like effects cannot be constrained.

Do not batch Enter/Return with text entry by default. It can send, submit, or accept a dialog. Any action batch must be policy-checked action by action and stop before a consequential boundary or unexpected state transition.

## 13. Results, observability, and retention

Define one structured task outcome exchanged across the session and consumed by UI and persistence, per independent user task, with no cross-task summary overwrite. The Mac is authoritative for whether an action was attempted and what local evidence was observed; the gateway may interpret that evidence and compose presentation text but cannot upgrade it to verified. Existing `AgentRunResult`/`StoredTaskResult` supply useful fields and storage compatibility, but their runtime representation may be replaced. Preserve code/model/outside-authored provenance and the untrusted boundary when results reenter planning.

Build on existing recent-artifact storage and Open/Reveal suggestions; add verification evidence and Copy path where the result identifies a real artifact. Record completed units, partial effects, pending/unknown commits, and the evidence supporting the outcome. Keep `finalSummary` as presentation text, not the sole execution record.

Use existing run/task identities for the events a delivered workflow needs: route, backend selection, observation, action, approval requested/granted/invalidated, verification, retry, fallback, interference, cancellation and completion. Add timestamps and stage durations where they answer a latency or reliability question; do not require a complete tracing platform before the first slice. Never log raw credentials, complete clipboard contents, unredacted screenshots, or an entire AX tree as routine telemetry.

Privacy must match the existing system:

- Local stores are encrypted and classified for retention/deletion. New stores join the same classification and wipe behavior; ephemeral context should normally remain memory-only.
- `TaskRecordingPolicy`, private mode, and memory settings apply to traces and resumability too.
- Standard backend retention currently includes request/response content and **redacted screenshots for 30 days**; usage metadata has a different lifetime; training snapshots have a separately consented lifecycle. See [server/README.md](server/README.md) and [sonny-backend-api-contract.md](docs/sonny-backend-api-contract.md).
- `retention: none` and task/account deletion must cover new content paths and derived training records. Provider non-retention is distinct from Sonny's own retention.
- Do not automatically convert every observation into a training sample. Define eligibility, consent, redaction, lineage, and deletion before dataset collection.

Persistence is split deliberately. The gateway stores task reasoning state, model history, routing events and permitted minimized content under server retention/deletion policy. The Mac stores user data, privacy settings, execution receipts, local approval/commit records and evidence needed for reconciliation. Raw AX handles, approval authority and unredacted captures never become gateway state. Resumption re-establishes the session and re-prepares locally rather than restoring an old action or approval.

## 14. Hosted contracts and release prerequisites

V2 moves model-backed orchestration behind the gateway/client boundary. The gateway owns the task reasoning coordinator, proprietary planner, model router, Visual Action Agent, model history, reasoning budgets and ordered proposal generation. Preserve task IDs, explicit retention, auth, usage accounting, screen-control charging/idempotency, payload limits, and cancellation/timeouts.

### Persistent Mac session

The Mac opens a persistent authenticated outbound session to the gateway; it never listens for inbound remote-control connections. The session carries capability availability, task requests, ordered observation requests and action proposals, locally minimized observations, structured outcomes, cancellation and reconciliation. Every message is bound to account, device, task ID, session ID, proposal sequence, action ID when applicable and bounded expiry.

The session is also the primary latency optimization. Keep model conversation and proprietary reasoning state on the gateway, reuse the authenticated transport, stream compact structured results, and send AX/image deltas only against a known observation generation. The gateway may propose a short batch of nonconsequential navigation actions with explicit local preconditions and a stop point; the Mac checks each action and stops on any divergence. No batch crosses an approval boundary or includes send, delete, purchase, credential submission or another non-idempotent commit. Deterministic local verification returns a result without another model turn when it can establish the postcondition.

The Mac rejects duplicate, stale, expired, out-of-order or cross-session proposals. Reconnect presents the Mac's last accepted sequence and local action/outcome ledger; the gateway resumes only after explicit reconciliation. It never replays the last proposal blindly. If a non-idempotent effect may have occurred, the Mac reports `outcome-unknown` and no reasoning path may try another backend until the effect is reconciled.

The gateway receives only observations the Mac releases after local scope checks, minimization and redaction. It cannot request raw pixels, raw AX text, clipboard contents, credentials or another app/window outside the task scope; it cannot disable redaction policy. TCC and OS permission state remain local prerequisites. The gateway sees declared availability or denial results but cannot grant, infer or override Accessibility, Screen Recording, Automation or other permissions.

Keeping prompts, workflow decomposition, routing thresholds and reasoning history on the gateway protects them from ordinary client inspection and lets them change without an app release. It does not make the action sequence invisible to the owner of the Mac: typed proposals and local capability implementations can still be observed or instrumented. Do not rely on obfuscation or client-side encryption as proof that code executed on a user-controlled machine is secret.

### Model tier routing

Add a proprietary gateway model router above provider routing. Its input is the reasoning purpose, required input/output modalities and schema, difficulty signals, latency target, remaining task budget and prior failed/escalation signals. The Mac may supply capability availability and bounded execution telemetry but does not select tiers, providers, prompts or planning strategy. The router's output is a configured tier, not a hard-coded vendor model name. A low-cost model such as GPT-6 Luna can fill the interaction tier, but replacing that model must not change Mac execution or policy code.

Start with a small deterministic policy rather than another model: exact instant operations use no model; ordinary structured planning and grounded screen steps use the cheapest eligible tier; escalation is bounded and occurs only for defined failures such as ambiguity, invalid proposals, insufficient visual/semantic grounding or repeated lack of progress. Record the routing reason and actual usage. Model/provider failover remains a separate availability concern, and no tier can approve an action, trust an observed identity or declare an effect verified.

Relevant current server contracts are [model.ts](server/src/routes/model.ts), [screen.ts](server/src/routes/screen.ts), and [limits.ts](server/src/model/limits.ts). The persistent session, task coordinator and proposal schemas are new server responsibilities rather than a reason to overload stateless model routes. Capability, observation, intent, proposal, outcome and versioned goal schemas need coordinated Swift/server validation tests; do not smuggle new fields into strict envelopes or bypass the gateway with a new provider SDK.

Production hosting is not established by the presence of server code. At the reviewed revision, `SonnyBackendHost.productionBaseURL` is nil in [SonnyBackendEnvironment.swift](Sources/MacAgentCore/SonnyBackendEnvironment.swift), and the deploy script has no working staging/production deployment path. Local development and fixture tests can proceed, but Milestone A is not complete or shippable until the authenticated gateway reasoning service, persistent session, reconnect/reconciliation path and deployment are verified.

Developer ID distribution remains provisional for this plan, while the repository's release direction includes signing/notarization. A local development certificate is not distribution evidence. If that route is confirmed, validate the actual signed/notarized bundle, target-specific Automation prompts, Screen Recording relaunch, Accessibility revocation, and any bundled helper on a clean machine. Distinguish user-granted TCC permissions from packaging entitlements: Apple Events has a hardened-runtime entitlement and usage description; Accessibility and Screen Recording are TCC grants, not new entitlement keys.

## 15. Delivery sequence and deletion points

These are milestones, not a fixed dependency graph. Pick the next slice from user value and what the previous slice taught us. Do not complete an abstract framework before a real workflow, preserve old internals merely to keep textual tests green, or leave two execution authorities permanently active.

### Milestone A — Choose and prove one useful workflow

Choose an unfamiliar non-refused app and a user goal with an observable result. Prefer an action without external send or destructive effects for the first proof. The founders' pick is WhatsApp with a draft-only goal (top of this plan). What that pick implies:

Milestone A may use Notes or another app as a controlled fixture, but the delivered runtime is not a Notes or WhatsApp runtime. Submit the goal through the gateway reasoning session and point the Mac's generic screen capability at the locally resolved app. Navigation, including setup such as creating a new note, proceeds through the same gateway Visual Action Agent and generic AX/screenshot observation/action contracts used for any app. Do not add `SupportedApp` entries, starting menu paths, default-folder recovery or app-specific completion summaries to the Mac microkernel. Keep fixture-specific state in test support.

- **The Accessibility tree is the only semantic route.** WhatsApp 26.36.74 declares no scripting dictionary (its `Info.plist` has neither `NSAppleScriptEnabled` nor `OSAScriptingDefinition`, where Notes has both), so there is no osascript template to write. The slice exercises exactly the missing capability of §7, with visual grounding from §12 where the tree is poor.
- **Return sends.** The draft is entered by setting the composer's value, not by typing keys, and text containing a newline is refused rather than typed. No step in this slice may press Return in that window. That is §12's no-batched-Return rule, with the stakes named.
- **The postcondition is the draft.** Success means the named chat is open and its composer holds exactly the requested text. A missing or ambiguous chat name, or two chats with similar names, ends in a clarification, never a best guess.
- **Chat names and messages are private and untrusted.** Send the model only what choosing the target needs, and treat a contact name or message text as observation data (rules 2 and 7 above).
- WhatsApp is already on `AppControlStarterList` as `net.whatsapp.whatsapp`, so the existing app-control standing applies without new policy. A controlled AppKit fixture can establish AX behavior; a disposable real-app case shows whether the discovery is useful outside a fixture. Inspect the AX tree and existing native or vision support before deciding which backend to implement.

Record only the current behavior and data contracts that this slice touches. Establish a small number of acceptance cases and a baseline for the user's perceived wait. The full retained-feature ledger belongs to migration planning, not a requirement to start the first slice.

Introduce an explicit task identity, a gateway reasoning session, one Mac execution authority, ordered proposal/replay protection, a boundary between untrusted gateway goal and locally resolved action, a policy decision, and an evidence-bearing result. Use existing useful leaf integrations. Keep UI presentation and gateway reasoning separate from action authority. If the first action is consequential, implement exact local approval and revalidation before enabling it; otherwise demonstrate that boundary with a focused controlled case before adding a send/delete workflow.

Evidence for this milestone: the chosen task works end to end through the authenticated gateway session; permission denial, stale target, disconnect/reconnect, duplicate or out-of-order proposal, cancellation, and an unobservable result are handled honestly; the gateway cannot dispatch a trusted action or mint approval. The new path does not require a new dependency in every large central initializer. The old production path may continue serving unrelated features during this bounded transition, but each live request executes on exactly one path.

### Milestone B — Test the boundary with another workflow

Add a second real goal with a different app or automation mechanism. Use a typed script only if that workflow's app actually supports and benefits from scripting; let the generic screen controller combine AX and visual grounding when direct integrations are unavailable. A Mail draft or another consequential workflow is useful here because it tests exact target/content approval and uncertain outcomes, but the app choice is not prescribed.

Revise the first slice's types and boundaries if the second workflow exposes a better shape. This is the point to decide whether a common backend interface or additional module boundary earns its maintenance cost. Do not preserve an early abstraction merely because it shipped in the first slice.

Evidence: both workflows use the same action authority, but keep their app-specific behavior local; a fallback cannot bypass policy or duplicate an uncertain commit; relevant behavior and OS integration checks pass.

### Milestone C — Migrate retained entry points and remove old authority

Build a compact parity ledger for typed/voice entry, instant utilities, file workflows, research/media, visual control, routines/scheduling, follow-ups/resume, artifacts/history, notifications, settings/private mode, permissions and account/gateway integration. Move coherent groups to the common lifecycle, preserving their outcomes and saved-data readers. History consumes explicit outcomes; a schedule submits a request; voice produces a command.

During migration, unmigrated features keep working through an explicit old route. Each feature switches live execution once; never shadow-execute external effects in both engines. Temporary compatibility adapters have a named replacement and deletion point. After a group's acceptance cases pass, delete its superseded view-model/runner/executor ownership. Old format readers may remain for user data; stored approval never carries forward as authority.

Retire workspace UI and execution binding in a separate data-compatible slice. Inspect routine, schedule, history, resumable and preference references. Preserve old encrypted records for user-initiated export or repair, without widening scope or silently changing destinations. Unrepresentable legacy items remain readable and explain the repair needed. The precise export format and migration implementation should be chosen from the data actually stored and the product's data-management surface, not treated as a reason to preserve workspace execution machinery.

Evidence: each migrated feature has a user-outcome check; old data still loads or offers a clear repair/export path; no retained entry point depends on UI focus for execution; duplicate authority and temporary bridges are removed at final cutover.

Skill-pack work no longer waits for this cutover: the packs are finished before the plan resumes (the current-phase section at the top, 2026-09-24).

### Milestone D — Add independent concurrent tasks when valuable

After the single-task lifecycle is stable, enable more than one user task. Each keeps its own context, cancellation, approval and result. Add the smallest admission and resource-ownership mechanism that handles observed conflicts. Shared foreground actions, app state and document/draft writes need serialization or revalidation; independent network/planning work may overlap.

Evidence: two tasks progress independently, a selected UI row cannot redirect an action or approval, stop-task affects only its task, conflicting desktop effects do not race, and neither a timeout nor fallback duplicates a possible commit. Choose numeric queue limits from measured use rather than an earlier draft's constants.

### Milestone E — Release and cleanup

At the release boundary, run the full relevant suites and affected packaged/signed-app smoke checks. Confirm hosted deployment and distribution assumptions before treating them as release guarantees. Remove obsolete source-layout tests whose underlying behavior now has a better check. Consider observer caches, warm capture, ghost cursor, local models or training datasets only after measurement shows a need.

The milestones can be rearranged when a concrete dependency requires it. A smaller internal or limited delivery can finish after A or B. Final replacement of the old execution core requires C; concurrency requires D only when that product capability is being delivered.

## 16. Representative coverage and verification

| Fixture | Purpose | Completion evidence |
|---|---|---|
| Finder/files | Preserve current selection/path rules and rename behavior | Resolved file identity and resulting path |
| Word conversion | Existing fixed-script regression case | Output file verification |
| Mail | Typed scripting, attachment, exact send barrier | Verified draft plus strongest available submission/delivery evidence |
| Native AppKit fixture | Stable AX roles, text, menus, disabled controls | Deterministic fixture state |
| WhatsApp (Milestone A), Slack or comparable messaging app | AX discovery without a dedicated native adapter | Exact conversation/draft state, approval before send |
| Safari and Chrome | Script support differences, web content, navigation | Bound tab/window and observed result |
| Generic Electron app | Incomplete/lazy AX tree and repeated labels | Unique target resolution or explicit fallback |
| Preview/file picker | Selected document, dialogs and app handoff | Pinned file/document and picker result |
| Canvas/poor-AX fixture | Visual grounding inside the generic screen controller | Independent observable result or honest indeterminate outcome |

This table is a coverage menu for the eventual capability, not a checklist every first delivery must pass. Select cases that exercise the changed path; broaden it as new backends, apps and consequential effects are introduced.

Use existing dependency-injection seams and controlled fixtures. Automated tests must not send real messages, mutate a user's apps, post real HID events, or require live model requests. Manual tests use disposable files/accounts and the packaged app for permission/foreground checks.

Preserve useful behavioral coverage, rewriting tests against the new boundaries where needed. Existing sources of cases include: plan decoder/registry, `AgentRunnerTests`, `AgentActionExecutorTests`, `RiskApprovalTests`, consequence-rule dispatch, vision session/containment, redaction, backend client, task deletion, private mode, and run-summary provenance. Add meaningful AX fixture tests, commit races, stale observations, UI-lease cleanup, app quit/relaunch, window movement, multi-display geometry, permission revocation, and cancellation after possible commit.

Replay records contain sanitized semantic snapshots, candidate sets, expected action/effect, and observed outcomes. Keep held-out evaluations separate from any training corpus.

Build and test commands are in [WORKFLOW.md](WORKFLOW.md). At each cutover run the full relevant Swift and server suites. Replace implementation-coupled assertions when their code disappears; do not preserve obsolete internals solely to satisfy a source scan. A skipped DB test is not evidence of a passing DB contract.

## 17. Performance criteria

Measure time to first **useful action** separately from immediate UI feedback and total task completion. Record local fast-path resolution, gateway connection/resume, session transport, gateway routing/planning/inference, local capability and resource resolution, AX observation, redaction/capture/upload, local action-gate work, approval wait, dispatch, local verification and reconciliation spans. Separate user wait from processing time.

Once enough real tasks exist to make the data meaningful, report p50/p95 by backend, app/task family, cold/warm state, OS and hardware. Include queue/lease wait when concurrency exists. Track success, first-attempt success, indeterminate outcomes, duplicate-commit prevention, fallback rate, model calls, stale approvals, interference, memory and energy use where the metric guides an actual decision.

Initial aspirations: feedback within roughly 50 ms, cached metadata/rules in a few milliseconds, and local/native first action within roughly 100–150 ms when the app is already ready. These are hypotheses to validate, not release guarantees. A universal sub-second cloud-planned task or one-call completion target is not justified by this repository. Reduce calls only while preserving verified outcomes.

## 18. Code organization

Keep the existing Swift package unless a real dependency boundary requires another module. File movement alone is not a simplification. Organize code around a few owners:

- `MacAgent`: app composition, presentation and native UI integration.
- `MacAgentCore/Execution`: the local microkernel, session client, proposal validation, capability/resource resolution, action preparation, policy, approval, replay protection, dispatch, verification and reconciliation.
- `MacAgentCore/Automation`: native operations, reviewed script templates, AX observation/actions and redacted visual/input tools; keep proven leaf implementations where practical.
- `server/Agent`: gateway task/session coordination, proprietary planning, model routing, Visual Action Agent reasoning, proposal sequencing and reasoning-state retention.
- Persistence: explicitly split gateway reasoning/session records from Mac user data, execution receipts, approval/commit records and privacy settings.
- Tests: fast contracts around session and microkernel seams, plus explicit server, reconnect/replay, OS and packaged-app integration suites.

These are logical groupings, not a requirement for a file, protocol and actor per noun. A new backend should implement the narrow automation contract; it should not require editing a giant initializer shared by every unrelated feature.

### Workspace retirement

Remove workspace navigation, creation/edit/open actions, quick-dispatch triggers, planner operations and task-to-workspace binding. New tasks receive resource scope directly from user intent and current permission policy; do not rename workspace machinery to “projects” and carry it forward.

Preserve old encrypted workspace records and make them exportable through a migration/data-management path. Historical tasks with workspace tags remain readable as legacy metadata. Inspect saved routine steps, schedules, recent-context/resumable records and UI preferences for workspace references. Translate only where the same behavior and boundaries can be represented; otherwise show a precise unsupported legacy-item message and offer export/edit. Never silently widen a task's permissions or delete unrelated saved data.

Migration contract: keep existing records encrypted at rest and provide a versioned way to read them while users migrate or export. The export is user-initiated, contains only selected records and no credentials or encryption keys, and never appears as an automatic plaintext side file. Choose the export format and UI after inspecting the stored schema and current data-management surface. Existing delete-local-data behavior must also delete preserved legacy stores and quarantine copies; externally saved exports are user-owned files.

For referenced settings, preserve existing explicit routine settings first, then a representable legacy workspace setting, then the current default. Persist the resolved preference with its migration version so future defaults do not silently change it. Unrepresentable workspace-dependent routines/resumable items remain readable/exportable and report the exact unsupported reference. Pause affected schedules and show a repair message instead of running with widened scope or silently disabling unrelated schedules. Acceptance cases cover successful migration, restart/idempotency, corrupt records, export round trip, failed references and deletion.

If callers currently use workspace settings to select a browser or resource boundary, carry any required retained preference into an explicit per-routine/per-task setting. Do not silently change a routine's destination browser or scope when removing the workspace UI. Remove old workspace execution paths after migration/read compatibility is covered; keep data deletion/export support for legacy records.

## 19. Definition of readiness

**First useful delivery:** Sonny can accept one goal for an unfamiliar non-refused app, run proprietary reasoning through an authenticated gateway session, request locally minimized semantic/visual observations, perform a bounded action through the Mac execution microkernel, and report a locally verified or explicitly uncertain outcome. Disconnect, replay, permission and approval boundaries have focused tests plus an affected real-app check. It need not implement every backend, migrate every feature, or support concurrent tasks. The existing path may continue serving unmigrated features without running the same external action twice.

**Core cutover:** retained user-facing features remain supported except workspaces, which are retired with readable/exportable legacy data. Every model-backed entry point uses the gateway reasoning/session lifecycle and every effect uses the Mac execution microkernel; UI focus and gateway/model output have no execution authority; trusted actions cannot be decoded directly from model text; and obsolete orchestration and compatibility scaffolding have been removed. Consequential effects use exact local approval and honest uncertain-outcome handling. Smaller files alone, or new gateway/client layers permanently wrapping the old authority, do not meet that bar.

**Concurrent-task delivery, when chosen:** separate user tasks progress without competing for desktop authority, consuming each other's approvals, overwriting results, or duplicating commits. Its resource and admission design is evaluated against real use rather than frozen by this document.
