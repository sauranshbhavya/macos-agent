import AppKit
import MacAgentCore
import SwiftUI

// cua-driver reads its policy variables once, when screen control first starts. Clearing them here,
// before any other thread exists, keeps a stray shell setting from stopping it (V2 plan section 12).
CuaEnvironment.clearManagedVariables()

let app = NSApplication.shared
// The one place that asks for the real Keychain and the real stores. The account model makes the
// process's single backend client, and the kernel is handed that same client: two clients would be
// two token caches, and the server reads a second refresh as a stolen token.
let accountModel = SonnyAccountModel.atItsRealKeychainLocation()
let screenAccessModel = ScreenAccessOnboardingModel()
let kernelStores = KernelStores(
    folder: (try? KernelStores.applicationSupportFolder())
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("Sonny/V2", isDirectory: true)
)
let appModel = SonnyAppModel(
    desk: SonnyKernel.makeDesk(client: accountModel.backendClient, stores: kernelStores),
    stores: kernelStores,
    client: accountModel.backendClient
)
// The readiness rows follow the session: signing in is a sheet and signing out a menu item, so
// neither re-fires anything that would refresh them, and the next account must not read the
// previous one's credit figure.
accountModel.sessionDidChange = { [weak appModel] in
    appModel?.refreshPermissions()
    appModel?.forgetAllowance()
}
// The plan row asks the account model's one entitlement service: a second would be a second clock
// anchor and a second refresh guard.
appModel.entitlementConfirmation = { [entitlements = accountModel.entitlements] in
    await entitlements.claimConfirmation()
}
let delegate = AppDelegate(
    model: appModel,
    accountModel: accountModel,
    screenAccessModel: screenAccessModel,
    firstRunCoordinator: FirstRunCoordinator(store: FirstRunStore(userDefaults: .standard))
)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
