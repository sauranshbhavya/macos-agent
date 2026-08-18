import Foundation

/// When Sonny may interrupt the user with a notification.
///
/// **The rule, decided by the founder on 2026-08-17: notify when Sonny is not the app the user is
/// working in.** Declined at the same time: gating on Command Center alone and ignoring the widget,
/// which would notify someone who is actively watching the widget do the task — the duplication the
/// old gate was written to prevent.
///
/// **Why this is two conditions and not one, which is the whole reason it is a named type.** The
/// obvious implementation is `!NSApp.isActive`, and it is wrong in a way that reads as correct in a
/// diff. The floating widget is built with `.nonactivatingPanel`
/// (`FloatingWidgetWindowController.swift`), deliberately, so that typing into it does not steal
/// focus from whatever app the user was in — a Spotlight-style overlay rather than a window that
/// grabs activation. So a user in the middle of typing a command into the widget has
/// `NSApp.isActive == false`, and an activation-only rule would interrupt them mid-sentence, every
/// time. The widget panel being key is the second half, and it is not optional.
///
/// **What this replaces.** `isAnySonnySurfaceVisible` — "a Sonny surface is on screen" — which had
/// been permanently true since the widget became a permanent, undismissable overlay, so every
/// notification path was dead. See this file's tests and SONNY-56's closing comment.
enum SonnyAttention {
    /// Whether the user is working in Sonny right now, in the only sense that matters to an
    /// interruption: Sonny is the active app, *or* the non-activating widget panel has key focus.
    static func isUserWorkingInSonny(isApplicationActive: Bool, isWidgetPanelKey: Bool) -> Bool {
        isApplicationActive || isWidgetPanelKey
    }

    /// The gate itself. One definition, read by every notification subscription — never a condition
    /// copied into four `sink` bodies.
    static func shouldNotify(isApplicationActive: Bool, isWidgetPanelKey: Bool) -> Bool {
        !isUserWorkingInSonny(isApplicationActive: isApplicationActive, isWidgetPanelKey: isWidgetPanelKey)
    }
}
