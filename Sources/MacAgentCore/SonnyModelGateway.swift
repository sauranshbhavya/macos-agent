import Foundation

/// The one model route the Mac app calls itself, voice transcription, on top of the shared backend
/// client. Every other model call is the gateway's own, inside a task.
///
/// **Nothing in this file names a provider, a model or a vendor endpoint**, so a change of provider
/// is a configuration change on the server rather than an app release.

/// `task_id` and `retention` — §2.4's two fields, required on every content-bearing request.
///
/// **One value carried together, because they are always answered together and neither has a
/// default.** §2.4.2 makes an omitted `retention` a `400` rather than a guess in either direction,
/// and the same reasoning applies on this side: a client type with a defaulted retention is a
/// client that can silently send the wrong privacy answer. Both are `let`s with no default, so a
/// call site that has not decided cannot compile.
public struct BackendTaskContext: Equatable, Sendable {
    /// §10.1's wire values. `none` is what a run started with **"Don't save this task"** sends.
    ///
    /// The word "incognito" appears in neither the enum nor the wire, deliberately (founder,
    /// 2026-08-16).
    public enum Retention: String, Equatable, Sendable {
        case standard
        /// §10.1's `"none"`: the backend meters the call and stores no content from it.
        ///
        /// **Named `notStored` rather than `none`, and the rename is not taste.** A case literally
        /// called `none` collides with `Optional.none` at every site where the value is optional-
        /// wrapped — `#expect(context?.retention == .none)` compares against `nil` and passes for a
        /// context that is absent, which is the opposite of what it reads as. That is not
        /// hypothetical: the first draft of `BackendTaskIdentityTests` was written that way and the
        /// assertion silently tested nothing until the compiler's own inference made it visible.
        /// The wire value is unchanged, because the wire value is the contract's.
        case notStored = "none"
    }

    /// A fresh id per recording, minted before the request is sent.
    public let taskID: String
    public let retention: Retention

    public init(taskID: String, retention: Retention) {
        self.taskID = taskID
        self.retention = retention
    }

    /// The two fields as they go on the wire, for a body builder to merge into its own.
    var wireFields: [String: Any] {
        ["task_id": taskID, "retention": retention.rawValue]
    }
}

/// The one model route the Mac calls directly: voice becomes text there. The one place its path is
/// written.
///
/// `usageModelName` is what `AIUsageRecord.model` is set to: the route's name rather than a model
/// identifier the client is not allowed to know (§4.2).
enum SonnyModelRoute {
    case transcription

    var path: String { "/v1/transcriptions" }
    var timeout: TimeInterval { SonnyBackendTimeouts.transcription }
    var usageModelName: String { "transcriptions" }
}

struct SonnyTranscriptionRouteResponse: Decodable {
    let text: String
    let usage: SonnyWireUsage?
}

/// The usage block the transcription route replies with.
struct SonnyWireUsage: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
    let total_tokens: Int?
    let audio_duration_seconds: Double?
    let source: String?

    /// The server's usage block as the app's own record.
    ///
    /// **`model` is the route name, never a model identifier** (§4.2). **`tokenSource` is the
    /// server's answer, never re-derived here** — the server is the only side that knows whether
    /// the provider reported anything, and a client that estimated on top of a reported figure
    /// would double-count. A block with no `source` at all leaves `tokenSource` nil, which is the
    /// same "no answer" the transcription path has always produced for a duration-only reply.
    func record(kind: AIUsageCallKind, route: SonnyModelRoute) -> AIUsageRecord {
        AIUsageRecord(
            kind: kind,
            model: route.usageModelName,
            tokenSource: source.flatMap(AIUsageTokenSource.init(rawValue:)),
            tokenCounts: AIUsageTokenCounts(
                inputTokens: input_tokens,
                outputTokens: output_tokens,
                totalTokens: total_tokens
            ),
            audioDurationSeconds: audio_duration_seconds
        )
    }
}

extension SonnyBackendClient {
    /// Send one model-route request and decode its reply. **Everything it can throw is a
    /// `SonnyBackendError`**, so each caller has one `catch` and one place to map onto its own copy.
    ///
    /// §9.1: **one key per logical operation, not one per attempt.** The key is minted here — the
    /// point where the operation begins — so the retry the shared client may perform reuses it,
    /// which is the entire mechanism §9.2's at-most-once metering guarantee rests on. A key minted
    /// per attempt would make every retry a new billable operation.
    ///
    /// `isRetrySafe: true`, per §9.3's table: with the same key, a retry returns the stored response
    /// rather than doing the work again.
    ///
    /// A body this client cannot read becomes `undecodableResponse` rather than a raw
    /// `DecodingError`, because these errors reach the user and a Foundation error rendered verbatim
    /// in the failure surface is a bug this repository has shipped before.
    func modelRouteResponse<T: Decodable>(
        _ type: T.Type,
        route: SonnyModelRoute,
        body: Data,
        contentType: String? = nil
    ) async throws -> T {
        let response = try await send(SonnyBackendRequest(
            method: "POST",
            path: route.path,
            body: body,
            contentType: contentType,
            authentication: .bearer,
            idempotencyKey: UUID(),
            timeout: route.timeout,
            isRetrySafe: true
        ))
        do {
            return try JSONDecoder().decode(T.self, from: response.data)
        } catch {
            throw SonnyBackendError.undecodableResponse(String(describing: error))
        }
    }
}

/// What the user is told when a call to Sonny's backend fails, in the app's own words.
///
/// **§7.1 forbids displaying the server's `message`**, and `SignInCopy` is the existing answer for
/// the sign-in routes. This is the same mapping for the transcription route, and it reuses
/// `SignInFailure` rather than growing a second taxonomy — that enum's own doc comment anticipates
/// exactly this ("SONNY-130 and SONNY-136 will reuse it").
///
/// **What this is not.** SONNY-136 owns making all four unreachable states distinguishable in the
/// app, and `feature/row-12-degradation` owns what the product *does* when the backend is down.
/// This is the narrower thing those two need to exist first: one sentence per failure, so that a
/// backend error reaching the existing failure surface reads as a sentence rather than as
/// `Backend returned 502 provider.unavailable: …`, which is what it would say without this.
public enum SonnyBackendCopy {
    /// Functional, not explanatory (founder, 2026-08-14): what happened and what to do next, and
    /// nothing about servers, tokens, providers or how any of it works.
    public static func sentence(for error: SonnyBackendError) -> String {
        // **Three codes are answered here rather than through `SignInFailure`, because a retry
        // cannot help and the shared sentence tells the user to try one** (PR #139, F7). §9.3 lists
        // all three as not retryable — "retrying any of these produces the identical failure and
        // burns a round trip" — and every one of them is reachable on this route while none
        // is reachable on the three unauthenticated sign-in routes `SignInFailure` was written for.
        // `request.invalid` in particular is what this server answers a missing `retention` with.
        //
        // The mapping is not wrong for sign-in; it is right there and wrong here, which is why this
        // is an interception rather than an edit to `SignInFailure`.
        if case .api(let api) = error {
            switch api.code {
            case .entitlementRequired:
                // **§7.2 case 2, and it reached `.unexpected` before SONNY-135** — `SignInFailure`
                // maps both entitlement codes there, correctly for the three unauthenticated
                // sign-in routes it was written for and wrongly here, where the shared sentence
                // ("Try again") invites a retry that is guaranteed to produce the identical answer.
                // The same interception, and the same reasoning, as the three codes below it.
                //
                // The words are `EntitlementCopy`'s, so a refusal the server raises and one this Mac
                // decides locally cannot say two different things about the same state.
                return EntitlementCopy.message(for: .notEntitled)
            case .entitlementExpired:
                // §7.2 case 2a: the entitlement lapsed mid-task. §16.4's graceful halt means the
                // step in flight finishes and the next one is blocked, so what the user needs is the
                // reason rather than a retry.
                return EntitlementCopy.message(for: .lapsed)
            case .providerRejected:
                // §7.2 case 5b's own words: "Told Sonny could not do this one. A retry would fail
                // identically." So the sentence says what happened and stops.
                return "Sonny couldn't do this one."
            case .requestInvalid:
                // The request was malformed — Sonny's fault, not the user's, and nothing they can
                // act on. Saying so plainly beats inviting a retry that fails the same way.
                return "Sonny couldn't send this one."
            case .requestTooLarge:
                return "That was too big for Sonny to send in one go."
            default:
                break
            }
        }
        switch SignInFailure(error) {
        case .offline:
            return "You're offline. Everything Sonny does on this Mac still works."
        case .backendUnreachable, .unexpected, .emailInvalid, .codeIncorrect, .codeExpired,
             .codeAlreadyUsed, .accountExists, .googleNotCompleted:
            // **What is left in this arm really is unreachable-or-unknown, and the previous version
            // of this comment was wrong about which** (PR #139, F7). It said the four code cases
            // "cannot arise on these routes" and named `.emailInvalid` among them — but
            // `SignInFailure` maps `request.invalid` to `.emailInvalid`, and `request.invalid` is
            // exactly what this server answers a missing `retention` with, so it arose constantly.
            // It is unreachable *now*, because the interception above takes `request.invalid` first;
            // the three `authCode*` cases, and SONNY-129's `accountExists` and `googleNotCompleted`,
            // are unreachable because these routes never return those codes. What remains is a backend that could not be reached and a code this build does
            // not recognise, and "try again" is honest for both.
            //
            // **`request.timeout` is reached here too, deliberately, and it is not unknown**
            // (SONNY-322, PR #208's F1). `SignInFailure` maps it to `.backendUnreachable`, so an
            // upload that did not arrive in time lands on this sentence — which is the one thing a
            // user in that position should do, and the reason the interception above does not take
            // it. Contrast `request.invalid` two arms up, whose whole point is to say the opposite.
            return "Sonny couldn't finish this one. Try again."
        case .tooManyAttempts:
            return "Too many requests just now. Try again shortly."
        case .outOfAllowance:
            return "You're out of allowance for this period."
        case .notConfigured:
            return "This build has no Sonny account service."
        case .signedOut:
            return "Sign in to Sonny to run this."
        case .updateRequired:
            // §8.3's wall, and the transcription route is refused by it exactly as the sign-in routes
            // are — `version/gate.ts` covers every route and runs before authentication. The
            // sentence is `ClientVersionCopy`'s for the reason the two entitlement arms above take
            // `EntitlementCopy`'s: one condition, one set of words, whichever surface meets it.
            return ClientVersionCopy.tooOldMessage
        }
    }
}
