import Foundation
import UserNotifications

/// Not `@MainActor`-isolated so the identifiers stay reachable from `UNUserNotificationCenterDelegate`
/// callbacks, which macOS can invoke off the main actor.
private enum SonnyNotificationCategory {
    static let permission = "SONNY_PERMISSION"
    static let error = "SONNY_ERROR"
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

    /// Fails when the current process has no real app-bundle identity — e.g. `swift run`'s bare
    /// executable (no `Info.plist`/`CFBundleIdentifier`), as opposed to a packaged `.app`.
    /// `UNUserNotificationCenter.current()` unconditionally crashes in that environment
    /// (`bundleProxyForCurrentProcess is nil`, an uncaught Objective-C exception, not a throwing
    /// Swift error) — this has to be checked *before* ever touching the class, not caught after.
    init?(onAllow: @escaping () -> Void, onRetry: @escaping () -> Void, onOpen: @escaping () -> Void) {
        guard Bundle.main.bundleIdentifier != nil else {
            return nil
        }
        center = .current()
        self.onAllow = onAllow
        self.onRetry = onRetry
        self.onOpen = onOpen
        super.init()
        center.delegate = self
        registerCategories()
        center.requestAuthorization(options: [.alert]) { _, _ in }
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

    private func deliver(_ content: UNMutableNotificationContent) {
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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
        Task { @MainActor [weak self] in
            switch actionIdentifier {
            case SonnyNotificationAction.allow:
                self?.onAllow()
            case SonnyNotificationAction.retry:
                self?.onRetry()
            case UNNotificationDefaultActionIdentifier:
                self?.onOpen()
            default:
                break
            }
        }
        completionHandler()
    }
}
