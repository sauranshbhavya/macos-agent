import AppKit
import MacAgentCore
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
// **The view model is bound to a name rather than built inline** (SONNY-136, PR #153's F4), because
// the line below needs to refer to it. It was `viewModel: .atItsRealStoreLocations(…)` in the call.
// **`accountIdentity` reads the Keychain, not the client actor** (SONNY-404, PR #207's F1): every
// queued server deletion carries the account it was pressed under, and the enqueue that records one
// runs synchronously before the local deletes. `SonnyTaskDeletionService.init` carries the argument.
let accountTokenStore = KeychainAccountTokenStore()
let agentViewModel = AgentViewModel.atItsRealStoreLocations(
    backendClient: accountModel.backendClient,
    accountIdentity: { (try? accountTokenStore.loadTokens())??.userID }
)
// **The session and the readiness row, joined here.** Signing in is a sheet over Command Center and
// signing out is a menu item, so neither re-fires the `onAppear` that is otherwise the only thing
// that refreshes the account row — the "show permission readiness" tool then reported a session the
// user no longer had, or denied one they did. This is the one file that holds both objects, which is
// why the wiring is a line here rather than a reference inside either.
accountModel.sessionDidChange = { [weak agentViewModel] in
    agentViewModel?.refreshPermissions()
    // **And the screen-control figure, for the same reason one line up** (SONNY-214; PR #188's F1).
    // It is an account-scoped number read over an authenticated session, and the only things that
    // ask for it are the two surfaces that show it, when they appear — which is precisely what a
    // sheet and a menu item do not re-fire. Without this line a signed-out user went on reading
    // "12 of 20 runs left this month" on the page they were already on, and the next user to sign in
    // on this Mac read the previous one's figure.
    agentViewModel?.forgetScreenControlAllowance()
    // **And the deletion queue** (SONNY-404, PR #207's F1). Every queued server deletion carries the
    // account it was pressed under; this is the moment a different account signing in makes the old
    // ones undeliverable, so they are discarded with the reason recorded, and whatever the new
    // account owns is swept. Without it a wipe pressed offline by one user deleted the *next* user's
    // everything at the following launch.
    agentViewModel?.settlePendingServerDeletionsForSessionChange()
}
// **The one screen-control billing gate, joined here for the same reason the line above is**
// (SONNY-213). It needs the account model's `EntitlementService` — one per process, because that
// actor holds the clock high-water anchor and the single-flight refresh guard — and the shared
// backend client, which is what the allowance read authenticates with. This is the only file that
// holds both objects. Without this line the view model keeps its `ClosedScreenControlGate` and
// screen control refuses, which is the fail-closed direction a missing wiring should take.
// **One service, handed to the gate twice under two protocols** (SONNY-215). Reading the allowance
// and buying more of it are two capabilities of the same object, and the gate names them separately
// so that nothing can reach the charging one while thinking about the reading one. Building two
// services here would be two clients, two sessions and two answers to one question.
let screenControlAllowanceService = ScreenControlAllowanceService(client: accountModel.backendClient)
agentViewModel.screenControlGate = SonnyScreenControlGate(
    entitlements: accountModel.entitlements,
    allowance: screenControlAllowanceService,
    topUp: screenControlAllowanceService
)
let delegate = AppDelegate(
    viewModel: agentViewModel,
    accountModel: accountModel,
    screenAccessModel: screenAccessModel,
    firstRunCoordinator: FirstRunCoordinator(store: FirstRunStore(userDefaults: .standard))
)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
