import CryptoKit
import Foundation
import Security

/// Sign in with Google, as far as this Mac takes part in it (SONNY-129, contract §3.6).
///
/// **The shape, in one paragraph.** The Mac makes a random PKCE verifier and keeps it; it sends the
/// gateway only the verifier's S256 challenge and gets back the address to open; the user signs in to
/// Google in their own browser; the browser comes back to `callbackURL` carrying a one-time code; and
/// the Mac trades that code *and the verifier* at the gateway for the §3.2 token response. The Mac
/// holds no secret at any point — a downloaded app cannot keep one — and a code intercepted on its way
/// back is useless without a verifier that never left this process until the last step.
///
/// **The browser is the user's own, never a web view inside Sonny.** `WebAuthenticating`'s real
/// implementation is `ASWebAuthenticationSession`, which on macOS "opens the user's default browser if
/// it supports web authentication sessions, or Safari otherwise" (Apple's documentation for that type)
/// and hands the callback back to the app that started it and to no other. So no other app can
/// register the same scheme and catch the code, and `Packaging/Info.plist` registers no URL scheme.
public enum SonnyGoogleSignIn {
    /// Where Google, by way of the gateway's auth provider, sends the browser back.
    ///
    /// **One string on both halves of the repository.** The gateway fixes it
    /// (`server/src/auth/oauth.ts`, `OAUTH_REDIRECT_URL`) and never takes it from a request; this is
    /// what the Mac waits on. `SonnyGoogleSignInTests` reads the server file and holds the two to
    /// one value, because a mismatch fails as a browser that never comes back, with nothing to say
    /// why.
    public static let callbackURL = "com.sonny.macagent://auth/callback"
    /// The scheme alone, which is all `ASWebAuthenticationSession` is handed. Lowercase, because
    /// schemes compare case-insensitively and the bundle identifier is not.
    public static let callbackScheme = "com.sonny.macagent"

    /// The one-time code the browser brought back, or why there is none.
    ///
    /// **The callback is checked against `callbackURL` in full, not only its scheme.** The session
    /// delivers anything under the scheme; a different host or path is not the flow this app started
    /// and its code is not spent. An `error` from the provider — the user declined, or the provider
    /// refused — is reported as `.declined`, whether it arrived in the query or, as some providers
    /// send it, in the fragment.
    public static func authorizationCode(from callback: URL) throws -> String {
        guard
            let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == callbackScheme,
            components.host?.lowercased() == "auth",
            components.path == "/callback"
        else {
            throw SonnyGoogleSignInError.malformedCallback
        }
        let query = components.queryItems ?? []
        let fragment = URLComponents(string: "?\(components.fragment ?? "")")?.queryItems ?? []
        if (query + fragment).contains(where: { $0.name == "error" }) {
            throw SonnyGoogleSignInError.declined
        }
        guard let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw SonnyGoogleSignInError.malformedCallback
        }
        return code
    }

    /// Whether the gateway's authorize address is one this Mac will hand a browser.
    ///
    /// `https`, or `http` to this machine for a developer's local auth provider — never a file, a
    /// custom scheme or anything else a browser could be made to open. The address comes from the
    /// gateway, which is trusted; this bounds what a misconfigured one can do rather than defending
    /// against a hostile one.
    public static func isOpenable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return url.host?.isEmpty == false
        case "http":
            return ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        default:
            return false
        }
    }
}

/// Why a Google sign-in ended without a session, in the terms the sign-in surface acts on.
public enum SonnyGoogleSignInError: Error, Equatable, Sendable {
    /// The user closed the browser sheet. Not a failure: nothing is shown.
    case cancelled
    /// The provider said no — the user declined, or the provider refused the request.
    case declined
    /// The browser came back somewhere this flow did not send it, or with no code.
    case malformedCallback
    /// The gateway handed back an address this Mac will not open.
    case unopenableAuthorizeURL
    /// The system could not run the browser session at all.
    case sessionFailed
}

/// A PKCE verifier and its S256 challenge (RFC 7636).
///
/// **The verifier never leaves this process until the exchange.** Only `challenge` is sent to start
/// the flow; `verifier` is sent once, with the code, and a stolen code cannot be spent without it.
public struct SonnyPKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    /// 32 random bytes, base64url without padding: 43 characters, inside RFC 7636 §4.1's 43 to 128.
    ///
    /// **`SecRandomCopyBytes`, and a failure is a throw rather than a weaker source.** A verifier from
    /// a predictable generator is a code anyone can spend; there is no acceptable fallback.
    public static func generate() throws -> SonnyPKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw SonnyGoogleSignInError.sessionFailed }
        return SonnyPKCE(verifier: base64URL(Data(bytes)))
    }

    /// The pair for a given verifier. Public so a test can pin RFC 7636's own example.
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The browser half of the flow, behind a seam so the sign-in logic can be tested without one.
///
/// **Never an embedded web view.** The one production conformance is `SystemWebAuthenticator` in the
/// app target, over `ASWebAuthenticationSession`; a conformance that rendered the provider's page
/// inside Sonny would break Google's own rule for native apps and the ticket's.
public protocol WebAuthenticating: Sendable {
    /// Open `url` in the user's browser and return the callback URL it comes back to. Throws
    /// `SonnyGoogleSignInError.cancelled` when the user closes it.
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}
