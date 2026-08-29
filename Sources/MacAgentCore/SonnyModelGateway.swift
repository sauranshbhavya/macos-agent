import Foundation

/// The five model routes the Mac app calls, on top of the one shared backend client (SONNY-130; the
/// vision route is SONNY-131's).
///
/// **What moved and what did not.** Before this file, four clients each read a vendor key out of the
/// user's own environment, each posted to a vendor endpoint, and each named a model identifier in
/// its own initializer default. All three of those now live on the gateway. What stayed on the Mac
/// is everything that decides anything: the prompts, the schemas, the strict decoders, the URL
/// policy, and the whole risk and approval engine. `docs/sonny-backend-api-contract.md` §1.3 draws
/// that line and §4.2 restates the half that matters here — "response *parsing* stays client-side;
/// only the credential and the routing moved."
///
/// **Nothing in this file names a provider, a model or a vendor endpoint**, which is SONNY-130's
/// sixth requirement and the reason it is load-bearing: it is what turns SONNY-110's move to a paid
/// zero-retention route into a configuration change on the server rather than an app release.

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
    /// The word "incognito" appears in neither the enum nor the wire, deliberately — founder,
    /// 2026-08-16, recorded on `TaskRecordingPolicy`, whose own doc comment carries the reasoning.
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

    /// §5.1: `CompletedTaskRecord.id`, **minted when the task starts** rather than when its record
    /// is written — a record written at completion carries an id that arrives after every request
    /// the task made, which would leave the retained content and the local row filed under
    /// different keys and SONNY-134's delete unable to join them.
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

/// The route each call is made against — the one place a path string is written.
///
/// `usageModelName` is what `AIUsageRecord.model` is set to. §4.2 makes that explicit and gives the
/// reason: the field is non-optional and eventually gets rendered, so it holds the route's name
/// rather than a model identifier the client is no longer allowed to know.
enum SonnyModelRoute {
    case plan
    case researchSynthesis
    case transcription
    case search
    /// §4.5, the screen-control route (SONNY-131).
    case screenAnalyze

    var path: String {
        switch self {
        case .plan: return "/v1/plan"
        case .researchSynthesis: return "/v1/research/synthesize"
        case .transcription: return "/v1/transcriptions"
        case .search: return "/v1/search"
        case .screenAnalyze: return "/v1/screen/analyze"
        }
    }

    var timeout: TimeInterval {
        switch self {
        case .plan: return SonnyBackendTimeouts.plan
        case .researchSynthesis: return SonnyBackendTimeouts.researchSynthesis
        case .transcription: return SonnyBackendTimeouts.transcription
        case .search: return SonnyBackendTimeouts.search
        case .screenAnalyze: return SonnyBackendTimeouts.screenAnalyze
        }
    }

    var usageModelName: String {
        switch self {
        case .plan: return "plan"
        case .researchSynthesis: return "research.synthesize"
        case .transcription: return "transcriptions"
        case .search: return "search"
        case .screenAnalyze: return "screen.analyze"
        }
    }
}

/// §4.2's request body, shared by `/v1/plan` and `/v1/research/synthesize`.
///
/// **One shape across two paths**, which is the contract's own decision and its reason: it lets the
/// server hold one adapter per provider instead of one per route, while still routing, metering and
/// pricing them separately.
struct SonnyTextRouteBody {
    let context: BackendTaskContext
    /// Ordered and role-tagged. §4.2: the server forwards this text and never edits, re-wraps or
    /// re-orders it — which is what keeps row I's `TRUSTED_USER_INSTRUCTION` and
    /// `UNTRUSTED_OBSERVED_CONTENT` boundaries intact across the network hop.
    let messages: [(role: String, text: String)]
    let schemaName: String
    let schema: [String: Any]

    func encoded() throws -> Data {
        var body = context.wireFields
        body["messages"] = messages.map { ["role": $0.role, "text": $0.text] }
        body["response_schema_name"] = schemaName
        body["response_schema"] = schema
        // Advisory hints, kept at the values the Mac has always sent so the move changes nothing a
        // model can see. §4.2: a provider with no equivalent ignores them.
        body["reasoning_effort"] = "medium"
        body["verbosity"] = "low"
        return try JSONSerialization.data(withJSONObject: body)
    }
}

/// §4.2's response to the two text routes.
struct SonnyTextRouteResponse: Decodable {
    let output_text: String
    let usage: SonnyWireUsage?
}

/// §4.4's response to `/v1/transcriptions`.
struct SonnyTranscriptionRouteResponse: Decodable {
    let text: String
    let usage: SonnyWireUsage?
}

/// §4.3's response to `/v1/search`. It carries no `usage` block, and that is the contract's shape
/// rather than an omission here — search has never fed the local per-task summary.
struct SonnySearchRouteResponse: Decodable {
    struct Item: Decodable {
        let title: String?
        let url: String
        let snippet: String?
    }

    let results: [Item]
}

/// The `usage` block every content-bearing response but search carries.
///
/// Every field is optional, because §2.1 makes the client tolerant of a response it cannot fully
/// read and because the two routes genuinely report different halves of it: a transcript may come
/// back with a duration and no tokens, a plan with tokens and no duration.
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
    /// `isRetrySafe: true` on all four, per §9.3's table: with the same key, a retry of any of them
    /// returns the stored response rather than doing the work again.
    ///
    /// A body this client cannot read becomes `undecodableResponse` rather than a raw
    /// `DecodingError`. That matters because these errors reach the user: every error a planner
    /// throws has to carry its own `LocalizedError`, and a Foundation error rendered verbatim in the
    /// failure surface is a bug this repository has shipped before. (That obligation used to be
    /// stated as `PlannerProvider`'s third, on a type SONNY-132 deleted with the client-side
    /// provider router; the obligation is unchanged and is now simply what `Planning` conformances
    /// owe.)
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
/// the sign-in routes. This is the same mapping for the four model routes, and it reuses
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
        // burns a round trip" — and every one of them is reachable on these four routes while none
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
             .codeAlreadyUsed:
            // **What is left in this arm really is unreachable-or-unknown, and the previous version
            // of this comment was wrong about which** (PR #139, F7). It said the four code cases
            // "cannot arise on these routes" and named `.emailInvalid` among them — but
            // `SignInFailure` maps `request.invalid` to `.emailInvalid`, and `request.invalid` is
            // exactly what this server answers a missing `retention` with, so it arose constantly.
            // It is unreachable *now*, because the interception above takes `request.invalid` first;
            // the three `authCode*` cases are unreachable because these routes never return those
            // codes. What remains is a backend that could not be reached and a code this build does
            // not recognise, and "try again" is honest for both.
            return "Sonny couldn't finish this one. Try again."
        case .tooManyAttempts:
            return "Too many requests just now. Try again shortly."
        case .outOfAllowance:
            return "You're out of allowance for this period."
        case .notConfigured:
            return "This build has no Sonny account service."
        case .signedOut:
            return "Sign in to Sonny to run this."
        }
    }
}
