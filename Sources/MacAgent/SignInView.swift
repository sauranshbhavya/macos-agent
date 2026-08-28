import MacAgentCore
import SwiftUI

/// Sign-in state for the whole app, held once and observed by Command Center.
///
/// **Its own object rather than another field on `AgentViewModel`.** The view model owns the run
/// loop and thirteen local stores; an account session shares none of that, and adding it there
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

    private let service: SonnyAccountService

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
    init(client: SonnyBackendClient) {
        self.backendClient = client
        self.service = SonnyAccountService(client: client)
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
        SonnyAccountModel(client: SonnyBackendClient(
            environment: SonnyBackendHost.resolve(),
            tokenStore: KeychainAccountTokenStore(),
            // Named rather than defaulted: the client's `= .shared` default is a session backed by
            // a 20 MB disk cache that nobody chose, which SONNY-130 and SONNY-134's authenticated
            // `GET`s would fill with the user's own data (PR #133, F11).
            session: SonnyBackendSession.forBackendCalls()
        ))
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
    }

    func useAnotherAddress() {
        step = .address
        code = ""
        failure = nil
        notice = nil
    }

    /// **Signs out even when the revoke could not happen**, and says which of the two occurred.
    /// `SonnyAccountService.signOut` clears this Mac either way; this only reports it.
    func signOut() async {
        await run {
            let outcome = try await service.signOut()
            identity = nil
            code = ""
            step = .address
            if case .clearedLocallyOnly = outcome {
                notice = SignInCopy.signedOutLocallyOnly
            }
        }
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
/// zero shadows, accent #5C84FE), on the same close-X chrome as `SettingsDialogView` and
/// `ProfileDialogView`.
///
/// **Google and Apple buttons are next branch's and this must not have to be rebuilt for them**
/// (founder, 2026-08-17 — Google lands early, Apple near launch, so the requirement has to hold
/// twice, months apart). They slot in above `emailForm` inside `addressStep`: the step is already
/// a vertical stack of independent blocks, and neither the model's state machine nor the code step
/// changes, because both providers return the same §3.2 token response this already adopts.
struct SignInDialogView: View {
    @ObservedObject var model: SonnyAccountModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(SonnyType.icon(11, weight: .semibold))
                        .foregroundStyle(SonnyTheme.muted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .sonnyPointerCursor()
                .sonnyHoverHighlight(cornerRadius: 12)
                .accessibilityLabel("Close sign-in")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.isSignedIn ? "Account" : SignInCopy.signInLabel)
                        .font(SonnyType.settingsContentTitle)
                        .foregroundStyle(SonnyTheme.text)
                        .padding(.bottom, 16)

                    SettingsDivider()

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
                .padding(.horizontal, 40)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }

            #if DEBUG
            debugHostLine
            #endif
        }
        .frame(width: 520, height: 400)
        .background(SonnyTheme.ink)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.container)
                .stroke(SonnyTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
    }

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SignInCopy.emailFieldLabel)
                .font(SonnyType.eyebrow)
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
                Button(SignInCopy.sendCodeLabel) {
                    Task { await model.sendCode() }
                }
                .buttonStyle(SonnyButtonStyle(tone: .primary, width: 110))
                .disabled(!model.canSendCode)
                .accessibilityLabel(SignInCopy.sendCodeLabel)
            }
        }
        .padding(.top, 20)
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SignInCopy.codeFieldLabel)
                .font(SonnyType.eyebrow)
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
                Button(SignInCopy.verifyLabel) {
                    Task { await model.verify() }
                }
                .buttonStyle(SonnyButtonStyle(tone: .primary, width: 110))
                .disabled(!model.canVerify)
                .accessibilityLabel(SignInCopy.verifyLabel)
            }

            // The fifth of the ticket's five cases, and the only one nothing will ever report: no
            // code arrived, so no request failed. It sits here from the moment this step appears,
            // beside the two controls that act on it.
            Text(SignInCopy.codeNotArriving)
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
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
        .padding(.top, 20)
    }

    private var signedInStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsAdaptiveControlRow {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.signedInAddress ?? "Signed in")
                        .font(SonnyType.bodyEmphasis)
                        .foregroundStyle(SonnyTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                Button(SignInCopy.signOutLabel) {
                    Task { await model.signOut() }
                }
                .buttonStyle(SonnyButtonStyle(tone: .secondary, width: 110))
                .disabled(model.isBusy)
                .accessibilityLabel(SignInCopy.signOutLabel)
            }
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var messages: some View {
        if let failure = model.failure {
            Text(SignInCopy.message(for: failure))
                .font(SonnyType.body)
                .foregroundStyle(SonnyTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
        } else if let notice = model.notice {
            Text(notice)
                .font(SonnyType.body)
                .foregroundStyle(SonnyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
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
                .padding(.horizontal, 40)
                .padding(.bottom, 12)
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
            .textFieldStyle(.plain)
            .font(SonnyType.caption)
            .foregroundStyle(SonnyTheme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(SonnyTheme.input)
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .stroke(SonnyTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
            .onSubmit(onSubmit)
            .disabled(model.isBusy)
            .accessibilityLabel(accessibilityLabel)
    }
}
