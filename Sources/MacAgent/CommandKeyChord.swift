import AppKit

/// The one question `AppWindowCoordinator`'s `.flagsChanged` monitor asks of an event before it
/// feeds `CommandKeyHintModel`: is ⌘ down, and no other chord modifier with it?
///
/// **Only the four chord modifiers take part.** The first draft compared the event's flags against
/// `.deviceIndependentFlagsMask`, which also carries `.capsLock`, `.function`, `.numericPad` and
/// `.help` — so with Caps Lock lit, ⌘ read as "not alone" for as long as it stayed lit and the
/// hold-⌘ hints never showed at all (phase 14's review, F1). Caps Lock is a state, not a chord, and
/// the keypad flag rides along with the arrow keys; neither says anything about what the user is
/// holding, so neither is consulted.
enum CommandKeyChord {
    /// Shift, Control, Option and Command: the modifiers a chord is made of.
    static let chordModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    static func isCommandHeldAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(chordModifiers) == .command
    }
}
