import Foundation
import MacAgentCore
import MacAgentTestSupport
@testable import MacAgent

/// A `FirstRunCoordinator` whose two flags land in a `UserDefaults` suite of this test's own.
///
/// **Every fixture uses this rather than `FirstRunStore(userDefaults: .standard)`**, for the reason
/// `makeHermeticAccountModel` exists one store further in: `.standard` is the one domain every
/// packaged build on this Mac shares, and the flag it holds is "first run is over" — a test that
/// reached it would either put the founder back through first run or take it away from him, and
/// neither shows up as a failing assertion anywhere. `FirstRunStore` has no default `userDefaults`
/// parameter, so this is the only way a test gets one at all.
///
/// The suite name is unique per call, so two tests in the same process cannot read each other's
/// flags. Pass `suiteName` explicitly to model the *same Mac* across a relaunch — two coordinators
/// over one suite is what a second launch of the app actually is.
@MainActor
func makeHermeticFirstRunCoordinator(
    suiteName: String = "com.sonny.tests.firstRun.\(UUID().uuidString)"
) -> FirstRunCoordinator {
    FirstRunCoordinator(store: makeHermeticFirstRunStore(suiteName: suiteName))
}

@MainActor
func makeHermeticFirstRunStore(
    suiteName: String = "com.sonny.tests.firstRun.\(UUID().uuidString)"
) -> FirstRunStore {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("UserDefaults refused the suite \(suiteName)")
    }
    return FirstRunStore(userDefaults: defaults)
}

/// A `ScreenAccessOnboardingModel` that reaches neither this Mac's TCC state nor its process.
///
/// **A bare `ScreenAccessOnboardingModel()` is not hermetic and one of its defaults is destructive.**
/// The checker default reads the developer's real grants, so a fixture inheriting it asserts against
/// whatever the machine happens to be set to; the relauncher default is `DefaultAppRelauncher`,
/// whose `relaunch()` calls `NSApp.terminate(nil)` — a test that reached it would end the test
/// process rather than fail. `NoOpRelauncher` counts instead.
@MainActor
func makeHermeticScreenAccessModel(
    screenRecordingGranted: Bool = false,
    accessibilityTrusted: Bool = false,
    accessibilityGrantsOnRequest: Bool = false,
    relauncher: NoOpRelauncher = NoOpRelauncher(),
    settingsOpener: @escaping (URL) -> Void = { _ in }
) -> ScreenAccessOnboardingModel {
    ScreenAccessOnboardingModel(
        permissionChecker: DeterministicScreenPermissions(
            accessibilityTrusted: accessibilityTrusted,
            screenRecordingGranted: screenRecordingGranted,
            accessibilityGrantsOnRequest: accessibilityGrantsOnRequest
        ),
        relauncher: relauncher,
        settingsOpener: settingsOpener
    )
}

/// Counts relaunches instead of performing one. Shared by the fixtures above so no suite has to
/// declare its own and risk defaulting the real one.
@MainActor
final class NoOpRelauncher: AppRelaunching {
    private(set) var relaunchCount = 0

    func relaunch() {
        relaunchCount += 1
    }
}
