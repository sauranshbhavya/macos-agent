import Foundation
import MacAgentCore
import MacAgentTestSupport
@testable import MacAgent

/// One `UserDefaults` suite, owned so it can be removed.
///
/// **The suite is torn down, and the reason is litter rather than correctness** (PR #159's review,
/// F4). The first version of these fixtures built `UserDefaults(suiteName: "…\(UUID())")` per call
/// and never removed the domain, so every suite that was written to left a plist in the developer's
/// `~/Library/Preferences/` under a name nothing could ever recognise again — the reviewer counted
/// **265** of them on the founder's Mac from a single afternoon, and no other `com.sonny.tests*`
/// domain in this tree had left a single file behind. The precedent was already in the file this
/// branch edited: `ProductShellTests` writes `defer { userDefaults.removePersistentDomain(forName:
/// suiteName) }` at four sites. `removeAtEndOfTest()` is that `defer`, in a place a caller cannot
/// forget to reach for, because the fixture hands back the thing that owns it.
@MainActor
struct FirstRunDefaultsSuite {
    let suiteName: String
    let userDefaults: UserDefaults

    /// A unique suite by default, so two tests in the same process cannot read each other's flags.
    /// Pass a name explicitly to model the *same Mac* across a relaunch — two coordinators over one
    /// suite is what a second launch of the app actually is.
    init(suiteName: String = "com.sonny.tests.firstRun.\(UUID().uuidString)") {
        self.suiteName = suiteName
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("UserDefaults refused the suite \(suiteName)")
        }
        userDefaults = defaults
    }

    var store: FirstRunStore { FirstRunStore(userDefaults: userDefaults) }

    @MainActor
    func makeCoordinator() -> FirstRunCoordinator { FirstRunCoordinator(store: store) }

    /// Removes the domain and the plist behind it. Safe to call more than once, and safe on a suite
    /// nothing ever wrote to.
    func removeAtEndOfTest() {
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}

/// A `FirstRunCoordinator` over a suite of this test's own, for the call sites that never write one
/// — `ProductShellTests`' nine `AppDelegate`/`CommandCenterView` fixtures, which construct the
/// coordinator and never call `begin`, so nothing is persisted and there is no plist to remove.
///
/// **A test that calls `begin`, `refresh` or `skipCurrentStep` must not use this**: those write, and
/// this hands back no way to clean up. Build a `FirstRunDefaultsSuite` and `defer` its
/// `removeAtEndOfTest()` instead.
///
/// Everything here exists rather than `FirstRunStore(userDefaults: .standard)` for the reason
/// `makeHermeticAccountModel` exists one store further in: `.standard` is the one domain every
/// packaged build on this Mac shares, and the flag it holds is "first run is over" — a test that
/// reached it would either put the founder back through first run or take it away from him, and
/// neither shows up as a failing assertion anywhere. `FirstRunStore` has no default `userDefaults`
/// parameter, so a fixture is the only way a test gets one at all.
@MainActor
func makeNonWritingFirstRunCoordinator() -> FirstRunCoordinator {
    FirstRunDefaultsSuite().makeCoordinator()
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
