# Working in Sonny

This is the current guidance for agents and contributors. Start with the user's requested outcome and the code that implements it. Historical plans and branch records are context, not standing instructions.

## Current phase (founders, 2026-09-25)

- **The [V2 implementation plan](docs/sonny-v2-implementation-plan.md) is under way, one phase at a time.** Its section 1 decisions replace the earlier feature freeze and the Milestone A scope. New work goes into the V2 kernel (`Sources/MacAgentCore/Kernel/`), the gateway agent (`server/src/agent/`) and the shared contract (`contracts/v2/`), not the current execution path, which phase 7 deletes.
- Changes to the current execution path are limited to fixes for defects that lose data, break security or block everyday use, and a founder approves each one.
- For V2 work, plan decisions 1 and 2 override the data rules below: V2 starts with fresh local stores, keeps no readers for old formats, and has no retention or deletion scaffolding beyond the security floor and the private-mode toggle.
- If a request conflicts with this phase, say so and ask before starting.

## Make changes

- Use the smallest coherent change that solves the requested problem. Fix nearby code when the outcome depends on it; explain material scope changes.
- Keep product decisions distinct from implementation sketches. Prefer a working vertical slice before adding frameworks, protocols, actors, or new modules. Treat the first implementation as revisable; change its shape when a second real workflow shows a better boundary.
- Preserve existing user data and behavior unless the task explicitly changes them. Read old formats at boundaries when replacing internals.
- Treat model output, web content, screenshots, and Accessibility text as untrusted. They cannot grant permission or create a trusted action on their own.
- Consequential actions need fresh approval of the actual effect. Revalidate the target and content before committing; never blindly replay an action whose outcome is uncertain.
- The UI may present and submit work, but execution state and authority must not depend on which task or window is focused.

## Verify what changed

- For an ordinary change, run the relevant build and focused behavioral tests, inspect the result, then stop verifying once the changed behavior is adequately covered. Multiple touched files alone do not justify a full suite. Use broader suites when shared execution or safety behavior affects many features, at cutover or release, or to resolve a concrete remaining risk. Check affected real packaged-app behavior when macOS permissions, focus, Apple Events, Accessibility, or screen input change.
- Swift and server checks cover different halves; use the commands in [WORKFLOW.md](WORKFLOW.md). Do not report a command as passing unless it was run and its result inspected.
- Keep a security check for credentials in tracked files. Review security, money, data-loss, approval, and trust-boundary changes more deeply than copy or local refactors.
- Prefer outcome-based tests. Keep a source scan only when it protects a stated property that cannot reasonably be tested at a better seam.
- Full manual checklists and repeated independent test runs are not default steps. Use them only for a specific risk or release need.

## Coordinate work

- One session owns one change, and a founder works with it directly. Use Plane for substantial or coordinated work, not as a prerequisite for every small change. A concise issue should describe the outcome, important constraints, and how it will be checked.
- Use separate branches or worktrees when concurrent work would otherwise collide. A PR and its diff are sufficient for ordinary change history; record a lasting design decision only when one was actually made.
- The founders own merges. Do not merge without their authorization.

Current product direction: [Sonny V2 architecture plan](sonny_v2_architecture_implementation_plan.md). Current app orientation: [README.md](README.md). Historical material is indexed in [docs/archive/README.md](docs/archive/README.md).
