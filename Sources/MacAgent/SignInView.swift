import AppKit
import MacAgentCore
import SwiftUI

/// Sign-in state for the whole app, held once and observed by Command Center.
///
/// **Its own object rather than another field on `AgentViewModel`.** The view model owns the run
/// loop and fourteen local stores; an account session shares none of that, and adding it there
/// would put one more required parameter on an initializer that already has no defaults at all,
/// and would land in every one of its fixtures — which exist only because SONNY-240 removed every
/// default from it.
///
/// (**Two numerals came out of that sentence, both stale, both for the same reason** — SONNY-326.
/// It read "a *sixteenth* required parameter on an initializer whose *fifteen* fixtures". A
/// required-parameter count moves whenever a store or a dependency is added, and a fixture count
/// moves whenever a fixture file is — both are ordinary work, both had already happened, and
/// neither number carried the argument. The argument is that the cost is paid at *every*
/// construction site, and that holds at any count.)
///
/// **`restore()` is what makes the app come back signed in.** It reads the Keychain and touches no
/// network, so it works on a launch with no connection — and, the case this ticket exists for, on
/// the relaunch macOS forces after a Screen Recording grant.
@MainActor
final class SonnyAccountModel: ObservableObject {
    enum Step: Equatable {
        /// Type an address.
        case address
        /// A code has been requested for `emailAddress`.
        case code
        /// Signed in.
        case signedIn
    }

    @Published private(set) var step: Step = .address
    @Published var emailAddress: String = ""
    @Published var code: String = ""
    @Published private(set) var identity: SonnyAccountIdentity?
    @Published private(set) var failure: SignInFailure?
    /// A neutral line — "Code sent.", or what sign-out managed. Never a failure.
    @Published private(set) var notice: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isConfigured = true
    /// What this Mac can currently prove about the account's subscription, or `nil` when it can
    /// prove nothing (SONNY-216).
    ///
    /// **`nil` is what a user who has never subscribed looks like, and it is why the Account
    /// section shows them no subscription line and no Manage control.** The gateway also refuses
    /// that account with `409 entitlement.no_subscription`, but a control that only fails when
    /// pressed is a broken control; not offering it is the requirement (founder direction,
    /// 2026-08-31). `SubscriptionReading` carries the four situations that produce `nil`.
    @Published private(set) var subscription: SubscriptionSnapshot?
    /// What the gateway last said about payment on this account, or `nil` when nothing is known
    /// (SONNY-380).
    ///
    /// **`nil` is the offline answer and the founders chose it.** The read is a network call and the
    /// grace window keeps capabilities working without one, so a Mac that cannot reach the gateway
    /// shows nothing about payment state and the line says what the claim proves — which is the
    /// state this surface was in before this ticket, now reached only when there is genuinely
    /// nothing to add rather than always.
    ///
    /// **Its own value rather than a field on `subscription`.** `SubscriptionSnapshot` is what the
    /// signed claim establishes, judged locally with no network; this is a separate, unsigned read
    /// that can fail on its own. Folding them would make one type mean two different kinds of
    /// certainty, and would put a network failure inside a value `SubscriptionReading.read`
    /// documents as pure.
    @Published private(set) var paymentState: BillingPaymentState?
    /// Whether this model has opened the billing portal and not yet re-read what came of it
    /// (SONNY-380, PR #206's F3; founders' decision of 2026-09-05, option A).
    ///
    /// **The re-read is gated on this rather than firing on every activation**, which is what the
    /// decision asks for: the customer pressed the control that resolves the state the line names,
    /// so coming back to the window is the one moment the line is expected to have changed. An
    /// ungated re-read would put an authenticated request on every switch back to Sonny for as long
    /// as the sheet is open, for a value that only a provider webhook can move.
    ///
    /// Not `@Published`: nothing renders from it, and publishing it would invite a view to.
    private(set) var didOpenBillingPortal = false
    /// Why the portal did not open, in the portal's own vocabulary (PR #183, F4).
    ///
    /// **Its own published value rather than `failure`**, because `failure` is a `SignInFailure` and
    /// `SignInCopy` is documented as the sentences *the sign-in flow* can show. Routing a portal
    /// press through it told a signed-in user that Sonny "couldn't finish signing you in", and told
    /// a user hitting a revoked provider credential to "try again in a moment" on the one failure
    /// whose definition is that a retry fails identically.
    @Published private(set) var portalFailure: BillingPortalFailure?

    private let service: SonnyAccountService
    /// Read for the subscription line only. **This model asks it nothing about permission** —
    /// `EntitlementService.decision(for:)` remains the one way that question is asked, and
    /// `currentSubscription()` deliberately returns no capability list, so this surface cannot
    /// become a second answer to it.
    ///
    /// **`let` rather than `private let`, for exactly the reason `backendClient` is exposed above,
    /// and it is the same argument twice** (SONNY-213). This process must hold **one** entitlement
    /// service: the actor carries the high-water clock anchor `effectiveNow` advances and persists,
    /// and the single-flight refresh guard that makes N stale readers cause one fetch. A second
    /// instance would be a second anchor — so a rollback closed by one would be open to the other —
    /// and a second guard guarding half the callers. Screen control's gate needs to ask this
    /// question, `main.swift` is the one file holding both objects, and handing it this instance is
    /// how "one client, one service" stays true by construction rather than by two call sites
    /// agreeing.
    let entitlements: EntitlementService

    /// Called after this Mac's session changes — a sign-in that succeeded, or a sign-out that
    /// cleared it (SONNY-136, PR #153's F4).
    ///
    /// **It exists because the readiness row was stale in both directions, and the direction that
    /// matters is the second one.** `AgentViewModel.modelAccessReadiness` is refreshed only by
    /// `refreshPermissions()`, whose call sites are all Command Center `onAppear`s and the Refresh
    /// button — and sign-in is a *sheet* over Command Center, so the window's `onAppear` does not
    /// re-fire when it closes. Signing in then left the "show permission readiness" tool answering
    /// *"Sign in to Sonny in Command Center."* for a signed-in user; signing out left it answering
    /// *"Signed in."* for a session that no longer exists, which is PR #139's F10 in its own words —
    /// readiness that is not readiness — reappearing at the surface this ticket was assigned to fix.
    ///
    /// **A callback rather than this type reaching for the view model.** `SonnyAccountModel` knows
    /// about a client and a service and nothing about the agent; giving it a reference to
    /// `AgentViewModel` would invert that for one notification. `main.swift` owns both objects and
    /// is where the two are already joined by the shared client, so it is where this is wired.
    ///
    /// Not called by `restore()`: that runs at launch, before any window exists, and the view model
    /// refreshes on the first `onAppear` anyway.
    var sessionDidChange: (@MainActor () -> Void)?

    /// The one backend client this process holds, exposed so `main.swift` can hand the *same* one to
    /// `AgentViewModel` (SONNY-130).
    ///
    /// **One client, not two, and the reason is the refresh guard.** `SonnyBackendClient` holds the
    /// single-flight generation counter that makes ten concurrent `401 auth.token_expired`s cause
    /// one token rotation; the server reads a second rotation presented past its ten-second overlap
    /// as theft and revokes the whole family (§3.3). A second client would have its own counter and
    /// its own cache, so the guard would be guarding half the callers. That was latent while
    /// sign-out was the only authenticated caller in the tree; SONNY-130 adds four more.
    let backendClient: SonnyBackendClient

    /// **`client` has no default**, for SONNY-240's reason applied to the Keychain: a default here
    /// would reach the one Keychain every packaged build on this Mac shares, invisibly, from any
    /// call site that predates the parameter. `atItsRealKeychainLocation()` is the one named place
    /// that asks for it, and `main.swift` is the only file allowed to call that.
    ///
    /// Takes the client rather than the service, because the client is the thing that is shared and
    /// the service is a thin wrapper over it. Building the service here keeps "one client, one
    /// service" true by construction rather than by two call sites agreeing.
    /// **`entitlementStore` and `entitlementKeys` have no defaults**, for the reason `client` has
    /// none: a default store here would reach the one Keychain every packaged build on this Mac
    /// shares, and a fixture that inherited it would read and delete the founder's real entitlement.
    /// `atItsRealKeychainLocation()` is the one named place that asks for the real pair.
    init(
        client: SonnyBackendClient,
        entitlementStore: any EntitlementStoring,
        entitlementKeys: EntitlementKeySet
    ) {
        self.backendClient = client
        self.service = SonnyAccountService(client: client)
        // Built here rather than injected whole, for the reason the account service is: the client
        // is the thing that is shared and must be one instance, and building both from it keeps
        // "one client, one service" true by construction rather than by call sites agreeing.
        self.entitlements = EntitlementService(
            client: client,
            store: entitlementStore,
            keys: entitlementKeys
        )
    }

    /// The shipping app's one request for the real Keychain and the real host resolution.
    ///
    /// Mirrors `AgentViewModel.atItsRealStoreLocations()` exactly, including why it exists: one
    /// named place where the real locations are allowed, rather than several where they arrive by
    /// silence. `SignInSurfaceTests.onlyMainAsksForTheRealKeychain` holds `Sources/` as the
    /// population — exact equality on `["SignInView.swift": 1, "main.swift": 1]`, so it fails in
    /// both directions — and only `main.swift` may call it. (This named
    /// `SignInReleaseSwitchScanTests`, whose population is the five staging-pointer tokens and not
    /// this one; PR #133, F7.)
    static func atItsRealKeychainLocation() -> SonnyAccountModel {
        SonnyAccountModel(
            client: SonnyBackendClient(
                environment: SonnyBackendHost.resolve(),
                tokenStore: KeychainAccountTokenStore(),
                // Named rather than defaulted: the client's `= .shared` default is a session backed by
                // a 20 MB disk cache that nobody chose, which SONNY-130 and SONNY-134's authenticated
                // `GET`s would fill with the user's own data (PR #133, F11).
                session: SonnyBackendSession.forBackendCalls()
            ),
            entitlementStore: KeychainEntitlementStore(secretStore: KeychainSecretStore()),
            // **The shipped set is empty in every release build**, so no claim verifies and the
            // subscription line renders for nobody until a gateway exists to have signed one — which
            // is `SonnyEntitlementKeys`' own recorded state, not a gap this ticket introduces. The
            // debug override is what a founder's manual pass points at a real gateway with.
            entitlementKeys: SonnyEntitlementKeys.resolve()
        )
    }

    var isSignedIn: Bool { identity != nil }

    var signedInAddress: String? { identity?.emailAddress }

    var canSendCode: Bool {
        !isBusy && isConfigured && !emailAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var canVerify: Bool {
        !isBusy && isConfigured && !code.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Read the Keychain. Called once at launch, before any window exists.
    func restore() async {
        isConfigured = await service.isConfigured()
        do {
            identity = try await service.restoredIdentity()
            step = identity == nil ? .address : .signedIn
        } catch {
            // Bytes that are not a session this build can read. The user signs in again, and the
            // next successful sign-in overwrites them; nothing here deletes a credential store on
            // the strength of a decode failure.
            identity = nil
            step = .address
            failure = .signedOut
        }
        if !isConfigured { failure = .notConfigured }
    }

    func sendCode() async {
        guard canSendCode else { return }
        let address = emailAddress.trimmingCharacters(in: .whitespaces)
        await run {
            _ = try await service.startEmailSignIn(email: address)
            emailAddress = address
            code = ""
            step = .code
            notice = SignInCopy.codeSentConfirmation
        }
    }

    func verify() async {
        guard canVerify else { return }
        let typedCode = code.trimmingCharacters(in: .whitespaces)
        await run {
            identity = try await service.verifyEmailCode(email: emailAddress, code: typedCode)
            code = ""
            step = .signedIn
        }
        // **Only when a session really arrived — and the guard is what does that, not the
        // placement** (PR #153, cycle 2's C2-F6). This comment used to say `run` swallows the
        // failure so a call inside it would fire on a wrong code too. It would not:
        // `service.verifyEmailCode` throws before `identity` is assigned, so a hook inside the
        // closure is simply never reached on a refusal — the reviewer built that mutant and it
        // survived the whole suite, correctly. What actually protects the refused case is the
        // `identity != nil` test on this line, and `aSuccessfulSignInAnnouncesItselfAndAFailedOne
        // DoesNot` is what holds it: remove the guard and its `refusedAnnouncements == 0` fails.
        //
        // Outside `run` for a different and smaller reason: `run` sets `isBusy = false` in a
        // `defer`, and a hook that fires while the surface still says it is busy invites the
        // refresh to read state the sign-in has not finished publishing.
        if identity != nil { sessionDidChange?() }
    }

    /// Re-read what the cached claim says about the subscription (SONNY-216).
    ///
    /// **Not routed through `run`**, and the difference is what `run` is for: it sets `isBusy`,
    /// clears the previous outcome and turns a throw into a named failure, all of which are right
    /// for something the user pressed a control for. This is a read that happens *because a dialog
    /// opened*, so a failure is not news — it is the ordinary state of a Mac with no gateway to have
    /// signed a claim — and reporting one would put a warning under a sign-in the user just
    /// completed. It cannot throw either: `currentSubscription()` answers `nil` rather than failing.
    ///
    /// ## Why this reads twice
    ///
    /// **Because one read cannot show a row on the first open, which is the branch's own headline
    /// manual item** (PR #183, F1). `currentSubscription()` is local and instant by design: it reads
    /// the cache, and when the cache is empty it starts a detached refresh and returns `nil`
    /// immediately. Nothing re-read when that refresh landed. And this is the *only* writer of the
    /// entitlement store — `decision(for:)` has no caller anywhere in `Sources/` — so on any Mac
    /// that has not previously opened Account the cache is empty **by construction**, and the trace
    /// was: open Account → nothing cached → refresh starts → row absent → claim arrives → nothing
    /// reads it → row stays absent until the dialog is closed and reopened.
    ///
    /// So: read, and if there was nothing, wait once for the fetch that read started and look
    /// again. The second read is skipped entirely when the first one answered, so the common case —
    /// a Mac with a valid cached claim — still never waits on the network.
    ///
    /// ## Three things about the wait that are true and are not obvious
    ///
    /// **The guard's condition is "the answer was `nil`", which is a larger set than "the cache was
    /// empty."** A never-subscribed account holds a real, verifying claim whose plan is the absence
    /// sentinel, so `currentSubscription()` answers `nil` for it — and once that claim passes the
    /// gateway's 8-hour refresh mark, the first read starts a refresh and this waits on the network
    /// on **every** Account open, for a row that will be absent either way. Not a defect: the wait
    /// is off the render path and the answer is correct. Worth knowing before someone reads the
    /// sentence above as "only on a first run".
    ///
    /// **`await refreshTask?.value` cannot be cancelled.** The task is `Task<Void, Never>`, so the
    /// wait has no cancellation point, and closing the Account sheet does not stop it. It would not
    /// have stopped the *refresh* either — that task is detached by design — so what is bounded here
    /// is only how long this method sits, and that bound is the client's: `refreshNow()` uses
    /// `SonnyBackendTimeouts.auth` (20 s) and is not retried on a transport timeout, so roughly 20 s
    /// realistically and about 100 s worst case across the retryable codes' three attempts.
    ///
    /// **Nothing on screen awaits this.** Both call sites are off the render path — `.task`, and an
    /// unstructured `Task` in `onChange` — and this does not set `isBusy`, so the row appears late
    /// rather than the dialog hanging.
    func refreshSubscription() async {
        // **Cleared here because this is what runs every time the Account sheet is presented**
        // (PR #183's cycle 3, C3). `portalFailure` is set by a press and was cleared by nothing on
        // appear, so a failed press left its sentence under the row, and closing and reopening
        // Account showed it again with no press behind it. `run()`'s own doc comment states the
        // standard this missed — "no path can forget to unset `isBusy` or leave a stale message
        // under a new result" — and this method is deliberately not routed through `run`, so it is
        // the path that has to do it itself.
        portalFailure = nil
        subscription = await entitlements.currentSubscription()
        // **This guard is the whole difference between the design above and a wait on every open.**
        // Removing it made every Account open await any refresh in flight — including for a
        // subscribed user whose cached claim had already answered — and it survived the whole suite
        // until `theCachedAnswerWinsAndDoesNotWaitForTheRefreshItStarted` was written for it
        // (cycle 3, C2; the third survivor in three rounds, all of them a guard nothing asserted).
        guard subscription == nil else { return }
        // **`awaitPendingRefresh()` rather than `refreshNow()`**, which would be a second request
        // beside the one already in flight: `startRefresh` is single-flighted and this joins it.
        // When no refresh is pending there is nothing to await and this returns immediately.
        await entitlements.awaitPendingRefresh()
        subscription = await entitlements.currentSubscription()
    }

    /// Re-read whether a payment failure is outstanding (SONNY-380).
    ///
    /// **Its own read rather than folded into `refreshSubscription()` above**, and the same
    /// reasoning the screen-control allowance already follows in this file: they are two requests to
    /// two routes, one of them local and instant and the other on the network, and a slow one must
    /// not hold the other's row off screen. It also leaves `refreshSubscription()`'s
    /// never-waits-when-the-cache-answered guard exactly as it is, which is a property one test
    /// exists solely to hold.
    ///
    /// **Nothing is reported when it fails, deliberately.** A Mac that has never reached a gateway
    /// is the ordinary state of this product, not news — the same judgement `refreshSubscription()`
    /// makes, for the same reason: a warning here would sit under a sign-in the user has just
    /// completed and would be about a line they can already read.
    ///
    /// **It is not gated on a subscription existing, and that costs one cheap request.** The gate
    /// would have to run after `refreshSubscription()` had answered, which is the coupling the
    /// paragraph above avoids; and at `.task` time both reads start together, so a gate would skip
    /// for every account and never retry. The server side is one indexed `SELECT` with no provider
    /// call, and the allowance read beside it is already unconditional on every Account open.
    func refreshPaymentState() async {
        paymentState = try? await service.billingPaymentState()
    }

    /// Re-read the payment state when the window comes back after the portal was opened
    /// (SONNY-380, PR #206's F3; founders' decision of 2026-09-05, option A).
    ///
    /// **What this fixes is a control that looked like it did nothing.** With `Manage subscription`
    /// the staleness did not matter, because nothing on the line depended on what the user did in
    /// the portal. `Update payment` *is* the resolution of the state the line names, so a customer
    /// who fixed their card and came back to a still-open sheet read `Past due` and the same button
    /// until they closed and reopened Account.
    ///
    /// **It shows whatever the read says, and `Past due` is a correct answer here.** The gateway
    /// learns from a provider webhook, so a return that beats the delivery honestly still answers
    /// `past_due` — that is true at that moment and is not an error, which is the half of the
    /// founders' decision most likely to be mistaken for a bug later.
    ///
    /// **The flag is cleared before the read, not after.** Two activations in quick succession
    /// would otherwise both pass the guard and issue two requests; clearing first makes the second
    /// one a no-op. It is also cleared on the way out of a failed read, because the guard is about
    /// a press that happened rather than about a read that succeeded.
    func refreshPaymentStateAfterReturningFromPortal() async {
        guard didOpenBillingPortal else { return }
        didOpenBillingPortal = false
        await refreshPaymentState()
    }

    /// Open the provider's hosted portal for this account (SONNY-216).
    ///
    /// **The link is fetched per press and never cached**, because the gateway mints a session token
    /// scoped to one customer that expires within the hour — a held link is a dead page later, and a
    /// link held across a sign-out would be the previous user's invoices.
    ///
    /// **`openURL` is handed a URL the gateway chose, and that is the whole of the trust here.** It
    /// arrives over TLS from Sonny's own gateway on an authenticated call, so it is not screen
    /// content and not model output — the untrusted-content rules that govern those do not reach it.
    /// It is still checked before it is opened, because "the server would never" is the assumption
    /// every deserialization bug is made of, and a `file:` URL handed to `NSWorkspace.open` is a
    /// different kind of action entirely.
    ///
    /// **The check is `SafeURL.validateWebURL` plus an https narrowing, and it is both rather than
    /// either** (PR #183, F7). This was a hand-rolled scheme comparison, and it was the only one of
    /// this repository's four such sites not to use the shared helper — which additionally requires
    /// a host and blocks loopback, RFC1918, link-local and `.local`, the same class of argument the
    /// `file:` sentence above already makes. The helper alone is not enough because it permits
    /// `http`, and a billing portal reached over cleartext is not one this app should open; the
    /// narrowing alone is not enough because it was what let a mutant weakening the guard to
    /// `scheme != "file"` survive the whole suite.
    func openBillingPortal() async {
        isBusy = true
        portalFailure = nil
        // The sign-in surface's own outcome is cleared too: the two share a dialog, and leaving a
        // stale sign-in notice above a fresh portal failure reads as one message about both.
        failure = nil
        notice = nil
        defer { isBusy = false }
        do {
            let response = try await service.hostedBillingPortalURL()
            let validated = try SafeURL.validateWebURL(response.absoluteString)
            guard validated.scheme?.lowercased() == "https" else {
                throw SonnyBackendError.undecodableResponse("billing portal URL")
            }
            // **Set after the guards, not before the request** (SONNY-380). A press that ended in
            // a refusal, a bad URL or a scheme this app will not open did not send the customer
            // anywhere, so there is nothing for their return to be about.
            didOpenBillingPortal = true
            openPortalURL(validated)
        } catch let error as SonnyBackendError {
            portalFailure = BillingPortalFailure(error)
        } catch {
            // `SafeURL.validateWebURL` throws its own error type for a URL with no host, a private
            // host, or an unsupported scheme. All of them mean the same thing to the user and none
            // of them is fixed by pressing again.
            portalFailure = .cannotBeOpened
        }
    }

    /// Injected so a test can assert the URL that would have opened without a browser launching on
    /// the machine running the suite. `main.swift` leaves it at the default.
    var openPortalURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    func useAnotherAddress() {
        step = .address
        code = ""
        failure = nil
        notice = nil
        portalFailure = nil
    }

    /// **Signs out even when the revoke could not happen**, and says which of the two occurred.
    /// `SonnyAccountService.signOut` clears this Mac either way; this only reports it.
    func signOut() async {
        await run {
            let outcome = try await service.signOut()
            identity = nil
            code = ""
            step = .address
            // **Cleared here, synchronously, and not left to the next `refreshSubscription()`**
            // (PR #183, F13). When a second user signs in, `onChange(of: step)` fires and
            // `signedInStep` renders immediately with whatever this holds, while the refresh behind
            // it awaits an actor hop, a Keychain read and a signature verification — so the previous
            // user's `<Plan> · Active` line and a live Manage subscription button are on screen in
            // the meantime. `SubscriptionReading`'s session check is what stops that being
            // permanent; this is what stops it happening at all.
            subscription = nil
            // **Cleared for exactly the reason above** (SONNY-380). A second user signing in would
            // otherwise meet the previous user's `Past due` and an Update payment button pointing at
            // a portal that is not theirs, for as long as the read behind it took to answer.
            paymentState = nil
            // A pending re-read belongs to the person who pressed the control, not to whoever signs
            // in next — the same reason the two values above are cleared here (SONNY-380).
            didOpenBillingPortal = false
            portalFailure = nil
            if case .clearedLocallyOnly = outcome {
                notice = SignInCopy.signedOutLocallyOnly
            }
        }
        // **Fires on both sign-out outcomes, including the one that failed to revoke**, because
        // `SonnyAccountService.signOut` clears this Mac either way — so the session is gone locally
        // whatever the server managed, and a row still reading "Signed in." would be wrong in
        // exactly the case the user is most likely to check.
        if identity == nil { sessionDidChange?() }
    }

    /// One place that clears the previous outcome, flips the busy flag, and turns anything thrown
    /// into a named failure. Every entry point above goes through it, so no path can forget to
    /// unset `isBusy` or leave a stale message under a new result.
    private func run(_ work: () async throws -> Void) async {
        isBusy = true
        failure = nil
        notice = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch let error as SonnyBackendError {
            failure = SignInFailure(error)
        } catch {
            // A Keychain write that failed is the one non-backend error reachable here, and it is
            // the case where reporting success would be worst: the user would grant Screen
            // Recording, watch the app relaunch, and come back signed out.
            failure = .unexpected
        }
    }
}

/// The sign-in surface. **Functional, not designed** — SONNY-109's whole-product UI/UX pass owns
/// how this looks; this ticket owns that it works. System A throughout (Inter, flat opaque fills,
/// zero shadows, accent #5C84FE), on the same close-X chrome as `SettingsDialogView`.
///
/// **Google and Apple buttons are next branch's and this must not have to be rebuilt for them**
/// (founder, 2026-08-17 — Google lands early, Apple near launch, so the requirement has to hold
/// twice, months apart). They slot in above `emailForm` inside `addressStep`: the step is already
/// a vertical stack of independent blocks, and neither the model's state machine nor the code step
/// changes, because both providers return the same §3.2 token response this already adopts.
/// The write half of the auto-top-up control (SONNY-215).
///
/// **Three fields and not four: there is no `isOn` here.** Whether the setting is on is a property of
/// the allowance the row above renders, so reading it from the same object is what keeps the switch
/// and the number it is about from being one request apart. What this carries is only what the
/// allowance cannot say — whether a write is in flight, why the last one failed, and how to make the
/// next one.
struct ScreenControlAutoTopUpControl {
    let isBusy: Bool
    let failure: BillingSettingFailure?
    let set: (Bool) async -> Void
}

struct SignInDialogView: View {
    @ObservedObject var model: SonnyAccountModel
    @Binding var isPresented: Bool

    /// The screen-control allowance to show beside the plan, or `nil` for none (SONNY-214, moved
    /// here from Insights by the founder decision of 2026-09-02).
    ///
    /// **Passed in rather than read from a second copy of the state.** It lives on the one
    /// `AgentViewModel` both surfaces observe — the widget's in-task line reads the same property —
    /// which is `.claude/rules/macagent-ui-conventions.md`'s shared-state rule: new published state
    /// goes on that instance and never gets a second, independently-coded path per surface.
    ///
    /// **Both parameters are required and first run passes `nil` in words.** A default would let a
    /// third host of this dialog silently show no figure, and where the line does *not* belong is a
    /// decision worth being able to read at the call site.
    let screenControlAllowance: ScreenControlAllowance?
    let refreshScreenControlAllowance: (() async -> Void)?
    /// The auto-top-up control's write half, or `nil` where the control does not belong (SONNY-215).
    ///
    /// **Its *read* half is deliberately absent from this type**: whether the setting is on comes off
    /// `screenControlAllowance.autoTopUp`, which is the same object the row above renders, so the
    /// switch and the number beside it can never be one request apart. A `Bool` here would be a
    /// second copy of a fact the view already holds.
    let screenControlAutoTopUp: ScreenControlAutoTopUpControl?

    var body: some View {
        VStack(spacing: 0) {
            SonnyDialogHeader(
                title: model.isSignedIn ? "Account" : SignInCopy.signInLabel,
                closeLabel: "Close sign-in"
            ) {
                isPresented = false
            }

            SettingsDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch model.step {
                    case .address:
                        addressStep
                    case .code:
                        codeStep
                    case .signedIn:
                        signedInStep
                    }

                    messages
                }
                .padding(.horizontal, SonnySpacing.xxxl)
                .padding(.top, SonnySpacing.sm)
                .padding(.bottom, SonnySpacing.xxxl)
            }

            #if DEBUG
            debugHostLine
            #endif
        }
        .sonnyDialogFrame(.regular)
        // **Read on appear and again when a sign-in completes**, and both are needed. The dialog is
        // a sheet, so a user who signs in inside it never re-appears it — without the second the row
        // would stay absent until the next time they opened Account, which is the same staleness
        // `sessionDidChange` exists for on the readiness row (SONNY-136, PR #153's F4).
        .task { await model.refreshSubscription() }
        .onChange(of: model.step) { _, step in
            guard step == .signedIn else { return }
            Task { await model.refreshSubscription() }
        }
        // The payment state is read on the same two occasions and for the same reason (SONNY-380),
        // and separately for the reason the allowance below is: two of these three go to the
        // network on every open — this one and the allowance — and neither may hold the other's row
        // off screen. `refreshSubscription()` is the odd one out, because it usually answers from
        // the cached claim without a request at all.
        //
        // (This read "it is the one of these three that goes to the network on every open", which
        // was true only of `FirstRunSequence`, the one host that passes
        // `refreshScreenControlAllowance: nil` — and that is not where the Account row is read.
        // PR #206's F4.)
        .task { await model.refreshPaymentState() }
        .onChange(of: model.step) { _, step in
            guard step == .signedIn else { return }
            Task { await model.refreshPaymentState() }
        }
        // **And once more when the window comes back, if the portal was opened from here**
        // (SONNY-380, PR #206's F3; founders' option A of 2026-09-05). `NSApplication`'s
        // notification rather than `ScenePhase`, because the portal opens in a browser: this app
        // resigns active and the sheet never disappears, so no SwiftUI lifecycle event fires.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshPaymentStateAfterReturningFromPortal() }
        }
        // The allowance is read on the same two occasions and for the same reason (SONNY-214). Its
        // own read rather than folded into the subscription's, so neither waits on the other: they
        // are two requests to two routes, and a slow one must not hold the other's row off screen.
        .task { await refreshScreenControlAllowance?() }
        .onChange(of: model.step) { _, step in
            guard step == .signedIn else { return }
            Task { await refreshScreenControlAllowance?() }
        }
    }

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.sm) {
            Text(SignInCopy.emailFieldLabel)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)

            SettingsAdaptiveControlRow {
                signInTextField(
                    prompt: SignInCopy.emailFieldPrompt,
                    text: $model.emailAddress,
                    accessibilityLabel: SignInCopy.emailFieldLabel
                ) {
                    Task { await model.sendCode() }
                }
            } trailing: {
                Button {
                    Task { await model.sendCode() }
                } label: {
                    if model.isBusy {
                        ProgressView().controlSize(.small).tint(SonnyTheme.textOnAccent)
                    } else {
                        Text(SignInCopy.sendCodeLabel)
                    }
                }
                .buttonStyle(SonnyButtonStyle(tone: .primary, width: 110))
                .disabled(!model.canSendCode)
                .accessibilityLabel(SignInCopy.sendCodeLabel)
            }
        }
        .padding(.top, SonnySpacing.xl)
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.sm) {
            Text(SignInCopy.codeFieldLabel)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)

            SettingsAdaptiveControlRow {
                signInTextField(
                    prompt: SignInCopy.codeFieldPrompt,
                    text: $model.code,
                    accessibilityLabel: SignInCopy.codeFieldLabel
                ) {
                    Task { await model.verify() }
                }
            } trailing: {
                Button {
                    Task { await model.verify() }
                } label: {
                    if model.isBusy {
                        ProgressView().controlSize(.small).tint(SonnyTheme.textOnAccent)
                    } else {
                        Text(SignInCopy.verifyLabel)
                    }
                }
                .buttonStyle(SonnyButtonStyle(tone: .primary, width: 110))
                .disabled(!model.canVerify)
                .accessibilityLabel(SignInCopy.verifyLabel)
            }

            // The fifth of the ticket's five cases, and the only one nothing will ever report: no
            // code arrived, so no request failed. It sits here from the moment this step appears,
            // beside the two controls that act on it.
            Text(SignInCopy.codeNotArriving)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: SonnySpacing.sm) {
                Button(SignInCopy.resendCodeLabel) {
                    Task { await model.sendCode() }
                }
                .buttonStyle(SonnyButtonStyle(tone: .secondary))
                .disabled(model.isBusy)
                .accessibilityLabel(SignInCopy.resendCodeLabel)

                Button(SignInCopy.useAnotherAddressLabel) {
                    model.useAnotherAddress()
                }
                .buttonStyle(SonnyButtonStyle(tone: .secondary))
                .disabled(model.isBusy)
                .accessibilityLabel(SignInCopy.useAnotherAddressLabel)
            }
        }
        .padding(.top, SonnySpacing.xl)
    }

    private var signedInStep: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.md) {
            SettingsAdaptiveControlRow {
                VStack(alignment: .leading, spacing: SonnySpacing.xs) {
                    Text(model.signedInAddress ?? "Signed in")
                        .font(SonnyType.bodyEmphasis)
                        .foregroundStyle(SonnyTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                Button {
                    Task { await model.signOut() }
                } label: {
                    if model.isBusy {
                        ProgressView().controlSize(.small).tint(SonnyTheme.text)
                    } else {
                        Text(SignInCopy.signOutLabel)
                    }
                }
                // Secondary, not danger: signing out is reversible, and this branch keeps the red
                // tone for what deletes.
                .buttonStyle(SonnyButtonStyle(tone: .secondary, width: 110))
                .disabled(model.isBusy)
                .accessibilityLabel(SignInCopy.signOutLabel)
            }

            subscriptionRow
            screenControlUsageRow
            screenControlAutoTopUpRow
            screenControlLastTopUpRow
        }
        .padding(.top, SonnySpacing.md)
    }

    /// Whether Sonny may buy more runs when these run out (SONNY-215).
    ///
    /// **Directly under the usage row, and that placement is what the label leans on.** The control's
    /// name says "when *these* run out", and "these" is the figure on the line above — the same
    /// device that lets "Delete what Sonny did on screen" name its object by sitting beside the
    /// section it deletes. Moved anywhere else the name stops being self-contained and would want the
    /// explanatory sentence the no-explanatory-copy rule forbids.
    ///
    /// **Absent, not disabled, when this deployment sells nothing** — the same founder direction of
    /// 2026-08-31 the subscription row follows: a control that only fails when pressed is a broken
    /// control, and a gateway with no top-up pack configured refuses every purchase. The absence also
    /// covers every state where there is no figure at all, because the row has nothing to attach
    /// "these" to.
    ///
    /// System A throughout, like everything else in this dialog: `SettingsAdaptiveControlRow`,
    /// `SonnyToggle`, flat opaque fills and no shadow. Nothing here is borrowed from the widget's
    /// material.
    @ViewBuilder
    private var screenControlAutoTopUpRow: some View {
        if let allowance = screenControlAllowance,
           let control = screenControlAutoTopUp,
           allowance.autoTopUp.isOffered {
            // **The price is on the control itself** (SONNY-215's F6, founder decision option B). A
            // switch that authorises a standing charge names the amount; nothing beside it explains
            // why, which is the line the no-explanatory-copy rule draws and the founder held.
            let label = ScreenControlUsagePresentation.autoTopUpLabel(price: allowance.autoTopUp.price)
            SettingsAdaptiveControlRow {
                Text(label)
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                // **The Settings dialog's own toggle, not a second one.** This ticket's contract is
                // the same one `SettingsAdaptiveControlRow` carries: a label-plus-control row uses
                // the shared component, and a shared component the rest of the target cannot name is
                // not a shared component.
                //
                // **The binding's setter is where the asymmetry lives.** Reading is synchronous and
                // comes off the allowance the row above renders; writing is a network call whose
                // answer replaces that allowance, so the set arm starts a task and the *server's*
                // reply is what moves the switch. A binding that wrote a local `@State` first would
                // show a user their card was about to be charged before anything had agreed to it.
                SonnySettingsToggle(
                    isOn: Binding(
                        get: { allowance.autoTopUp.isOptedIn },
                        set: { next in Task { await control.set(next) } }
                    )
                )
                .disabled(control.isBusy)
                .accessibilityLabel(label)
            }

            // **Rendered here rather than in `messages`**, for the reason the portal's failure line
            // is: this sentence is about the control directly above it, and a setting failure
            // appearing under the sign-in form would read as a statement about signing in.
            if let failure = control.failure {
                Text(BillingSettingCopy.message(for: failure))
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// What this account was last charged for a top-up (SONNY-215's F6, founder decision option B).
    ///
    /// **A record, not a setting**, which is why it is its own row below the switch rather than a
    /// second line inside it: it stays true after the switch is turned off, and it is about money
    /// rather than about runs.
    ///
    /// **Rendered whenever there is a charge to show, including when the setting is off and even
    /// when this deployment stopped offering top-ups.** A user who was charged is owed the record
    /// whatever the switch says now — hiding it behind `isOffered`, as the switch above is, would
    /// make a receipt disappear because a configuration changed.
    @ViewBuilder
    private var screenControlLastTopUpRow: some View {
        if let charge = screenControlAllowance?.lastTopUp,
           let line = ScreenControlUsagePresentation.lastTopUpLine(charge) {
            SettingsAdaptiveControlRow {
                Text(ScreenControlUsagePresentation.lastTopUpLabel)
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                Text(line)
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(ScreenControlUsagePresentation.lastTopUpLabel), \(line)")
            }
        }
    }

    /// How many screen-control runs the plan has left, beside the plan itself (SONNY-214).
    ///
    /// **Here, and deliberately not on Insights.** It was built there first, against a founder
    /// decision of 2026-07-24 that nobody in the chain had read: that page refuses
    /// usage/quota-consumption metrics outright, on stated product-strategy grounds — cancellation
    /// anxiety in heavy users, "am I getting my money's worth" doubt in light ones. The ruling of
    /// 2026-09-02 moved the line here instead of overriding that decision, so both stand: Insights
    /// stays encouraging, and the figure appears where somebody is already thinking about their
    /// plan. The widget's in-task line is a different surface and did not move.
    ///
    /// **Absent, not zeroed, when there is no figure** — the same rule the subscription row above
    /// follows and the same one `ScreenControlAllowanceService` states: a failed read is a failure
    /// and never a number, because zero locks a user out of what they paid for and any positive
    /// number promises runs the server never granted.
    @ViewBuilder
    private var screenControlUsageRow: some View {
        if let screenControlAllowance {
            // Formatted once and read twice — the visible line and the screen reader's must be the
            // same sentence, and two calls are two places for them to stop being.
            let line = ScreenControlUsagePresentation.usageLine(screenControlAllowance)
            SettingsAdaptiveControlRow {
                Text(ScreenControlUsagePresentation.label)
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                Text(line)
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(ScreenControlUsagePresentation.label), \(line)")
            }
        }
    }

    /// The subscription state and the way to the provider's hosted portal (SONNY-216).
    ///
    /// **The whole row is absent, not disabled, when this Mac cannot prove a subscription exists.**
    /// A user who signed in and never subscribed has no plan record — the gateway sends
    /// `plan: "none"` for exactly that — and the portal has no customer to open for them. The
    /// gateway does refuse that with `409 entitlement.no_subscription`, but a control that only
    /// fails when pressed is a broken control, so this does not offer one (founder direction,
    /// 2026-08-31). The same absence covers a claim that is stale, unreadable or somebody else's:
    /// in every one of those the honest answer is that this Mac currently knows nothing, and a line
    /// is worse than no line.
    ///
    /// **The state a signed claim cannot establish arrives separately, and it wins the word**
    /// (SONNY-380). A customer whose payment has failed keeps every capability through the grace
    /// window by §16.4's design, so their claim is byte-identical to a healthy one's and this row
    /// said `Active` for the length of it. `model.paymentState` is the unsigned read that separates
    /// them, and the control is named for what it resolves rather than always for the portal it
    /// opens — one button, two labels, the same destination. Nothing here explains a grace window,
    /// which is the standing rule and is why the line gained two words rather than a sentence.
    @ViewBuilder
    private var subscriptionRow: some View {
        if let subscription = model.subscription {
            // **One value read once, so the line and the control cannot disagree** (SONNY-380). Both
            // derive from the payment state, and reading `model.paymentState` twice would let a
            // refresh landing between them put `Past due` beside `Manage subscription`.
            let payment = model.paymentState
            let line = SubscriptionCopy.line(for: subscription, payment: payment)
            let control = SubscriptionCopy.controlLabel(for: payment)
            SettingsAdaptiveControlRow {
                HStack(spacing: SonnySpacing.sm) {
                    SonnyBadge(text: subscription.plan.capitalized, tone: .accent)
                    Text(line)
                        .font(SonnyType.body)
                        .foregroundStyle(SonnyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(line)
            } trailing: {
                Button(control) {
                    Task { await model.openBillingPortal() }
                }
                .buttonStyle(SonnyButtonStyle(tone: .secondary, width: 160))
                .disabled(model.isBusy)
                .accessibilityLabel(control)
            }

            // **Rendered here rather than in `messages`**, which is the sign-in surface's channel:
            // this sentence is about the control directly above it, and a portal failure appearing
            // under the sign-in form would read as a statement about signing in (PR #183, F4).
            if let portalFailure = model.portalFailure {
                Text(BillingPortalCopy.message(for: portalFailure))
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let failure = model.failure {
            Text(SignInCopy.message(for: failure))
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, SonnySpacing.md)
        } else if let notice = model.notice {
            Text(notice)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, SonnySpacing.md)
        }
    }

    #if DEBUG
    /// Which host this debug build is pointed at, so the founder's manual pass can see that the
    /// `defaults write` took. Never compiled into a release build, which has no pointer to report.
    @ViewBuilder
    private var debugHostLine: some View {
        if let host = SonnyBackendHost.resolve()?.baseURL.absoluteString {
            Text(host)
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SonnySpacing.xxxl)
                .padding(.bottom, SonnySpacing.md)
        }
    }
    #endif

    private func signInTextField(
        prompt: String,
        text: Binding<String>,
        accessibilityLabel: String,
        onSubmit: @escaping () -> Void
    ) -> some View {
        TextField(prompt, text: text)
            .sonnyTextField()
            .onSubmit(onSubmit)
            .disabled(model.isBusy)
            .accessibilityLabel(accessibilityLabel)
    }
}
