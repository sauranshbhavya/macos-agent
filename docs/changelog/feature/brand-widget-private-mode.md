### Branch: feature/brand-widget-private-mode
Status: in progress — implementation and focused unit tests complete; founder visual pass pending
Date: 2026-09-21
Tickets: none, by the founder's explicit instruction for this change
Reviewed by: none yet; fresh-session review remains pending if this branch is prepared for merge

Spec sections covered: restrained System A sidebar treatment and System B visual treatment only; no product-spec behavior is added beyond moving the existing per-run trace-suppression control.
Files changed: `Sources/MacAgent/ContentView.swift`, `CommandCenterView.swift`, `SonnyWidgetTheme.swift`, `FloatingWidgetView.swift`, `FloatingWidgetWindowController.swift`, `AgentActivityPresentation.swift`, `AgentViewModel.swift`, `ScreenControlUsagePresentation.swift`, `Sources/MacAgentCore/FinderSelectionCapabilityAdapter.swift`; `Tests/MacAgentTests/TaskRecordingPresentationTests.swift`, `WidgetCircularButtonFillTests.swift`, `WidgetComposerStateTests.swift`, `WidgetMicHoverHintTests.swift`, `HoverTeardownAuditTests.swift`, `FinderSelectionSentenceFitsTheWidgetTests.swift`, `ResumeOfferPresentationTests.swift`; this entry and `docs/manual-tests/feature/brand-widget-private-mode.md`.
Tests: `swift build` and the focused widget/sidebar suites pass in the uncommitted working tree based on `760d94a7`; the hover audit's one stale requirement for the removed mic tracker was updated and passes alone. The full flagged command remains blocked by the two reproducible, untouched `ShellSurfaceDetectorTests.aRealTerminalPanelIsRefusedAtEveryRealisticCaptureSize` cases `1280x800 @ 12pt` and `800x600 @ 13pt`, both of which return no shell signals from the on-device Vision recognizer; the same failures reproduce under `--filter ShellSurfaceDetectorTests`.
Mutation plan: none, by the founder's explicit instruction; unit tests only.

Behavior added:
- System A applies a dark green brand tint only to the sidebar. The main canvas, panels, cards, text, controls and blue accent retain their previous neutral palette.
- The Command Center sidebar mark grows from its former small inset treatment to a 22pt mark in the standard large-control frame. The mark and Ask Sonny action use the palette gold; the sidebar's avatar and task badge remain green rather than sharing the main content's blue accent.
- System B returns to its black-and-white glass surfaces and original action colors; the composer is 520pt wide and 44pt tall, with correspondingly larger compact and microphone controls. On macOS 26 and later those surfaces use SwiftUI's native `.glassEffect`; macOS 14 and 15 retain the real AppKit vibrancy fallback required by the package deployment target.
- The Start button is 28pt tall inside the 44pt composer, leaving the same 8pt inset above, below and to its right.
- The composer logo now toggles the existing per-run `TaskRecordingPolicy`; it uses the high-contrast white foreground, and when trace suppression is on the composer pill gets a low-opacity white dotted outline. The separate eye button and the "Won't be saved" chip are removed.
- The mic uses an untinted circular Liquid Glass surface with no custom hover panel. While recording, the countdown and mic share a second outer Liquid Glass capsule, leaving the mic's circle nested inside it.
- The compact control uses size-neutral press feedback before one deterministic bottom-anchored panel resize. Layout-level matched geometry and AppKit frame animation were removed after they formed a `fittingSize`/frame-notification feedback loop that moved the icon without completing expansion and hung the app; Reduce Motion disables the press scale.
- The composer placeholder is a 96%-white custom overlay rather than a native `TextField` prompt, because AppKit dimmed the native placeholder again after SwiftUI applied its foreground color.
- The recording-control branch explicitly suppresses animation, so stopping a recording removes the countdown capsule without making the composer look like a new text field is entering from below.
- `composerPrivacyMark` has an explicit active-state branch and a TODO for the future private-mode asset; until that asset exists, both states render the current Sonny mark.

Behavior preserved (required, no blanket claims):
- The toggle still writes only `.record` or `.suppressTraces`, remains unavailable after dispatch, exposes the honest accessibility label "Don't save this task", and resets through the existing run lifecycle.
- Workspace-binding and follow-up chips retain their order and continue to control the composer's optional chip row; private mode no longer reserves that row.
- Widget panels and pills still share one width, and the result and resume-offer text measurements were updated to the new width rather than allowed to drift from the rendered surface.
- Semantic allow, warning and error colors remain distinct from the new brand palette where their meaning is safety-relevant.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- "Private mode" is a visual description, not new storage behavior. The logo reuses the existing trace-suppression policy instead of introducing a second privacy flag, and user-facing accessibility copy keeps naming the narrower promise the product actually makes.
- System A keeps the brand treatment deliberately narrow: a dark green sidebar with gold brand actions around the existing flat, opaque neutral content system. System B remains independently themed and uses untinted native Liquid Glass where the operating system provides it.

Known limitations / deferred scope: the private-state icon is intentionally the ordinary Sonny mark until a dedicated asset is supplied; the replacement site is marked with a TODO in `FloatingWidgetView.swift`.
Open questions (required, write "none" if true): none.

Next branch: none assigned.
