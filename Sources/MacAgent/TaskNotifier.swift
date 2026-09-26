import AppKit
import Combine
import MacAgentCore
import UserNotifications

/// Posts a notification when a task needs the person or ends while they're working elsewhere, and
/// when a scheduled or watcher task reports. Clicking one brings the widget forward; nothing is
/// approved from a notification, because an approval shows the exact effect first.
@MainActor
final class TaskNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private let model: SonnyAppModel
    private let preferences: SonnyNotificationPreferences
    private let isPersonElsewhere: () -> Bool
    private var posted: Set<String> = []
    private var watching: Set<AnyCancellable> = []

    /// Nil outside a packaged app, where the notification center isn't available.
    init?(model: SonnyAppModel, preferences: SonnyNotificationPreferences, isPersonElsewhere: @escaping () -> Bool) {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        center = .current()
        self.model = model
        self.preferences = preferences
        self.isPersonElsewhere = isPersonElsewhere
        super.init()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        model.controller.$tasks
            .sink { [weak self] tasks in Task { @MainActor in self?.look(at: tasks) } }
            .store(in: &watching)
        model.desk.$notices
            .sink { [weak self] notices in Task { @MainActor in self?.announce(notices) } }
            .store(in: &watching)
    }

    private func look(at tasks: [TaskSnapshot]) {
        for task in tasks {
            guard let event = Self.event(for: task) else { continue }
            post(event.kind, key: event.key, body: event.body)
        }
    }

    struct Event: Equatable {
        let kind: SonnyNotificationKind
        let key: String
        let body: String
    }

    /// What a task's state posts, if anything. A task the person asked Sonny not to save still
    /// says when it needs them or ends, but with nothing of its own in the words or the key:
    /// Notification Center keeps what it's given after Sonny quits.
    static func event(for task: TaskSnapshot) -> Event? {
        let quiet = task.isPrivate
        switch task.phase {
        case .awaitingApproval(let commit):
            return Event(kind: .approvalNeeded, key: "\(commit.commitID)", body: quiet ? privateNeedsYou : commit.preview.title)
        case .awaitingAnswer(let ask):
            return Event(kind: .approvalNeeded, key: quiet ? "\(task.id)-ask" : "\(task.id)-ask-\(ask.question)", body: quiet ? privateNeedsYou : ask.question)
        case .paused(.outcomeUnknown(_, _, let title)):
            return Event(kind: .approvalNeeded, key: "\(task.id)-paused", body: quiet ? privateNeedsYou : "Sonny may already have done this: \(title)")
        case .completed(let summary) where !task.origin.isUnattended:
            return Event(kind: .taskFinished, key: "\(task.id)-end", body: quiet ? "A task that isn't being saved has finished." : summary)
        case .failed(let failure) where !task.origin.isUnattended:
            return Event(kind: .taskFailed, key: "\(task.id)-end", body: quiet ? "A task that isn't being saved couldn't finish." : failure.message)
        default:
            return nil
        }
    }

    static let privateNeedsYou = "A task that isn't being saved needs you."

    private func announce(_ notices: [DeskNotice]) {
        for notice in notices {
            let fromWatcher = notice.kind == .watcherStopped || notice.origin == .watcher
            let kind: SonnyNotificationKind = fromWatcher ? .watcherFired : .routineRan
            post(kind, key: notice.id.uuidString, body: notice.message)
        }
    }

    /// Each event is considered once. One the person saw in Sonny as it happened is never posted
    /// later.
    private func post(_ kind: SonnyNotificationKind, key: String, body: String) {
        guard posted.insert(key).inserted, isPersonElsewhere(), preferences.isEnabled(kind) else { return }
        let content = UNMutableNotificationContent()
        content.title = kind.title
        content.body = String(body.prefix(240))
        center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { self.model.showWidget() }
    }
}

extension TaskOrigin {
    /// Started with nobody at the Mac; the desk reports these itself.
    var isUnattended: Bool {
        self == .schedule || self == .watcher
    }
}
