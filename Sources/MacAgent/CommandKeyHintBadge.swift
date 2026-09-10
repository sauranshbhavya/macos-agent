import SwiftUI

/// The glimpse of a shortcut shown while `CommandKeyHintModel.isShowingHints` is true: the
/// shortcuts sheet's own key-cap chrome (`SonnyKeyCap`), drawn small enough to sit as a badge on the
/// control it names rather than as a row in a list.
///
/// **`accessibilityHidden`, always.** The control this decorates already carries the same chord
/// through `.keyboardShortcut`, which is what VoiceOver reads; the badge is a sighted-only glimpse,
/// so a screen reader gains nothing from it and would otherwise hear the chord announced twice.
struct CommandKeyHintBadge: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(keys, id: \.self) { key in
                SonnyKeyCap(text: key, font: SonnyType.micro, minWidth: 12, height: 14)
            }
        }
        .accessibilityHidden(true)
    }
}
