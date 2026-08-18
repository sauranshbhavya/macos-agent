import Foundation
import OSLog
import UserNotifications

/// Not `@MainActor`-isolated so the identifiers stay reachable from `UNUserNotificationCenterDelegate`
/// callbacks, which macOS can invoke off the main actor.
enum SonnyNotificationLog {
    static let logger = Logger(subsystem: "com.sonny.macagent", category: "notifications")
}

private enum SonnyNotificationCategory {
    static let permission = "SONNY_PERMISSION"
    static let error = "SONNY_ERROR"
    /// A finished run's result. Its own category rather than reusing `error`, which carries a
    /// "Retry" action that makes no sense on a run that succeeded (SONNY-56).
    static let outcome = "SONNY_OUTCOME"
}

private enum SonnyNotificationUserInfo {
    static let taskID = "SONNY_TASK_ID"
}

private enum SonnyNotificationAction {
    static let allow = "SONNY_ALLOW"
    static let retry = "SONNY_RETRY"
}

/// Real native macOS Notification Center banners (`UserNotifications`), not custom-built UI — per
/// docs/sonny-founder-design-decisions.md: "Native macOS notifications for v1, not a custom
/// overlay... native respects Do Not Disturb and other system-expected behavior." macOS renders
/// the chrome shown in wireframes 1/2 itself; this class only supplies title/body/action and
/// routes the actions back to real AgentViewModel behavior. Closes the gap flagged earlier in
/// docs/sonny-ui-backend-gaps.md: previously, an approval/error happening while the user was in
/// another app had no on-page hint at all.
@MainActor
final class SonnyNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private let onAllow: () -> Void
    private let onRetry: () -> Void
    private let onOpen: () -> Void
    /// The default action for a finished-run notification, which opens that task rather than the
    /// widget (PR #67 review, F4). Separate from `onOpen` because the two land in different places:
    /// a failure's message lives in the widget, a result's lives in Command Center.
    private let onOpenTask: (String?) -> Void

    /// Fails when the current process has no real app-bundle identity — e.g. `swift run`'s bare
    /// executable (no `Info.plist`/`CFBundleIdentifier`), as opposed to a packaged `.app`.
    /// `UNUserNotificationCenter.current()` unconditionally crashes in that environment
    /// (`bundleProxyForCurrentProcess is nil`, an uncaught Objective-C exception, not a throwing
    /// Swift error) — this has to be checked *before* ever touching the class, not caught after.
    init?(
        onAllow: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onOpenTask: @escaping (String?) -> Void = { _ in }
    ) {
        guard Bundle.main.bundleIdentifier != nil else {
            return nil
        }
        center = .current()
        self.onAllow = onAllow
        self.onRetry = onRetry
        self.onOpen = onOpen
        self.onOpenTask = onOpenTask
        super.init()
        center.delegate = self
        registerCategories()
        // Both results were previously discarded, so a denied prompt left every later post
        // failing silently with nothing anywhere to explain why no banner ever appeared.
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                SonnyNotificationLog.logger.warning(
                    "Notification authorization failed: \(error.localizedDescription, privacy: .public)"
                )
            } else if !granted {
                SonnyNotificationLog.logger.info(
                    "Notification authorization denied; Sonny's fallback banners will not appear."
                )
            }
        }
    }

    private func registerCategories() {
        let allowAction = UNNotificationAction(identifier: SonnyNotificationAction.allow, title: "Allow", options: [])
        let retryAction = UNNotificationAction(identifier: SonnyNotificationAction.retry, title: "Retry", options: [])

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: SonnyNotificationCategory.permission,
                actions: [allowAction],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: SonnyNotificationCategory.error,
                actions: [retryAction],
                intentIdentifiers: [],
                options: []
            ),
            // No actions. SONNY-121 owns acknowledgement and will decide what, if anything, this
            // one offers — adding a speculative button here would be a second place it has to undo.
            UNNotificationCategory(
                identifier: SonnyNotificationCategory.outcome,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func postPermissionNotification(resource: String) {
        let content = UNMutableNotificationContent()
        content.title = "Sonny"
        content.body = "Requesting access to \(resource)"
        content.categoryIdentifier = SonnyNotificationCategory.permission
        deliver(content)
    }

    func postErrorNotification(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Sonny"
        content.body = message
        content.categoryIdentifier = SonnyNotificationCategory.error
        deliver(content)
    }

    /// A finished run's summary, for a user who was working somewhere else while it ran.
    func postOutcomeNotification(summary: String, taskID: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Sonny"
        content.body = summary
        content.categoryIdentifier = SonnyNotificationCategory.outcome
        // The task travels with the notification rather than being looked up when the click
        // arrives: by then another run may have finished, and "the most recent task" would open the
        // wrong one.
        if let taskID {
            content.userInfo[SonnyNotificationUserInfo.taskID] = taskID
        }
        deliver(content)
    }

    private func deliver(_ content: UNMutableNotificationContent) {
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error {
                SonnyNotificationLog.logger.warning(
                    "Notification delivery failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let taskID = response.notification.request.content.userInfo[SonnyNotificationUserInfo.taskID] as? String
        Task { @MainActor [weak self] in
            switch actionIdentifier {
            case SonnyNotificationAction.allow:
                self?.onAllow()
            case SonnyNotificationAction.retry:
                self?.onRetry()
            case UNNotificationDefaultActionIdentifier:
                // Dispatched by category. The seam was already here and simply unused: every
                // category shared one handler, so the outcome notification inherited behaviour
                // written for the failure one (PR #67 review, F4).
                if category == SonnyNotificationCategory.outcome {
                    self?.onOpenTask(taskID)
                } else {
                    self?.onOpen()
                }
            default:
                break
            }
        }
        completionHandler()
    }
}
