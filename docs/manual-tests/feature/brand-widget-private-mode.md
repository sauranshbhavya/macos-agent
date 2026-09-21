### Restrained sidebar palette, larger marks and private-mode widget treatment (new 2026-09-21, user-directed)

Setup: package and open the app, then inspect both Dark and Light appearances. Open the floating widget over one light window and one dark window so its material and edge treatment are visible against both.

- [ ] The Command Center sidebar uses the darker green treatment in Dark appearance and a restrained green tint in Light appearance. Its logo and Ask Sonny button use the palette gold; the profile avatar and task badge use green rather than purple or blue. The main canvas, panels, cards, text, controls and blue accent look unchanged from the prior neutral theme.
- [ ] The sidebar Sonny mark is clearly larger than before, stays sharp and centred in expanded and collapsed sidebar states, and does not collide with the sidebar toggle.
- [ ] The floating widget is slightly larger, remains centred above the Dock, and its pill and expanded panels still align on their leading edge.
- [ ] On macOS 26 or later the widget uses the system's native Liquid Glass rendering. It visibly samples the content behind it and reads as black-and-white glass rather than a green-tinted or flat opaque fill; existing action colors remain legible over both light and dark windows.
- [ ] The Start button has equal visible spacing above, below and to its right inside the composer pill.
- [ ] The separate eye/private-chat button is gone. The composer logo, typed text and helper placeholder remain clearly readable over light and dark content. Clicking the logo turns a subtle dotted white outline on; clicking it again removes the outline.
- [ ] Turning the dotted state on adds no "Won't be saved" chip and does not create an empty chip row. Workspace and follow-up chips still render normally when used.
- [ ] Start one task with the dotted outline on. The existing "Don't save this task" behavior still applies, the logo cannot change the setting while the task is in flight, and the setting resets after the task settles.
- [ ] Hovering the microphone opens no custom hint row. Its idle background is an untinted Liquid Glass circle; once recording starts, the countdown and mic sit in one outer Liquid Glass capsule with the mic circle visibly nested inside it.
- [ ] Stop an active recording from the nested mic control. The countdown capsule disappears directly, without a textbox-like surface rising into the composer from below.
- [ ] Collapse and click the widget logo to re-expand it. The logo gives restrained press feedback, the composer appears at full size, and repeated expand/collapse cycles neither move the icon sideways nor hang the app; Reduce Motion disables the press scale.
- [ ] Show an expanded result or permission panel. The larger dimensions do not clip controls, text, dotted outline or glass edges.
