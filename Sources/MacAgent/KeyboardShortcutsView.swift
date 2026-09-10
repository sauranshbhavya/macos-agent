import SwiftUI

/// Read-only reference for every key equivalent the app answers today, opened from the account
/// menu (or ⌘/, while the window is key). Three groups, in the order a user meets them: what
/// Command Center itself answers, what the floating widget answers, and what works from anywhere.
struct KeyboardShortcutsSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            SonnyDialogHeader(title: "Keyboard shortcuts", closeLabel: "Close keyboard shortcuts") {
                isPresented = false
            }

            ScrollView {
                VStack(alignment: .leading, spacing: SonnySpacing.xl) {
                    KeyboardShortcutGroup(title: "Command Center", rows: commandCenterRows)
                    KeyboardShortcutGroup(title: "Widget", rows: widgetRows)
                    KeyboardShortcutGroup(title: "Anywhere", rows: anywhereRows)
                }
                .padding(.horizontal, SonnySpacing.xxl)
                .padding(.bottom, SonnySpacing.xl)
            }
        }
        .sonnyDialogFrame(.regular)
    }

    private var commandCenterRows: [KeyboardShortcutRowContent] {
        var rows: [KeyboardShortcutRowContent] = [
            KeyboardShortcutRowContent(action: "Ask Sonny", keys: ["⌘", "N"]),
            KeyboardShortcutRowContent(action: "Jump to", keys: ["⌘", "K"])
        ]
        // The pages in sidebar order, so this list can never drift from the sidebar's own ⌘-number
        // wiring (`sidebarButton(_:ordinal:)`).
        rows += CommandCenterDestination.allCases.enumerated().map { index, destination in
            KeyboardShortcutRowContent(action: destination.title, keys: ["⌘", "\(index + 1)"])
        }
        rows += [
            KeyboardShortcutRowContent(action: "Search tasks", keys: ["⌘", "F"]),
            KeyboardShortcutRowContent(action: "Clear the search", keys: ["Esc"]),
            KeyboardShortcutRowContent(action: "Settings", keys: ["⌘", ","]),
            KeyboardShortcutRowContent(action: "Keyboard shortcuts", keys: ["⌘", "/"]),
            KeyboardShortcutRowContent(action: "Open or close the sidebar", keys: ["⌘", "⌥", "S"]),
            KeyboardShortcutRowContent(action: "Close a sheet", keys: ["Esc"]),
            KeyboardShortcutRowContent(action: "Close the window", keys: ["⌘", "W"]),
            KeyboardShortcutRowContent(action: "Minimize the window", keys: ["⌘", "M"]),
            KeyboardShortcutRowContent(action: "Hide Sonny", keys: ["⌘", "H"])
        ]
        return rows
    }

    private var widgetRows: [KeyboardShortcutRowContent] {
        [
            KeyboardShortcutRowContent(action: "Allow or send", keys: ["Return"]),
            KeyboardShortcutRowContent(action: "Deny or cancel", keys: ["Esc"])
        ]
    }

    private var anywhereRows: [KeyboardShortcutRowContent] {
        [
            KeyboardShortcutRowContent(action: "Hold to speak", keys: Self.keyCaps(fromChord: PushToTalkHotKey.displayName)),
            KeyboardShortcutRowContent(action: "Stop Sonny", keys: Self.keyCaps(fromChord: EmergencyStopHotKey.displayName))
        ]
    }

    /// Splits a hotkey's own display string into individual key caps rather than spelling the
    /// chord out a second time: each symbol character becomes its own cap, and a trailing run of
    /// ASCII letters or digits (e.g. "Space") becomes one. Reads `PushToTalkHotKey.displayName`
    /// ("⌃⌥Space") as `["⌃", "⌥", "Space"]` and `EmergencyStopHotKey.displayName` ("⌃⌥⎋") as
    /// `["⌃", "⌥", "⎋"]`.
    private static func keyCaps(fromChord chord: String) -> [String] {
        var caps: [String] = []
        var word = ""
        for character in chord {
            if character.isASCII, character.isLetter || character.isNumber {
                word.append(character)
            } else {
                if !word.isEmpty {
                    caps.append(word)
                    word = ""
                }
                caps.append(String(character))
            }
        }
        if !word.isEmpty {
            caps.append(word)
        }
        return caps
    }
}

private struct KeyboardShortcutRowContent {
    let action: String
    let keys: [String]
}

private struct KeyboardShortcutGroup: View {
    let title: String
    let rows: [KeyboardShortcutRowContent]
    @Environment(\.sonnyDensity) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.sm) {
            Text(title)
                .font(SonnyType.settingsSectionLabel)
                .foregroundStyle(SonnyTheme.text)

            VStack(spacing: density.rowGap) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    KeyboardShortcutRow(action: row.action, keys: row.keys, isLast: index == rows.count - 1)
                }
            }
        }
    }
}

private struct KeyboardShortcutRow: View {
    let action: String
    let keys: [String]
    let isLast: Bool
    @Environment(\.sonnyDensity) private var density

    var body: some View {
        HStack {
            Text(action)
                .font(SonnyType.body)
                .foregroundStyle(SonnyTheme.text)

            Spacer(minLength: SonnySpacing.md)

            HStack(spacing: SonnySpacing.xs) {
                ForEach(keys, id: \.self) { key in
                    SonnyKeyCap(text: key)
                }
            }
        }
        .frame(height: density.scaled(32))
        .sonnyDivider(isLast ? Color.clear : SonnyTheme.cardBorder)
    }
}
