import Foundation

/// What the menu-bar item shows for the state Sonny is in, decided in one place so the icon, its
/// tint and its VoiceOver name cannot disagree.
///
/// The precedence is the widget's own for the states it shows: a question waiting for the user
/// outranks work in progress, and work in progress outranks a failure that nothing is doing
/// anything about. A failure that has been dismissed is `errorMessage == nil` and reads as idle.
///
/// Tints are named rather than coloured here: the menu bar draws template images, and
/// `AppDelegate` maps each name onto `NSColor` when it applies the presentation, because this
/// type is a value and has no business importing AppKit.
struct StatusItemPresentation: Equatable {
    enum Tint: Equatable {
        /// The system's menu-bar foreground, whatever the bar's own appearance is.
        case plain
        /// Sonny is working.
        case accent
        /// Sonny is waiting for the user.
        case attention
        /// The last task failed and nobody has dismissed it.
        case failure
    }

    let systemImageName: String
    let tint: Tint
    let accessibilityLabel: String

    static let idle = StatusItemPresentation(
        systemImageName: "wand.and.stars.inverse",
        tint: .plain,
        accessibilityLabel: "Sonny"
    )

    static let working = StatusItemPresentation(
        systemImageName: "wand.and.stars",
        tint: .accent,
        accessibilityLabel: "Sonny, working"
    )

    static let waiting = StatusItemPresentation(
        systemImageName: "wand.and.stars",
        tint: .attention,
        accessibilityLabel: "Sonny, waiting for you"
    )

    static let failed = StatusItemPresentation(
        systemImageName: "wand.and.stars",
        tint: .failure,
        accessibilityLabel: "Sonny, the last task failed"
    )

    static func forState(isRunning: Bool, isAwaitingApproval: Bool, hasFailure: Bool) -> StatusItemPresentation {
        if isAwaitingApproval {
            return .waiting
        }
        if isRunning {
            return .working
        }
        if hasFailure {
            return .failed
        }
        return .idle
    }
}
