import Foundation

/// The words a too-old build is told, owned here rather than anywhere the wire can reach.
///
/// **The same rule and the same reason as `SignInCopy`, `SonnyBackendCopy` and `EntitlementCopy`**:
/// §7.1 forbids displaying the server's `message`. The gateway's own refusal reads "This client is
/// older than the minimum supported version 2.0.0." — a true sentence, and not one this product
/// would ever show.
///
/// **One owner for the wall's sentence, shared by `SignInCopy` and `SonnyBackendCopy`.** A too-old
/// build is refused on every route including the three unauthenticated sign-in ones
/// (`version/gate.ts` runs before the auth gate), so the same user meets this state on the sign-in
/// sheet and on the transcription route. Two literals would be two sentences about one condition.
public enum ClientVersionCopy {
    public static let tooOldMessage = "This version of Sonny is too old. Update to carry on."
}
