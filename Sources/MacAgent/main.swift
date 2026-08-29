import AppKit
import SwiftUI

let app = NSApplication.shared
// **The one place in the repository that asks for the real local-store locations** (SONNY-240).
// `AppDelegate.init` takes the view model rather than defaulting it, so the request is written here
// where a reader can see it, and no other file — production or test — can make it by saying nothing.
// The same rule for the Keychain (SONNY-128): `SonnyAccountModel.atItsRealKeychainLocation()` is the
// one named request for the real Keychain and the real host resolution, and this is the only file
// allowed to make it.
// **One backend client for the process, built once and shared** (SONNY-130). The account model
// makes it — that is where the real Keychain is asked for — and the view model is handed the same
// instance rather than building a second. Two clients would be two token caches and two
// single-flight refresh guards, and the server reads a second rotation inside its ten-second overlap
// as a stolen token and revokes the whole family (contract §3.3).
// **First run's two collaborators are named here for the same reason** (SONNY-137).
// `FirstRunStore` writes two flags into the one `UserDefaults` domain every packaged build on this
// Mac shares, and `ScreenAccessOnboardingModel` reads this machine's real TCC grants — so both are
// required parameters all the way down rather than defaults a fixture inherits by saying nothing.
// The screen-access model is built once and shared by first run and Settings › Security & Access,
// so a Screen Recording request made in one is visible as relaunch guidance in the other; two
// instances would be two answers to "does this launch still owe a relaunch".
let accountModel = SonnyAccountModel.atItsRealKeychainLocation()
let screenAccessModel = ScreenAccessOnboardingModel()
let delegate = AppDelegate(
    viewModel: .atItsRealStoreLocations(backendClient: accountModel.backendClient),
    accountModel: accountModel,
    screenAccessModel: screenAccessModel,
    firstRunCoordinator: FirstRunCoordinator(store: FirstRunStore(userDefaults: .standard))
)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
