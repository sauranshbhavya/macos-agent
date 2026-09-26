import SwiftUI

/// The glimpse of a shortcut shown while `CommandKeyHintModel.isShowingHints` is true: the
/// shortcuts sheet's own key-cap chrome (`SonnyKeyCap`), one cap holding the whole chord ("⌘1",
/// "⌘⌥S") rather than a cap per key, so the badge stays small beside the control it names. Sized by
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
