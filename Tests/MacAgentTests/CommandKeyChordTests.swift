import AppKit
import Testing
@testable import MacAgent

/// Phase 14's review, F1: `.deviceIndependentFlagsMask` carries Caps Lock, Fn, the keypad flag and
/// Help beside the four chord modifiers, so comparing an event's whole device-independent set
/// against `.command` read ⌘ as "not alone" for as long as Caps Lock stayed lit — and the hold-⌘
/// hints never showed for anyone typing with it on. `CommandKeyChord` reduces the flags to the four
/// modifiers a chord is made of first. Every case below feeds the reduction a set the monitor could
/// actually receive, and the reduction is what the coordinator's monitor calls (pinned by
/// `SidebarHintsSourceScanTests`), so a mask widened back is caught here rather than found by a
/// founder with Caps Lock on.
@Suite
struct CommandKeyChordTests {
    @Test
    func commandAloneIsAlone() {
        #expect(CommandKeyChord.isCommandHeldAlone([.command]))
    }

    /// The finding itself and its siblings in the same mask: a state light, a key-position flag and
    /// the keypad flag, none of which says anything about what the user is holding.
    @Test
    func capsLockFnAndTheKeypadFlagDoNotStopCommandReadingAsAlone() {
        let sets: [NSEvent.ModifierFlags] = [
            [.command, .capsLock],
            [.command, .function],
            [.command, .numericPad],
            [.command, .help],
            [.command, .capsLock, .function, .numericPad, .help],
        ]
        for flags in sets {
            #expect(CommandKeyChord.isCommandHeldAlone(flags), "flags \(flags.rawValue) should read as ⌘ alone")
        }
    }

    @Test
    func anyChordModifierJoiningCommandEndsAlone() {
        let sets: [NSEvent.ModifierFlags] = [
            [.command, .shift],
            [.command, .option],
            [.command, .control],
            [.command, .shift, .capsLock],
        ]
        for flags in sets {
            #expect(!CommandKeyChord.isCommandHeldAlone(flags), "flags \(flags.rawValue) are a chord, not ⌘ alone")
        }
    }

    /// Option alone, Shift alone, nothing at all, Caps Lock alone: no ⌘ means never alone, whatever
    /// else is set (the review's F14 asked for the single-non-⌘-modifier case by name).
    @Test
    func withoutCommandNothingIsAlone() {
        let sets: [NSEvent.ModifierFlags] = [[.option], [.shift], [.control], [], [.capsLock], [.function, .numericPad]]
        for flags in sets {
            #expect(!CommandKeyChord.isCommandHeldAlone(flags), "flags \(flags.rawValue) hold no ⌘")
        }
    }

    /// The mask is exactly the four chord modifiers: one more and Caps Lock is back in, one fewer
    /// and a real chord reads as alone.
    @Test
    func theChordModifiersAreExactlyTheFour() {
        #expect(CommandKeyChord.chordModifiers == [.command, .shift, .option, .control])
        #expect(!CommandKeyChord.chordModifiers.contains(.capsLock))
        #expect(!CommandKeyChord.chordModifiers.contains(.function))
    }
}
