import SwiftUI

/// The glimpse of a shortcut shown while `CommandKeyHintModel.isShowingHints` is true: the
/// shortcuts sheet's own key-cap chrome (`SonnyKeyCap`), one cap holding the whole chord ("⌘1",
/// "⌘⌥S") rather than a cap per key. The sheet's per-key caps run past 40pt for a two-key chord,
/// and the collapsed rail's tile is 36 wide, so a cap per key covered the very icon it named (phase
/// 14's review, F4 and F11); one cap at the micro size is under 30 for a two-key chord. Sized by
/// `SonnyMetrics.hintBadgeHeight` and `hintBadgeMinWidth`, never by a literal in the body.
///
/// **`accessibilityHidden`, always.** The control this decorates already carries the same chord
/// through `.keyboardShortcut`, which is what VoiceOver reads; the badge is a sighted-only glimpse,
/// so a screen reader gains nothing from it and would otherwise hear the chord announced twice.
struct CommandKeyHintBadge: View {
    let chord: String

    var body: some View {
        SonnyKeyCap(text: chord, font: SonnyType.micro, minWidth: SonnyMetrics.hintBadgeMinWidth, height: SonnyMetrics.hintBadgeHeight)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The collapsed rail's treatment: the cap hangs centred beneath the control it names, its
    /// centre `SonnyMetrics.hintBadgeDrop` below the control's bottom edge, so it sits in the gap
    /// the rail keeps between its controls and covers neither this icon nor the next one. The
    /// expanded sidebar has room beside each control and places the cap inline instead, so this is
    /// never applied there.
    func commandKeyHintBelow(_ chord: String, isShowing: Bool) -> some View {
        overlay(alignment: .bottom) {
            if isShowing {
                CommandKeyHintBadge(chord: chord)
                    .offset(y: SonnyMetrics.hintBadgeDrop)
            }
        }
    }
}
