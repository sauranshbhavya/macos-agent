import AppKit
import SwiftUI

let app = NSApplication.shared
// **The one place in the repository that asks for the real local-store locations** (SONNY-240).
// `AppDelegate.init` takes the view model rather than defaulting it, so the request is written here
// where a reader can see it, and no other file — production or test — can make it by saying nothing.
let delegate = AppDelegate(viewModel: .atItsRealStoreLocations())
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
