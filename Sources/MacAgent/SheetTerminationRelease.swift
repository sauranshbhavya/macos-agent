import AppKit

/// Lets Sonny quit while a sheet is up (SONNY-448).
///
/// **The cause, measured rather than inferred.** AppKit refuses termination outright while any
/// window presented modally has `preventsApplicationTerminationWhenModal` set, and a sheet is
/// presented modally. The property defaults to `true`, and every sheet this app shows is a window
/// with that default: the first-run sequence, Settings, the screen-access dialog on top of Settings,
/// every `confirmationDialog`. The refusal is silent — `terminate(_:)` returns at once, the delegate
/// is never asked, nothing is logged — so both halves of the founders' report were this one line of
/// AppKit: ⌘Q on the sign-in step did nothing, and Relaunch Sonny started the new copy with
/// `open -n` and then had its own `NSApp.terminate(nil)` refused, because that button only ever
/// appears inside a sheet. The changelog entry for `fix/quit-under-a-sheet` has the probe and its
/// readings.
///
/// **Cleared when a sheet begins, not when Sonny quits, because not every quit passes through
/// Sonny.** The Dock's Quit, Activity Monitor's, an AppleScript `quit` and a logout arrive as a quit
/// Apple event that AppKit answers itself — and it reaches the refusal without calling
/// `AppDelegate.quit()`, or even `-[NSApplication terminate:]`: its stack goes from
/// `_handleAEQuit` straight to `_shouldTerminate`. So a fix placed in `quit()`, or in an
/// `NSApplication` subclass overriding `terminate(_:)`, would have left every one of those refused.
/// The flag is read at the moment of the refusal, so a flag already cleared answers every route.
///
/// **Every window, not only the sheet.** When `willBeginSheetNotification` arrives, the sheet about
/// to attach is not yet in its parent's `sheets` — but it is already in the app's window list, so
/// clearing the whole list clears it in the same call, with no later turn of the run loop for a
/// quit to fall into. The property only matters for a window presented modally, and nothing in this
/// app is presented modally except as a sheet: no `runModal`, no modal session.
///
/// **What quitting then does to an open sheet** is SwiftUI's: its sheet window dismisses itself for
/// termination by writing `false` to the presenting binding, before the delegate is asked. A
/// binding whose setter records a decision would record one the user never made —
/// `FirstRunCoordinator.withdrawUnanswered()` is the first-run sheet's answer to that.
@MainActor
enum SheetTerminationRelease {
    /// Starts watching for sheets. The returned token is the observation; it lives as long as the
    /// caller keeps it, which for the app is the life of the process.
    ///
    /// `queue: nil` delivers on the posting thread, synchronously, and AppKit posts this on the main
    /// thread while it begins a sheet — which is what makes the clear land before the sheet is up.
    static func install(
        on notificationCenter: NotificationCenter,
        windows: @escaping @MainActor () -> [NSWindow]
    ) -> NSObjectProtocol {
        notificationCenter.addObserver(
            forName: NSWindow.willBeginSheetNotification,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                release(windows())
            }
        }
    }

    static func release(_ windows: [NSWindow]) {
        for window in windows {
            window.preventsApplicationTerminationWhenModal = false
        }
    }
}
