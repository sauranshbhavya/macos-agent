# Sonny V2: implementation plan for the gateway and the Mac microkernel

Written 2026-09-25 against `main` at `482633c3` and this branch's architecture change (`a62cab2e`). It
turns [the V2 architecture plan](../sonny_v2_architecture_implementation_plan.md) and
[the architecture diagrams](sonny-architecture-diagrams.md) into ordered work. Where this plan and
the architecture plan disagree, this one reflects the later decisions listed below.

## 1. Decisions this plan is built on

Sauransh, 2026-09-25:

1. **No backwards compatibility.** Old saved routines, history, workspaces and settings do not need
   readers, migrations or exports. V2 starts with fresh local stores. Old server routes are deleted
   at cutover, not versioned.
2. **Earlier privacy promises no longer bind.** Retention `none`, the 30-day content store, training
   snapshot plumbing, per-task deletion and role-based Accessibility minimization are not
   requirements. What remains:
   - A **security floor** (section 7.4): passwords, secure fields and detected secrets never leave
     the Mac.
   - The **private-mode toggle** (decision 10).
3. **Persistent WebSocket session** between the Mac and the gateway, as the architecture plan says.
   (I recommended turn-based HTTP; section 2 records why and what the socket costs.)
4. **Skill packs move to the gateway** and are matched automatically per task. The Mac ships no packs
   and the Add/Remove Skills screen goes away.
5. **Effect policy: the model declares, the Mac can only raise.** Every proposed action carries the
   model's claimed effect. Local rules can raise it, never lower it. Section 7 has the table.
6. **PR #289 is closed without merging.** Its generic pieces are carried into the first V2 slice
   (section 9, phase 4).
7. **The planner owns the task, and the screen agent is its subagent.** The screen agent has its own
   prompt, context and history and is never the same agent as the planner. Both run inside one task:
   one session, one budget, one cancellation path.
8. **Billing is token credits.** Users buy credits, and every model call spends them by tokens. The
   differentiator is a smarter, more risk-averse agent, not a cheaper one.
9. **Routines are saved as goals** and reasoned again through the gateway on every run.
10. **The private-mode toggle stays, end to end.** Bhavya's composer-logo toggle (commit `336959ca`)
    is ported in phase 6. A private task is not written to local history, and the gateway deletes its
    transcript as soon as the task ends.
11. **Gateway task transcripts are kept 30 days**, then deleted. Private tasks are deleted sooner
    (decision 10).
12. **The agent never types into a password or secure field.** The user takes over for sign-in.
13. **With no gateway connection, a model-backed task fails at once and the app shows a server
    error.** Zero-model instant commands never use the server and are unaffected.

Standing rules from the architecture plan that still hold: the Mac is the only thing that executes;
model output, web content, Accessibility text and screenshots are untrusted; a consequential effect
gets a fresh approval of the exact effect; an action runs once and an uncertain one is never
replayed; a refusal is never a reason to try another backend; scripts come only from reviewed
templates; UI focus never decides what runs.

## 2. Review of the architecture change

### What holds up

- **Reasoning on the gateway, authority on the Mac.** This is the right split. Today every prompt is
  Swift (about 7.7K lines of prompt and reasoning code) and the server is a pass-through that
  forwards whatever the Mac sends. Moving prompts, planning and the screen agent to the server
  protects them from ordinary inspection and lets them change without an app release. It also
  shrinks the Mac.
- **One local action gate for every backend.** Today approval lives in two places:
  `AgentRunner.approvalRequest` for plans, and `VisionSessionRunner.authorize` for screen steps.
- **AX and screenshots as tools the agent picks per step.** This is better than a fixed "AX first,
  then vision" ladder.
- **"Decompose #289, don't generalize it."** Its policy file grew a new regression with each review
  round because it encoded one app's shape. The real WhatsApp probe showed that the fake chat app
  matched no real app.

### What I questioned, and where it landed

| # | Issue in the architecture change | Outcome |
|---|---|---|
| 1 | **Skill packs are missing.** The plan never mentions the 473 packs (238 deep) that were just finished. Its screen-control section says neither side gets "app-specific workflow recipes". Read literally, that throws the packs away. | Decided: the packs are gateway reasoning data, matched per task. The "no app recipes" rule applies to **Mac code only**. |
| 2 | **"Unknown effect → stop" cannot work for arbitrary UI.** A deterministic gate on the Mac almost never knows what an unlabeled button does, so the agent would stop on nearly every click. | Decided: the model declares, and the Mac can only raise (section 7). The remaining risk is accepted and stated. |
| 3 | **The socket is the expensive part.** Every server guarantee runs as a one-HTTP-request hook: auth, idempotency, metering, the spend cap and the version gate. None of these runs on socket messages. Token expiry, sign-out and deploys all need socket-specific handling. The latency gain is small, because the model call dominates each step and HTTP keep-alive already reuses the connection. | Decided: WebSocket. Section 5 contains the cost: auth runs on the upgrade request, the other guarantees become plain functions called per message, and task state lives in Postgres so any instance can resume a task. |
| 4 | **"Planner" and "Visual Action Agent" are drawn as two reasoning systems with no stated relationship.** They share a goal, a budget and the same proposal channel. | Decided (decision 7): **one task, two agents**. The planner owns the task and calls the screen agent as a subagent. Section 5 has the design. |
| 5 | **The plan does not split server-side tools from Mac-side tools.** Web search, public-page reading and synthesis don't touch the Mac, yet today they go Mac → gateway → provider → Mac. | The gateway runs them itself. Only actions that touch the Mac cross the socket. |
| 6 | **Much of the plan is compatibility and privacy work**: versioned readers, workspace export, retention and deletion coverage, AX text minimization. | Removed by decisions 1 and 2. About 6K lines of Mac code and about 3K lines of server code are deleted instead of extended. |
| 7 | **Hosting is on the critical path but has no owner.** `SonnyBackendHost.productionBaseURL` is `nil` (`Sources/MacAgentCore/SonnyBackendEnvironment.swift:52`), and the staging and production deploys exit 3. A socket also needs a proxy that passes upgrades and a drain procedure. | A parallel hosting track (phase H). Development runs against the local Docker gateway. |
| 8 | **cua-driver has unverified edges.** 1) The vendored 0.28.3 library contains fragments of telemetry environment-variable names (`CUA_TELEMETRY_EN…`) and policy variables (`CUA_DRIVER_POLICY_FILE`, `CUA_DRIVER_DISABLE_UNRESTRICTED`, `CUA_DRIVER_PERMISSION_MODE`) that could widen its authorization ceiling from the environment. 2) #289 discards cua's per-action result (`effect`, `evidence`). 3) The capability manifest is hard-coded to Notes. 4) cua reads only windows on the current Space, so screen work needs the app in front. | Phase 0 reads the SDK source for items 1 and 4. Phase 4 uses the action result as local evidence, builds the manifest per task, and takes a foreground lease for every screen action. |
| 9 | **Billing assumes Mac-owned sessions.** Credits count distinct client-minted screen `session_id`s (`server/src/credit/store.ts:90`). Once every model-backed task runs on the gateway, the billable unit changes. | Decided (decision 8): token credits, charged per model call (section 5). |

## 3. End state

```text
MAC (Swift)                                           GATEWAY (Node, Fastify)

Composer / voice / routine / schedule / follow-up
        |
   TaskController ── zero-model instant path ──┐
        |                                      │
   GatewayConnection  ══════ wss /v2/session ══╪══>  Session layer (auth, reauth, rate, dedupe)
        ^                                      │            |
        |  observe / propose / ask / finish    │      Planner agent per task
        |                                      │        └─ screen subagent
   TaskRuntime (one per task)                  │        model router, prompts, skill packs
     ProposalValidator                         │        server tools: search, read page, synthesize
     Capability registry ── native / script / screen (cua + capture + redaction)
     ActionGate + ApprovalBroker               │            |
     ExecutionLedger + ForegroundLease         │      Postgres: device, agent_task, agent_message
        |                                      │
   macOS, apps, files  <───────────────────────┘
```

**Deleted from the Mac:** the planner, `AgentPlan` as the core model, `AgentRunner`,
`AgentActionExecutor`, the vision reasoning loop and its prompts, research prompts, skill packs and
the Skills UI, workspaces, `RunSlot`/`RunScope`, and the privacy and deletion scaffolding except the
private-mode flag.

**Deleted from the server:** `/v1/plan`, `/v1/research/synthesize`, `/v1/screen/analyze`, the public
`/v1/search`, the content-retention system, training snapshots, the task deletion routes and the
`retention` field.

## 4. Wire protocol

All messages are JSON text frames on one socket per device. The shapes live once in `contracts/v2/`
as JSON Schema. The Swift `Codable` types and the server Zod schemas are both tested against the same
fixture files, which is the pattern `server/test/fixtures/agent-plan-schema.json` already uses.

### Envelope

```json
{ "v": 1, "type": "propose", "id": "<uuid>", "task": "<task id>", "seq": 7, "re": 6 }
```

- `id` is unique per message, and the receiver ignores a repeat.
- `seq` counts per task and per direction, and only goes up.
- `re` is the other side's `seq` that this message answers.

Messages without a `task` are connection-level: `hello`, `welcome`, `reauth`, `goodbye`.

### Mac → gateway

| type | carries |
|---|---|
| `hello` | device id, app version, **capability manifest**, and a resume list |
| `task.start` | task id, goal text, origin, the `private` flag, light context (frontmost app, Finder selection), prior task id for follow-ups |
| `observation` | answer to `observe`: bounded AX snapshot, redacted screenshot, or both, with app, window and generation |
| `outcome` | answer to `propose`: action id, status, local evidence |
| `answer` | the user's reply to `ask` |
| `task.cancel` | stop the task |
| `reauth` | a fresh access token |

**Capability manifest** (in `hello`):

- operation names, versions and argument-schema hashes
- screen tools available
- permission states: Accessibility, Screen Recording, Automation per app
- mode: Safe, Normal or Power

**Resume list** (in `hello`): per unfinished task, the last `seq` seen and the local action ledger.

**Outcome status** (in `outcome`) is one of:

- `done`
- `failed`
- `refused` (by the gate)
- `declined` (by the user)
- `stale`
- `outcome_unknown`

### Gateway → Mac

| type | carries |
|---|---|
| `welcome` | session id, server time, payload limit, state of each resumed task |
| `observe` | what to look at: AX, screenshot or both, target app/window hint, bounds |
| `propose` | one action, or a short batch of navigation-only actions with a stop point. Each action carries: action id, operation or screen action, arguments, **declared effect**, expected result |
| `ask` | a clarification question for the user |
| `finish` | the gateway's summary. The Mac decides the verified status from its own evidence |
| `reauth.required`, `goodbye` | token about to expire; server closing (deploy drain) |

### Exactly-once rules

1. **Reasoning has no side effects, so the gateway may redo a turn.** If the server dies mid-turn,
   the reconnect re-runs that turn from the stored transcript.
2. **The Mac never dispatches the same action id twice.** Its `ExecutionLedger` goes through these
   states and is written to disk before dispatch:

   `received → prepared → approved → dispatched → done | failed | outcome_unknown`

3. **An action that was dispatched but has no outcome after a crash or disconnect becomes
   `outcome_unknown`.**
   - If its effect was navigation or observation, the Mac re-observes and continues.
   - If it was consequential, the task pauses and asks the user, for example: "I may already have
     sent this. Check, then continue or stop."
   - Nothing may retry it through another backend.
4. **The Mac drops proposals that don't fit.** It ignores a proposal whose `seq` is not newer than
   the last one accepted, whose task is finished or cancelled, or whose session is not the current
   one.

## 5. Gateway work

New code goes in `server/src/agent/`.

**Session layer**

- **Upgrade route.** Add `@fastify/websocket`. The route `GET /v2/session` runs the existing
  version gate and auth gate as ordinary `onRequest` hooks on the upgrade request. The token goes in
  the `Authorization` header, never the URL.
- **Token refresh.** Send `reauth.required` two minutes before the access token expires. The Mac
  refreshes through the existing `/v1/auth/refresh` and sends `reauth`. The server runs the same
  checks as the gate (`verifyAccessToken`, denylist, `gateway_session`). A socket past its expiry
  is closed with code 4401.
- **Sign-out and account deletion.** An in-process registry, account → sockets, closes the
  account's sockets immediately. Postgres `LISTEN/NOTIFY` is added only when there is more than
  one instance.
- **Device identity.** A random device id is kept in the Mac Keychain and sent in `hello`. A new
  connection from the same device replaces the old one.
- **Limits and liveness.**
  - A per-account token bucket for messages.
  - `maxPayload` of about 6 MB, because screenshots are capped at 3 MB before base64.
  - Heartbeat every 20 s.
- **Deploy drain.** Send `goodbye` (close code 1012) and stop accepting connections. The Mac
  reconnects to the new process, and the task resumes from Postgres.
- **DB pool.** Take a pool connection per message, never per socket. The pool max is 10
  (`server/src/db/pool.ts:110`).

**Per-message guarantees.** Extract these from the hooks into plain functions that both the HTTP
routes and the agents call:

- `meterModelCall` from `metering/hook.ts`
- the spend hold and settle, from `entitlement/hook.ts`

Every model call inside a task writes a metering row keyed by a step id instead of an HTTP request
id. The row records the tier, provider, input and output tokens, and credits charged.

**Token credits** (decision 8). The existing `credit/*` balance is rebased from counting screen
sessions to spending by tokens:

1. Before each model call, hold credits for that call's maximum tokens at the chosen tier.
2. Afterwards, settle to the actual usage. Per-tier rates (credits per thousand input and output
   tokens) are configuration.
3. An empty balance stops the task **before its next model call, never in the middle of a Mac
   action**. The app says so plainly.
4. Top-up and auto top-up (`routes/credits.ts`) stay as they are.

**Storage.** New migrations:

- `device (id, account_id, last_seen_at)`
- `agent_task (id, account_id, device_id, status, private, goal, origin, mode, budgets, last_seq_in, last_seq_out, timestamps)`
- `agent_message (task_id, direction, seq, msg_id unique, type, body jsonb, created_at)`

The transcript is the reasoning history. Screenshots are held in memory for the current turn and
are not written to the database, to keep the database small.

Two retention rules:

- **Ordinary tasks** are deleted 30 days after they end, by a sweeper that reuses the advisory-lock
  pattern of today's `content/expiry.ts`.
- **Private tasks** are deleted as soon as they reach a terminal state. The transcript exists only
  while the task is live, which is when reconnect and resume need it. A follow-up to a private
  task starts with no prior history. Metering rows hold counts and tokens only, so they are kept for
  billing.

**Agents** (decision 7). A task runs two agents with separate prompts and context. Both are small
state machines driven by messages.

**The planner** owns the task:

1. On `task.start` it loads matching skill packs and the prior task's history, assembles its
   prompt, and calls the model with its tools:
   - the manifest's typed operations, with descriptions owned by the server
   - server tools: web search, read public page, write note
   - `screen_task(app, objective, done_when)`, which starts the screen agent
   - control tools: ask, finish
2. It may emit a batch of typed operations; that is what planning is today.
3. Server tools run on the server and the loop continues. Typed operations become `propose`, and
   the planner waits for outcomes.
4. When the last batch was marked final and every outcome came back `done` with evidence, it
   finishes without another model call.

**The screen agent** is the planner's subagent. What it gets:

- **Input:** only the objective the planner gave it, the declared screen tools, fresh observations
  and its own short action history. It gets neither the planner's conversation nor the skill packs,
  unless the planner passes a relevant excerpt in the objective.
- **Tools:** observe, press, set value, type, key, scroll, menu, click at a point, and return.
- **Returns to the planner:** a structured result — done, failed, needs clarification, or
  outcome unknown — with what it observed.
- **Clarification:** it never asks the user directly. The planner decides whether to ask.

**Shared rules for both agents:**

- The task's model-call, turn and wall-time budgets, and its cancellation. A cancel stops whichever
  agent is running.
- At most one screen agent at a time per task.
- The model router picks a tier for each agent's call separately.
- Proposals carry `agent: planner | screen` for the receipt. The Mac gives both the same authority,
  which is none.
- The gateway validates every proposal against the manifest schema before sending, so a bad model
  output costs one retry, not a round trip.

**Model router.** A small deterministic function, with no model of its own:

- Input: purpose, modality, retry and no-progress signals, remaining budget.
- Output: a tier, `fast`, `standard` or `strong`. Config maps each tier to a provider chain, for
  example `fast` to gpt-5.6-luna with gpt-oss-120b as failover. No model name appears in code.
- Escalate one tier on invalid structured output, two steps with no progress, or ambiguity the model
  flags. Log the reason.
- The vision adapter (`server/src/model/vision.ts`, currently off the router) joins the router as a
  multimodal capability of a tier.
- Keep the existing failover rule: fail over only on an unavailable provider.

**Prompts and packs move to the server.** They become server files owned by the agent:

- `OpenAIPlanner.systemPrompt`
- the adapters' `AgentTool` descriptions
- `VisionSessionPromptBuilder`
- `WebResearchPromptBuilder`
- the prompt half of `UntrustedContentBoundary`
- `PriorTaskContext` rules

Skill packs move from `Sources/MacAgent/Resources/SkillPacks` to `server/skill-packs/`:

- loaded at boot through a TypeScript port of the pack decoder and its content rules (the
  `SkillPackTests` checks move with them)
- matched by goal text, target domain and bundle id, at most three per task (today's cap)

**Server tools.** Research becomes a server tool: search through the existing Tavily adapter, read
public pages with a server fetch, synthesize through the router. Its note comes back as text, and the
Mac writes it with a typed `write_file` operation.

## 6. Mac work

New code goes in `Sources/MacAgentCore/Kernel/`. The existing leaves stay where they are.

| Component | Job | Built from |
|---|---|---|
| `GatewayConnection` (actor) | One `URLSessionWebSocketTask`. Handles hello/welcome, reconnect with backoff and jitter, reauth, and routing messages to tasks. Queues outbound messages while offline. Behind a small `GatewayTransport` protocol so tests use an in-memory transport. | New |
| `TaskRuntime` (actor, one per task) | Task states: queued, connecting, running, observing, awaiting approval, awaiting answer, paused, reconciling, completed, failed, cancelled, outcome unknown. Terminal states are final. | New |
| `ProposalValidator` | Strict decoding. Checks the task, session and `seq`. Checks that the operation is in the local manifest and its arguments match the schema. Refuses a target app that is refused locally. | New. Reuses `AppControlStarterList`, `ScreenControlEligibility`, `ShellSurfaceDetector` |
| `Capability` protocol and registry | `prepare(args) → PreparedAction`, `execute(PreparedAction) → Outcome`, and optional `verify`. A `PreparedAction` holds the live target, the effect, the preconditions and the retry rule. | The `execute` bodies of 25 existing adapters (section 8). Planner metadata is removed. |
| `ActionGate` | Declared effect, local raise rules, mode, app standing and the unattended flag decide one of: run, confirm with a preview, or refuse. | New. Keeps the behaviours of `RiskApprovalPolicy` and `VisionConsequenceClassifier` (section 7) |
| `ApprovalBroker` | A `PreparedCommit` holds task, action id, single-use commit id, effect, target identity, content digest and expiry. Before consuming it: revalidate, then consume atomically. Any material change voids it. | Replaces `RunSlot`'s approval token |
| `ExecutionLedger` | Per-task action states on disk, for exactly-once and reconciliation. | New. Reuses `LocalStorageEncryption` |
| `ForegroundLease` | One global lease for any action that needs the app in front: screen actions and scripts that open windows. | New |
| `ScreenCapability` | AX snapshot and actions through cua-driver; screenshots through `ScreenCaptureService`; redaction and secret detection; a bounded observation builder. | Taken from #289: `CuaDriverClient`, `CuaDriverLibrary`, the generic parts of `AppInteractionWindow` and `AppInteractionScreen`, fetch and packaging scripts. Plus the existing capture, redaction and input leaves. |
| `TaskController` (@MainActor) | The only thing the UI talks to. Submits requests, publishes per-task snapshots, and routes approvals by task and action id, never by focus. | Replaces the orchestration inside `AgentViewModel` |
| Instant path | `InstantCommandResolver`, trimmed: no workspace dispatch, and no local "use <app> to…" screen plans. It emits local proposals that go through the same validator, gate and ledger. | Existing |

**Entry points.** Every entry point creates the same `TaskRequest`:

- **Composer and voice.** Voice transcription stays on its HTTP route, and its text becomes a
  request.
- **Routines.** A routine is saved as a goal (decision 9). Each run is a new model-backed task.
- **Schedules.** A schedule submits a request marked unattended. Anything that would need
  confirmation is refused and reported.
- **Follow-ups.** A follow-up names its prior task id, and the gateway has that task's history.
- **Resume.** Resume reconnects and re-prepares every action.
- **Watchers.** Watchers submit a request when triggered.
- **No connection.** When the socket cannot connect, a model-backed request fails at once, and the
  app shows a server error in plain words, never a raw one (decision 13).

**UI.** `AgentViewModel` (9.7K lines, 59 published properties) is rewritten as thin presentation
over `TaskController`, not refactored in place. The Skills screen and all workspace UI go.

**Bhavya's commit `336959ca` is ported in the same phase** (`origin/feature/brand-widget-private-mode`,
88 commits behind `main`). It is ported by hand onto the rewritten presentation, because it will
not rebase cleanly. What it brings:

- **Command Center:** the dark green sidebar with gold brand actions, and the larger sidebar mark.
- **Widget:**
  - the black-and-white Liquid Glass widget: `.glassEffect` on macOS 26, the vibrancy fallback on
    macOS 14 and 15
  - the 520 × 44 pt composer and the larger mic and compact controls
  - the fix for the resize loop that hung the app
- **Private mode:** the composer logo as the private-mode toggle.
  - `TaskRecordingPolicy` stays as the flag behind it.
  - A private task skips local history and sends `private: true` in `task.start` (decision 10).
  - The toggle's accessibility label is "Don't save this task", and it now holds on both sides.

Bhavya's manual-test list on that branch is the acceptance list for the port, minus its
workspace-chip check.

**Fresh stores.** V2 writes under a new Application Support subfolder. On first launch it deletes
the old folder and the old Keychain items. Nothing is migrated.

## 7. The action gate

### 7.1 Effect vocabulary

The existing numeric risk tiers 0–4 and the three escalation consequences are replaced by one list:

`observe` · `navigate` · `edit_local` · `create` · `destructive` · `external` · `financial` ·
`credential` · `unknown`

### 7.2 Raise rules

These are deterministic and local, and can only raise an effect:

| Signal | Raised to |
|---|---|
| Return, Enter or ⌘Return while a text field or composer is focused | `external` |
| The target's label, title or menu path contains a commit word (send, post, submit, reply, share, invite, publish) | `external` |
| … contains pay, buy, purchase, order, subscribe, transfer or checkout | `financial` |
| … contains delete, remove, trash, discard, overwrite, erase or reset | `destructive` |
| The target is a secure text field, or the text to type matches `SecretTextDetector` | `credential` |
| The typed operation's own floor (for example `rename` → `destructive`, a Mail send template → `external`) | that floor |
| The model declared `unknown` or declared nothing | `unknown` |
| The target app is refused: terminals, script editors, a shell on screen, or an app outside its standing | refuse |

### 7.3 Decision by mode

| Effect | Safe | Normal | Power | Unattended |
|---|---|---|---|---|
| observe, navigate | run | run | run | run |
| edit_local, create | confirm | run | run | run |
| destructive, external, financial, unknown | confirm | confirm | confirm | refuse |
| credential | refuse | refuse | refuse | refuse |

Power differs from Normal only in skipping the per-app standing check, as it does today. "Confirm"
shows the exact effect: recipient, content and target. The standing rule against batching Return
with text entry also still holds. A batch stops before any action that is not `observe` or
`navigate`.

### 7.4 Security floor and accepted risk

**Security floor.** These never leave the Mac:

- secure field values
- text matching `SecretTextDetector`
- the image regions `LocalRedactionService` masks

Nothing else is minimized. AX labels, window titles and chat names may be sent to the gateway.

**Accepted risk.** An unlabeled control that the model wrongly declares as navigation can still
commit an effect. The mitigations are the raise rules, Safe mode, per-app standing and a receipt
listing every action taken. There is no further guarantee.

## 8. What happens to existing code

| Area | Fate |
|---|---|
| `OpenAIPlanner`, `ToolRegistry`, the planner half of `AgentPlan`, `ClarifiedCommand`, `PriorTaskContext`, `ChainedArtifactCarry`, `PlannedDestinations` | Delete. Prompts and rules move to the gateway. |
| `AgentRunner`, `AgentActionExecutor` (2.8K lines), `PlanItemJob*`, `PlanScopedResources` | Delete. The per-operation preparation that resolves live files and outputs moves into each capability's `prepare`. |
| 30 capability adapters (6.7K lines) | Keep 25 `execute` bodies as kernel capabilities and drop their `AgentTool` metadata. Of the other five: delete the three workspace adapters; the vision-session adapter becomes the screen capability; the web-research adapter becomes a server tool. |
| `VisionSessionRunner`, `VisionSessionPromptBuilder`, `VisionModelClient`, `VisionDecisionParser` | Delete. The loop and prompt move to the gateway. Keep the attention monitors and pause/stop from `VisionSessionContainment`. |
| Capture, input, redaction, OCR, focus leaves (about 3.1K lines) | Keep. |
| `WebResearchSynthesizer` and its prompt builder, `TavilySearchProvider` | Delete. Research is a server tool. |
| `SkillPack*`, `SkillGuidance`, `SkillsPresentation`, `SkillSelectionStore`, the pack resources, `SkillPackTests` | Move to the server (decoder, rules, tests), then delete from the Mac. |
| Workspaces (about 2.9K lines across 10 files, plus `AutomationStores` parts) | Delete. |
| `RunSlot`/`RunScope` | Delete. `TaskRuntime` owns identity. |
| `LocalStoreClassification`, `PendingServerDeletionStore`, `SonnyTaskDeletionService`, `LocalDataQuarantine`, `BackendTaskContext.retention` | Delete. Keep `LocalStorageEncryption` and the Keychain store, which the new stores reuse. |
| `TaskRecordingPolicy` | Keep, as the private-mode flag (decision 10). |
| Server `content/*` (about 2.4K lines), `snapshots.ts`, `routes/tasks.ts`, migrations' retention tables, the provider data-policy config | Delete, and drop their tables in a new migration. The expiry sweeper's advisory-lock pattern is reused for task retention first. |
| Server `credit/*` | Keep top-up and auto top-up. Replace the screen-session count with token spending (section 5). |
| Server auth, billing, entitlements, transcription, health, meta, idempotency | Keep. Metering and the spend cap are refactored into callable functions. |
| Source-scan tests (about 80 files read `Sources/`) | Delete with the code they scan. New code gets behaviour tests only. |

## 9. Order of work

Each phase ends in something that runs. They go roughly in order; phase H runs alongside them.

### Phase 0 — Clear the ground

- Close PR #289 with a comment pointing here. Close the stale branches from the review.
- Read the cua-driver SDK source (`abi.rs`, and the policy and telemetry modules) for three things:
  - whether telemetry can switch on from the environment
  - whether `CUA_DRIVER_*POLICY*` variables can widen the bounded manifest
  - whether `cua_driver_session_create_v1` pins a session to an app

  If the environment can widen the ceiling, clear those variables before `create`.
- Decide the first host (phase H) so the socket's proxy is known.

**Done when:** the SDK questions are answered in writing on the V2 issue.

### Phase 1 — Contracts

- Write `contracts/v2/` JSON Schemas:
  - envelope and every message type
  - capability manifest
  - effect vocabulary
  - AX observation
  - screenshot observation
- Write Swift `Codable` mirrors and server Zod mirrors.
- Write shared fixture files that both sides decode and re-encode.

**Done when:** both suites round-trip every fixture, and an unknown field or type fails on both
sides.

### Phase 2 — Gateway session, without a model

- The session layer and storage from section 5, including both retention rules.
- A "scripted agent" used in tests, which replays a fixed list of proposals.
- Metering and spend functions extracted, with the token-credit hold and settle.

**Done when** tests with a real `ws` client against `buildApp` show:

- a task starts and gets scripted proposals
- a disconnect mid-task, then reconnect, resumes with no duplicate proposal
- a repeated message id is ignored
- an expired token forces `reauth` and closes with 4401 if ignored
- sign-out closes the socket
- a drain sends `goodbye`
- a model call inside a task writes a metering row and settles credits by tokens
- an empty balance stops the task before its next model call
- a private task's rows are gone once it ends, and an ordinary task's rows go after 30 days

### Phase 3 — Mac kernel skeleton

- `GatewayConnection`, `TaskRuntime`, `ProposalValidator`, `ActionGate`, `ApprovalBroker`,
  `ExecutionLedger` and `TaskController`.
- One capability, `open_app`.
- An in-memory transport for tests.

**Done when** kernel tests show:

- a scripted gateway opens an app end to end
- duplicate, stale, out-of-order and cross-task proposals are dropped
- cancel during dispatch stops further actions
- a disconnect after dispatch yields `outcome_unknown` and a pause
- approval binds to task and action id, and a changed content digest voids it

### Phase 4 — Screen control, Milestone A

**Mac:**

- Bring over #289's cua pieces:
  - `CuaDriverClient`
  - `CuaDriverLibrary`
  - the fetch and packaging scripts
  - the `Package.swift` `CCuaDriver` target
  - `FakeCuaNotes` as a fixture
  - the generic loop tests: offered-element check, stale reference refused, largest window,
    unreadable window, set-value fallback
- Build the capability manifest per task from the resolved app.
- Keep cua's action result as local evidence.
- Build the observation from AX (bounded node count and text budget, secure fields masked) and/or a
  redacted target-window screenshot.

**Gateway:**

- The screen agent, with its prompt ported from `VisionSessionPromptBuilder` and #289's step prompt.
- A minimal planner whose only tools are `screen_task`, ask and finish. That is enough to prove the
  subagent relationship before phase 5 fills in the planner.
- The model router with the three tiers.

**Fixture: a new note in Notes.** No Notes code in the runtime: the model chooses ⌘N or File › New
Note through the generic menu and key tools. If New Note is greyed out, the model picks a folder or
asks. Sonny no longer has its own recovery code for that case.

**Done when:**

- the packaged app, against the local Docker gateway, creates the note end to end
- permission denied, stale target, disconnect and reconnect, cancel, and an unobservable result
  each end honestly
- the gateway cannot cause an action the gate refuses
- a Return in a text field is raised to `external` and asks
- a secure field is never typed into, and the task asks the user to take over
- the screen agent's result reaches the planner, and a cancel stops whichever agent is running

### Phase 5 — Typed operations and the planner move, Milestone B

**Mac:** port every retained adapter to a kernel capability.

**Gateway:**

- The planner prompt, tool descriptions and skill packs move over.
- The full planner: typed operations, server tools, skill packs and `screen_task`.
- Research moves to a server tool.

**The Milestone B workflow is a Mail send**, which proves the `PreparedCommit` path:

- a typed osascript template creates the draft, with the To field and body set by the template's
  typed arguments
- the gate asks once with the exact recipient and body
- changing the draft after approval voids the approval
- a timeout after send becomes `outcome_unknown` and is never retried

The AX probe found the Mail body cannot be written through Accessibility, so this is script
territory.

**Done when:**

- every retained operation has a capability with a behaviour test
- the planner's old test cases (from `AgentRunnerTests` and `OpenAIPlannerTests`) are rewritten as
  gateway tests against the new tool catalog
- the Mail flow passes its approval and uncertain-outcome cases

### Phase 6 — Entry points and UI

- Composer, voice, instant, routines, schedules, follow-ups, resume and watchers all go through
  `TaskController`.
- Rewrite `AgentViewModel` as presentation.
- Remove the Skills and workspace UI.
- Port Bhavya's commit `336959ca` (section 6), including the private-mode toggle end to end.

**Done when:**

- every entry point has an outcome test
- no execution path reads UI focus
- a scheduled run refuses a confirm-level action and reports it
- a routine run starts a new model-backed task from its saved goal
- a private task leaves no local history and no gateway rows after it ends
- with the gateway down, a model-backed request shows the server error at once
- Bhavya's manual-test list passes on the packaged app

### Phase 7 — Cutover and deletion

- Delete everything section 8 marks for deletion, on both sides, including the screen-session credit
  count.
- Switch to fresh stores.
- Delete `origin/feature/brand-widget-private-mode` and the #289 branch; their content now lives in
  the port.
- Run the full Swift and server suites, including DB tests.
- Run a packaged-app smoke check of each retained feature group.

**Done when:** nothing references the deleted types or routes, and both suites pass.

### Phase H — Hosting (alongside phases 2–7)

- Provision the chosen host.
- Put a TLS proxy that passes WebSocket upgrades in front of it.
- Make `deploy.sh staging` real.
- Set `productionBaseURL`.
- Check that a deploy drains sockets and Macs reconnect.

**Required before anything ships.** Not required for development.

### Later — Concurrent tasks

More than one `TaskRuntime` at a time, a queue on the foreground lease, and per-task stop. The
protocol already names the task in every message, so this is Mac-side work.

Built on 2026-09-26:

- Up to three model-backed tasks run at once (`TaskController.defaultMaxLiveTasks`). More wait
  their turn, oldest first. The number is a starting point, not a measured limit.
- Screen actions, and typed operations that bring an app forward, share one foreground lease, so no
  task pulls another app to the front in the middle of another task's click.
- An app's screen work belongs to one task at a time, until that task ends or moves to another
  app. A second task is told the app is busy (`foreground_unavailable` with the Mac's reason), and
  the planner hears that reason.
- The composer, Run again and a routine's Run now start a new task while others run. Stop and the
  emergency-stop hotkey still stop every task, and each task's own Stop stops only that one.

## 10. Testing approach

- **Contracts:** shared fixtures, decoded on both sides (phase 1).
- **Server:** unit tests drive `buildApp` with a real `ws` client and the existing store fakes. DB
  tests cover the task tables and metering. Both agents are tested with a scripted model adapter;
  there are no live model calls in automated tests.
- **Mac:** kernel tests use the in-memory transport and `FakeCua`. No real sockets, no real HID
  events and no real apps in automated tests.
- **Packaged app:** a manual check for each phase that touches permissions, focus or real input,
  written in the PR.
- **No new source-scan tests.** Where a property matters, test the behaviour.

## 11. Open questions

The first round was answered on 2026-09-25 and is recorded as decisions 7–13 in section 1.
Still open, and not blocking before phase 4:

1. **Credit rates per tier and the price of a credit.** The code reads them from configuration, so
   this is a pricing decision, not an engineering one.

## 12. Phase 0 findings (2026-09-25)

### cua-driver 0.28.3 SDK source

Read at tag `cua-driver-rs-v0.28.3` (commit `e1824be1`). The dylib is the `cua-driver-sdk` cdylib.
Paths are under `libs/cua-driver/rust/crates/`.

1. **Telemetry: none in the library.** The PostHog sender is only in the CLI crate
   (`cua-driver/src/telemetry.rs:25`, using `ureq`). The SDK has no HTTP client, and the vendored
   dylib contains neither `posthog` nor `ureq`. The `CUA_TELEMETRY_EN…` string is an allowlist of
   variables handed to a child daemon that only the UniFFI host can start
   (`cua-driver-sdk/src/embedded.rs:835-865`); no C ABI function reaches it. The only network code
   is loopback-only browser debugging (`core/src/browser/cdp_ws.rs:87-100`), used by browser tools
   Sonny doesn't allow.
2. **The environment cannot widen the ceiling.** Every `CUA_DRIVER_*` policy variable is read once
   at create (`cua-driver-sdk/src/abi.rs:209-312`). Each one can only make create fail or narrow
   what is allowed. The context Sonny's `invoke_v1` calls run under is built from the explicit
   mode and manifest, "without consulting compatibility environment variables"
   (`core/src/session_authorization.rs:529-566`). Every call is checked against the manifest,
   including its expiry and idle timeout (`core/src/authorization.rs:1126-1172`).
3. **A session is not pinned to an app.** Create takes no pid or bundle id. The only app
   restriction is the manifest's `resources.apps`; for input and observation tools cua resolves
   the target pid's bundle id itself and matches it, so a caller can't claim a false one.
4. **Gap: `invoke_menu` is not app-checked.** It is classed as metadata-only
   (`core/src/authorization.rs:895`), so any app's menu, including Sonny's own, passes the
   manifest, and it activates the target app (`platform-macos/src/tools/invoke_menu.rs:307-314`).
5. **Off-Space windows.** Background input to a window on another Space is refused
   (`core/src/background_input.rs:228-241`). With `delivery_mode: "foreground"` cua raises the
   app and then gives focus back. The manifest's delivery-mode ceiling is recorded but not
   enforced.
6. **Other effects.** A screenshot can fall back to `/usr/sbin/screencapture` with a temp file;
   `set_value` on Safari runs `osascript`. The SDK has no event taps, no clipboard use outside the
   clipboard tools, and no file writes outside temp unless a tool asks for an output file.

**What phase 4 does about it:**

- Build the cua manifest per task, with `resources.apps` holding only the resolved target app.
- The Swift wrapper refuses a menu action unless the target pid's bundle id is the task's app and
  the pid is not Sonny's own.
- The wrapper sets `delivery_mode` itself and never passes the model's choice through. Screen
  actions run under the `ForegroundLease`, so the app is already in front.
- At launch, before any other thread starts, clear the nine managed variables
  (`CUA_DRIVER_PERMISSION_MODE`, `CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS`,
  `CUA_DRIVER_DISABLE_UNRESTRICTED`, `CUA_DRIVER_POLICY_FILE`,
  `CUA_DRIVER_MANAGED_POLICY_FILE`, `CUA_DRIVER_CAPABILITY_MANIFEST_FILE`,
  `CUA_DRIVER_CAPABILITY_MANIFEST_APPROVED`, `CUA_DRIVER_SESSION_POLICY_FILE`,
  `CUA_DRIVER_SESSION_POLICY_APPROVED`), so a stray shell setting can't stop create from working.
- Keep the telemetry tripwire in the fetch script, and read the source again before any version
  bump.

### First host

Oracle Cloud, on a VM, as recorded in `docs/sonny-row-12-host-decision.md` §12.4; Supabase keeps
auth and Postgres. The proxy in front of the gateway is **Caddy** on the same VM. It terminates TLS
with automatic certificates, passes WebSocket upgrades with no extra configuration, and reloads
without dropping connections. The gateway's own drain (`goodbye`, close code 1012) covers
restarts of the gateway process itself. This is a recommendation for phase H and doesn't block
phases 1 to 7, which run against the local Docker gateway.
