# Sonny backend API contract, v1

The agreement between the Mac app and the backend. Written for SONNY-124, against `main` at
`6f89a5d`. Every file:line and every measurement below was taken at that SHA and re-verified there;
the tree will move, so re-check before relying on one.

**This document is host-agnostic.** No requirement in it comes from any hosting platform's published
limits, and nothing in it presumes where the server runs. The host choice is deliberately held
(SONNY-125, gated on SONNY-114), and it does not change anything written here. Where a number here
constrains the host, it is derived from Sonny's own code and says so.

**What binds what.** Twelve of row 12's fourteen tickets are written against this document. Where a
ticket's own description conflicts with this contract, the ticket wins for that ticket's work and the
conflict gets recorded here — a contract nobody can correct is worse than one that drifts. Where this
contract diverges from `docs/sonny-major-release-spec.md` §16.2, section 4.7 says so and why;
amending the spec is row 20's (SONNY-108), not this document's.

**What this is not.** It is not a plan — that is `docs/sonny-row-12-plan.md`, which carries the
measurements and the founder decisions this contract respects. It is not an implementation. It writes
no code and names no host, language, framework or database.

---

## 1. The boundary

### 1.1 What crosses it

The founder's decision of 2026-08-16: **the boundary is anything that needs a provider credential**,
not "model calls." Nine files in `Sources/` send an HTTP request. Six need a credential and move
behind the backend. Three need none and stay local by decision.

| Client type | Credential today | file:line at `6f89a5d` (key, endpoint, send) | Endpoint |
|---|---|---|---|
| `OpenAIPlanner` | `OPENAI_API_KEY` | `OpenAIPlanner.swift:41`, `:43`, `:68` | `POST /v1/plan` |
| `CerebrasPlanner` | `CEREBRAS_API_KEY` | `CerebrasPlanner.swift:51`, `:53`, `:81` | `POST /v1/plan` |
| `OpenAITranscriber` | `OPENAI_API_KEY` | `OpenAITranscriber.swift:41`, `:43`, `:74` | `POST /v1/transcriptions` |
| `VisionModelClient` (`OpenCodeVisionModelClient`) | `OPENCODE_API_KEY` | `VisionModelClient.swift:111`, `:92`, `:152` | `POST /v1/screen/analyze` |
| `WebResearchSynthesizer` (`OpenAIWebResearchSynthesizer`) | `OPENAI_API_KEY` | `WebResearchSynthesizer.swift:320`, `:322`, `:345` | `POST /v1/research/synthesize` |
| `TavilySearchProvider` | `TAVILY_API_KEY` | `TavilySearchProvider.swift:39`, `:40`, `:65` | `POST /v1/search` |

Both planners map to the same endpoint. That is the point: after SONNY-132 the client names a route
and the server names a provider, so "which planner" stops being a client concept.

One row is shaped differently and the table would mislead without the note. The other five read their
key as a defaulted `apiKey` init parameter, so the "key" column is the read itself.
`OpenCodeVisionModelClient` takes a whole `environment` dictionary instead (`VisionModelClient.swift:104`)
and reads the key out of it at `:111`; the variable's *name* is a separate constant at `:94`. The
column cites `:111`, the read, for parity with the others.

### 1.2 What does not cross it

Three files make network requests with no credential and get **no endpoint in this contract**. The
tradeoff was named when the decision was made: their traffic keeps carrying the user's own IP address
to those hosts, where proxying would hide it. That is a privacy question rather than a billing one,
and the decision is to leave them local.

| Client type | Send sites at `6f89a5d` | Reaches |
|---|---|---|
| `HackerNewsService` | `:46`, `:55` | `hacker-news.firebaseio.com` |
| `MediaPlaybackService` | `:652` | `itunes.apple.com` |
| `WebResearchService` | `:275`, `:309` | whatever page the command names, plus its `robots.txt` |

**`AgentViewModel.swift` is not a network call site**, despite spec §16.5's migration note (spec line
2153) naming it. Enumerated rather than asserted: at `6f89a5d` the file's only `URLSession`- or
`URLError`-adjacent mentions are a doc comment at `:778-779` and a `URLError(.cancelled)` comparison
at `:784` — three lines, no request. It still changes in this row, for provider construction and
error copy, and it gets no endpoint.

### 1.3 The line the contract draws inside a request

The client composes the prompt. The server composes the provider request.

That line is not arbitrary and it is the single most load-bearing decision in this document, so the
reasoning is recorded rather than implied.

- **The server must own provider, model, endpoint and credential.** SONNY-130 requires that no
  provider name, model identifier or vendor endpoint remain in the client, and SONNY-132 requires
  that adding a provider be a config entry plus a server adapter and never a client change. A thin
  pass-through of one vendor's request shape fails both, and fails §16.5's "provider-agnostic router
  interface designed in from day one" directly.
- **The client must keep owning the prompt.** Every prompt Sonny sends is assembled by a builder that
  is also a security boundary: `UntrustedContentBoundary` owns the four delimiter strings,
  `WebResearchPromptBuilder` forwards to it for fetched pages, and
  `VisionSessionPromptBuilder.decisionPrompt` (`VisionSessionPromptBuilder.swift:33`) wraps
  everything a vision session observes. `.claude/rules/macagentcore-conventions.md` states the rule
  those follow: never re-declare the markers, because "two independently maintained copies of a
  security boundary is the shape where one gets hardened and the other does not." Rebuilding the
  prompt server-side creates exactly that second copy and moves an injection defence off the machine
  — the same class of ground as the three already recorded for not building §9's server-side agent
  loop.

So each model route takes **Sonny-shaped, provider-neutral materials**: role-tagged message text the
client built, an optional JSON Schema for structured output, and the bytes for image or audio routes.
The server maps that to whichever provider it has chosen and maps the reply back. Adding Anthropic is
a server adapter. Moving the vision route to a zero-retention provider (SONNY-110) is a config entry.
Neither is an app release.

Two things follow that implementers get wrong if they are not told:

- **`model` leaves the client entirely.** `OPENAI_MODEL`, `OPENAI_TRANSCRIBE_MODEL`, `CEREBRAS_MODEL`
  and `SONNY_VISION_MODEL` become server configuration. No request field names a model and no
  response returns one (section 4.2).
- **Redaction and encoding stay client-side and structurally so.** `RedactedPayload`
  (`LocalRedactionService.swift:50`) has a `fileprivate` initializer (`:69`) precisely so that an
  unredacted image cannot be constructed outside the redaction service, and
  `RedactedCaptureEncoder.render` is the only way a capture becomes bytes that leave the device. The
  server never sees a raw screenshot, and must never be handed one "for convenience."

---

## 2. Conventions

Everything in section 2 applies to every endpoint unless an endpoint says otherwise.

### 2.1 Wire format

- UTF-8 JSON, `Content-Type: application/json`, except `POST /v1/transcriptions`
  (`multipart/form-data`, section 4.4).
- Field names are `snake_case`.
- Timestamps are RFC 3339 in UTC with a `Z` suffix: `2026-08-17T09:41:07Z`.
- Durations are seconds, as numbers. Byte counts are integers.
- All identifiers are opaque strings. The client never parses one for meaning.
- **Unknown response fields are ignored by the client.** This is a requirement, not a convenience —
  it is what makes section 8's additive-only rule work. One deliberate exception exists and must not
  be widened: `AgentPlanDecoder.decodeStrict` (`AgentPlan.swift`) rejects unknown keys in the
  *model's plan output*, which is a different document from this API's envelope. The envelope is
  tolerant; the plan inside `output_text` stays strict.
- **No response field ever carries a sentence the app displays.** Section 7.1 states this as a rule
  with its reason.

### 2.2 Request headers

| Header | On | Value |
|---|---|---|
| `Authorization` | every authenticated request | `Bearer <access_token>` |
| `Idempotency-Key` | every `POST` | a client-minted UUID, section 9 |
| `Sonny-Client-Version` | every request | marketing version plus build, e.g. `1.0.0+412` |
| `Sonny-Platform` | every request | `macos/<os version>`, e.g. `macos/26.5.2` |
| `Content-Encoding` | optional | `gzip` — see section 6.4 |
| `Accept-Encoding` | every request | should include `gzip` |

**Section 4.1's `Auth` column is the single source of truth for which endpoints need a Bearer token.**
Restating a partial list here is how a client ends up attaching an access token to the calls made
before it has one. For convenience, the endpoints that carry no `Authorization` header at all are
`GET /v1/meta`, `GET /v1/health`, `POST /v1/auth/email/start`, `POST /v1/auth/email/verify`,
`POST /v1/auth/oauth/google`, `POST /v1/auth/oauth/apple` and `POST /v1/auth/refresh` — the last of
these authenticates with the refresh token in its body and deliberately sends no header, so that an
expired or missing access token can never be the reason a refresh fails.

### 2.3 Response headers

| Header | Meaning |
|---|---|
| `Sonny-Api-Version` | `1.<minor>` — the minor version that served this response |
| `Sonny-Request-Id` | a UUID, also in every error body and every metering event |
| `Date` | **the authoritative clock.** Section 3.5 |
| `Retry-After` | seconds, on `429 limit.rate` and on `503` |
| `Sonny-Deprecation` | `true` when this client is below the recommended version, section 8.4 |
| `Sonny-Deprecation-Info` | a URL, present only alongside `Sonny-Deprecation` |

`Sonny-Request-Id` is the one string a user could ever be asked to quote for support. It is the join
key between an error the user saw, the metering event, and the retained content — which is what makes
SONNY-134's support lookup answerable without a database trawl.

### 2.4 Fields every content-bearing request carries

The five model routes are `/v1/plan`, `/v1/research/synthesize`, `/v1/transcriptions`, `/v1/search`
and `/v1/screen/analyze`.

| Field | Required on | Type | Meaning |
|---|---|---|---|
| `task_id` | all five | string | The local task this request belongs to. Section 5.1 |
| `retention` | all five | `"standard"` \| `"none"` | Section 10.1. **Never defaulted** — see 2.4.2 |
| `session_id` | `/v1/screen/analyze` only | string | Screen-control session. Section 5.2. Absent on the other four |
| `session_iteration` | `/v1/screen/analyze` only | integer | 1-based. Absent on the other four |

`task_id` and `retention` are required on all five and are never defaulted. `session_id` and
`session_iteration` are required on `/v1/screen/analyze` and do not appear at all on the other four —
there is no session to name. Section 4's per-route bodies show this concretely.

#### 2.4.1 What the client supplies and what the server derives

Stated because two sessions will otherwise build two different metering shapes. The client supplies
`task_id`, `retention`, `session_id`, `session_iteration`, the content, and — from the headers of
2.2 — the `Idempotency-Key`, `Sonny-Client-Version` and `Sonny-Platform`. On `/v1/screen/analyze` it
also supplies the image's `pixel_width` and `pixel_height`, which it is the only side that knows
(4.5). Everything else on a metering event — user, provider, model, token counts, durations, byte
counts, outcome — is the server's, derived from the authenticated session and the upstream call.

**The client never reports its own usage numbers to the server.** A client-reported bill is not a
bill.

#### 2.4.2 `retention` has no default

A request without `retention` is `400 request.invalid`. It is not defaulted to `"standard"` and it is
not defaulted to `"none"`.

Defaulting either way is the specific bug this rule exists to prevent. Default to `"standard"` and a
client that forgets the field silently stores content the user asked not to store. Default to
`"none"` and a client that forgets the field silently loses the retention the founder decided to
have. An omitted privacy field must be a loud error, not a quiet guess.

---

## 3. Authentication

### 3.1 Two tokens

- **Access token** — short-lived, sent as `Authorization: Bearer`. **A JWT issued by Supabase Auth**
  (amended 2026-08-21, SONNY-127 — see section 14). **The client must not decode, inspect or make any
  decision from it.** Entitlement is a separate, signed, deliberately-parseable claim (section 5),
  and that separation is the property this rule protects: what stops the client making entitlement
  decisions from an authentication artifact is the rule, not the encoding. The token was specified as
  opaque because opacity enforced the rule mechanically; under the founder's 2026-08-21 decision to
  use Supabase Auth it is a JWT, so **the rule is now a contract obligation the client must keep
  rather than one its encoding keeps for it**, and SONNY-128's review is where that is checked.
  **Verification of a presented access token — signature and expiry — is SONNY-203's and does not
  exist yet** (noted 2026-08-21, PR #87 F2; owner corrected from SONNY-128 the same day, PR #87
  second round F5 — SONNY-128 is the client half and its never-touch list forbids `server/`, so it
  could never have supplied this). SONNY-127 issues tokens and supplies the skew tolerance that
  verification will apply; no route on that branch verifies one. SONNY-203 verifies the Supabase
  token as **HS256 with the algorithm pinned**, checking `iss`, `aud` and `exp`, and trusting `sub`
  as the user id.
- **Refresh token** — long-lived, opaque, rotated on every use, stored in the Keychain through the
  existing `KeychainSecretStore` (the concrete struct at `KeychainSecretStore.swift:21`, behind the
  `KeychainSecretStoring` protocol at `:4-7`) as a new account on the existing store, following the
  DI pattern `LocalStorageEncryptionKeyManager` already uses
  (`LocalStorageEncryption.swift:39-40` for the naming precedent). It is not a new store and must not
  become a variant of the pattern.

### 3.2 The token response

Returned by `POST /v1/auth/email/verify`, `POST /v1/auth/oauth/{provider}` and `POST /v1/auth/refresh`.

```json
{
  "access_token": "…",
  "token_type": "Bearer",
  "expires_in": 3600,
  "expires_at": "2026-08-17T10:41:07Z",
  "refresh_token": "…",
  "refresh_expires_at": "2026-11-15T09:41:07Z",
  "user": { "id": "…" }
}
```

`expires_in` and `expires_at` are both present on purpose. `expires_in` is immune to clock skew and is
what the client should schedule from; `expires_at` is what it should log and compare against server
time. A client that has both never has to choose between a wrong local clock and no information.

### 3.3 How expiry is signalled, and refresh

- Proactively: the client refreshes when `expires_in` is most of the way spent. It does not wait for
  a 401.
- Reactively: a request with an expired access token gets `401` with `code: "auth.token_expired"`.
  The client refreshes once and retries the original request exactly once.
- **Single-flight refresh.** Ten concurrent 401s cause one refresh, not ten. This is SONNY-128's to
  implement and its acceptance criteria pin it; it is stated here because the server's rotation rule
  below only works if the client honours it.
- **Rotation with an overlap and reuse detection.** Each refresh issues a new refresh token. The
  previous token stays valid for a short overlap window, so a crash between receiving a new token and
  writing it to the Keychain does not sign the user out. Presenting a refresh token that has already
  been rotated away *past* the overlap is treated as theft: the whole token family is revoked and the
  response is `401 auth.token_revoked`. The overlap's length is **not** SONNY-127's to set after all: under the
  2026-08-21 decision to serve auth from Supabase Auth it is the platform's, and is **10 seconds**
  by default (corrected 2026-08-21, PR #87 F10 — this line previously said SONNY-127's, which was
  written before that decision). The shape is fixed here because retrofitting reuse detection after
  tokens exist is the expensive path, and the platform's shape matches it.
- Sign-out revokes the family server-side and clears the Keychain entry locally. **Sign-out, "delete
  my local data", and "reset the encryption identity" are three different actions with three
  different blast radii.** Branch 7 deliberately made local data deletion leave the Keychain
  encryption key alone; conflating any two of the three is a real bug and has its own acceptance
  criterion on SONNY-128.

### 3.4 401 versus 403

The distinction is one question: **does signing in again fix it?**

| | 401 | 403 |
|---|---|---|
| Means | The request could not be attributed to a signed-in user | It was attributed fine, and this user may not do this |
| Causes | missing, malformed, expired or revoked token | not entitled, plan lapsed, capability gated |
| Client does | refresh once, then send the user to sign-in | never refreshes, never retries |
| Codes | `auth.unauthenticated`, `auth.token_expired`, `auth.token_revoked` | `entitlement.required`, `entitlement.expired` |

A 403 that the client retries after refreshing is a bug that presents as an infinite sign-in loop. A
401 the client treats as a permission failure is a bug that presents as a user being told to upgrade
when they only needed to sign in again. Both have happened in other products; the table is the
defence.

Limits are neither: they are `429` (section 7.2), because a limit is a state that clears, not an
identity or a permission.

### 3.5 Clock

Expiry, grace and idempotency windows are all evaluated against a clock the server owns and the user
can change.

- Every response carries a `Date` header. The client stores the offset between that and its own clock
  and does all expiry arithmetic in server time.
- A client that has never seen a response — first launch, offline — falls back to its own clock and
  the claim's own tolerance (section 5.3). It does not refuse to work.
- The server never trusts a client-supplied timestamp for anything billable or expiring.

The concrete skew tolerance is SONNY-135's to set and test at both edges; the mechanism is fixed
here so that SONNY-127 and SONNY-135 use the same one.

### 3.6 The auth endpoint shapes

`POST /v1/auth/email/start` — request a sign-in code.

```json
{ "email": "…" }
```
```json
{ "request_id": "…", "expires_in": 600 }
```

**The response is identical whether or not that address has an account.** An endpoint that answers
differently is an account-existence oracle for anyone who finds it. Code lifetime, per-address and
per-source rate limits are SONNY-127's — an unlimited code endpoint is a free email-sending service
for whoever finds that instead.

`POST /v1/auth/email/verify` — exchange a code for tokens.

```json
{ "email": "…", "code": "…" }
```

Returns the token response of 3.2 on success. On failure it returns one of three distinct codes —
`auth.code_invalid`, `auth.code_expired`, `auth.code_used` — because SONNY-127 has to rate-limit them
differently and SONNY-128 has to say three different things to the user.

**Where those three come from, since the provider does not supply them** (noted 2026-08-21,
SONNY-127). Supabase Auth returns a single `otp_expired` reading "Token has expired or is invalid"
for all three cases. The gateway therefore derives them from its own record of what it issued —
consumed, aged out, or neither — rather than from the provider's error. What the client receives is
unchanged; this note exists so nobody later reads the provider's single error as evidence that the
contract over-specified. Codes are single-use, so a
replay of this call returns the stored original result — including the original failure — and never
un-consumes a code. Section 9.3 has the whole retry table.

**`link_hint`, an optional field on the token response** (added 2026-08-21, extended 2026-08-22,
SONNY-127). Present when the server can see a reason to suspect this sign-in belongs with an existing
account and cannot prove one. It is advisory: it names no account and carries no identifier, because
naming one would answer "does this address have an account?" to anyone who can reach the endpoint.
Two values:

| `link_hint` | Means |
|---|---|
| `relay_address_may_belong_to_existing_account` | An Apple Hide My Email relay address, which matches nothing by design |
| `verified_email_matches_existing_account` | A verified, non-relay address that **does** match an existing identity — and which no longer merges on that alone (founder decision, 2026-08-22; `docs/sonny-identity-linking-rule.md` §2.1) |

A client that ignores the field is correct and gets two accounts; there is no failure mode in
ignoring it, only a worse experience. **Surfacing it — the prompt that offers to join the two — is
SONNY-128's and SONNY-129's**, and neither the field nor the prompt merges anything: rule 4 is the
only path that joins two existing accounts.

`POST /v1/auth/oauth/google` and `POST /v1/auth/oauth/apple` — the body is whatever the provider's
flow yields and is SONNY-129's to fix, once that ticket has established which Sign in with Apple
mechanism actually works for a Developer-ID-signed, non-App-Store Mac app. Both return the same token
response of 3.2, and both land on the same account as an email sign-in for the same person, per the
identity-linking rule SONNY-127 owns. This contract fixes the paths and the response so the sign-in
surface does not have to be rebuilt when they arrive.

`POST /v1/auth/refresh` — `{ "refresh_token": "…" }`, returning the token response of 3.2 with a new
refresh token. Rotation, overlap and reuse detection are in 3.3.

`POST /v1/auth/signout` — no body. Revokes this session's refresh-token family server-side and
returns `204`. The client clears its Keychain entry and touches nothing else (3.3).

`GET /v1/health` — liveness and a build identifier, unauthenticated. Its shape is SONNY-126's; it is
listed here only so nobody adds a second one.

---

## 4. Endpoints

### 4.1 The set

| Method and path | Auth | Purpose | Owner |
|---|---|---|---|
| `GET /v1/meta` | none | Version negotiation, entitlement verification keys, server time | **no owner yet — see below** |
| `GET /v1/health` | none | Liveness and build identifier | SONNY-126 |
| `POST /v1/auth/email/start` | none | Request a sign-in code | SONNY-127 |
| `POST /v1/auth/email/verify` | none | Exchange a code for tokens | SONNY-127 |
| `POST /v1/auth/oauth/google` | none | Sign in with Google | SONNY-129 |
| `POST /v1/auth/oauth/apple` | none | Sign in with Apple | SONNY-129 |
| `POST /v1/auth/refresh` | refresh token in body | Rotate tokens | SONNY-127 |
| `POST /v1/auth/signout` | yes | Revoke this session's family | SONNY-127 |
| `GET /v1/account/entitlements` | yes | Fetch the signed entitlement claim | SONNY-135 |
| `DELETE /v1/account` | yes | Delete the account and everything under it | SONNY-127, SONNY-134 |
| `POST /v1/plan` | yes | Planner | SONNY-130 |
| `POST /v1/research/synthesize` | yes | Web-research synthesis | SONNY-130 |
| `POST /v1/transcriptions` | yes | Voice transcription | SONNY-130 |
| `POST /v1/search` | yes | Web search | SONNY-130 |
| `POST /v1/screen/analyze` | yes | Screen control | SONNY-131 |
| `DELETE /v1/tasks/{task_id}` | yes | Delete this task's retained content | SONNY-134 |

**`GET /v1/meta` and the version gate have no owning ticket, and that is a gap in row 12's ticket
set rather than an open question here.** Writing section 8 is what exposed it. SONNY-126 builds "one
health endpoint that returns a version identifier" and its non-goals say "any endpoint beyond health"
explicitly, so `/v1/meta` is outside it; and pulling all fourteen row-12 tickets and searching them
for `/v1/meta`, `api_version`, `minimum_supported_client`, `version.unsupported` and
`Sonny-Deprecation` returns nothing outside this document. Three things therefore need an owner: the
endpoint itself, the middleware that answers `410 version.unsupported` on every route, and the
deprecation headers. Filed as **SONNY-155**, Backlog and untriaged, for the founder to assign;
creation is memory, assignment is authority.

### 4.2 One body shape, two text routes

`POST /v1/plan` and `POST /v1/research/synthesize` take the same body. Keeping them one shape across
two paths is what lets the server hold one adapter per provider instead of one per route, while still
routing, metering and pricing them separately.

```json
{
  "task_id": "…",
  "retention": "standard",
  "messages": [
    { "role": "system", "text": "…" },
    { "role": "user",   "text": "…" }
  ],
  "response_schema_name": "agent_plan",
  "response_schema": { "type": "object", "additionalProperties": false, "…": "…" },
  "reasoning_effort": "medium",
  "verbosity": "low"
}
```

- `messages` is ordered and role-tagged. `role` is `"system"` or `"user"`. The text is exactly what
  the client's prompt builders produce today — `OpenAIPlanner.systemPrompt(toolRegistry:)`
  (`OpenAIPlanner.swift:129`) for the planner's system message, `WebResearchPromptBuilder` for
  synthesis, including its `TRUSTED_USER_INSTRUCTION` and `UNTRUSTED_OBSERVED_CONTENT` wrapping. The
  server forwards the text; it never edits, re-wraps or re-orders it.
- `response_schema_name` is a short, stable identifier for the schema — `"agent_plan"` for the
  planner, `"web_research_note"` for synthesis, matching the names the client's own schema builders
  already use (`AgentPlanSchema.responseFormat()` at `AgentPlan.swift:433`,
  `WebResearchNoteSchema.responseFormat()`). It is required, and it is what a provider adapter that
  needs a named schema or a named tool uses. It is never rendered anywhere.
- `response_schema` is a JSON Schema. The server maps it to whichever structured-output mechanism the
  chosen provider has — `text.format` with `type: "json_schema"` on one, tool-use on another, a
  prompt suffix on a third, as `CerebrasPlanner` already does today
  (`CerebrasPlanner.swift:129-131` for the native path, its schema-in-prompt fallback otherwise).
  **The client does not know which mechanism was used and must not need to.**
- `reasoning_effort` and `verbosity` are advisory hints, not guarantees; a provider that has no
  equivalent ignores them.

Response:

```json
{
  "request_id": "…",
  "output_text": "…",
  "usage": {
    "input_tokens": 4210,
    "output_tokens": 318,
    "total_tokens": 4528,
    "source": "reported"
  }
}
```

- `output_text` is the model's text, unmodified. The client decodes it exactly as it does today —
  `AgentPlanDecoder.decodeStrict` for the planner, `WebResearchNoteDecoder.decodeStrict` for
  synthesis. Response *parsing* stays client-side; only the credential and the routing moved.
- `usage.source` is `"reported"` or `"estimated"`, mirroring `AIUsageTokenSource`
  (`TaskUsage.swift:20`). The server estimates only when the provider reported nothing, and says
  which it did. This is what keeps the app's local per-task usage summary populated after the
  gateway lands (SONNY-130's fifth requirement).
- **The response names no provider and no model.** SONNY-132's acceptance criteria include the
  founder confirming nothing in the app mentions a provider name anywhere; a field the app receives
  is a field that eventually gets rendered. `AIUsageRecord.model` (`TaskUsage.swift:55`) is
  non-optional, so the client sets it to the route name — `"plan"`, `"screen.analyze"` — rather than
  a model identifier it is no longer allowed to know. Which provider actually served the request is
  recorded server-side on the metering event (section 6), where failover accounting needs it.

### 4.3 `POST /v1/search`

```json
{ "task_id": "…", "retention": "standard", "query": "…", "max_results": 5 }
```

```json
{
  "request_id": "…",
  "results": [ { "title": "…", "url": "…", "snippet": "…" } ]
}
```

`max_results` is clamped to 1–20 on both sides; the client already clamps at
`TavilySearchProvider.swift:54`.

**The server does not filter or validate result URLs.** The client drops non-`http`/`https` results
today, and real URL policy — `SafeURL`, the whitelist, the risk engine — is deliberately downstream
in the capability adapter. Moving any of it server-side would put a safety decision on the far side
of a network call, which is the thing this row's architecture exists not to do.

### 4.4 `POST /v1/transcriptions`

`multipart/form-data`, two parts:

| Part | Content-Type | Content |
|---|---|---|
| `meta` | `application/json` | `{ "task_id": "…", "retention": "standard" }` |
| `audio` | `audio/mp4` | the recording, bytes verbatim |

Multipart rather than base64-in-JSON because base64 would inflate the audio by a third for no gain,
and the client already builds a multipart body (`OpenAITranscriber.swift:106-124`).

What the recorder produces today, so the server knows what it will receive: `.m4a`, MPEG-4 AAC, mono,
44.1 kHz, `AVAudioQuality.high` (`AudioCommandRecorder.swift:32-38`). There is **no maximum duration**
today, which is why the byte limit in section 6.1 exists as a backstop; the duration cap and its
user-facing refusal are SONNY-130's.

```json
{
  "request_id": "…",
  "text": "…",
  "usage": { "audio_duration_seconds": 4.8, "input_tokens": null, "output_tokens": null, "total_tokens": null, "source": "reported" }
}
```

`audio_duration_seconds` maps to `AIUsageRecord.audioDurationSeconds` (`TaskUsage.swift:58`), which
the local summary already sums.

### 4.5 `POST /v1/screen/analyze`

```json
{
  "task_id": "…",
  "session_id": "…",
  "session_iteration": 5,
  "retention": "standard",
  "prompt": "…",
  "image": {
    "media_type": "image/jpeg",
    "encoding": "base64",
    "data": "…",
    "pixel_width": 2406,
    "pixel_height": 1354
  }
}
```

```json
{ "request_id": "…", "output_text": "…", "usage": { "…": "…" } }
```

Five rules on this route specifically. Each is here because breaking it is silent.

1. **The server must not resample, re-encode, crop or rotate the image.** The coordinate space the
   model answers in is `SentImageSize`, and the prompt, the bounds check, the point-to-screen scale
   and the journal all read that one value. A server-side resize would leave every returned
   coordinate scaled by a factor nothing on the client knows about — clicks landing inside the
   window, plausible-looking, and wrong. Forward the bytes.
2. **`media_type` is per-capture and is never assumed.** `RedactedCaptureEncoder` encodes both PNG
   and JPEG and sends the smaller, so roughly half of real captures are `image/jpeg` and half are
   `image/png`. The client already carries this in `RedactedPayload.imageMediaType` and builds the
   provider's data URL from it (`VisionModelClient.swift:139`). A server that hardcodes either is
   wrong half the time.
3. **`pixel_width` and `pixel_height` are required**, and are the dimensions of the image *as
   encoded* — which since SONNY-114 may be smaller than the capture's own. They are on the wire
   because vision token cost is driven by pixel dimensions rather than bytes, so metering cannot
   derive the cost without them.
4. **The image arrives already redacted, and the server never receives a raw one.** Section 1.3.
5. **One request is one iteration.** There is no conversation state on the server. Continuity lives
   client-side in the runner's `history`, redacted before every send and folded into `prompt`. A
   session sends up to twelve of these (`VisionSessionLimits.default.maximumIterations = 12`,
   `VisionSessionContainment.swift:205`, `:209-210`), with a fresh full capture at the top of every
   pass (`VisionSessionRunner.swift:196`) including for `wait`, `delegate`, `done` and `stuck`.

### 4.6 `DELETE /v1/tasks/{task_id}`

```json
{ "task_id": "…", "deleted_at": "2026-08-17T09:41:07Z", "requests_deleted": 3 }
```

Delete means deleted everywhere — the local record and the backend's retained copy (founder,
2026-08-16, via SONNY-14). Three rules:

- It must reach training snapshots, not only the live content store. That is what the recorded
  snapshot lineage exists for, and it is why lineage cannot be retrofitted after anything has been
  trained on. SONNY-134 implements; this contract fixes that the path exists and is reachable from
  the app rather than being an internal admin operation.
- **A task with nothing stored returns success, not 404**, with `requests_deleted: 0`. An incognito
  run, or a task that ran before the user signed in, has no server-side content — and a delete that
  is already true must not surface as an error the user has to interpret.
- `404 resource.not_found` is reserved for a `task_id` that belongs to a different user. It never
  means "nothing was stored."

The same path serves a user's data-deletion request, so it is needed twice over. `DELETE /v1/account`
reaches everything this reaches, plus the account record.

### 4.7 Reconciling with spec §16.2

§16.2 (spec lines 2103-2117) lists eleven initial endpoints. Eight of them assume §9's server-side
agent loop, which v1 consciously does not build — a dated deviation recorded in
`docs/sonny-founder-design-decisions.md` and on SONNY-16, with its three grounds. Under this row's
architecture there is no server-side task resource to create, read, feed context to, or cancel.

| §16.2 endpoint | v1 | Why |
|---|---|---|
| `POST /v1/tasks` | not built | §9 task orchestration. The agent loop stays on the Mac |
| `GET /v1/tasks/{task_id}` | not built | No server-side task state exists to read |
| `POST /v1/tasks/{task_id}/context` | not built | Context packets are assembled client-side into the prompt |
| `POST /v1/tasks/{task_id}/observations` | not built | §9.2 would hold screen-derived observations in server task state — one of the three recorded grounds |
| `POST /v1/tasks/{task_id}/approvals` | not built | Approval is local and structural. `AgentRunner`, `RiskApproval` and `ToolRegistry` contain no network call, and a network hiccup must never participate in deciding whether an action is destructive |
| `POST /v1/tasks/{task_id}/cancel` | not built | Cancellation is local and immediate; the emergency stop must not depend on a round trip |
| `GET /v1/capabilities` | not built | The capability registry is local — `CapabilityRegistry.default`, surfaced to the planner as `ToolRegistry.plannerDescription` inside the system prompt |
| `GET /v1/policies` | not built | The policy and risk engine are local, by the same ground as approvals |
| `GET /v1/account/entitlements` | **kept, same path** | Section 5 |
| `POST /v1/transcriptions` | **kept, same path** | Section 4.4 |
| `POST /v1/screen/analyze` | **kept, same path** | Section 4.5 |

Added beyond §16.2: the auth endpoints (§16.3 requires them; §16.2 never listed them), `/v1/plan`,
`/v1/research/synthesize`, `/v1/search`, `DELETE /v1/tasks/{task_id}`, `DELETE /v1/account`,
`GET /v1/meta` and `GET /v1/health`.

**`DELETE /v1/tasks/{task_id}` reuses §16.2's path space for something else, and that is worth saying
plainly.** There is no task *resource* on this server. `task_id` is a client-minted key that content
and metering are filed under; `DELETE` removes everything filed under it. A reader arriving from
§16.2 should not expect a `GET` on the same path to exist. It does not.

---

## 5. Identity of a task, a session, and an entitlement

### 5.1 `task_id`

`task_id` is `CompletedTaskRecord.id` — the field SONNY-115 adds. It does not exist at `6f89a5d`:
`CompletedTaskRecord` (`TaskHistoryStore.swift:12`) has no identifier, and the type's own comment
says so at `:27`. Until SONNY-115 merges there is nothing to put in this field, which is one reason
the gateway tickets sit behind row D as well as behind this contract.

**The id must be minted when the task starts, not when its record is written.** `CompletedTaskRecord`
is written at completion, so an id that only appears in that initializer's default arrives after
every request the task made. SONNY-115's field takes an id as a parameter, so this is a matter of the
caller passing the dispatch-time id through rather than letting it default — but it is the kind of
thing that is cheap now and expensive after the gateway lands. SONNY-130 and SONNY-131 build the
requests that need it.

A request whose task has no id yet — a path that should not exist after SONNY-130, but might during
it — sends a fresh UUID rather than omitting the field. An unattributed request still has to be
meterable and deletable.

### 5.2 `session_id`

`session_id` is `VisionSessionRecord.id` (`VisionSessionJournalStore.swift:85`, defaulted to
`UUID().uuidString` at `:103`). It already exists, it is already one per screen-control session, and
it is already handed to the interaction layer the moment the session starts
(`VisionSessionRunner.swift:135`) so the task-history row can link to it.

Two properties make it the right choice rather than a convenient one:

- It is minted in the runner's initializer regardless of whether a journal store is wired, so a run
  with "Don't save this task" on — which is implemented by handing the session no journal store —
  still has an id. Metering runs for those runs (section 10.1), and metering needs the key.
- It is created at start rather than at end, for the reason its own doc comment gives: a session that
  is stopped, refused or crashes still did things worth recording.

Per-session screen-control cost, the number SONNY-17's pricing waits on, is the sum of metering
events sharing a `session_id`. That is the whole reason it is on the wire.

### 5.3 The entitlement claim

`GET /v1/account/entitlements` returns a signed claim the client can verify **with no network call**.

```json
{
  "entitlement": "<JWS compact serialization>",
  "expires_at": "2026-08-24T09:41:07Z",
  "refresh_after": "2026-08-17T21:41:07Z"
}
```

The claim's decoded payload:

```json
{
  "v": 1,
  "sub": "<user id>",
  "plan": "<plan key>",
  "capabilities": ["…"],
  "issued_at": "2026-08-17T09:41:07Z",
  "expires_at": "2026-08-24T09:41:07Z",
  "grace_seconds": 0,
  "skew_tolerance_seconds": 0
}
```

- Signed server-side with EdDSA (Ed25519), JWS compact serialization, the signing key named by the
  JWS header's `kid`. The client verifies against a public key set it ships with, and
  `GET /v1/meta` publishes the current set so an online client can learn a rotated key without an app
  update. The shipped set is the offline fallback. Rotation therefore never requires a release, and a
  client that has been offline for a long time still verifies against what it shipped with.
- `capabilities` is a list of opaque capability keys. **Which capabilities are gated is row 18's
  (SONNY-23), not this contract's** — this contract fixes only that they are named strings in a list
  the client reads.
- `grace_seconds` and `skew_tolerance_seconds` are carried **in the claim**, not compiled into the
  app, so the server can change them without a release. Their values are SONNY-135's to set and to
  test at both edges; the contract fixes that they travel here.
- Revocation reaches a live client within the claim's lifetime, because that lifetime is the bound. A
  short lifetime plus a generous grace window gets both properties: a cancelled subscription stops
  working soon, and a user on a plane does not.

#### 5.3.1 Fails closed only for paid or gated features

§16.3, and the default most likely to be inverted by accident. The contract states it as a code
shape rather than a boolean, because a boolean is what gets read backwards:

> **A free local capability never consults the entitlement claim at all.** Not "consults it and
> succeeds"; does not call it. A check that is never made cannot fail closed.

That is stronger than "fail closed for paid features," and it is verifiable: it holds as long as no
free path takes the entitlement check as a dependency. It is also already true of the thing it most
matters for — `InstantCommandResolver` (`InstantCommandResolver.swift`) imports only `Foundation`,
makes no network call of any kind, and returns `.plan(AgentPlan)` directly from local stores.

For a gated capability, with no valid claim and no network, the answer is no. Both directions are
pinned by tests on SONNY-135.

---

## 6. Sizes

### 6.1 Request body limits

Enforced by the server, respected by the client. Measured on the **decoded** body — see 6.4.

| Route | Limit | Where the number comes from |
|---|---|---|
| `POST /v1/screen/analyze` | 4,200,000 bytes | Derived below |
| `POST /v1/transcriptions` | 10 MiB (10,485,760) | Backstop for an unbounded recording, until SONNY-130's duration cap |
| `POST /v1/research/synthesize` | 4 MiB (4,194,304) | Full readable text of every fetched page |
| every other route | 1 MiB (1,048,576) | Typical planner body is tens of KB |

**The screen-control figure, derived rather than borrowed.** The client cannot construct a larger
body. The image is capped at `VisionCaptureEgressPolicy.default.maximumImageBytes = 3,000,000` bytes
(`RedactedCaptureEncoder.swift:92`), which the same constant backs on the client's own refusal
(`VisionModelClient.swift:90`, guard at `:122`). Base64 turns 3,000,000 bytes into exactly
`ceil(3,000,000 / 3) × 4 = 4,000,000` characters. Adding the prompt — 4,673 characters on the
shipping fixture SONNY-114 measured, growing by roughly one history line per iteration across at most
twelve — and about 120 bytes of JSON envelope gives a request at the ceiling of about **4.01 MB**.

Those three inherited figures are SONNY-114's, not this ticket's, and they carry its SHAs: the 4.01 MB
ceiling and the 4,673-character prompt were measured at `e260575` and re-verified after that branch's
rebase at `b07bee8`; the largest JSON body across all fifteen of its fixtures, 3,512,879 bytes, was
measured at `e260575`. The branch merged to `main` at `6f89a5d`, where `maximumImageBytes` is still
3,000,000 — re-verified for this document. 4,200,000 leaves roughly 190,000 bytes of headroom over
the largest body the client can build, which is about forty times the measured prompt.

**The limit is set as low as the client's own ceiling allows, on purpose.** Every byte of headroom
above what the client can actually produce is a byte that eliminates hosts for nothing. Rounding this
up to a comfortable-looking figure would quietly narrow SONNY-125's shortlist, which is a host
decision, and not this document's to make.

**This number and SONNY-114's are one number.** If `maximumImageBytes` ever moves, this limit is
re-derived in the same change. A server limit sized for an old client ceiling is a limit that means
nothing, which is the same failure SONNY-114 fixed on the client side.

**This is the figure SONNY-125 has to prove lands**, at the wall-clock the route needs (section 12).
A host that cannot carry it is not a candidate, whatever else it offers. That is a constraint this
contract places on the host decision, and it is derived from Sonny's own code rather than read off
any host's documentation — which is also why it is not a round number.

### 6.2 Over the limit

The client refuses before sending, as it already does — `VisionModelClientError` is declared at
`VisionModelClient.swift:18-39`, and its `payloadTooLarge` case is thrown at `:123` behind the guard
at `:122`, before the request body is built. The server refuses with `413 request.too_large`,
carrying `limit_bytes` and `actual_bytes` so the refusal is diagnosable.

**The server's limit must be greater than or equal to the client's.** A client that believes its
payload is fine and gets a 413 has a failure it cannot explain to the user, and one it cannot fix by
retrying. The oversize path stays a clear refusal rather than a truncated upload — that reasoning is
recorded in the client's own doc comment and still holds.

### 6.3 Response body limits

Every response is capped at 1 MiB. Nothing any route returns today comes near it: plans, research
notes, transcripts and vision decisions are all small JSON. The cap exists so an unexpected provider
reply cannot become an unbounded client-side allocation.

### 6.4 Compression

The server **must** accept `Content-Encoding: gzip` on requests and must apply size limits to the
decoded body. It must honour `Accept-Encoding: gzip` on responses.

The client does not compress today. SONNY-146 (filed, Backlog) measured 29–35% lossless recovery from
deflating the finished vision body at `e260575`. Requiring the server to accept it now means the
client can adopt it later without touching this contract or its version — which is exactly what
section 8's additive rule is for.

---

## 7. Error taxonomy

### 7.1 The envelope, and the rule about `message`

```json
{
  "error": {
    "code": "entitlement.required",
    "message": "Screen control requires an active plan.",
    "retryable": false,
    "retry_after_seconds": null,
    "request_id": "…"
  }
}
```

**The client never displays `message`.** It maps `code` to its own copy and shows that. `message` is
for logs, for the support lookup, and for a developer reading a response by hand.

This is not style. Sonny's standing rule since 2026-08-14 is that the product does not explain itself
— no how-it-works sentences, no data-sent-to-AI copy, disclosure confined to Safe mode and the
website. A server-authored sentence rendered in the app is a hole straight through that rule, changed
by whoever edits the server, with no review by anyone who knows it. Mapping `code` to client-owned
copy closes it, and it also means an error's wording can be fixed in an app release without a server
deploy, and vice versa, without either surprising the other.

`code` values are stable strings and are part of the versioned contract: changing what one means is a
breaking change (section 8.2).

### 7.2 The taxonomy

The seven cases **SONNY-124's own scoped requirements** name are distinguishable by `code`, not by
status — several share a status on purpose, because HTTP has fewer meanings than this product has
outcomes. (Attribution matters in this repo: the seven-case list is that ticket's scoping language,
not a founder decision. The founder decisions this document carries are the ones marked as such —
the credential boundary, retention, the sign-in set, the provider set, fail-closed-for-gated-only,
delete-everywhere, the "Don't save this task" naming and enforcement, and website-only training
consent.) "What the user gets" describes the outcome, not the literal wording; the wording is
SONNY-128's for sign-in and SONNY-136's for everything else.

| # | Case | Status | `code` | Retryable | Client does | What the user gets |
|---|---|---|---|---|---|---|
| 1 | Not signed in | 401 | `auth.unauthenticated` | no | opens sign-in | Asked to sign in. Nothing about servers or tokens |
| 1a | Access token expired | 401 | `auth.token_expired` | after refresh | refreshes once, retries once | Nothing — this is invisible when it works |
| 1b | Token revoked or reused | 401 | `auth.token_revoked` | no | clears the Keychain entry, opens sign-in | Asked to sign in again |
| 2 | Signed in, not entitled | 403 | `entitlement.required` | no | refuses locally, does not retry | Told this needs a plan they do not have. Row 18 owns what is gated |
| 2a | Entitlement lapsed mid-task | 403 | `entitlement.expired` | no | finishes the step in flight, blocks the next | §16.4's graceful halt: never interrupted between a click and its observation |
| 3 | Over a rate limit | 429 | `limit.rate` | yes, after `Retry-After` | backs off and retries once | Told to try again shortly. Time-bounded, and it clears by waiting |
| 3a | Over a spend cap | 429 | `limit.spend` | no | refuses locally | Told they are out for this period. **No `Retry-After`** — waiting seconds does not fix it |
| 4 | Payload too large | 413 | `request.too_large` | no | refuses, never truncates | Told the screenshot was too big for one request, naming the real problem |
| 5 | Provider unavailable | 502 | `provider.unavailable` | yes | retries with backoff, then gives up | Told Sonny could not reach what it needed. Never a vendor name |
| 5a | Provider timed out | 504 | `provider.timeout` | yes | retries once | Told it took too long |
| 5b | Provider rejected the request | 502 | `provider.rejected` | no | gives up | Told Sonny could not do this one. A retry would fail identically |
| 6 | Backend failure | 500 | `server.error` | yes | retries with backoff | Told something went wrong on Sonny's side |
| 6a | Backend unavailable | 503 | `server.unavailable` | yes, after `Retry-After` | backs off | Same, plus a sense that it is temporary |
| 7 | Network unreachable | *no response* | `client.offline` | yes | falls back to local capabilities | Told they are offline. **Everything that works offline keeps working** |

Also part of the taxonomy:

| Case | Status | `code` | Notes |
|---|---|---|---|
| Malformed request | 400 | `request.invalid` | Includes a missing `retention` (2.4.2) |
| Unknown or foreign task id | 404 | `resource.not_found` | Never means "nothing was stored" (4.6) |
| Idempotency key reused with a different body | 409 | `idempotency.conflict` | Section 9 |
| Client below the minimum supported version | 410 | `version.unsupported` | Section 8.3 |
| Sign-in code wrong, expired or already used | 400 | `auth.code_invalid`, `auth.code_expired`, `auth.code_used` | Three distinct codes because SONNY-127 and SONNY-128 both need to tell them apart |

Case 7 is the only one with no HTTP status, and that is the point: it is not a response, it is the
absence of one. The client synthesises it and must be able to tell it apart from a backend that
answered with a 500 — the first means "everything local still works," the second means "Sonny is up
but this particular thing failed," and telling a user the wrong one of those is a real failure of the
error-handling-is-UX rule. SONNY-136 owns making all four unreachable states distinguishable in the
app.

---

## 8. Versioning

The one part of this contract that is expensive to add later, so it is specified rather than
implied.

### 8.1 What `/v1` means

`/v1` is the major version and it is in the path. Within it, the server may only change things
additively:

- may add a new endpoint
- may add an **optional** request field
- may add a response field
- may add a new `code` to an error family, if it is a *narrowing* of an existing one and old clients
  behave sanely on the family
- may change any value the contract already calls server-controlled: `grace_seconds`,
  `skew_tolerance_seconds`, provider, model, and request-size limits **upward**
- may **lower** a server deadline freely

Two of those carry a bound, because without it an additive change breaks a shipped client:

- **A request-size limit may rise but never fall.** Lowering one turns requests a shipped client
  believes are legal into `413`s it cannot avoid, which is a breaking change however it is dressed.
- **A server total deadline may only rise while it stays below the client timeout section 12 states
  for that route.** Section 12's governing rule — the client's timeout is always longer than the
  server's total deadline — is what makes a slow request surface as a typed `504` rather than as a
  transport timeout the client cannot tell apart from a dead network. Raising a deadline past that
  point silently inverts it for every shipped client. Doing so is a breaking change, and the client
  timeout has to move in the same change to this document.

Clients ignore unknown response fields (2.1). That is what makes all of the above safe.

### 8.2 What counts as breaking

A change is breaking — and therefore needs `/v2`, not a minor bump — if it does any of these:

1. removes or renames a request or response field
2. changes a field's type, or its meaning
3. makes an optional request field required, or a nullable response field non-nullable
4. removes an endpoint, or changes what a path does
5. changes what an existing error `code` means, or reuses a retired one
6. narrows an accepted value set — for example rejecting a `media_type` that used to work
7. adds a new value to a wire enum that a client switches over exhaustively

Item 7 is the trap, so it has its own rule. **Every client-side enum over a wire value carries an
unknown fallback from the first release.** With that, adding a value is additive; without it, adding
a value is a crash or a silent misread in every shipped client. The server may add an enum value in a
minor version only because clients are required to tolerate one.

### 8.3 What an old client is told

`GET /v1/meta`:

```json
{
  "api_version": "1.0",
  "minimum_supported_client": "1.0.0",
  "recommended_client": "1.0.0",
  "upgrade_url": "…",
  "server_time": "2026-08-17T09:41:07Z",
  "entitlement_keys": [ { "kid": "…", "alg": "EdDSA", "public_key": "…" } ]
}
```

A client below `minimum_supported_client` gets **`410 Gone`** with `code: "version.unsupported"` on
every endpoint, including `/v1/meta` itself answering honestly, and an `upgrade_url` in the error
body.

That is the answer to the user who has not updated in six months: a definite, actionable state that
the app can render as "Sonny needs an update" with a button, rather than a parse failure, an empty
plan, or a spinner that never resolves. It is a status the client can recognise without understanding
anything else about the response, which is the property that matters, because by definition this
client predates whatever changed.

The client calls `GET /v1/meta` on launch and on any `410`. It does not call it per request.

### 8.4 Before the cliff

`minimum_supported_client` is a wall. `recommended_client` is a warning, and it exists so nobody ever
hits the wall by surprise.

A client at or above the minimum but below the recommended version gets its requests served normally,
plus `Sonny-Deprecation: true` and `Sonny-Deprecation-Info: <url>` on every response. The app can
prompt an update while everything still works. Raising `minimum_supported_client` past a version that
was never given a deprecation period is itself a breach of this contract.

### 8.5 When `/v2` happens

A new major version is a new path prefix, served **alongside** `/v1`, not instead of it. `/v1` is
retired only after `minimum_supported_client` has moved past every client that speaks it — which
means the deprecation ladder in 8.4 runs first, in full.

The reason this is affordable: the shapes in this contract are Sonny's own and are deliberately thin.
No provider's request shape, response shape, model identifier or error format appears anywhere in
them. So a provider change, a model change, a failover, or a move to a zero-retention vision route
(SONNY-110) never touches the version at all. What forces a version bump is a change to what *Sonny*
means — which should be rare, and which is the only thing worth paying for.

---

## 9. Idempotency

### 9.1 The key

Every `POST` carries `Idempotency-Key: <uuid>`, minted by the client.

**One key per logical operation, not one per attempt.** A retry of a request reuses that request's
key — that is the entire mechanism. A new operation, including the next iteration of a screen-control
session, mints a new one, because a fresh capture is a genuinely different request even though it
looks similar.

### 9.2 What the server guarantees

- The key is stored with its response for **24 hours**. Within that window, a repeat of the same key
  returns the stored response.
- **A metering event is written at most once per idempotency key, ever.** That single sentence is
  what makes a client retry unable to double-bill a user, and it is the reason the key is required
  rather than optional.
- The same key presented with a *different* body is `409 idempotency.conflict`. It is not silently
  treated as new, because the shapes that produce it are a client bug or a replay, and both are
  worth surfacing.
- A key seen while its original request is still in flight gets `409 idempotency.conflict` with
  `retryable: true` and a `Retry-After`, rather than a second upstream call.

### 9.3 What is safe to retry

| Request | Safe to retry | Why |
|---|---|---|
| any `GET` | yes, always | No side effect, nothing metered |
| `POST /v1/plan`, `/research/synthesize`, `/search`, `/transcriptions`, `/screen/analyze` | yes, with the same key | Section 9.2 |
| `POST /v1/auth/refresh` | yes, with the same key | Rotation plus the overlap window (3.3) means a lost response does not cost the session |
| `POST /v1/auth/email/start` | yes, with the same key | Without the key, a retry sends a second code and races the first |
| `POST /v1/auth/email/verify` | **no** | A code is single-use by design (SONNY-127). The idempotency record returns the original *result*, including the original failure; it does not un-consume a code |
| `POST /v1/auth/oauth/google`, `POST /v1/auth/oauth/apple` | **open** | These flows typically carry a single-use provider authorization code, in which case they behave like `email/verify` rather than like `email/start`. SONNY-129 settles it when it settles the body shape (3.6), and records which |
| `POST /v1/auth/signout` | yes | Revoking an already-revoked family succeeds |
| `DELETE /v1/tasks/{task_id}`, `DELETE /v1/account` | yes | Naturally idempotent; a second delete succeeds with `requests_deleted: 0` |

**Retry is decided by `code`, never by status.** Several statuses carry more than one code with
opposite semantics, which is the whole reason section 7's taxonomy keys off `code` — and a client
that retried on status would retry `provider.rejected`, a 502 whose retry is guaranteed to fail
identically.

- Retryable: `limit.rate` (after `Retry-After`), `provider.unavailable`, `provider.timeout`,
  `server.error`, `server.unavailable`, `client.offline`, and `auth.token_expired` after exactly one
  refresh.
- Not retryable: `request.invalid`, `auth.unauthenticated`, `auth.token_revoked`,
  `entitlement.required`, `entitlement.expired`, `limit.spend`, `request.too_large`,
  `provider.rejected`, `resource.not_found`, `idempotency.conflict` on a differing body, and
  `version.unsupported`. Retrying any of these produces the identical failure and burns a round trip.

The one exception to "never by status" is a response with no parseable body at all, which the client
treats as `server.error` and may retry once.

---

## 10. Retention, incognito and consent

### 10.1 `retention`

`"standard"` — the backend retains the full request and response content on the content clock.
`"none"` — the backend meters the call and stores no content from it: no debugging copy, no
analytics record, and never in a training snapshot.

`"none"` is what the app sends for a run started with **"Don't save this task"** on. Two naming
notes, both deliberate:

- The user-facing name is "Don't save this task," and the word "incognito" is not used in any
  user-facing string (founder, 2026-08-16; SONNY-120 records the reasoning — incognito borrows a
  promise from browsers that this feature does not keep, and the usual remedy is a clarifying
  sentence, which the no-explanatory-copy rule forbids). The wire field is not a user-facing string,
  and it does not use the word either.
- The value is `"none"` rather than a boolean because it names what happens at the storage layer,
  which is where the guarantee is enforced.

Two rules the contract fixes and SONNY-134 implements:

1. **Enforced where the storing happens, not at the call site.** A flag the client sets and the
   server is trusted to remember to check is a request, not a guarantee.
2. **Structurally excluded from training snapshots, not filtered by a query.** If an incognito run
   can reach a snapshot because someone dropped a `WHERE` clause, the guarantee is not one.

**Metering runs either way.** Incognito changes what is stored, never what is billed. A metering
design that dropped these events would silently make those runs free, and it is the case most likely
to be dropped by accident — which is why SONNY-133 carries an acceptance criterion for it.

The accepted cost, recorded so it is not later read as a defect: a user reporting that an incognito
run misbehaved cannot be diagnosed from stored data. That is the feature working.

### 10.2 Training consent

`training_consent` is a field on the **user record**, values `"granted"` and `"not_granted"`,
defaulting to `"not_granted"` — so a user whose consent was never written is excluded. SONNY-127 owns
the field and its write path; SONNY-134 makes the snapshot builder honour it.

**It never appears on a request, and never in a response the app reads.** Both halves matter:

- Not on a request, for the same reason `retention` is enforced server-side — a client-supplied
  consent flag is a client-trust decision on the most consequential field in the system.
- Not in a response the app reads, because consent is captured in the website signup flow and never
  as an in-app toggle (founder, 2026-08-16). A toggle would have to explain itself and would collide
  head-on with the no-explanatory-copy rule. An app that can read the state will eventually render
  it.

### 10.3 What is retained, said plainly

The backend retains full request and response content for a bounded 30–90 days — redacted
screenshots, command text, model replies **and voice audio** — for three named purposes: debugging
and support, product analytics, and training or fine-tuning a model. Founder decision, 2026-08-16,
made with the case against it in front of him.

Consequences this contract carries:

- **Voice audio is content.** It is the most personally sensitive of the four types and the one most
  likely to be overlooked because nobody listed it. `POST /v1/transcriptions` carries `retention`
  exactly like every other content route, and its audio lands in the same store on the same clock.
- **Provider error bodies are content too.** An error body that echoes the input is content arriving
  in a field nobody classified. It goes into the content store on the content clock, not into an
  unclassified log. Provider request IDs are kept for correlation.
- **Two clocks, not one.** Raw content on the short end of the range; derived metrics and usage
  indefinitely, since they are what compound in value; training snapshots on their own
  separately-consented lifecycle. This is why the metering event (section 11) holds no content — it
  has to outlive it.
- This is a conscious deviation from §16.5's "Request logging excludes sensitive content by default."
  §16.5's other four requirements are met in full. Recorded as a dated deviation on SONNY-16 and in
  `docs/sonny-founder-design-decisions.md`; not re-litigated here.
- What is retained is the *redacted* content, because redaction runs before anything leaves the
  device and `RedactedPayload` is structurally non-bypassable. Nothing may claim this system does not
  retain screen content. It does. It just does not let the provider do it too.

---

## 11. The metering event

What the server records per call. Not a request field — section 2.4.1 says which parts the client
supplies. It holds no content, so it can outlive content on the longer clock.

| Field | Type | Source | Notes |
|---|---|---|---|
| `event_id` | string | server | |
| `request_id` | string | server | Same value as the `Sonny-Request-Id` header |
| `idempotency_key` | string | client header | One event per key, ever (9.2) |
| `user_id` | string | server | From the authenticated session |
| `occurred_at` | timestamp | server | |
| `route` | enum | server | `plan`, `research.synthesize`, `transcription`, `search`, `screen.analyze` |
| `provider` | string | server | Which provider actually served it. Required for failover accounting (SONNY-132) and never returned to the client |
| `model` | string | server | Server-side only, for the same reason |
| `input_tokens` | int, nullable | provider | |
| `output_tokens` | int, nullable | provider | |
| `total_tokens` | int, nullable | provider | |
| `token_source` | enum | server | `reported` or `estimated`, mirroring `AIUsageTokenSource` (`TaskUsage.swift:20`) |
| `image_bytes` | int, nullable | server | `screen.analyze` only |
| `image_pixel_width` | int, nullable | client | `screen.analyze` only. Vision token cost tracks pixels, not bytes |
| `image_pixel_height` | int, nullable | client | |
| `audio_duration_seconds` | number, nullable | provider or server | `transcription` only. Maps to `AIUsageRecord.audioDurationSeconds` |
| `request_bytes` | int | server | Decoded size |
| `response_bytes` | int | server | |
| `duration_ms` | int | server | Total, server-observed |
| `upstream_duration_ms` | int | server | Time waiting on the provider |
| `outcome` | enum | server | `ok`, `provider_error`, `server_error`, `refused`, `client_cancelled` |
| `task_id` | string, nullable | client | Section 5.1 |
| `session_id` | string, nullable | client | Section 5.2 |
| `session_iteration` | int, nullable | client | |
| `retention` | enum | client | `standard` or `none`. Recorded so an incognito run's *usage* is visible while its content is not |
| `client_version` | string | client header | |

**Per-session screen-control cost** — the figure SONNY-17's credit weight waits on — is the sum over
events sharing a `session_id`. Nothing in the product records it today: `AIUsageCallKind`
(`TaskUsage.swift:3-6`) has exactly three cases, `planner`, `webResearchSynthesis` and
`transcription`, and none is vision. That is not an inference from one file: grepping all thirteen
vision-path files under `Sources/` — `VisionModelClient.swift`, `VisionSessionRunner.swift`,
`VisionSessionEnvironment.swift`, `VisionSessionContainment.swift`, `VisionSessionPromptBuilder.swift`,
`VisionSessionJournalStore.swift`, `VisionSessionCapabilityAdapter.swift`, `VisionSessionTypes.swift`,
`AgentViewModel+VisionSession.swift`, `ScreenCaptureService.swift`, `LocalRedactionService.swift`,
`RedactedCaptureEncoder.swift` and `ScreenActionSynthesizer.swift` — for `usageRecorder`,
`AIUsageRecord` or `TaskUsageRecording` returns zero matches in every one of them at `6f89a5d`. The
four production recording sites in the whole repo are `OpenAIPlanner.swift:82`,
`CerebrasPlanner.swift:97`, `WebResearchSynthesizer.swift:359` and `OpenAITranscriber.swift:102`.

So this shape is defined rather than mirrored from an existing one, and the vision route is the
reason the metering exists.

Two things it must not lose:

- **The local per-task summary keeps working.** `TaskUsageRecorder` feeds
  `AgentViewModel.taskUsageSummary`, a live UI surface. Server-side metering is the billable truth;
  where the two disagree the server is authoritative, and the local summary must not silently go
  blank. SONNY-130 and SONNY-133 both carry this.
- **Usage outlives content.** The two clocks are the point (10.3).

---

## 12. Timeouts

No explicit network timeout exists anywhere in the client today. All six credential-bearing clients
take `session: URLSession = .shared` and none overrides `URLSessionConfiguration` or sets
`URLRequest.timeoutInterval` — so every one of them runs on Foundation's stock defaults, which nothing
in this codebase chose. There is also no retry, no backoff and no shared HTTP client of any kind;
SONNY-128 writes the first one.

The contract states both sides, and the governing rule is one line:

> **The client's timeout is always longer than the server's total deadline.**

So the client sees the server's typed `504 provider.timeout` — which it can explain — rather than its
own opaque transport timeout, which it cannot tell apart from a dead network.

| Route | Server upstream deadline | Server total deadline | Client timeout |
|---|---|---|---|
| `POST /v1/screen/analyze` | 90 s | 105 s | 120 s |
| `POST /v1/research/synthesize` | 90 s | 105 s | 120 s |
| `POST /v1/plan` | 60 s | 75 s | 90 s |
| `POST /v1/transcriptions` | 60 s | 75 s | 90 s |
| `POST /v1/search` | 20 s | 25 s | 30 s |
| auth, account, meta, health, delete | 10 s | 15 s | 20 s |

The vision and synthesis routes get the longest budgets because they genuinely take longest: a vision
call carries megabytes upstream and waits on a large model, and a session spends up to twelve of them
in sequence.

**These deadlines constrain the host exactly as section 6.1's size limit does, and for the same
reason.** A platform that terminates a request before its route's total deadline turns a slow-but-
working model call into a failure the user experiences as Sonny giving up. So SONNY-125 has two
things to prove and not one: that a 4,200,000-byte body lands, and that a request may sit for 105
seconds waiting on a deliberately slow upstream without the platform cutting it off. Both numbers are
derived from what Sonny does — the payload from the client's own encoder ceiling, the deadline from
how long a large vision model actually takes — and neither is read off any host's documentation. That
ticket's own scoped requirements already ask for both measurements; this is the contract stating what
the answers have to clear.

Three rules alongside the table:

- **Cancellation beats every timeout.** The emergency stop and any user cancellation cut the client
  request immediately, without waiting for a deadline. That path must never route through the
  network.
- **A cancelled request may still have cost money.** If the server observed the upstream call
  complete, it writes a metering event with `outcome: client_cancelled`. Silently free cancellations
  would be a hole in the spend cap.
- **Mid-loop failure is decided, not discovered.** A `5xx` or a token expiry between iteration 4 and
  5 of a twelve-iteration session has to have a chosen behaviour. The contract fixes the inputs — the
  error is typed, `auth.token_expired` is refresh-and-retry-once, `provider.unavailable` and
  `server.error` are retryable, `provider.rejected` is not, and there is no server-side session state
  to resume from. **Which of retry, abort-with-partial-history, or a new typed error the session
  takes is SONNY-131's**, and it is required to pick and pin it with a test rather than let it
  emerge. Today there is no retry at all: `VisionSessionRunner.runLoop()` has no `catch`, so a single
  throw from `decide` (`VisionSessionRunner.swift:261`) ends the session on that iteration.

---

## 13. What this contract deliberately leaves open

Each item is genuinely undecided, and each names the ticket that closes it. Nothing here is a gap
that was overlooked.

| Open | Owner |
|---|---|
| The host, and proving a 4,200,000-byte body lands on it, and that a request may sit 105 s on a slow upstream | SONNY-125 |
| **Who builds `GET /v1/meta`, the `410 version.unsupported` gate, and the deprecation headers** | **nobody yet** — SONNY-155, Backlog, untriaged (4.1) |
| Whether the OAuth sign-in calls are replay-safe (9.3) | SONNY-129, alongside the body shape |
| Server language, framework, database, deploy path, migrations, credential rotation | SONNY-126 |
| The per-user spend-cap mechanism, and what happens when two requests from one user race it | SONNY-125 names it, SONNY-135 implements it |
| The identity-linking rule, and how it survives Hide My Email relay addresses | SONNY-127 |
| Sign-in code lifetime, rate limits, and the refresh overlap window's length | SONNY-127 |
| Literal user-facing copy for every `code` in section 7 | SONNY-128 (sign-in), SONNY-136 (everything else) |
| The audio duration cap and its refusal | SONNY-130 |
| Vision mid-loop failure behaviour: retry, abort, or a new typed error | SONNY-131 |
| Failover trigger, fallback order, and whether the user is told | SONNY-132 |
| Per-provider retention and training configuration values | SONNY-132, with SONNY-110's answer landing in it |
| The exact retention window inside 30–90 days | SONNY-134 |
| Snapshot lineage's concrete shape, and what the support lookup may see | SONNY-134 |
| `grace_seconds` and `skew_tolerance_seconds` values | SONNY-135 |
| Which capability keys are gated | SONNY-23 (row 18) |
| Plans, prices, allowances, credit weights | SONNY-17 (row 13) |
| Whether requests are compressed on the wire | SONNY-146 |
| Enterprise or team entitlements | SONNY-107 (row 19) |

---

## 14. Changes to this document

Append-only, newest last. A change here is a change to what twelve tickets were written against, so
it carries a date, a reason, and the ticket that prompted it.

The log starts once the document is merged. Iteration inside SONNY-124's own branch — including its
pre-merge review round — is part of "created" and does not get a row; a changelog that recorded the
author's own drafting would bury the changes a downstream session actually has to notice.

| Date | Change | Ticket |
|---|---|---|
| 2026-08-17 | Created, at `main` `6f89a5d` | SONNY-124 |
| 2026-08-21 | **3.1 — the access token is a JWT rather than opaque.** Founder decision of 2026-08-21 to serve auth from Supabase Auth, which issues JWTs. The client's obligation not to decode it or decide anything from it is unchanged and is now carried by this contract rather than by the encoding. Three things this does **not** change, checked against the platform rather than assumed: 3.3's rotation, overlap and reuse detection are exactly what Supabase Auth does (10-second reuse interval; reuse beyond it revokes the whole family), 3.2's response shape is unchanged, and 3.6's three code failures are unchanged — the gateway derives them from its own issuance record because the provider returns one error for all three. | SONNY-127 |
