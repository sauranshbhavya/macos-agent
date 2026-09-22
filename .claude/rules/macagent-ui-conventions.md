---
paths:
  - "Sources/MacAgent/**"
---
# MacAgent UI guidance

Follow [AGENTS.md](../../AGENTS.md). The earlier detailed UI record is preserved at [docs/archive/macagent-ui-conventions-2026-09.md](../../docs/archive/macagent-ui-conventions-2026-09.md); consult a relevant section when changing an existing surface, but do not preserve UI-owned execution machinery merely because it is described there.

- The floating widget and Command Center must show the same task, approval, and result truth. Presentation or selected-task focus cannot decide which action executes or which approval is answered.
- Keep the existing visual language: System A tokens for the main app and System B treatment for the widget and notifications. Use the design reference and current UI as the baseline for affected surfaces.
- Show permission requests, failures, cancellation, and uncertain outcomes on a surface the user can actually see. Check the affected real-app flow when SwiftUI wiring or macOS focus matters.
- Keep UI tests focused on observable behavior and presentation logic. Use a source scan only where view behavior cannot reasonably be tested through another seam.
