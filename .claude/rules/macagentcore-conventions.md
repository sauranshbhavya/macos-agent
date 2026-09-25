---
paths:
  - "Sources/MacAgentCore/**"
---
# MacAgentCore guidance

Follow [AGENTS.md](../../AGENTS.md) and the current [V2 direction](../../sonny_v2_architecture_implementation_plan.md). The earlier detailed convention record is preserved at [docs/archive/macagentcore-conventions-2026-09.md](../../docs/archive/macagentcore-conventions-2026-09.md); consult a relevant section when changing an established security or storage boundary, but do not treat its old class layout as a target architecture.

- Keep untrusted model, web, Accessibility, and screen content separate from user authority. Observed labels may trigger more scrutiny, never grant permission or lower it.
- Preserve existing approval, cancellation, and uncertain-outcome behavior while moving execution ownership. Test exact targets and effects at the boundary that dispatches them.
- New persisted data must follow current encryption, retention, migration, and deletion behavior. Prefer a versioned reader over silently changing or discarding old records. V2 kernel code (`Kernel/`) is the exception: it starts with fresh stores and keeps no readers for old formats (V2 plan decision 1).
- Keep OS, model, storage, and clock effects behind testable boundaries. Add a protocol when there is a real boundary or alternate implementation, not for every helper.
- Use focused behavioral tests. A source scan needs a stated property and evidence that it catches the defect it claims to catch.
