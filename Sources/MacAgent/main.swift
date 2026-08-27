import AppKit
import SwiftUI

let app = NSApplication.shared
// **The one place in the repository that asks for the real local-store locations** (SONNY-240).
// `AppDelegate.init` takes the view model rather than defaulting it, so the request is written here
// where a reader can see it, and no other file — production or test — can make it by saying nothing.
// The same rule for the Keychain (SONNY-128): `SonnyAccountModel.atItsRealKeychainLocation()` is the
// one named request for the real Keychain and the real host resolution, and this is the only file
// allowed to make it.
let delegate = AppDelegate(
    viewModel: .atItsRealStoreLocations(),
    accountModel: .atItsRealKeychainLocation()
)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
