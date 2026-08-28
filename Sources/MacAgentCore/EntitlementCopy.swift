import Foundation

/// What the user is told when a gated thing is refused, in the app's own words (SONNY-135).
///
/// **The same rule and the same reason as `SignInCopy` and `SonnyBackendCopy`**: §7.1 forbids
/// displaying the server's `message`, because a sentence authored on the server and rendered in the
/// app is a hole straight through Sonny's standing rule that the product does not explain itself,
/// editable by whoever edits the server with no review from anyone who knows that rule. So a refusal
/// maps to a case, and a case maps to words this repository owns.
///
/// **Functional, not explanatory** (founder, 2026-08-14): what happened and what to do next, and
/// nothing about tokens, claims, clocks-as-mechanisms, servers or how any of it works. In particular
/// none of these says why a check exists or how entitlement is decided.
///
/// **Scope, stated because SONNY-136 owns the rest.** Contract §13 gives SONNY-136 "literal
/// user-facing copy for every `code` in section 7" outside sign-in. What is here is the four refusals
/// *this* ticket creates and nothing else, so that a gate row 18 wires has a sentence the day it is
/// wired rather than a placeholder. `SonnyBackendCopy` keeps the wire-error mapping and gains the two
/// entitlement codes there, beside the limit ones it already answers.
public enum EntitlementCopy {
    public static func message(for refusal: EntitlementRefusal) -> String {
        switch refusal {
        case .notSignedIn:
            return "Sign in to Sonny to use this."
        case .noClaim:
            // Signed in and never online since. Connecting once is the whole of what is needed, and
            // it is the only thing the user can do.
            return "Connect once so Sonny can check your plan."
        case .unreadableClaim, .claimIsForAnotherSession:
            // Both are recovered the same way and neither is the user's doing, so they share a
            // sentence — the same call `SonnyBackendError` makes for its four unreachable states,
            // and for the same reason: "there is exactly one thing a user can do about all of them."
            return "Sonny couldn't check your plan. Sign in again."
        case .clockUnusable:
            // The one refusal with a real, specific action behind it, which is why it is not folded
            // into the sentence above.
            return "Your Mac's date and time are too far off. Set them automatically and try again."
        case .lapsed:
            return "Sonny couldn't check your plan recently enough. Reconnect and try again."
        case .notEntitled:
            return "This isn't part of your plan."
        }
    }
}
