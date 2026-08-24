import Foundation
import MacAgentCore

/// Where the Memory section's switches live.
///
/// **`UserDefaults`, not a twelfth encrypted store, and the choice is deliberate** (SONNY-208).
/// `.claude/rules/macagent-ui-conventions.md`'s Preferences rule sends a non-privacy-sensitive
/// preference here, and what these keys hold is a boolean about Sonny's future behaviour — never a
/// word of the user's own content, which is what `LocalStorageEncryption` exists to protect. Two
/// consequences settled it:
///
/// - **A wipe must not switch memory back on.** Every encrypted store is deleted by Delete Local
///   Data. A memory switch living in one would be erased by the very action a privacy-minded user
///   reaches for, and recording would silently resume — the opposite of what they asked for. These
///   keys survive it, so "off" stays off.
/// - **The *unexpected* fail-open path is removed, not fail-open itself.** Stated precisely, because
///   a privacy control is the wrong place for a comfortable summary: this switch's default **is**
///   on, deliberately — a new user with no key stored must record, which is what
///   `?? true` below says — so an absent or wrong-typed value reads as recording. What
///   `UserDefaults` removes is the path where that happens *without the user ever having chosen it*:
///   a local store that will not decrypt reports a failure and yields nothing, and a switch read
///   that way would silently fall back to on for someone who had turned it off. There is no
///   decryption step here to fail, so the only way this reads on is the way it is supposed to —
///   nobody has turned it off. Do not shorten this to "it fails closed"; it does not, and that was
///   a real over-claim in this branch's own records (PR #98 round-3 review, F6).
///
/// Booleans are read with `object(forKey:) as? Bool ?? true`, never `.bool(forKey:)` — the same
/// convention and the same reason as `usePointerCursors`: a missing key must mean "on" for a new
/// user, and `.bool(forKey:)` silently answers `false`.
struct MemorySettingsStore {
    private enum Keys {
        static let memoryEnabled = "com.sonny.memory.enabled"

        static func category(_ category: MemoryCategory) -> String {
            "com.sonny.memory.category.\(category.rawValue).enabled"
        }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    /// The stored switches, composed with whatever the administrator currently says.
    ///
    /// The policy is passed in rather than read here so this type stays a pure reader of the user's
    /// own choices: row 19's provider is asked once, by the view model, and its answer reaches every
    /// consumer through one value.
    func load(policy: MemoryEnterprisePolicy) -> MemoryRecordingSettings {
        MemoryRecordingSettings(
            isEnabledByUser: userDefaults.object(forKey: Keys.memoryEnabled) as? Bool ?? true,
            categoriesDisabledByUser: Set(
                MemoryCategory.allCases.filter { category in
                    guard category != .clipboardHistory else {
                        // Clipboard recording's switch is `ClipboardHistorySettings.isEnabled`, which
                        // predates this store and which the monitor already fails closed on. Never
                        // written here, so never read here either — a second flag over the same
                        // behaviour is how a surface ends up disagreeing with what is recording.
                        return false
                    }
                    return !(userDefaults.object(forKey: Keys.category(category)) as? Bool ?? true)
                }
            ),
            policy: policy
        )
    }

    func setMemoryEnabled(_ isEnabled: Bool) {
        userDefaults.set(isEnabled, forKey: Keys.memoryEnabled)
    }

    /// Records a per-type switch.
    ///
    /// `.clipboardHistory` is refused rather than silently written, so a caller that routes it here
    /// by mistake is a test failure rather than a second source of truth nobody notices. The one
    /// legitimate path is `AgentViewModel.setMemoryCategoryEnabled(_:to:)`, which sends clipboard to
    /// its own existing setting.
    func setCategoryEnabled(_ isEnabled: Bool, for category: MemoryCategory) {
        guard category != .clipboardHistory else { return }
        userDefaults.set(isEnabled, forKey: Keys.category(category))
    }
}
