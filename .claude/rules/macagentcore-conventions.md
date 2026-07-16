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

All 8 local stores (routines, workspaces, clipboard history + settings, snippets, recent artifacts, Shortcut run history, task history) share one pattern via `LocalStorageEncryption`: a defaulted `encryption: LocalStorageEncryption = .shared` constructor param, AES-GCM encryption with the `SONNYENC1\n` file header, and transparent legacy-plaintext-JSON migration (decode once, rewrite encrypted on next successful load). A new store follows this exactly — don't invent a variant encryption scheme or skip migration. `LocalStorageEncryption.shared` auto-detects test processes (bundle path / `XCTestConfigurationFilePath`) and supplies a deterministic ephemeral key under SwiftPM/XCTest; new tests should still prefer an explicitly injected key manager over relying on that fallback, and must never exercise the user's real login Keychain.

Load failures and write failures need different user-facing handling. An existing file that fails to decrypt/decode on load is a real, visible problem — surface it via `recordLocalStorageLoadFailure(_:error:)` / `clearLocalStorageLoadFailure(_:)`, never collapse it into empty/default state with `try?`. A *write* failure is a different thing and must not reuse that same load-failure banner (its wording is hardcoded to "could not be decrypted or decoded," which is wrong for a save failure) — set a direct, accurate `errorMessage` instead, following `applyClipboardHistoryNoticeChoice`'s pattern.

## Testing

Everything OpenAI/network/Shortcuts/filesystem-adjacent is behind an injectable seam so tests never make live calls — fixture-backed HTTP protocols, fake planners/transcribers, `FailingPlanner: Planning` conformances for exercising planner-independent paths. When you change a `Planning` method signature, every existing conformance (including the test fakes) needs updating in the same change, not left to bit-rot.

## Untrusted content boundary

Fetched web/observed content never enters `OpenAIPlanner.plan(command:)`. The executable `AgentPlan` is decided from the trusted user command first; only after that does an adapter fetch pages and hand them to a separate synthesizer, wrapped per-source as `UNTRUSTED_OBSERVED_CONTENT_BEGIN id=... source_url=... retrieved_at=...` / `UNTRUSTED_OBSERVED_CONTENT_END id=...`, distinct from the `TRUSTED_USER_INSTRUCTION_BEGIN/END` wrapper around the real instruction. Any new capability that fetches external content must keep this separation — don't concatenate fetched text into a prompt that also carries executable-plan authority.
