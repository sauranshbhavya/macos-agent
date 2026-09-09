import Foundation
import SwiftUI

/// Founder ask, 2026-09-09: "Information density slider for all the menus in Sonny app." Three
/// stops scale row heights, paddings and list gaps; text size, icon size, control height
/// (`SonnyMetrics.controlSmall`/`.controlRegular`/`.controlLarge`), the sidebar width, every radius
/// and the page inset are untouched — those are the shapes a control or a hit target needs
/// regardless of how much the user wants on screen at once, and `SonnyMetrics` keeps its constants
/// because the dialogs' fixed chrome still reads them.
///
/// `regular` equals today's shipped values exactly (`SonnyDensityTests` pins that), so a user who
/// never touches the slider sees no change at all.
enum SonnyDensity: String, CaseIterable, Identifiable {
    case compact
    case regular
    case comfortable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .regular: return "Default"
        case .comfortable: return "Comfortable"
        }
    }

    /// The slider's three stops, left to right.
    var sliderValue: Double {
        switch self {
        case .compact: return 0
        case .regular: return 1
        case .comfortable: return 2
        }
    }

    /// The inverse of `sliderValue`, rounded to the nearest stop so a `Slider`'s continuous
    /// dragging never lands between two cases.
    init(sliderValue: Double) {
        switch Int(sliderValue.rounded()) {
        case ..<1: self = .compact
        case 1: self = .regular
        default: self = .comfortable
        }
    }

    /// A page's list rows (Tasks, the Insights recent-activity list drives off `scaled` instead —
    /// see the "one-off heights" below): `TaskHistoryRow`, `CommandCenterGroupHeader`,
    /// `JumpToPaletteRow`.
    var listRowHeight: CGFloat {
        switch self {
        case .compact: return 30
        case .regular: return 36
        case .comfortable: return 44
        }
    }

    /// The sidebar's own rows and Settings' sidebar rows.
    var navRowHeight: CGFloat {
        switch self {
        case .compact: return 26
        case .regular: return 30
        case .comfortable: return 36
        }
    }

    /// The account menu's rows, and `RoutineDetailStepRow`.
    var compactRowHeight: CGFloat {
        switch self {
        case .compact: return 24
        case .regular: return 28
        case .comfortable: return 32
        }
    }

    /// `TasksToolbarRow` and `CollectionHeader`.
    var toolbarHeight: CGFloat {
        switch self {
        case .compact: return 32
        case .regular: return 36
        case .comfortable: return 40
        }
    }

    /// `WorkspaceCard`'s own inset.
    var cardInset: CGFloat {
        switch self {
        case .compact: return 12
        case .regular: return 16
        case .comfortable: return 20
        }
    }

    /// The gap between rows inside a plain list (`TaskHistoryRow`, `RoutineRow`,
    /// `StandingWatcherRow`, `MemoryRow`, `MemoryEntryRow`, `InsightsRecentActivityRow`,
    /// `KeyboardShortcutRow`, `RoutineDetailStepRow`). Zero at Compact and Default — those rows
    /// already carry their own divider — and a visible gap only once Comfortable asks for more air.
    var rowGap: CGFloat {
        switch self {
        case .compact: return 0
        case .regular: return 0
        case .comfortable: return 4
        }
    }

    /// The vertical gap between a page's header and the content below it.
    var sectionGap: CGFloat {
        switch self {
        case .compact: return 12
        case .regular: return 16
        case .comfortable: return 24
        }
    }

    /// `WorkspaceCard`'s floor.
    var cardMinHeight: CGFloat {
        switch self {
        case .compact: return 170
        case .regular: return 190
        case .comfortable: return 210
        }
    }

    /// Scales a one-off row height that has no named token of its own: `RoutineRow` (56),
    /// `StandingWatcherRow` (44), `MemoryRow` (44), `MemoryEntryRow` (52), the Insights rows (32),
    /// `KeyboardShortcutRow` (32).
    func scaled(_ base: CGFloat) -> CGFloat {
        let factor: CGFloat
        switch self {
        case .compact: factor = 0.85
        case .regular: factor = 1
        case .comfortable: factor = 1.2
        }
        return (base * factor).rounded()
    }
}

private struct SonnyDensityKey: EnvironmentKey {
    static let defaultValue: SonnyDensity = .regular
}

extension EnvironmentValues {
    var sonnyDensity: SonnyDensity {
        get { self[SonnyDensityKey.self] }
        set { self[SonnyDensityKey.self] = newValue }
    }
}

/// The density preference: a cosmetic, non-privacy-sensitive setting, so plain injected
/// `UserDefaults` rather than an encrypted store — the same rule `SonnyAppearanceModel` follows,
/// and for the same reason (`.claude/rules/macagent-ui-conventions.md`, Preferences).
@MainActor
final class SonnyDensityModel: ObservableObject {
    static let userDefaultsKey = "com.sonny.preferences.density"

    @Published var density: SonnyDensity {
        didSet {
            userDefaults.set(density.rawValue, forKey: Self.userDefaultsKey)
        }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        // `object(forKey:) as? String`, not `string(forKey:)`, per the same rule `SonnyAppearanceModel`
        // follows: a key that has never been written must read as the default rather than as
        // whatever a bare accessor happens to coerce a missing value to. An unknown stored string
        // (a value from a future release, or a corrupted default) also falls back to `.regular`
        // rather than crashing or reading as a fixed case.
        let stored = userDefaults.object(forKey: Self.userDefaultsKey) as? String
        density = stored.flatMap(SonnyDensity.init(rawValue:)) ?? .regular
    }
}
