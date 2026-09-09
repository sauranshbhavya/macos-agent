import Foundation

/// The six kinds of native notification `SonnyNotificationService` can post. One case per category
/// that service owns, in the order Settings › Notifications lists them.
///
/// **`title` is not a second copy of the notification's own title — it is read from
/// `SonnyNotificationService`, where each `post…` method sets `content.title` to exactly this
/// string.** The two are the same word twice on purpose: the Settings row and the banner it is
/// switching off have to agree, or a toggle would say "Watcher fired" while the thing it silences is
/// titled something else.
enum SonnyNotificationKind: String, CaseIterable, Identifiable {
    case approvalNeeded
    case taskFinished
    case taskFailed
    case routineRan
    case watcherFired
    case storageProblem

    var id: String { rawValue }

    var title: String {
        switch self {
        case .approvalNeeded: return "Approval needed"
        case .taskFinished: return "Task finished"
        case .taskFailed: return "Task failed"
        case .routineRan: return "Routine ran"
        case .watcherFired: return "Watcher fired"
        case .storageProblem: return "Storage problem"
        }
    }

    /// The moment this toggle names, for the Settings row beneath its title — the moment, not the
    /// mechanism, per the founders' no-explanatory-copy rule.
    var settingsDetail: String {
        switch self {
        case .approvalNeeded: return "Sonny needs your approval to continue"
        case .taskFinished: return "A task finishes"
        case .taskFailed: return "A task stops on an error"
        case .routineRan: return "A scheduled routine runs"
        case .watcherFired: return "A watcher sees a change"
        case .storageProblem: return "A local file cannot be read or written"
        }
    }
}

/// Per-kind on/off for Sonny's native notifications (Settings › Notifications).
///
/// **Plain injected `UserDefaults`, not `LocalStorageEncryption`.** This is a cosmetic preference —
/// which banners a user wants to see — with no privacy sensitivity of its own, the same rule
/// `SonnyAppearanceModel` follows (`.claude/rules/macagent-ui-conventions.md`, Preferences).
///
/// **Reads with `object(forKey:) as? Bool ?? true`, never `.bool(forKey:)`.** The latter silently
/// resolves a missing key to `false`, which would launch every notification kind off for a user who
/// never touched this page — wrong for a preference the product wants on by default.
@MainActor
final class SonnyNotificationPreferences: ObservableObject {
    @Published private(set) var enabled: [SonnyNotificationKind: Bool]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [SonnyNotificationKind: Bool] = [:]
        for kind in SonnyNotificationKind.allCases {
            loaded[kind] = defaults.object(forKey: Self.key(for: kind)) as? Bool ?? true
        }
        enabled = loaded
    }

    func isEnabled(_ kind: SonnyNotificationKind) -> Bool {
        enabled[kind] ?? true
    }

    func setEnabled(_ isEnabled: Bool, for kind: SonnyNotificationKind) {
        enabled[kind] = isEnabled
        defaults.set(isEnabled, forKey: Self.key(for: kind))
    }

    private static func key(for kind: SonnyNotificationKind) -> String {
        "com.sonny.preferences.notifications.\(kind.rawValue)"
    }
}
