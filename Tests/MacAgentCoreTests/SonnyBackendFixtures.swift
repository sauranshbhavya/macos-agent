import Foundation
import MacAgentTestSupport
@testable import MacAgentCore

/// Shared shapes for the sign-in and backend-client suites: the contract's §3.2 token response, its
/// §7.1 error envelope, and a client wired to a stub host.
///
/// One copy rather than one per suite, because three suites assert against the same two wire shapes
/// and a second hand-written copy of an envelope is how one of them ends up testing a shape the
/// server does not send.
enum SonnyBackendFixtures {
    static let userID = "acct_7f3c"
    static let email = "founder@example.com"

    static func tokenResponseJSON(
        accessToken: String = "access-1",
        refreshToken: String = "refresh-1",
        expiresIn: Int = 3600,
        refreshExpiresAt: String? = "2026-11-15T09:41:07Z",
        userID: String = SonnyBackendFixtures.userID,
        linkHint: String? = nil
    ) -> Data {
        var object: [String: Any] = [
            "access_token": accessToken,
            "token_type": "Bearer",
            "expires_in": expiresIn,
            "expires_at": "2026-08-26T10:41:07Z",
            "refresh_token": refreshToken,
            "user": ["id": userID]
        ]
        if let refreshExpiresAt { object["refresh_expires_at"] = refreshExpiresAt }
        if let linkHint { object["link_hint"] = linkHint }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func errorEnvelopeJSON(
        code: String,
        message: String = "Server-authored sentence the client must never display.",
        retryable: Bool = false,
        retryAfterSeconds: Double? = nil,
        requestID: String = "req_abc"
    ) -> Data {
        var error: [String: Any] = [
            "code": code,
            "message": message,
            "retryable": retryable,
            "request_id": requestID
        ]
        error["retry_after_seconds"] = retryAfterSeconds ?? NSNull()
        return try! JSONSerialization.data(withJSONObject: ["error": error])
    }

    static func storedTokens(
        accessToken: String = "access-0",
        refreshToken: String = "refresh-0",
        expiresAt: Date,
        userID: String = SonnyBackendFixtures.userID,
        emailAddress: String? = SonnyBackendFixtures.email
    ) -> SonnyAccountTokens {
        SonnyAccountTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: expiresAt,
            refreshTokenExpiresAt: nil,
            userID: userID,
            emailAddress: emailAddress
        )
    }
}

/// Every retry delay the client asked for, in order, and never an actual wait.
///
/// A suite that really slept would be betting on the wall clock, which `CLAUDE.md` records as the
/// shape that manufactures mutation kills. The durations are the thing worth asserting anyway:
/// whether a `Retry-After` the server sent replaced the computed backoff is a decision, and a
/// stopwatch is a poor way to read one.
final class RecordedSleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []

    var recorded: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ seconds: TimeInterval) {
        lock.lock()
        values.append(seconds)
        lock.unlock()
    }
}

/// Every request the stub saw, in arrival order.
final class RecordedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []

    var recorded: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ request: URLRequest) {
        lock.lock()
        values.append(request)
        lock.unlock()
    }

    func count(path: String) -> Int {
        recorded.filter { $0.url?.path == path }.count
    }
}
