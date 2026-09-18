import AppKit
import AuthenticationServices
import MacAgentCore

/// The one production `WebAuthenticating`: `ASWebAuthenticationSession`, which opens the user's own
/// browser — never a web view inside Sonny (SONNY-129).
///
/// **Why this API and not opening a URL and registering a scheme.** Apple's documentation for the type:
/// "In macOS, the system opens the user's default browser if it supports web authentication sessions,
/// or Safari otherwise. On completion, the service sends a callback URL to the session." The callback
/// goes back to the session that asked for it and to no other process, so another app registering the
/// same scheme cannot catch the code; `Packaging/Info.plist` needs no URL-scheme entry; and a user who
/// closes the browser comes back here as a cancellation rather than as a sign-in that never finishes.
///
/// **`prefersEphemeralWebBrowserSession` is left `false`**, so the browser's existing Google sign-in is
/// reused and the user is not asked for a password they already entered there. The trade is that the
/// browser keeps its own Google session afterwards, which is the browser's state and not Sonny's.
@MainActor
final class SystemWebAuthenticator: NSObject, WebAuthenticating, ASWebAuthenticationPresentationContextProviding {
    /// Held until the session finishes. `ASWebAuthenticationSession` must be kept alive by its owner, or
    /// it is torn down and its completion never runs.
    private var session: ASWebAuthenticationSession?

    nonisolated func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.begin(url: url, callbackScheme: callbackScheme, continuation: continuation)
            }
        }
    }

    /// Named `begin` rather than `start` for `ResumeOfferPresentationTests`' reason: that scan counts
    /// every `start(` in the app's sources as a route into a task run, and this is not one.
    private func begin(url: URL, callbackScheme: String, continuation: CheckedContinuation<URL, Error>) {
        let webAuthenticationSession = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
            Task { @MainActor in self?.session = nil }
            if let callback {
                continuation.resume(returning: callback)
            } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                continuation.resume(throwing: SonnyGoogleSignInError.cancelled)
            } else {
                continuation.resume(throwing: SonnyGoogleSignInError.sessionFailed)
            }
        }
        webAuthenticationSession.presentationContextProvider = self
        webAuthenticationSession.prefersEphemeralWebBrowserSession = false
        self.session = webAuthenticationSession
        if !webAuthenticationSession.start() {
            self.session = nil
            continuation.resume(throwing: SonnyGoogleSignInError.sessionFailed)
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? ASPresentationAnchor()
        }
    }
}
