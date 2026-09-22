> Archived original V2 draft. It is historical design exploration, not the current delivery plan. See [current direction](../../sonny_v2_architecture_implementation_plan.md). Some relative links below were written when this file was at the repository root.

# Sonny v2 Architecture and Implementation Plan

## Purpose

This document defines a concrete technical plan for evolving Sonny from a planner-driven macOS task runner into a low-latency, local-first computer agent capable of arbitrary app automation.

The intended end state is that Sonny behaves less like a chatbot that occasionally clicks things and more like a second human/intern living inside the user's Mac:

- It understands the user's intent.
- It uses deterministic/native mechanisms whenever possible.
- It can operate arbitrary applications.
- It minimizes cloud-model calls.
- It does not unnecessarily steal the user's mouse or foreground focus.
- It pauses before consequential actions such as sending messages, deleting files, making purchases, submitting credentials, or committing external effects.
- It can optionally visualize what it is doing with a ghost cursor.
- It verifies that actions actually succeeded before proceeding.
- It continuously improves through structured execution traces and future task-specific local-model training.

This document assumes:

- Minimum supported hardware: Apple Silicon M1 with 8 GB RAM.
- Distribution: Developer ID outside the Mac App Store.
- Sonny may request Accessibility and Screen Recording permissions.
- Arbitrary application automation is a product requirement.
- A local model sidecar is acceptable.
- Latency and inference cost should be minimized.
- Consequential actions require user approval.
- Execution should be invisible when possible, with optional ghost-cursor visualization.

---

# 1. Existing Architecture Summary

The current architecture is approximately:

```text
Prompt
  ↓
FloatingWidgetView.submit()
  ↓
AgentViewModel.start()
  ↓
AgentViewModel.performStart()
  ↓
InstantCommandResolver OR OpenAIPlanner
  ↓
AgentPlan
  ↓
Risk assessment
  ↓
AgentRunner.execute()
  ↓
AgentActionExecutor
  ↓
CapabilityAdapter
  ↓
AgentRunResult
  ↓
finalSummary
  ↓
Widget / Task Receipt
```

Important current properties:

- `AgentViewModel` owns a large amount of orchestration responsibility.
- `InstantCommandResolver` handles a small number of deterministic fast paths.
- Most non-instant commands fall through to `OpenAIPlanner`.
- `AgentPlan` is relatively operation-oriented.
- `AgentActionExecutor` owns execution and risk checks.
- Capability adapters perform real work.
- Approval is mostly plan/run-oriented.
- Final presentation collapses largely into `finalSummary: String`.
- There is already a stale-approval check, which should be retained and strengthened.
- `copySummary()` exists but is currently orphaned.
- The current architecture is good for typed deterministic capabilities, but does not yet provide a robust arbitrary-app interaction runtime.

---

# 2. Architectural Principle

The core architectural change is:

> Sonny should be a semantic operating-system automation runtime with AI used for routing, planning, ambiguity resolution, and unknown cases.

Do not make visual computer use the default execution mode.

Use this execution hierarchy:

```text
1. Deterministic capability / direct API
2. Apple Events / native app scripting
3. App-specific semantic integration
4. macOS Accessibility
5. Visual computer use / CUA
6. Replan / ask user
```

This order is essential.

Native and semantic automation will provide:

- lower latency,
- lower inference cost,
- better reliability,
- better observability,
- better safety classification,
- less user disruption.

Visual computer use provides universality and should be treated as the fallback layer.

---

# 3. Target High-Level Architecture

```text
                         USER COMMAND
                              │
                              ▼
                    ┌──────────────────┐
                    │   AgentRuntime   │
                    └────────┬─────────┘
                             │
                    cached machine state
                             │
                             ▼
                    ┌──────────────────┐
                    │ ExecutionRouter  │
                    │ rules + local ML │
                    └────────┬─────────┘
                             │
         ┌───────────────────┼────────────────────┐
         │                   │                    │
         ▼                   ▼                    ▼
   deterministic         interactive         needs planning
         │                   │                    │
         │                   │             cloud planner
         │                   │                    │
         └───────────────────┴────────────────────┘
                             │
                             ▼
                    ┌──────────────────┐
                    │ Execution Engine │
                    └────────┬─────────┘
                             │
          ┌──────────────────┼───────────────────┐
          │                  │                   │
          ▼                  ▼                   ▼
   Native/Capability    Apple Events / AX    Visual CUA
          │                  │                   │
          └──────────────────┴───────────────────┘
                             │
                             ▼
                      Verify expected state
                             │
                    consequence detected?
                        │            │
                       no           yes
                        │            │
                        ▼            ▼
                     continue    Commit barrier
                                      │
                                 user approves
                                      │
                                      ▼
                                revalidate state
                                      │
                                      ▼
                                   execute
                                      │
                                      ▼
                                 final result
```

---

# 4. First Major Refactor: Remove Orchestration From AgentViewModel

## Problem

`AgentViewModel` currently owns:

- UI state,
- run lifecycle,
- cancellation,
- planning,
- routing,
- approval state,
- execution,
- final result state,
- task history updates.

As interactive automation becomes longer-lived and more concurrent, this will become brittle.

## Goal

Make `AgentViewModel` a UI-facing state adapter only.

## Proposed Structure

```swift
@MainActor
final class AgentViewModel: ObservableObject {
    private let runtime: AgentRuntime

    @Published var command: String = ""
    @Published var widgetState: WidgetState
    @Published var activeApproval: ApprovalPresentation?
    @Published var suggestions: [RunSuggestion] = []

    func start(origin: RunOrigin, fromComposer: Bool) {
        // forward to runtime
    }

    func cancel() {
        // forward to runtime
    }
}
```

Introduce:

```swift
actor AgentRuntime {
    let contextEngine: ContextEngine
    let router: ExecutionRouter
    let planner: TaskPlanner
    let executor: ExecutionEngine
    let policyEngine: PolicyEngine
    let historyStore: TaskHistoryStore

    func start(command: String, origin: RunOrigin) async
    func cancel(runID: RunID) async
    func approve(commitID: CommitID) async
}
```

---

# 5. Introduce RunSession

Long-running tasks need their own explicit execution lifetime.

```swift
actor RunSession {
    let id: RunID
    let command: String
    let origin: RunOrigin

    var goal: TaskGoal?
    var plan: AgentPlan?
    var state: RunState

    var executionTrace: [ExecutionEvent]
    var pendingCommit: PreparedCommit?
    var artifacts: [RunArtifact]

    func cancel()
    func pause()
    func resume()
}
```

Suggested states:

```swift
enum RunState {
    case created
    case routing
    case planning
    case executing
    case waitingForApproval(CommitID)
    case paused
    case completed
    case failed(AgentError)
    case cancelled
}
```

## Why

This enables:

- explicit task lifetime,
- clean cancellation,
- approval resume,
- future background tasks,
- concurrency,
- detailed execution tracing,
- pause/resume,
- better UI state synchronization.

---

# 6. Build ContextEngine

## Principle

Do not wait for a prompt to arrive before discovering the current machine state.

Sonny should maintain a lightweight, continuously updated semantic model of the current desktop.

## ContextEngine Responsibilities

Track:

- frontmost application,
- current focused window,
- current focused Accessibility element,
- currently selected text,
- Finder selection where available,
- clipboard metadata,
- open windows,
- active browser URL/title where accessible,
- recent application changes,
- recent window focus changes,
- latest Accessibility mutations,
- latest useful screenshot frame,
- recent user keyboard/mouse activity,
- active Sonny run ownership.

Example:

```swift
actor ContextEngine {
    var activeApplication: AppSnapshot
    var activeWindow: WindowSnapshot?
    var focusedElement: AXElementSnapshot?
    var currentSelection: SelectionSnapshot?
    var clipboard: ClipboardSnapshot?
    var recentEvents: RingBuffer<ContextEvent>

    let accessibilityObserver: AccessibilityObserver
    let screenObservationEngine: ScreenObservationEngine

    func snapshot() async -> MachineContext
}
```

## Context Snapshot

Keep this compact:

```swift
struct MachineContext: Sendable {
    let activeApplication: ApplicationSnapshot
    let activeWindow: WindowSnapshot?
    let focusedElement: AXElementSnapshot?
    let selection: SelectionSnapshot?
    let clipboardMetadata: ClipboardMetadata?
    let recentEvents: [ContextEvent]
}
```

Do not serialize the entire Accessibility tree into every model call.

---

# 7. Accessibility Observation

Use macOS Accessibility as a first-class semantic control layer.

Introduce:

```swift
protocol AccessibilityObserving {
    func snapshot(
        application: ApplicationTarget,
        scope: AXScope
    ) async throws -> AXSnapshot

    func focusedElement() async throws -> AXElementSnapshot?
}
```

Possible implementation:

```swift
final class AXObservationProvider: AccessibilityObserving {
    // wraps AXUIElement / AXObserver
}
```

Suggested semantic snapshot:

```swift
struct AXElementSnapshot: Sendable, Hashable {
    let id: AXElementID
    let role: String
    let subrole: String?
    let title: String?
    let value: String?
    let description: String?
    let enabled: Bool
    let focused: Bool
    let frame: CGRect?
    let supportedActions: [AXActionName]
}
```

## Important

Use `AXObserver` notifications where possible.

Avoid repeatedly traversing the entire application hierarchy.

Maintain a cache of:

- active app subtree,
- focused window subtree,
- changed elements,
- known stable semantic identifiers.

---

# 8. Screen Observation Engine

Use ScreenCaptureKit as the visual observation layer.

Responsibilities:

- keep a warm stream where appropriate,
- maintain latest useful frame,
- capture specific app/window/region when needed,
- avoid repeated stream initialization,
- expose window geometry,
- crop visual observations intelligently.

```swift
actor ScreenObservationEngine {
    func latestFrame(for target: VisualTarget) async throws -> ScreenFrame
    func capture(_ target: VisualTarget) async throws -> ScreenFrame
}
```

Targets:

```swift
enum VisualTarget {
    case display(CGDirectDisplayID)
    case application(BundleIdentifier)
    case window(WindowID)
    case rect(CGRect)
}
```

## Rule

Never default to uploading the full display if:

- target application is known,
- target window is known,
- relevant control region is known.

Prefer the smallest useful visual context.

---

# 9. ExecutionRouter

The current routing logic is effectively:

```text
InstantCommandResolver
      ↓ miss
OpenAIPlanner
```

Replace it with:

```text
InstantCommandResolver
      ↓ miss
ExecutionRouter
      ↓
direct capability
native scripting
interactive semantic execution
visual execution
cloud planning
clarification
```

Suggested interface:

```swift
protocol ExecutionRouting {
    func route(
        command: String,
        context: MachineContext
    ) async throws -> ExecutionRoute
}
```

```swift
enum ExecutionRoute {
    case instant(AgentOperation)
    case capability(CapabilityInvocation)
    case interactive(InteractionGoal)
    case needsPlanning
    case clarification(ClarificationRequest)
}
```

---

# 10. Fast Local Decision Layer

Do not use a local model as a free-form planner.

Use it for bounded decisions.

Good candidate tasks:

- intent family,
- capability family,
- native vs AX vs visual,
- whether visual state is needed,
- candidate UI element choice,
- retry vs fallback vs replan,
- rough ambiguity classification.

Bad candidate tasks:

- full free-form planning,
- final user-visible prose,
- authoritative safety decisions,
- arbitrary long reasoning.

Example output:

```swift
struct FastDecision {
    let route: FastRouteClass
    let taskFamily: TaskFamily
    let appFamily: AppFamily?
    let needsVisualState: Bool
    let needsPlanner: Bool
    let confidence: Float
}
```

---

# 11. Laya / Jev Strategy

Treat Laya/Jev-style models as a future Sonny-specific fast decision model.

Do not immediately make stock Laya authoritative.

Recommended rollout:

```text
rules + existing planner
        ↓
collect execution traces
        ↓
label routing outcomes
        ↓
train Sonny-specific decision model
        ↓
evaluate
        ↓
move only proven decisions local
```

## M1/8 GB Constraint

Do not keep multiple large models resident.

Production target:

```text
ONE local decision model
```

Prefer a small encoder / structured decision model.

Initial experiment may use:

```text
Swift app
  ↓ Unix socket / XPC
Python sidecar
  ↓
PyTorch MPS
  ↓
one hot checkpoint
```

Requirements:

- model loaded once,
- no Python process launch per command,
- no checkpoint loading per inference,
- bounded memory use,
- local request/response format kept stable,
- runtime implementation replaceable later.

Possible sidecar request:

```json
{
  "command": "send this to Michael on Slack",
  "context": {
    "frontmostApp": "Preview",
    "selection": "/Users/me/Desktop/report.pdf",
    "installedTargets": ["Slack"]
  },
  "questions": {
    "route": ["capability", "appleEvents", "ax", "vision", "planner"],
    "needsVision": [true, false]
  }
}
```

Possible response:

```json
{
  "route": "ax",
  "needsVision": false,
  "confidence": 0.91
}
```

---

# 12. SemanticOperation

Do not give the model unrestricted AppleScript as the primary abstraction.

Introduce a typed semantic action layer.

```swift
enum SemanticOperation: Sendable {
    case launchApplication(BundleIdentifier)

    case filesystem(FileOperation)
    case finder(FinderOperation)
    case mail(MailOperation)
    case browser(BrowserOperation)
    case messaging(MessagingOperation)
    case calendar(CalendarOperation)

    case accessibility(UIOperation)
}
```

Examples:

```swift
enum MailOperation {
    case createDraft(
        recipients: [String],
        subject: String?,
        body: String
    )

    case attachFile(URL)
    case sendCurrentDraft
}
```

```swift
enum FileOperation {
    case move(URL, to: URL)
    case rename(URL, to: String)
    case copy(URL, to: URL)
    case trash(URL)
    case permanentlyDelete(URL)
}
```

## Why

Typed semantic operations provide:

- better policy enforcement,
- better logging,
- better retry behavior,
- easier testing,
- clearer user previews,
- backend flexibility.

The same semantic operation may be implemented using:

- Swift APIs,
- Scripting Bridge,
- Apple Events,
- AppleScript,
- Accessibility,
- visual automation.

---

# 13. AppleEventsBackend

Do not make a generic arbitrary-script adapter the main automation path.

Instead:

```swift
protocol SemanticExecutionBackend {
    func canExecute(_ operation: SemanticOperation) async -> Bool
    func execute(_ operation: SemanticOperation) async throws -> OperationResult
}
```

Implement:

```swift
final class AppleEventsBackend: SemanticExecutionBackend
```

Internally this may use:

- Scripting Bridge,
- NSAppleScript,
- `osascript`,
- direct Apple Event APIs.

But this is an implementation detail.

## App-Specific Adapters

Consider:

```swift
protocol AppScriptingAdapter {
    var bundleIdentifier: String { get }

    func supportedOperations() async -> Set<SemanticOperationKind>

    func execute(
        _ operation: SemanticOperation
    ) async throws -> OperationResult
}
```

Build adapters over time for important scriptable apps.

---

# 14. AccessibilityBackend

Introduce:

```swift
final class AccessibilityBackend: SemanticExecutionBackend
```

Responsibilities:

- locate candidate UI elements,
- rank/filter candidates,
- execute AX actions,
- set values,
- focus controls,
- invoke buttons/menu items,
- verify postconditions.

Possible `UIOperation`:

```swift
enum UIOperation {
    case focus(ElementQuery)
    case press(ElementQuery)
    case setValue(ElementQuery, String)
    case select(ElementQuery)
    case openMenuItem(MenuPath)
}
```

---

# 15. Candidate Generation

Do not ask a model:

```text
"What should I click?"
```

First deterministically generate a small set of relevant candidates.

Input:

- current subgoal,
- current AX state,
- focused app/window,
- element role,
- titles,
- enabled state,
- frame,
- actions.

Output:

```swift
struct ActionCandidate {
    let id: CandidateID
    let action: SemanticAction
    let element: AXElementSnapshot?
    let heuristicScore: Float
}
```

Example:

```text
Goal: Attach report.pdf

Candidates:
A. Button "Attach"
B. Menu Item File → Attach Files
C. Button "Send"
D. Text Area "Message"
E. Replan
```

Then the local decision model can perform a bounded choice.

This is much more reliable than sending a full Accessibility tree to a model.

---

# 16. InteractionGoal

Move plans away from click-by-click instructions.

Use goal-based interactive units.

```swift
struct InteractionGoal: Sendable {
    let application: ApplicationTarget?
    let objective: Objective
    let completionCriteria: [StatePredicate]
    let allowedEffects: EffectSet
    let commitPolicy: CommitPolicy
}
```

Example:

```swift
InteractionGoal(
    application: .bundleID("com.apple.mail"),
    objective: .composeEmail(
        to: ["sam@example.com"],
        subject: nil,
        body: "I'll be there at eight."
    ),
    completionCriteria: [
        .draftContainsRecipient("sam@example.com"),
        .draftContainsBodyHash(bodyHash)
    ],
    allowedEffects: [
        .openApplication,
        .createDraft
    ],
    commitPolicy: .requireApproval(
        before: .externalCommunication
    )
)
```

---

# 17. Update AgentPlan

Recommended new shape:

```swift
struct AgentPlan: Sendable, Codable {
    let objective: String
    let units: [ExecutionUnit]
    let completionCriteria: [CompletionCriterion]
}
```

```swift
enum ExecutionUnit: Sendable, Codable {
    case deterministic(CapabilityInvocation)
    case semantic(SemanticOperation)
    case interactive(InteractionGoal)
}
```

The planner should not predict every click.

It should produce:

- task objective,
- semantic operations,
- interactive subgoals,
- completion criteria.

---

# 18. ExecutionEngine

Replace capability-only execution with a backend-aware engine.

```swift
actor ExecutionEngine {
    let nativeBackend: NativeCapabilityBackend
    let appleEventsBackend: AppleEventsBackend
    let accessibilityBackend: AccessibilityBackend
    let visualBackend: VisualInteractionBackend

    let policyEngine: PolicyEngine
    let verifier: StepVerifier

    func execute(
        _ unit: ExecutionUnit,
        in session: RunSession
    ) async throws -> ExecutionUnitResult
}
```

---

# 19. Execution Fallback Ladder

Every interaction should follow this order unless explicitly overridden:

```text
Can a deterministic capability execute it?
       │
      yes → execute
       │
      no
       ▼
Can Apple Events / native scripting execute it?
       │
      yes → execute
       │
      no
       ▼
Can Accessibility execute it semantically?
       │
      yes → execute
       │
      no / verification failed
       ▼
Can visual CUA execute it?
       │
      yes → execute
       │
      no
       ▼
Replan
       │
still blocked
       ▼
Ask user
```

This ladder should be explicit in code.

---

# 20. Step Verification

Do not consider an action successful merely because it executed without throwing.

Every meaningful action should have expected effects.

```swift
struct ExecutableAction {
    let action: AgentAction
    let expectedEffects: [StatePredicate]
}
```

Examples:

```text
Action:
Press "New Message"

Expected:
A compose window exists
```

```text
Action:
Set recipient field to "sam@example.com"

Expected:
Recipient field contains "sam@example.com"
```

```text
Action:
Attach report.pdf

Expected:
Attachment named "report.pdf" is visible
```

Implement:

```swift
protocol StepVerifying {
    func verify(
        _ predicates: [StatePredicate],
        context: MachineContext
    ) async throws -> VerificationResult
}
```

Suggested result:

```swift
enum VerificationResult {
    case satisfied
    case partiallySatisfied
    case failed(reason: String)
    case indeterminate
}
```

---

# 21. Retry and Escalation

When verification fails:

```text
1. Re-observe
2. Retry same semantic path if state plausibly lagged
3. Try alternate semantic candidate
4. Escalate to visual interaction
5. Replan
6. Ask user
```

Add retry metadata:

```swift
struct RetryPolicy {
    let maxSemanticAttempts: Int
    let maxVisualAttempts: Int
    let allowReplan: Bool
}
```

---

# 22. PolicyEngine and Effect-Based Safety

Do not use an ML model as the final authority for consequential actions.

Create an effect-based policy layer.

```swift
enum ActionEffect: Sendable {
    case readOnly
    case localReversibleMutation
    case externalCommunication
    case deleteData
    case permanentlyDeleteData
    case financialCommitment
    case installSoftware
    case securityChange
    case credentialSubmission
}
```

Policy:

```swift
enum ApprovalRequirement {
    case autoRun
    case lightweightConfirmation
    case explicitCommit
    case previewOnly
    case refuse
}
```

```swift
protocol PolicyEvaluating {
    func requirement(
        for effect: ActionEffect,
        action: AgentAction,
        context: MachineContext
    ) -> ApprovalRequirement
}
```

---

# 23. Commit Barrier

Approval should happen immediately before the irreversible or externally consequential effect.

Example:

```text
User: "Tell Jake I pushed the fix."

Sonny:
- Open Slack
- Find Jake
- Open conversation
- Type "I pushed the fix"
- STOP

Approval UI:
"Send message to Jake?"
"I pushed the fix"

[Cancel] [Send]
```

This is better than approving an entire plan at the beginning.

---

# 24. PreparedCommit

```swift
struct PreparedCommit: Sendable {
    let id: CommitID
    let effect: ActionEffect
    let action: AgentAction

    let targetFingerprint: TargetFingerprint
    let stateFingerprint: StateFingerprint

    let preview: CommitPreview
    let createdAt: ContinuousClock.Instant
    let expiresAt: ContinuousClock.Instant
}
```

Approval binds to exactly:

- the target,
- the action,
- the content,
- the current state.

Approval does not mean:

> Sonny may keep doing arbitrary consequential work.

---

# 25. Stale Approval Validation

When the user approves:

```text
Read current state
  ↓
Compare target fingerprint
  ↓
Compare state fingerprint
  ↓
If unchanged:
    execute exact approved action
Else:
    invalidate approval
    regenerate preview
```

Examples of stale state:

- selected chat changed,
- file changed,
- compose window changed,
- recipient changed,
- page navigated,
- target element disappeared.

The existing stale-approval concept should be retained and strengthened around exact commit tokens.

---

# 26. VisualInteractionProvider

CUA should operate on subgoals, not entire broad tasks.

Interface:

```swift
protocol VisualInteractionProvider {
    func advance(
        goal: InteractionGoal,
        observation: VisualObservation,
        trace: InteractionTrace
    ) async throws -> VisualDecision
}
```

Possible implementations:

```text
OpenAIComputerProvider
AnthropicComputerProvider
FutureLocalVisionProvider
```

Keep this provider-neutral.

---

# 27. Visual Subgoal Example

Bad prompt:

```text
"Find the file I downloaded, attach it to an email to Fred, explain it,
send the email, then archive the original."
```

Good visual subgoal:

```text
Current subgoal:
Open the Downloads folder in the file picker.

Completion condition:
The file picker displays ~/Downloads.

Do not select or open any file yet.
```

Small subgoals improve:

- reliability,
- cost,
- safety,
- verification,
- recovery.

---

# 28. Batch Visual Actions Where Safe

If the computer-use provider can return multiple low-risk actions, Sonny may batch them when:

- state transitions are predictable,
- no consequential action is crossed,
- no ambiguous UI decision occurs,
- intermediate verification is unnecessary.

Example:

```text
click text field
type query
press Enter
```

can often batch.

Do not batch:

```text
select recipient
type message
press Send
```

because Send is a commit boundary.

---

# 29. Ghost Cursor

The ghost cursor should be visualization only.

Do not couple it to physical mouse control.

Architecture:

```text
Execution Engine
      │
      ├── actual action
      │      AX / Apple Event / CGEvent
      │
      └── InteractionEvent
                 │
                 ▼
        GhostCursorOverlay
```

Example:

```swift
struct InteractionEvent: Sendable {
    let timestamp: ContinuousClock.Instant
    let kind: InteractionKind
    let targetFrame: CGRect?
    let description: String
    let backend: InteractionBackend
}
```

The ghost cursor can animate toward `targetFrame` even when the real action occurred invisibly via Accessibility.

---

# 30. Foreground vs Background Execution

Every execution path should declare whether it requires the foreground UI.

```swift
enum InteractionRequirement {
    case backgroundSafe
    case foregroundRequired
}
```

Examples:

Background-safe:

- filesystem operations,
- some Apple Events,
- calculations,
- indexing,
- API work,
- preparing data.

Foreground-required:

- many AX flows,
- visual CUA,
- some dialogs,
- some app-specific controls.

Sonny should prefer background-safe execution whenever possible.

---

# 31. UIExecutionLane

Interactive desktop manipulation must be serialized.

```swift
actor UIExecutionLane {
    func acquire(for runID: RunID) async throws -> UILease
}
```

Only one run should manipulate the foreground interactive UI at a time.

Parallel work can still include:

- file search,
- network requests,
- parsing,
- summarization,
- indexing,
- background scripting.

---

# 32. Detect User Interference

Monitor physical keyboard/mouse activity.

If the user interferes during foreground-required automation:

```text
user input detected
      ↓
mark environment changed
      ↓
pause unsafe action sequence
      ↓
re-observe state
      ↓
resume only if valid
```

Do not blindly continue executing old screen coordinates after user interaction.

---

# 33. Result Model Upgrade

Stop treating `finalSummary: String` as the full result representation.

Introduce:

```swift
struct AgentPresentationResult: Sendable {
    let message: String
    let copyValue: String?
    let artifacts: [RunArtifact]
    let suggestions: [RunSuggestion]
    let receipt: ExecutionReceipt?
}
```

Example UI:

```text
Created large-files.zip

[Open]
[Reveal in Finder]
[Copy path]
```

instead of only:

```text
"Zipped 3 files to ~/Desktop/large-files.zip."
```

---

# 34. Immediate UX Fixes

Do immediately:

1. Wire `AgentViewModel.copySummary()` to a visible copy button.
2. Add `.textSelection(.enabled)` to the floating widget result text.
3. Add artifact-aware result actions.
4. Display approval previews with exact target/action/content.
5. Display a concise execution state such as:
   - Opening Mail
   - Preparing message
   - Waiting for approval
   - Sending
   - Done

---

# 35. Observability

Structured traces are mandatory.

Log:

```text
runID
command
route
route latency
planner used?
planner latency
frontmost app
target app
backend selected
candidate actions
selected candidate
action effect
approval required?
approval wait time
execution start
execution finish
verification result
retry count
fallback count
visual calls
visual round-trip latency
success/failure
user interruption
user correction
final result
```

Do not indiscriminately retain raw screenshots.

Store semantic execution data wherever possible.

---

# 36. ExecutionTrace

```swift
struct ExecutionEvent: Sendable {
    let timestamp: ContinuousClock.Instant
    let runID: RunID
    let category: ExecutionEventCategory
    let payload: ExecutionEventPayload
}
```

Possible categories:

```swift
enum ExecutionEventCategory {
    case routed
    case planned
    case backendSelected
    case candidateGenerated
    case actionStarted
    case actionFinished
    case verification
    case retry
    case fallback
    case approvalRequested
    case approvalGranted
    case approvalInvalidated
    case userInterference
    case completed
    case failed
}
```

---

# 37. Latency Metrics

Primary product metric:

```text
timeToFirstUsefulAction
```

Do not optimize only for full completion time.

Suggested engineering targets:

| Stage | Initial target |
|---|---:|
| command capture → runtime | < 5 ms |
| cached context read | < 5 ms |
| deterministic routing | < 2 ms |
| local learned routing | < 75 ms p95 |
| first native action | < 100 ms where possible |
| first AX action | < 150 ms where possible |
| working UI shown | < 50 ms |
| cloud-planned task first useful action | aim for < 1 s |
| visual CUA | minimize round trips |

These are design goals, not guaranteed measurements.

---

# 38. Required Timing Instrumentation

Track spans:

```text
submit → context
context → route
route → plan
plan → execution
execution → first useful action
action → observation
observation → verification
visual capture
visual encode
visual upload
visual inference
visual response
approval wait
commit execution
total task time
```

Use signposts / structured metrics.

---

# 39. Cost Strategy

Goal:

> Use one generative reasoning call where possible, zero when deterministic routing is sufficient.

Example task:

```text
"Find the PDF I downloaded yesterday, rename it invoice.pdf,
attach it to an email to Fred, and say 'here it is'."
```

Ideal execution:

```text
local route
    ↓
local/native file search
    ↓
local rename
    ↓
Apple Events / AX email draft
    ↓
attach file
    ↓
STOP at send
    ↓
user approval
    ↓
send
```

Avoid:

```text
LLM
screenshot
LLM
click
screenshot
LLM
click
...
```

---

# 40. Suggested Folder / Module Layout

Possible project organization:

```text
Sonny/
├── Agent/
│   ├── AgentRuntime.swift
│   ├── RunSession.swift
│   ├── RunState.swift
│   ├── AgentPlan.swift
│   └── ExecutionUnit.swift
│
├── Context/
│   ├── ContextEngine.swift
│   ├── MachineContext.swift
│   ├── AccessibilityObserver.swift
│   ├── AXSnapshot.swift
│   ├── ScreenObservationEngine.swift
│   └── UserInputObserver.swift
│
├── Routing/
│   ├── ExecutionRouter.swift
│   ├── InstantCommandResolver.swift
│   ├── FastDecisionEngine.swift
│   ├── RuleBasedRouter.swift
│   └── SidecarDecisionClient.swift
│
├── Planning/
│   ├── TaskPlanner.swift
│   ├── OpenAIPlanner.swift
│   └── PlanDecoder.swift
│
├── Execution/
│   ├── ExecutionEngine.swift
│   ├── UIExecutionLane.swift
│   ├── StepVerifier.swift
│   ├── RetryPolicy.swift
│   └── ExecutionTrace.swift
│
├── Backends/
│   ├── Native/
│   │   └── NativeCapabilityBackend.swift
│   │
│   ├── AppleEvents/
│   │   ├── AppleEventsBackend.swift
│   │   ├── AppScriptingAdapter.swift
│   │   └── AppleScriptFallbackAdapter.swift
│   │
│   ├── Accessibility/
│   │   ├── AccessibilityBackend.swift
│   │   ├── AXActionExecutor.swift
│   │   ├── AXCandidateGenerator.swift
│   │   └── ElementQuery.swift
│   │
│   └── Visual/
│       ├── VisualInteractionProvider.swift
│       ├── OpenAIComputerProvider.swift
│       ├── VisualObservation.swift
│       └── InteractionTrace.swift
│
├── Semantics/
│   ├── SemanticOperation.swift
│   ├── InteractionGoal.swift
│   ├── StatePredicate.swift
│   ├── Objective.swift
│   └── ActionEffect.swift
│
├── Policy/
│   ├── PolicyEngine.swift
│   ├── ApprovalRequirement.swift
│   ├── PreparedCommit.swift
│   ├── StateFingerprint.swift
│   └── TargetFingerprint.swift
│
├── Presentation/
│   ├── AgentPresentationResult.swift
│   ├── RunArtifact.swift
│   └── ExecutionReceipt.swift
│
└── Overlay/
    ├── GhostCursorOverlay.swift
    └── InteractionVisualizationController.swift
```

---

# 41. Migration Plan

## Phase 0 — Instrument Current System

Before changing architecture:

- add timing spans,
- log planner usage,
- log capability selection,
- log execution outcome,
- log approval outcome,
- log total latency.

Goal:

Understand the current baseline.

Acceptance criteria:

- every run has a trace ID,
- route/planner/execution timings are visible,
- success/failure is attributable to a stage.

---

## Phase 1 — Extract AgentRuntime

Move orchestration out of `AgentViewModel`.

Tasks:

- create `AgentRuntime`,
- create `RunSession`,
- move planning calls,
- move execution calls,
- move approval lifecycle,
- keep UI behavior unchanged.

Acceptance criteria:

- current features still work,
- `AgentViewModel` no longer owns core task execution logic,
- cancellation works,
- approval resume works.

---

## Phase 2 — ContextEngine

Tasks:

- implement frontmost app tracking,
- implement focused window tracking,
- add AX observer,
- cache focused element,
- track user input,
- introduce latest screen frame management.

Acceptance criteria:

- context snapshot is available without synchronous expensive OS discovery,
- active app/window changes are reflected quickly,
- no full AX traversal required for ordinary routing.

---

## Phase 3 — SemanticOperation

Tasks:

- define semantic operation hierarchy,
- map existing `AgentOperation`s into semantic operations where appropriate,
- keep legacy adapters working behind compatibility wrappers.

Acceptance criteria:

- planner/executor can express effects without naming a backend,
- backend choice is separate from task semantics.

---

## Phase 4 — AppleEventsBackend

Tasks:

- add typed Apple Events execution,
- add Scripting Bridge where practical,
- add `osascript` only as a fallback implementation,
- add first app adapters.

Recommended first apps:

- Finder,
- Mail,
- Safari,
- Notes,
- Calendar.

Acceptance criteria:

- typed semantic operations can execute without foreground UI where supported,
- no arbitrary AppleScript is required for common cases,
- effects pass through PolicyEngine.

---

## Phase 5 — AccessibilityBackend

Tasks:

- AX element snapshots,
- element queries,
- action execution,
- deterministic candidate filtering,
- verification.

Acceptance criteria:

- Sonny can reliably operate common UI controls,
- execution is semantic rather than coordinate-based,
- actions have postconditions.

---

## Phase 6 — PolicyEngine + Commit Barrier

Tasks:

- define `ActionEffect`,
- classify existing operations,
- implement `PreparedCommit`,
- bind approval to exact action/target/state,
- invalidate stale approvals.

Acceptance criteria:

- external communication does not auto-send,
- destructive actions do not auto-commit,
- target changes invalidate old approvals.

---

## Phase 7 — Goal-Based Planner

Tasks:

- update `AgentPlan`,
- add `ExecutionUnit`,
- add `InteractionGoal`,
- add completion criteria,
- stop planning individual clicks unless unavoidable.

Acceptance criteria:

- planner output remains valid even if UI layout changes,
- executor decides backend,
- interactive tasks can re-route between AX and CUA.

---

## Phase 8 — Visual CUA

Tasks:

- implement provider-neutral interface,
- implement first provider,
- crop observations intelligently,
- execute subgoal-level visual tasks,
- add verification,
- enforce commit barrier during CUA.

Acceptance criteria:

- arbitrary unsupported UIs can be manipulated,
- CUA is only used after semantic paths fail or are unavailable,
- visual execution cannot bypass policy.

---

## Phase 9 — Ghost Cursor

Tasks:

- execution event stream,
- overlay,
- animate semantic actions,
- expose user toggle.

Acceptance criteria:

- ghost cursor can visualize AX/native actions,
- real user cursor is not required to move,
- overlay can be disabled.

---

## Phase 10 — Local Decision Model

Do this only after collecting traces.

Tasks:

- create routing dataset,
- label successful routes,
- evaluate stock Laya/Jev-like models,
- fine-tune Sonny-specific model,
- integrate behind feature flag,
- compare against rules/cloud routing.

Acceptance criteria:

- statistically meaningful improvement or equal quality at lower latency/cost,
- no safety decisions delegated to model,
- graceful fallback exists.

---

# 42. Recommended Initial App Coverage

Even though arbitrary app automation is the goal, optimize first for representative categories:

1. Finder — filesystem + native scripting.
2. Mail — scripting + AX + commit barrier.
3. Safari — scripting + AX + browser-state semantics.
4. Slack — AX-heavy app.
5. Chrome — AX + web content edge cases.
6. Notes — native/simple AX.
7. Preview — file/document context.
8. Generic Electron app — stress AX quality.
9. One custom-canvas app — validate visual fallback.

Do not make the architecture depend on these apps.

Use them as test fixtures.

---

# 43. Test Strategy

## Unit Tests

Test:

- routing rules,
- policy classification,
- state fingerprinting,
- stale approval logic,
- semantic-to-backend mapping,
- candidate filtering,
- retry logic.

## Integration Tests

Build controlled fixtures for:

- AX button press,
- form fill,
- file picker,
- menu navigation,
- Mail draft,
- Finder rename,
- Send approval,
- delete approval.

## Replay Tests

Store sanitized semantic execution traces and replay:

```text
context
goal
candidate set
expected action
expected backend
expected policy
```

This becomes future local-model training/evaluation data.

---

# 44. Reliability Metrics

Track:

```text
task success rate
first-attempt success rate
verification failure rate
AX → CUA fallback rate
CUA → replan rate
user correction rate
stale approval rate
user-interference rate
average retries per task
planner calls per task
visual calls per task
```

Segment by:

- application,
- task family,
- backend,
- OS version,
- hardware class.

---

# 45. Local Model Dataset

Every route decision can become training data.

Example record:

```json
{
  "command": "attach this to an email to Fred",
  "context": {
    "frontmostApp": "Preview",
    "selectionType": "file",
    "selectionExtension": "pdf"
  },
  "chosenRoute": "interactive",
  "preferredBackend": "appleEvents",
  "fallbackBackend": "accessibility",
  "success": true
}
```

Also collect:

- candidate set,
- chosen candidate,
- verification result,
- final backend,
- whether fallback was needed.

Human review a subset before training.

---

# 46. Privacy Requirements

Because Sonny observes the user's desktop:

- avoid long-term raw screenshot retention by default,
- redact or avoid credential fields,
- keep semantic state local where possible,
- make cloud visual calls explicit in privacy documentation,
- separate telemetry from task content,
- provide telemetry opt-out,
- never train on private user content without explicit policy/consent.

---

# 47. Security Requirements

Do not allow:

```text
planner → arbitrary shell / arbitrary AppleScript → unrestricted execution
```

without policy constraints.

All actions should pass through typed execution boundaries.

At minimum:

```text
planner
  ↓
typed semantic operation
  ↓
policy engine
  ↓
backend selection
  ↓
execution
  ↓
verification
```

For intentionally supported shell/script execution:

- sandbox commands,
- classify side effects,
- constrain environment,
- require approval for high-risk actions,
- log exact command,
- disable hidden policy bypasses.

---

# 48. Handling Unknown Applications

For an unknown app:

```text
identify bundle ID
      ↓
look for known adapter
      ↓ no
inspect AX support
      ↓
AX candidate execution
      ↓ insufficient
capture relevant window
      ↓
visual CUA
      ↓
verify through AX if possible
      ↓
verify visually otherwise
```

Over time, repeated interaction patterns may justify creating a dedicated adapter.

---

# 49. Learning New Capabilities

When a repeated visual task is observed:

```text
CUA performs task repeatedly
      ↓
structured traces show stable pattern
      ↓
engineer converts pattern to semantic adapter
      ↓
future tasks become deterministic
```

This creates a natural optimization loop:

```text
visual → semantic → native
```

The more Sonny is used, the fewer expensive visual actions should be required.

---

# 50. Recommended Execution Example

User:

```text
"Find the PDF I downloaded yesterday, rename it invoice.pdf,
attach it to an email to Fred, and say 'here it is'."
```

Expected flow:

```text
1. Runtime receives command.
2. ContextEngine provides cached context.
3. Router classifies:
   - file search + rename
   - email composition
   - external communication commit required.
4. Planner creates:
   - deterministic file unit
   - interactive email-compose goal
   - send commit.
5. File backend finds matching PDF.
6. File backend renames it.
7. Mail adapter attempts Apple Events.
8. If unavailable, AX backend opens compose UI.
9. Recipient, body, attachment are populated.
10. Verifier confirms:
    - Fred selected
    - correct body
    - invoice.pdf attached.
11. PolicyEngine emits PreparedCommit for send.
12. UI displays exact send preview.
13. User approves.
14. Runtime revalidates recipient/body/window.
15. Send action executes.
16. Verifier confirms draft/send state changed.
17. Presentation result shows:
    - email sent
    - attachment used
    - optional receipt.
```

Only one reasoning-model call may be needed.

Potentially none if the task becomes common enough to route deterministically.

---

# 51. Recommended `performStart()` End State

The current giant orchestration path should converge toward:

```swift
func start(command: String, origin: RunOrigin) async {
    let session = RunSession(
        command: command,
        origin: origin
    )

    let context = await contextEngine.snapshot()

    let route = try await router.route(
        command: command,
        context: context
    )

    switch route {
    case .instant(let operation):
        try await executor.execute(
            .deterministic(operation),
            in: session
        )

    case .capability(let invocation):
        try await executor.execute(
            .deterministic(invocation),
            in: session
        )

    case .interactive(let goal):
        try await executor.execute(
            .interactive(goal),
            in: session
        )

    case .needsPlanning:
        let plan = try await planner.plan(
            command: command,
            context: context
        )

        try await executor.execute(
            plan,
            in: session
        )

    case .clarification(let request):
        await presentClarification(request)
    }
}
```

The view model should not contain execution strategy.

---

# 52. Non-Goals

Do not attempt initially:

- fully autonomous long-running background workflows with no user visibility,
- replacing deterministic policy with ML,
- letting a local model generate unrestricted shell scripts,
- training a foundation model from scratch,
- solving arbitrary visual UI exclusively through pixels,
- building app-specific native adapters for every application before shipping CUA,
- optimizing the local model before gathering real Sonny traces.

---

# 53. Priority Order

If engineering resources are limited, implement in this exact order:

```text
1. Instrumentation
2. AgentRuntime / RunSession extraction
3. ContextEngine
4. SemanticOperation
5. PolicyEngine + commit barrier
6. AppleEventsBackend
7. AccessibilityBackend
8. Verification + fallback
9. Goal-based plan format
10. Visual CUA
11. Ghost cursor
12. Trace dataset
13. Sonny-specific local decision model
```

Do not start with the local model.

Do not start with screenshot-only CUA.

The semantic execution runtime is the foundation.

---

# 54. Definition of Success

Sonny v2 should feel like:

> "I told another person on my Mac what I wanted, and they handled it."

Not:

> "I watched an AI slowly reason about every click."

A successful implementation should achieve:

- instant response for deterministic commands,
- semantic execution for most standard UI tasks,
- arbitrary-app fallback through CUA,
- very few cloud round trips,
- strong action verification,
- explicit approval only at consequential commit points,
- minimal foreground disruption,
- transparent optional ghost visualization,
- clear result artifacts,
- structured traces suitable for future optimization.

The long-term competitive advantage is not merely that Sonny can use a computer.

It is that Sonny understands macOS well enough to avoid using the computer like a human unless it actually has to.
