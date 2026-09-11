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
    /// What the scheduler did while nobody was watching — ran, failed, was skipped, or had its
    /// schedule paused (SONNY-113).
    ///
    /// **Its own category for the same reason `outcome` has one, and the cost of not having it was
    /// larger here.** These posted through `error` until now, so every scheduled notice arrived with
    /// a Retry button — wrong twice. A run that succeeded ("X ran on schedule.") is not something to
    /// retry, and the button's action is `retryLastCommand()`, which re-dispatches the *user's own
    /// last submitted command*: `performScheduledRun` deliberately never writes `lastCommand`, so
    /// Retry on "your 9am routine failed" ran whatever the user last typed, a task with no
    /// relationship to the routine. `ScheduledRoutineRunTests.aScheduledRunDoesNotBecomeTheRetryTarget`
    /// demonstrates that property directly — it was written to protect the widget's Retry button and
    /// is equally the proof that this notification must not offer one.
    ///
    /// Latent rather than live until now: every notification was suppressed by the old
    /// `isAnySonnySurfaceVisible` gate, and SONNY-56 opening the gate is what made it reachable.
    static let scheduled = "SONNY_SCHEDULED"
    /// Something wrong with Sonny's own stored data — a store that will not decrypt, or a save that
    /// failed (SONNY-187).
    ///
    /// **The third category added for the same reason, and the worst fit of the three while it
    /// lasted.** These posted through `error` too, so "your snippets file could not be decrypted"
    /// arrived wearing a Retry button — and Retry is `retryLastCommand()`, which re-dispatches the
    /// *user's own last submitted command*, a task with no relationship to the file the banner is
    /// about. It is also reachable from a bookkeeping write failing during a run that otherwise
    /// succeeded, so the button could re-run a task that had just worked.
    ///
    /// Worse here than it was for `scheduled`, on this channel's own stated terms.
    /// `AgentViewModel.localStorageNotice` exists precisely so a storage problem is not confused
    /// with a task outcome — a corrupt store "must never make a successful task read as failed" —
    /// and posting it in the failure category, with a failure's action, is that same confusion
    /// arriving through the notification instead of the widget.
    static let storage = "SONNY_STORAGE"
    /// What a standing watcher had to say — the page changed, or the watcher stopped and why
    /// (SONNY-236).
    ///
    /// **The fourth category added for the same reason as the three above it, and the first where
    /// the notification is the entire feature.** A watcher notifies and does nothing else, so this
    /// banner is not a fallback for a surface the user missed — it *is* the delivery, arriving hours
    /// or days after the user asked, when by definition they are not looking at Sonny.
    ///
    /// Posting it through `error` would have been wrong three times over, one more than
    /// `scheduled` and `storage` each were. A page changing is not a failure. The Retry button that
    /// category carries runs `retryLastCommand()`, which re-dispatches the user's own last submitted
    /// command — a task with no relationship to the watched page. And a watcher may not act, by
    /// founder decision, so a button that dispatches anything is precisely the route to acting that
    /// decision declined; leaving it on the category would have put one on screen without anybody
    /// choosing to.
    static let watcher = "SONNY_WATCHER"
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
    /// The default action for a scheduled-run notification (SONNY-113). A third destination for the
    /// same reason there is a second: the notice's own controls live in Command Center — the
    /// Routines page is where a paused schedule is switched back on, and the notice strip carrying
    /// the reason renders there — so fronting the widget would answer the click with less than the
    /// user came for.
    private let onOpenScheduledRun: () -> Void
    /// The default action for a storage-notice notification (SONNY-187). A fourth destination, and
    /// it lands where `onOpenScheduledRun` does rather than sharing it, because the two are separate
    /// decisions about separate notices that happen to agree today. Command Center is where the
    /// storage notice renders as a row and where Settings' local-data controls are; the widget shows
    /// the same notice but has nothing to do about it beyond dismissing it.
    private let onOpenStorageNotice: () -> Void
    /// The default action for a watcher notification (SONNY-236). A fifth destination, landing where
    /// the storage and scheduled ones do rather than sharing their closures, for the reason
    /// `onOpenStorageNotice` gives about the fourth: separate decisions about separate notices that
    /// happen to agree today. Command Center is where a watcher is listed and where its Stop control
    /// will be; the widget has nothing to do about one.
    private let onOpenWatcherNotice: () -> Void
    /// Whether a given kind of notification should post at all, read from Settings › Notifications
    /// (`SonnyNotificationPreferences`). Defaulted to always-on so every existing call site and
    /// fixture keeps its old behaviour without naming the preference.
    private let isEnabled: (SonnyNotificationKind) -> Bool

    /// Fails when the current process has no real app-bundle identity — e.g. `swift run`'s bare
    /// executable (no `Info.plist`/`CFBundleIdentifier`), as opposed to a packaged `.app`.
    /// `UNUserNotificationCenter.current()` unconditionally crashes in that environment
    /// (`bundleProxyForCurrentProcess is nil`, an uncaught Objective-C exception, not a throwing
    /// Swift error) — this has to be checked *before* ever touching the class, not caught after.
    init?(
        onAllow: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onOpenTask: @escaping (String?) -> Void = { _ in },
        onOpenScheduledRun: @escaping () -> Void = {},
        onOpenStorageNotice: @escaping () -> Void = {},
        onOpenWatcherNotice: @escaping () -> Void = {},
        isEnabled: @escaping (SonnyNotificationKind) -> Bool = { _ in true }
    ) {
        guard Bundle.main.bundleIdentifier != nil else {
            return nil
        }
        center = .current()
        self.onAllow = onAllow
        self.onRetry = onRetry
        self.onOpen = onOpen
        self.onOpenTask = onOpenTask
        self.onOpenScheduledRun = onOpenScheduledRun
        self.onOpenStorageNotice = onOpenStorageNotice
        self.onOpenWatcherNotice = onOpenWatcherNotice
        self.isEnabled = isEnabled
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
            ),
            // No actions either, and this empty array is load-bearing rather than a default
            // (SONNY-113). The only action Sonny has that could plausibly go here is Retry, and
            // Retry cannot mean "run the routine again" — it is wired to `retryLastCommand()`, which
            // re-dispatches the user's own last submitted command. There is no per-routine retry
            // entry point to offer instead, and inventing one is not this ticket's. The click opens
            // Command Center, where the routine's real controls are.
            UNNotificationCategory(
                identifier: SonnyNotificationCategory.scheduled,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
            // No actions, and the empty array is load-bearing here for the same reason it is above
            // (SONNY-187). Sonny has no "fix this store" action to offer, and the only action it
            // does have — Retry — re-dispatches the user's last command, which has nothing to do
            // with the file that would not save. The click opens Command Center instead.
            UNNotificationCategory(
                identifier: SonnyNotificationCategory.storage,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
            // No actions, and here the empty array is not merely load-bearing but required by a
            // founder decision (SONNY-236). A watcher notifies and does nothing else — it may not
            // open, write, send, file, delete or run anything — so there is no action for this
            // category to offer, and adding one later is not a UI change but a reversal of the
            // decision. The click opens Command Center, which is a place to look rather than a thing
            // done on the user's behalf.
            UNNotificationCategory(
                identifier: SonnyNotificationCategory.watcher,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func postPermissionNotification(resource: String) {
        guard isEnabled(.approvalNeeded) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Approval needed"
        content.body = "Requesting access to \(resource)"
        content.categoryIdentifier = SonnyNotificationCategory.permission
        deliver(content)
    }

    func postErrorNotification(message: String) {
        guard isEnabled(.taskFailed) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Task failed"
        content.body = message
        content.categoryIdentifier = SonnyNotificationCategory.error
        deliver(content)
    }

    /// A finished run's summary, for a user who was working somewhere else while it ran.
    func postOutcomeNotification(summary: String, taskID: String?) {
        guard isEnabled(.taskFinished) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Task finished"
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

    /// What the scheduler did while the user was elsewhere (SONNY-113).
    ///
    /// Carries every scheduled outcome, successes included — the notice's own channel already does,
    /// deliberately, because "an action taken with nobody watching should be visible after the
    /// fact" is the whole reason unattended execution needs a surface. That is exactly why it must
    /// not post through `postErrorNotification`: a routine that ran fine would arrive in the
    /// notification category Sonny reserves for failures, wearing a Retry button.
    func postScheduledRunNotification(message: String) {
        guard isEnabled(.routineRan) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Routine ran"
        content.body = message
        content.categoryIdentifier = SonnyNotificationCategory.scheduled
        deliver(content)
    }

    /// A problem with Sonny's own stored data, for a user who was working somewhere else
    /// (SONNY-187).
    ///
    /// Its own category rather than `postErrorNotification`, which is what it used: a storage
    /// problem is not the task the user ran failing, and the failure category's Retry button acts on
    /// a command that has nothing to do with it.
    func postStorageNoticeNotification(message: String) {
        guard isEnabled(.storageProblem) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Storage problem"
        content.body = message
        content.categoryIdentifier = SonnyNotificationCategory.storage
        deliver(content)
    }

    /// What a standing watcher had to say, for a user who by definition was somewhere else
    /// (SONNY-236).
    ///
    /// Carries every ending, not only the change the user was waiting for: a watcher that expired or
    /// gave up in silence leaves them believing Sonny is still watching. `StandingWatcherNoticeCopy`
    /// decides which sentence; this only delivers it.
    func postWatcherNotification(message: String) {
        guard isEnabled(.watcherFired) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Watcher fired"
        content.body = message
        content.categoryIdentifier = SonnyNotificationCategory.watcher
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
                switch category {
                case SonnyNotificationCategory.outcome:
                    self?.onOpenTask(taskID)
                case SonnyNotificationCategory.scheduled:
                    self?.onOpenScheduledRun()
                case SonnyNotificationCategory.storage:
                    self?.onOpenStorageNotice()
                case SonnyNotificationCategory.watcher:
                    self?.onOpenWatcherNotice()
                default:
                    self?.onOpen()
                }
            default:
                break
            }
        }
        completionHandler()
    }
}
