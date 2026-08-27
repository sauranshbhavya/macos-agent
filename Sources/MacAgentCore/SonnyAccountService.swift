import Foundation

/// What `POST /v1/auth/email/start` came back with (§3.6).
///
/// **The response is identical whether or not the address has an account**, and that is the point:
/// an endpoint that answered differently would be an account-existence oracle. So there is nothing
/// here to branch on and nothing to tell the user beyond "sent".
public struct SignInCodeRequest: Equatable, Sendable {
    public let requestID: String
    public let expiresIn: TimeInterval
}

public enum SignOutOutcome: Equatable, Sendable {
    /// Nothing is owed: the family was revoked server-side (or there was none to revoke), and the
    /// Keychain entry is gone.
    case revoked
    /// The Keychain entry is gone; the server was not reached. Recorded rather than swallowed.
    case clearedLocallyOnly(SignInFailure)
}

/// The three auth calls the Mac app makes, on top of the one shared client.
///
/// Refresh is deliberately not here: it belongs to `SonnyBackendClient`, which is the only thing
/// that sees a 401 and the only thing that can hold the single-flight guard across every concurrent
/// caller. Splitting it out would put two places in the app that can rotate a refresh token.
public struct SonnyAccountService: Sendable {
    private let client: SonnyBackendClient

    public init(client: SonnyBackendClient) {
        self.client = client
    }

    public func restoredIdentity() async throws -> SonnyAccountIdentity? {
        try await client.restoredIdentity()
    }

    public func isConfigured() async -> Bool {
        await client.isConfigured
    }

    /// Ask for a sign-in code.
    ///
    /// Retry-safe with the operation's own key (§9.3): "without the key, a retry sends a second code
    /// and races the first". A *new* press of "Send a new code" is a new operation and mints a new
    /// key, because it is meant to send another code.
    public func startEmailSignIn(email: String) async throws -> SignInCodeRequest {
        let body = try JSONSerialization.data(withJSONObject: ["email": email])
        let response = try await client.send(SonnyBackendRequest(
            method: "POST",
            path: "/v1/auth/email/start",
            body: body,
            authentication: .none,
            idempotencyKey: UUID(),
            timeout: SonnyBackendTimeouts.auth,
            isRetrySafe: true
        ))
        guard let decoded = try? JSONDecoder().decode(WireCodeRequest.self, from: response.data) else {
            throw SonnyBackendError.undecodableResponse("email/start response")
        }
        return SignInCodeRequest(requestID: decoded.request_id, expiresIn: decoded.expires_in)
    }

    /// Exchange a code for a session, and **write it to the Keychain before returning**.
    ///
    /// That ordering is this ticket's headline requirement, and it is a property of this one line:
    /// `client.adopt` saves to the Keychain first and updates its own cache second, and nothing
    /// downstream of this call — no UI callback, no first-run step, and above all not
    /// `ScreenAccessOnboardingModel.relaunchNow()` — can run before it has. A Keychain write that
    /// fails throws out of here, so the user is never told they are signed in when no disk agrees.
    ///
    /// **Not retry-safe** (§9.3): a code is single-use, so a second attempt spends something the
    /// user cannot get back and the idempotency record would return the original failure anyway.
    public func verifyEmailCode(email: String, code: String) async throws -> SonnyAccountIdentity {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "code": code])
        let response = try await client.send(SonnyBackendRequest(
            method: "POST",
            path: "/v1/auth/email/verify",
            body: body,
            authentication: .none,
            idempotencyKey: UUID(),
            timeout: SonnyBackendTimeouts.auth,
            isRetrySafe: false
        ))
        let decoded = try SonnyTokenResponse.decode(response.data)
        let tokens = decoded.tokens(emailAddress: email, receivedAt: await client.serverNow())
        try await client.adopt(tokens)
        return tokens.identity
    }

    /// Revoke the family server-side, then clear this Mac. **The local clear happens either way.**
    ///
    /// Order matters and cannot be the other one: clearing first destroys the very token the revoke
    /// has to present. Clearing unconditionally afterwards is the deliberate half — a user who
    /// pressed Sign out and is left holding a refresh token because a network call failed has been
    /// told something untrue about their own machine.
    ///
    /// **Sign-out is not "delete my local data" and not "reset the encryption identity."** Contract
    /// §3.3 names all three and says conflating any two is a real bug; branch 7 deliberately made
    /// local data deletion leave the Keychain encryption key alone. This touches one Keychain
    /// account under `com.sonny.account` and no file under `~/Library/Application Support/Sonny/`.
    @discardableResult
    public func signOut() async throws -> SignOutOutcome {
        var outcome = SignOutOutcome.revoked
        do {
            _ = try await client.send(SonnyBackendRequest(
                method: "POST",
                path: "/v1/auth/signout",
                body: nil,
                authentication: .bearer,
                idempotencyKey: UUID(),
                timeout: SonnyBackendTimeouts.auth,
                // §9.3: revoking an already-revoked family succeeds.
                isRetrySafe: true
            ))
        } catch let error as SonnyBackendError {
            switch error {
            case .notSignedIn:
                // Nothing was held, so nothing needed revoking. Still fall through to the clear,
                // which is a no-op on an empty Keychain account and cannot be wrong.
                break
            case .api(let api) where api.code == .authTokenRevoked || api.code == .authUnauthenticated:
                // The family was already gone. That is the state the user asked for.
                break
            default:
                outcome = .clearedLocallyOnly(SignInFailure(error))
            }
        }
        try await client.discardSessionLocally()
        return outcome
    }
}

private struct WireCodeRequest: Decodable {
    let request_id: String
    let expires_in: TimeInterval
}
