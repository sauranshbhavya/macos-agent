import AppKit
import Combine
import SwiftUI

/// The three answers to "which appearance": the app's own dark look, its light look, or whatever
/// macOS is set to. Stored by raw value, so the names are part of the on-disk contract.
enum SonnyAppearance: String, CaseIterable, Identifiable {
    case dark
    case light
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "System"
        }
    }

    /// What `NSApp.appearance` is set to. `nil` hands the choice back to the system, which is what
    /// "System" means and the only way the app follows a change the user makes in System Settings
    /// while it is running.
    var nsAppearance: NSAppearance? {
        switch self {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }
}

/// The interface-theme preference: a cosmetic, non-privacy-sensitive setting, so plain injected
/// `UserDefaults` rather than an encrypted store, the same rule `usePointerCursors` and
/// `displayFullNames` follow (`.claude/rules/macagent-ui-conventions.md`, Preferences).
///
/// **The app's appearance is set at the application, not per window.** Menus, popovers, sheets and
/// alerts all read `NSApp.appearance`, and a window-level override would leave those following the
/// system while the window did not. The one exception is the floating widget, whose panel forces
/// `.darkAqua` on itself (`FloatingWidgetWindowController`): System B is dark by design, its glass
/// material is a dark HUD material, and its tokens are white literals.
///
/// **Dark is the default for a new install**, because it is the product's designed look and what
/// every screenshot and wireframe shows; a user who wants Light or System says so once.
@MainActor
final class SonnyAppearanceModel: ObservableObject {
    static let userDefaultsKey = "com.sonny.preferences.appearance"

    @Published var appearance: SonnyAppearance {
        didSet {
            userDefaults.set(appearance.rawValue, forKey: Self.userDefaultsKey)
            apply()
        }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let stored = userDefaults.string(forKey: Self.userDefaultsKey)
        appearance = stored.flatMap(SonnyAppearance.init(rawValue:)) ?? .dark
    }

    /// Pushes the stored choice onto `NSApp`. Called once at launch, once the application object
    /// exists, and again on every change; reading the preference alone changes nothing on screen.
    func apply() {
        NSApp?.appearance = appearance.nsAppearance
    }
}
