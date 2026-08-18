---
paths:
  - "Sources/MacAgentCore/**"
  - "Tests/MacAgentCoreTests/**"
---
# MacAgentCore conventions

`MacAgentCore` is business logic only — no SwiftUI, no UI state. Capabilities, risk/approval, local stores, planner integration.

## Capability adapters

Every executable capability is a `CapabilityAdapter`, registered in `DefaultCapabilityAdapters.all()`. A new capability follows the same shape as the existing ones (`OpenSafeURLCapabilityAdapter`, `RunRoutineCapabilityAdapter`, etc.) — don't add a one-off switch case in the executor instead. Adapters own `preview(_:)` (synchronous, non-throwing, must never make a live network/OAuth/API call — dry-run has to stay truly free of side effects) and `assessRisk(plan:context:)` (defaults to a static `defaultRiskTier` when the capability doesn't need dynamic escalation). Capabilities whose plans can contain nested sub-plans (routines) use the `previewNestedPlan`/`executeNestedPlan`/`assessNestedPlan` closures on `CapabilityExecutionContext` — all three, not a subset, or nested risk silently doesn't get assessed.

## Risk tiers and the approval boundary

Tiers: 0 auto-run, 1 auto-run unless policy tightens, 2 lightweight confirmation, 3 explicit approval, 4 refuse. `AgentRunner` is the only thing that decides approve/refuse — it calls `AgentActionExecutor.assessRisk(plan:)` for a read-only assessment, then gates. `AgentActionExecutor.execute(plan:log:)` is the already-approved execution primitive and must never re-gate itself; if you're tempted to add a confirmation check inside `execute()`, the gating belongs in `AgentRunner` instead. Approval decisions carry the approved tier, not a bool, so a stale approval can be rejected if a fresh reassessment lands at a higher tier.

## Local stores

All 9 local stores (routines, workspaces, clipboard history + settings, snippets, recent artifacts, Shortcut run history, task history, the vision session journal) share one pattern via `LocalStorageEncryption`: a defaulted `encryption: LocalStorageEncryption = .shared` constructor param, AES-GCM encryption with the `SONNYENC1\n` file header, and transparent legacy-plaintext-JSON migration (decode once, rewrite encrypted on next successful load). A new store follows this exactly — don't invent a variant encryption scheme or skip migration. `LocalStorageEncryption.shared` auto-detects test processes (bundle path / `XCTestConfigurationFilePath`) and supplies a deterministic ephemeral key under SwiftPM/XCTest; new tests should still prefer an explicitly injected key manager over relying on that fallback, and must never exercise the user's real login Keychain.

Load failures and write failures need different user-facing handling. An existing file that fails to decrypt/decode on load is a real, visible problem — surface it via `recordLocalStorageLoadFailure(_:error:)` / `clearLocalStorageLoadFailure(_:)`, never collapse it into empty/default state with `try?`. A *write* failure is a different thing and must not reuse that same load-failure banner (its wording is hardcoded to "could not be decrypted or decoded," which is wrong for a save failure) — set a direct, accurate `errorMessage` instead, following `applyClipboardHistoryNoticeChoice`'s pattern.

## Testing

Everything OpenAI/network/Shortcuts/filesystem-adjacent is behind an injectable seam so tests never make live calls — fixture-backed HTTP protocols, fake planners/transcribers, `FailingPlanner: Planning` conformances for exercising planner-independent paths. When you change a `Planning` method signature, every existing conformance (including the test fakes) needs updating in the same change, not left to bit-rot.

## Untrusted content boundary

**There are two untrusted sources, and the delimiters live in one place.** `UntrustedContentBoundary` owns the four marker strings and the escaping; `WebResearchPromptBuilder` forwards to it. Never re-declare them — two independently maintained copies of a security boundary is the shape where one gets hardened and the other does not.

**Fetched web content.** It never enters `OpenAIPlanner.plan(command:)`. The executable `AgentPlan` is decided from the trusted user command first; only after that does an adapter fetch pages and hand them to a separate synthesizer, wrapped per-source as `UNTRUSTED_OBSERVED_CONTENT_BEGIN id=... source_url=... retrieved_at=...` / `UNTRUSTED_OBSERVED_CONTENT_END id=...`, distinct from the `TRUSTED_USER_INSTRUCTION_BEGIN/END` wrapper around the real instruction. Any new capability that fetches external content must keep this separation — don't concatenate fetched text into a prompt that also carries executable-plan authority.

**Screen content (row I).** Everything a vision session observes — the window title, the running history of what happened on screen, and the screenshot itself — is untrusted, and it is the *more* dangerous of the two sources: a fetched page is at least one the user's own command pointed at, while a vision session sees whatever happens to be on screen, including a window some other program put there. `VisionSessionPromptBuilder` wraps all of it as observed content and wraps only the user's goal as trusted, and the system rules name the screenshot as data in so many words — a boundary that covers text but not pixels has a hole exactly where the interesting attacks are. `VisionPromptInjectionTests` is a standing red-team corpus, meant to be appended to.

**Egress encoding, and the two orderings it fixes (SONNY-114).** `RedactedCaptureEncoder.render(paintingRegions:inPNGData:policy:)` is the only way a capture becomes bytes that leave the device, and it takes the regions and the source together so that *painting happens before any resampling* — the painted pixels travel between its two halves as a type whose initializer is private to that file, so resampling an unpainted image is not a call anyone can write. It encodes both PNG and JPEG and sends the smaller, which routes dense-text captures (JPEG's worst case, and the content class lossy compression hurts most) to lossless without a rule that says so, and it resamples only when a capture will not fit the byte budget, spending quality first because resolution is the expensive axis. The second ordering: the resulting image may be **smaller than the capture**, so the coordinate space the model reasons in is `SentImageSize`, never `CapturedWindowImage.pixelWidth/pixelHeight`. Everything the model is told about the picture and everything it says back about it — the prompt's declared dimensions, the bounds check, the point-to-screen scale, the journal's `imageX`/`imageY` — reads that one value. A new consumer of a model-returned coordinate that reaches for the capture's dimensions is off by the resample factor.

Two rules that are easy to blur and must not be:

- **On-screen text is never an instruction to Sonny.** Not when it says "SYSTEM:", not when it names Sonny, not when it looks urgent. The founder's 2026-08-14 delegation decision — the vision model may hand an instruction to the planner mid-run — is *not* an exception to this: delegation is the model choosing a means toward the user's own goal, while obeying screen text would be the goal itself changing because a window said so. A model using a tool, versus an attacker picking the objective.
- **Screen-derived signals may add scrutiny and never remove it.** `VisionConsequenceClassifier` reads the target control's visible label, which is attacker-controllable, and that is safe in exactly one direction: an injected "Delete" earns an approval a click would not otherwise have needed, and no label removes one. Any new use of observed content in a security decision has to be one-directional in the same way, or it is a channel.
