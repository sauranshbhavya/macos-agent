# Sonny backend API contract, v1

The agreement between the Mac app and the backend. Written for SONNY-124, against `main` at
`4a7d996`. Every file:line and every measurement below was taken at that SHA and re-verified there;
the tree will move, so re-check before relying on one.

**Which half of this document you are reading matters, and it is stated here rather than left to be
inferred** (added 2026-08-26, SONNY-288). Three kinds of text live in it and they age differently:

- **Live contract.** The shapes — endpoints, request and response bodies, headers, error `code`
  values, the versioning rule, idempotency, retention, the metering event and the timeout table.
  These bind whatever the tree looks like, and every change to one is a dated row in section 14.
- **A dated snapshot of the client.** Every `file:line` and every measured figure outside section 14
  was read at `4a7d996` **unless it stamps a SHA of its own**, and says nothing about the tree since.
  A citation that has moved is a stale reading, not a changed contract. **Five SHAs were cited
  outside section 14 at `554d85a`** (`git show 554d85a:docs/sonny-backend-api-contract.md | sed -n
  '1,/^## 14\./p' | grep -ohE '\b[0-9a-f]{7,40}\b' | sort -u | wc -l` → 5; `grep -P` answers the same,
  and the pattern also catches the odd hex-shaped word, so read it as an upper bound), **and 10.2's
  divergence record makes `554d85a` itself the sixth** — the same command without the `git show`,
  over whatever tree you are reading, is what says how many there are now. Of the six, **exactly one
  is not on `main`**: `e260575`, in 6.1 and 6.4, a branch head a rebase replaced — which is why 6.1
  pairs it with the post-rebase `692c904`. It still resolves, so `git show` on it proves nothing; the
  check that separates the two cases is `git merge-base --is-ancestor <sha> origin/main`, read with
  nothing between it and `$?` (`for t in 728d1ea 4a7d996 692c904 e260575 6b72909 554d85a; do git
  merge-base --is-ancestor $t origin/main; echo "$t $?"; done` → `0`, `0`, `0`, `1`, `0`, `0`, run
  2026-08-27). **This sentence said four until 2026-08-27, and the miss is worth naming rather than
  absorbing**: `6b72909` had been added to 4.4 that morning by SONNY-130's own commit — section 14's
  preamble names it — without this sentence or its loop moving with it, so the document's account of
  itself had stopped matching the document, which is the same class of omission section 14 was
  back-filled for on the same day (SONNY-297). The sixth, `554d85a`, is not a miss; it is the stamp
  10.2's divergence record was added under. **This sentence broke its own count once while being
  written**, by naming that commit here rather than in section 14: a commit citation belongs to that
  section's kind and not to this one's, and running the command beside the number is what said so.
  That is this repository's convention working: a branch SHA records *when* a figure was measured,
  not a tree anyone is expected to fetch.
- **Section 14 cites more, and they are a different kind of citation.** From the back-fill of
  2026-08-27 onward every row names the commit the change landed in — where a change happened, not
  where a figure was read — and those are counted and ancestry-checked in that section's own
  preamble rather than in the count above.
- **A live board reading.** Section 13's table, and every sentence in the body that says a question
  is some ticket's to answer. These describe who owes what, so they go stale as tickets close.
  Section 13 carries the date it was last resolved against the board; read any owner named in the
  body against that same date.

**This document is host-agnostic.** No requirement in it comes from any hosting platform's published
limits, and nothing in it presumes where the server runs. The host choice was deliberately held when
this was written (SONNY-125, gated on SONNY-114); **it was made on 2026-08-21 and nothing here
changed** (updated 2026-08-26, SONNY-288) — the gateway runs on a VM, staged Oracle Cloud then AWS,
with Supabase keeping auth and Postgres (`docs/sonny-row-12-host-decision.md` §12.4, and section
13's first row). **That staging read deploymind → Oracle → AWS until 2026-08-30, when the founders
dropped the deploymind stage (SONNY-373) — and no requirement here changed then either**, which is
the same property holding a second time. Host-agnosticism is the property that made that survivable,
so it is kept rather than spent. Where a number here constrains the host, it is derived from Sonny's
own code and says so.

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

| Client type | Credential today | file:line at `4a7d996` (key, endpoint, send) | Endpoint |
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

| Client type | Send sites at `4a7d996` | Reaches |
|---|---|---|
| `HackerNewsService` | `:46`, `:55` | `hacker-news.firebaseio.com` |
| `MediaPlaybackService` | `:652` | `itunes.apple.com` |
| `WebResearchService` | `:275`, `:309` | whatever page the command names, plus its `robots.txt` |

**`AgentViewModel.swift` is not a network call site**, despite spec §16.5's migration note (spec line
2153) naming it. Enumerated rather than asserted: at `4a7d996` the file's only `URLSession`- or
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
  **Verification of a presented access token — signature and expiry — exists as of SONNY-203**
  (built 2026-08-22; the gap was noted 2026-08-21 as PR #87 F2, and its owner corrected from
  SONNY-128 the same day, PR #87 second round F5 — SONNY-128 is the client half and its never-touch
  list forbids `server/`, so it could never have supplied this). SONNY-127 issued tokens and supplied
  the skew tolerance that verification applies; no route on that branch verified one. SONNY-203
  verifies the Supabase token as **HS256 with the algorithm pinned**, checking `iss`, `aud` and
  `exp`, and trusting `sub` as the user id — then attributes that `sub` to a live Sonny account, so a
  cryptographically perfect token naming a closed one is refused. **The gate is deny-by-default**:
  §4.1's `Auth` column is a list of the routes that are *public*, and everything else is challenged,
  so a route added without a thought about authentication refuses everyone rather than serving
  quietly. **What verification cannot do is un-issue a token**: an access token is self-contained, so
  signing out revokes the refresh family while the access token keeps verifying until its own `exp`
  plus the 30-second skew tolerance of §3.5 — one hour and thirty seconds on Supabase's default
  lifetime. A closed account is refused immediately on every request; the
  remaining window is SONNY-237's.
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

**The concrete skew tolerance is set, and it is 30 seconds** (updated 2026-08-26, SONNY-288). This
line said it was SONNY-135's to set, which section 3.1 already contradicted by citing "the 30-second
skew tolerance of §3.5". SONNY-127 supplied the value and SONNY-203 applies it to every verified
access token: `export const EXPIRY_SKEW_TOLERANCE_SECONDS = 30;`
(`grep -n 'EXPIRY_SKEW_TOLERANCE_SECONDS = ' server/src/auth/clock.ts` → `34:` at `728d1ea`). The
mechanism was fixed here so SONNY-127 and SONNY-135 would use the same one, and they do.

**This is not section 5.3's `skew_tolerance_seconds`.** That is a separate value carried inside the
entitlement claim, it is still SONNY-135's to set, and section 13 keeps them as separate rows —
conflating the two is how a set value gets read as an open question, which is what this line was.

### 3.6 The auth endpoint shapes

`POST /v1/auth/email/start` — request a sign-in code.

```json
{ "email": "…" }
```
```json
{ "request_id": "…", "expires_in": 600 }
```

**The response is identical whether or not that address has an account.** An endpoint that answers
differently is an account-existence oracle for anyone who finds it. Code lifetime and the
per-address and per-source rate limits were SONNY-127's, **and it set them** (updated 2026-08-26,
SONNY-288): a code lives 600 seconds, which is the `expires_in` above
(`grep -n 'CODE_LIFETIME_SECONDS = ' server/src/auth/codes.ts` → `33:` at `728d1ea`), and the four
limits are 3 per address per 15 minutes and 10 per source per hour on this route, 5 per address per
15 minutes and 30 per source per hour on `email/verify`
(`grep -nE 'export const CODE_(REQUEST|VERIFY)_PER_(ADDRESS|SOURCE)' server/src/auth/ratelimit.ts`
→ 4 lines, `36`, `37`, `50`, `79`, at `728d1ea`). An unlimited code endpoint would have been a free
email-sending service for whoever found it.

`POST /v1/auth/email/verify` — exchange a code for tokens.

```json
{ "email": "…", "code": "…" }
```

Returns the token response of 3.2 on success. On failure it returns one of three distinct codes —
`auth.code_invalid`, `auth.code_expired`, `auth.code_used` — because SONNY-127 has to rate-limit them
differently and SONNY-128 has to say three different things to the user.

**Amended 2026-08-22 (SONNY-127, PR #87 fifth round, F1): the three distinct codes are disclosed
only to a caller who can be seen to have requested the code.** Everyone else gets
`auth.code_invalid`.

The reason is that the three codes *are* an account-existence oracle, and it was a working one. One
unauthenticated request per address, carrying a code known to be wrong and never calling
`email/start`, returned `auth.code_used` for a mailbox whose owner had signed in — something the
caller did not cause and could not otherwise observe — `auth.code_expired` for a mailbox that had
asked and never used, and `auth.code_invalid` for an address with nothing. Reproduced against a real
database. The signal also never decayed (still `auth.code_used` after 400 simulated days) and nothing
bounded enumeration (200 distinct addresses probed from one source, 0 refused).

**Two conditions gate the disclosure**, and both are about the caller rather than the code: the
issuance's recorded source must match the caller's, and the issuance must be recent — one code
lifetime past its expiry. The per-source rate limit `email/start` has always had is now on this route
too.

**What this narrows.** SONNY-127's acceptance criterion — "an expired code, a reused code, and a
wrong code each fail with the contract's distinct errors" — held for every caller and now holds for
the caller it was written about: the one completing a sign-in, who is the only party SONNY-128 has to
say three different things to. A caller who cannot be seen to have asked for the code is told
`auth.code_invalid`, which is true of what they are holding. **The client contract is unchanged**: a
client in the flow sees exactly what it saw before, so nothing on SONNY-128 changes.

**What it does not close, stated rather than implied, and widened 2026-08-22 after measurement.**
The match is on a salted hash of `request.ip` — unforgeable over the wire, and still a statement
about *where* a request came from rather than *who* sent it. Two sizes:

- **Even with `TRUSTED_PROXIES` set correctly**, everyone behind one public address shares a source.
  A co-tenant on a victim's NAT who knows the victim's address learns, within the disclosure window,
  whether that mailbox consumed its code. Household and office are the small version; a carrier's
  CGNAT egress or a shared VPN exit is the large one. Narrower than the oracle this closed, and real.
- **With `TRUSTED_PROXIES` unset behind a proxy**, every caller collapses to one source and the match
  is vacuous deployment-wide — the same misconfiguration the per-source rate limit degrades under.

The recency bound applies in both. **The unconditional fix is a flow token**: `email/start` returning
an opaque value that `email/verify` echoes back, which ties disclosure to *this exchange* rather than
to a network location. Two request/response shapes, landing on SONNY-128; not built, and the lever if
the residual above is ever judged too wide.

**The per-address rate-limit refusal is gated the same way** (added 2026-08-22). Answering `429` to
every caller made the attempt *count* readable — probe a mailbox and see how many tries you get
before the wall — which is recent activity at an address the prober neither caused nor could
otherwise observe. A caller who asked for the code still gets `429` with `Retry-After`; everyone else
gets the `400` a wrong code produces. The body and status now match; the *timing* does not, because
the refused path skips the provider call, and that residual is the same one `email/start`'s silent
per-address refusal already carries.

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
response of 3.2. **Neither lands on an existing account on the strength of an email address**
(corrected 2026-08-26, SONNY-288). This sentence said both "land on the same account as an email
sign-in for the same person", which the `link_hint` table directly above it already contradicted.
Under the rule SONNY-127 built, and the founder's decision of 2026-08-22 that rule 2 flags rather
than links, a verified non-relay match creates a **new** account and returns
`verified_email_matches_existing_account`; a Hide My Email relay matches nothing and returns
`relay_address_may_belong_to_existing_account`; and rule 4 — a sign-in completed while already
authenticated on the target account — is the only path that joins two existing accounts
(`docs/sonny-identity-linking-rule.md` §1 and §4). This contract fixes the paths and the response so
the sign-in surface does not have to be rebuilt when they arrive.

`POST /v1/auth/refresh` — `{ "refresh_token": "…" }`, returning the token response of 3.2 with a new
refresh token. Rotation, overlap and reuse detection are in 3.3.

`POST /v1/auth/signout` — no body. Revokes this session's refresh-token family server-side and
returns `204`. The client clears its Keychain entry and touches nothing else (3.3).

**The access token presented here stops working too, from the next request** (SONNY-237). It used to
keep verifying until its own `exp` plus the skew tolerance of 3.5 — an hour and thirty seconds on
Supabase's default — because an access token is self-contained and the gateway verifies it locally.
The gateway now records the token's session and refuses it on every authenticated route with
`401 auth.token_revoked`, which 7.2 already defines as "clears the Keychain entry, opens sign-in".
No shape moved and no code was added; a state that used to be served is now refused. **This route
itself stays reachable with such a token**, deliberately: the revocation is recorded before the
provider is called, so a retry of a sign-out that answered `502` or `504` — both retryable under 9.3
— must not meet the record its own first attempt wrote. **And a token that carries no session claim
cannot be covered**: the provider omits the claim in some cases, and such a token keeps the window
above.

**A provider that cannot be reached answers `502 provider.unavailable` here, not `204`** (SONNY-311).
`204` would assert a revocation that did not happen: the family is still live at the provider, so a
refresh token in someone else's hands can still mint access tokens against the project. A provider
that *rejects* the token is different and still answers `204` — an already-invalid token means the
family is already gone, which is the state the caller asked for. The client clears this Mac either
way, so the `502` strands nobody; what it adds is that the client can tell the two apart. `refresh`
answers the same `502` for the same condition, which `email/verify` already did.

`GET /v1/health` — liveness and a build identifier, unauthenticated. Its shape was SONNY-126's, and
that ticket closed on 2026-08-21 having built it: `{ "status", "version", "environment" }` with
`Cache-Control: no-store` (updated 2026-08-26, SONNY-288;
`grep -n 'app.get("/v1/health"' server/src/routes/health.ts` → `29:` at `728d1ea`). It is listed
here only so nobody adds a second one.

---

## 4. Endpoints

### 4.1 The set

| Method and path | Auth | Purpose | Owner |
|---|---|---|---|
| `GET /v1/meta` | none | Version negotiation, entitlement verification keys, server time | SONNY-204 — see below |
| `GET /v1/health` | none | Liveness and build identifier | SONNY-126 |
| `POST /v1/auth/email/start` | none | Request a sign-in code | SONNY-127 |
| `POST /v1/auth/email/verify` | none | Exchange a code for tokens | SONNY-127 |
| `POST /v1/auth/oauth/google` | none | Sign in with Google | SONNY-129 |
| `POST /v1/auth/oauth/apple` | none | Sign in with Apple | SONNY-129 |
| `POST /v1/auth/refresh` | refresh token in body | Rotate tokens | SONNY-127 |
| `POST /v1/auth/signout` | yes | Revoke this session's family | SONNY-127 |
| `GET /v1/account/entitlements` | yes | Fetch the signed entitlement claim | SONNY-135 |
| `GET /v1/account/credits` | yes | How many screen-control runs are left this period | SONNY-212 |
| `PUT /v1/account/credits/auto-top-up` | yes | Turn automatic top-ups on or off | SONNY-215 |
| `POST /v1/account/credits/top-up` | yes | Buy one more pack of screen-control runs | SONNY-215 |
| `DELETE /v1/account` | yes | Delete the account and everything under it | SONNY-127, SONNY-134 |
| `POST /v1/plan` | yes | Planner | SONNY-130 |
| `POST /v1/research/synthesize` | yes | Web-research synthesis | SONNY-130 |
| `POST /v1/transcriptions` | yes | Voice transcription | SONNY-130 |
| `POST /v1/search` | yes | Web search | SONNY-130 |
| `POST /v1/screen/analyze` | yes | Screen control | SONNY-131 |
| `DELETE /v1/tasks/{task_id}` | yes | Delete this task's retained content | SONNY-134 |
| `DELETE /v1/tasks` | yes | Delete several tasks' retained content in one call | SONNY-404 |
| `DELETE /v1/tasks/{task_id}/screenshots` | yes | Delete this task's screenshots and nothing else | SONNY-404 |
| `DELETE /v1/account/content` | yes | Delete everything retained for this account at or before an optional `before`; the account stays open | SONNY-404 |
| `POST /v1/billing/checkout` | yes | Where to send this account to subscribe | SONNY-211 |
| `POST /v1/billing/webhook` | HMAC signature over the raw body, not a Bearer token | Subscription lifecycle from the payment provider | SONNY-211 |
| `POST /v1/billing/portal` | yes | Where to send this account to manage an existing subscription | SONNY-216 |
| `GET /v1/billing/payment-state` | yes | Whether a payment failure is outstanding on this account | SONNY-380 |

**`GET /v1/account/credits` was served from SONNY-212 and was missing from this table until
2026-09-03** (SONNY-215). It is listed now, beside the two routes that would otherwise have
documented a feature whose read half was undocumented. The omission is worth a sentence rather than
a silent fix, because this table is not a convenience: §2.2 names its `Auth` column the single
source of truth for which endpoints carry a Bearer token, and `server/src/auth/gate.ts`'s
deny-by-default list is derived from it — so a served route absent here is the same invariant the
paragraph below states, failing in the other direction. Nothing about the route changed; it has been
authenticated and challenged since it shipped, which `gate.test.ts`'s population scan asserts.

**`POST /v1/billing/webhook` is the one row in this table no client ever calls, and its `Auth` cell
says a mechanism rather than `yes` or `none` for that reason** (added 2026-08-30, SONNY-211). Every
other endpoint here is the Mac talking to the gateway, which is the boundary §1.1 draws. This one is
the payment provider talking to the gateway: it carries no `Authorization` header, and it is not
public either — it is authenticated by an HMAC signature over the exact bytes of its body, and a
delivery that fails that check is refused before anything reads its payload. It is listed here
because §2.2 makes this column the single source of truth for which endpoints carry a Bearer token,
and `server/src/auth/gate.ts`'s deny-by-default list is derived from it: a route absent from this
table and present in that list would make the gate's own stated invariant false. **It is deliberately
absent from §2.2's convenience list**, which exists so a *client* does not attach an access token to
a call made before it has one — no client makes this call, and naming it there would invite one to
try.

**`GET /v1/meta` and the version gate had no owning ticket when this section was written. They have
one now: SONNY-204** (updated 2026-08-26, SONNY-288). Writing section 8 is what exposed the gap.
SONNY-126 builds "one health endpoint that returns a version identifier" and its non-goals say "any
endpoint beyond health" explicitly, so `/v1/meta` was outside it; and pulling all fourteen row-12
tickets and searching them for `/v1/meta`, `api_version`, `minimum_supported_client`,
`version.unsupported` and `Sonny-Deprecation` returned nothing outside this document. Three things
therefore needed an owner: the endpoint itself, the middleware that answers `410 version.unsupported`
on every route, and the deprecation headers. That was filed as **SONNY-155**, a triage ticket, which
closed on 2026-08-21 handing all three to **SONNY-204** ("Gateway: GET /v1/meta, the version gate,
and the deprecation headers"). **All three are built** (2026-09-03, SONNY-204):
`server/src/routes/meta.ts` serves the endpoint, `server/src/version/gate.ts` is the `410` gate and
section 8.4's headers, and `server/src/version/policy.ts` is the version arithmetic under both. The
sentence that stood here — "SONNY-204 sits in Backlog and none of the three is built, so every
statement section 8 makes about them still describes work that has not started" — was true when it
was written on 2026-08-26 and is the record of the gap that ticket closed. **The client half of 8.3
is not built and is SONNY-402**: the Mac sends `Sonny-Client-Version` and already decodes
`version.unsupported` into a typed error, and it neither calls `/v1/meta` nor reads the deprecation
headers nor renders a too-old state.

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
44.1 kHz, `AVAudioQuality.high` (`AudioCommandRecorder.swift:34-39` at `6b72909`). It had **no
maximum duration** until SONNY-130, which is why the byte limit in section 6.1 exists as a backstop.

**The duration cap now exists** (updated 2026-08-27, SONNY-130): 180 seconds, in
`VoiceRecordingLimit.maximumDurationSeconds`, refused on the Mac before a byte is sent and shown as
"That recording is too long. Sonny listens for up to 3 minutes at a time." The recorder also bounds
the *file* a few seconds above that, so a hotkey that sticks cannot grow one without limit. Section
6.1's 10 MiB is unchanged and is now the backstop it was always described as: the two sides measure
different units on purpose, because the Mac is the only side that knows a duration honestly — a
client-supplied one would be a client-trust decision on the field that decides the bill, which 2.4.1
forbids in general — and at this recorder's bitrate 180 seconds is roughly 2 MB, so the client's cap
binds an order of magnitude before the server's.

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
  trained on. **Built by SONNY-134 on 2026-08-28**: the delete removes the live content and every
  `sonny.training_snapshot_member` copied from it in one transaction, and records which snapshots
  lost rows in `sonny.content_deletion`. This contract fixes that the path exists and is reachable
  from the app rather than being an internal admin operation — which it is, as an ordinary
  authenticated route on the same gate as every other. **The app calls it since SONNY-333**
  (2026-09-03), so "delete means deleted everywhere" is now true of the button as well as of the
  endpoint. It is called from a queue rather than from the press: `AgentViewModel.deleteTask` writes
  the task id to `pending-server-deletions.json` *before* it deletes the three local records, then
  fires a delivery pass that does not block the button, and `AppDelegate` sweeps whatever is left at
  the next launch. That ordering is the founders' decision of 2026-08-30 — delete locally at once,
  queue the server delete, retry it — and the queue is what makes a delete performed offline or
  signed out still reach here. **Three other deletions in the app still stop at the Mac** and are
  SONNY-404's: the whole local-data wipe, the Memory Task-history row's Delete, and "Delete what
  Sonny did on screen", which cannot use this route at all because this route takes a task's whole
  content and that button names one part of it.
- **A task with nothing stored returns success, not 404**, with `requests_deleted: 0`. An incognito
  run, or a task that ran before the user signed in, has no server-side content — and a delete that
  is already true must not surface as an error the user has to interpret.
- `404 resource.not_found` is reserved for a `task_id` that belongs to a different user. It never
  means "nothing was stored."

The same path serves a user's data-deletion request, so it is needed twice over. `DELETE /v1/account`
reaches everything this reaches, plus the account record.

### 4.6.1 `DELETE /v1/tasks`

```json
{ "task_ids": ["…", "…"] }
```

```json
{ "deleted_at": "2026-09-05T09:41:07Z", "tasks_deleted": 2, "tasks_not_found": 0, "requests_deleted": 5 }
```

Everything 4.6 says about one task, said about several in one request (SONNY-404). It is an
**additive** change under 8.1: a new endpoint, no existing path's behaviour altered, no field
removed or renamed, no error `code` given a new meaning. The one thing 8.2 would have caught is
absent by construction — neither route adds a value to an enum a client switches over.

- **The Mac's *Memory › Task history › Delete* is what this exists for.** That control removes every
  history row at once, and the founder decided on 2026-09-05 that it queues one bulk call rather
  than one call per row. The client's queue is the reason it has to be one: it holds 200 obligations
  and a history holds up to 10,000 rows, so one obligation per row would silently drop the
  difference at the single press that asks for the most.
- **`task_ids` holds 1 to 10,000 identifiers**, each 1 to 200 characters after trimming, and the
  ceiling is the Mac's own history cap rather than a number chosen here. An empty array, a missing
  field or a longer list is `400 request.invalid`. The body is under 6.1's 1 MiB default for every
  route that does not name its own — roughly 400 KB at the ceiling.
- **A `task_id` belonging to a different account is skipped and counted in `tasks_not_found`; the
  call still succeeds.** 4.6 answers one foreign id with a `404`, and the batch equivalent of
  refusing outright would let one stale id on a Mac two people have signed into strand every other
  deletion in the client's queue for good. The client reads a non-zero `tasks_not_found` exactly the
  way it reads 4.6's `404` — not deliverable by *this session*, never not deliverable — and keeps
  the obligation.
- **`tasks_deleted` counts the submitted ids this account owns or that this gateway has never heard
  of.** Both are settled: 4.6's rule that a task with nothing stored is a success rather than a
  `404`, applied per id. `requests_deleted` is 4.6's field summed across the batch.
- **It records what the same deletions performed one at a time would record**: one
  `sonny.content_deletion` row per task, with that task's own counts and its own snapshot lineage,
  including a row of zeroes for a task that stored nothing. A summary row would make the record of a
  wipe read differently from the record of the same act performed slowly.

**It carries its body on a `DELETE`, and that is a constraint on the host rather than a detail.** An
intermediary that strips a `DELETE` request body turns every call to this route into a
`400 request.invalid` that no client can avoid — so it is one more thing SONNY-125 has to prove of a
candidate host, beside 6.1's payload size and 12's wall-clock. The alternative considered was
`POST /v1/tasks/delete`, which 9.1 would then oblige to carry an `Idempotency-Key` for an operation
9.3 already calls naturally idempotent: a key whose only job would be to stand in for a lost response
that costs nothing to ask for again.

### 4.6.2 `DELETE /v1/tasks/{task_id}/screenshots`

```json
{ "task_id": "…", "deleted_at": "2026-09-05T09:41:07Z", "screenshots_deleted": 2 }
```

The narrowest of the three deletes: it clears this task's redacted screenshots — the live rows and
every training-snapshot copy of them — and touches nothing else the task said (SONNY-404). Additive
under 8.1 on the same terms as 4.6.1.

- **It exists because 4.6 is too wide for the button that needed it.** The Mac's *Delete what Sonny
  did on screen* removes one task's vision-session record and leaves the task, its command and its
  result standing. Pressing 4.6's route there would have deleted the request text and the served
  responses too, which is more than that control says. The founder decided on 2026-09-05 for this
  route rather than for a button whose words stop claiming server reach, on the ground that
  screenshots are the most sensitive content this gateway holds and that snapshot copies of them
  carry no expiry today (10.3, and `expireSnapshots` skipping a NULL `expires_at`).
- **A clear, not a delete.** The row survives with `screenshot` and `screenshot_media_type` set to
  NULL; the media type goes with the image because a media type beside a NULL image describes
  nothing and would be the one surviving trace of what was captured. `screenshots_deleted` counts
  live rows cleared. The snapshot copies cleared beside them are in the gateway's own
  `sonny.content_deletion` record rather than on the wire, under a `reason` of its own and counters
  of its own — filed under `task` it would say the whole task was deleted, and counted in
  `content_rows` it would change what that column means for every reader that predates this route.
- **The three answers are 4.6's, unchanged**, because they are about ownership rather than about
  what is removed: `404 resource.not_found` for a `task_id` belonging to a different account, `200`
  with `screenshots_deleted: 0` for a task this gateway never stored, and the clear scoped by
  account whatever the ownership read said.

### 4.6.3 `DELETE /v1/account/content`

```json
{ "deleted_at": "2026-09-05T09:41:07Z", "requests_deleted": 34, "stored_responses_deleted": 2 }
```

Everything this account has stored — live content, every training-snapshot copy of it, and the
response bodies §9.2 keeps for twenty-four hours — and **the account stays open** (SONNY-404).
Additive under 8.1: a new endpoint, no existing path's behaviour altered, no field removed or
renamed.

- **This is the Mac's "Delete Sonny local data", which is a promise about the account.** Founder
  decision 2026-09-04, restated 2026-09-05 after a coordinator's question had briefly reversed it.
  That press deletes what the Mac holds and what this route reaches, and its own words say so in
  both states.
- **It closes nothing, which is the whole line between this route and `DELETE /v1/account`.**
  Closing an account is a different promise with no control in the app today: identities,
  entitlement and usage are untouched here, and the user keeps using Sonny straight afterwards.
  §10.3's long clock is why usage survives — `sonny.metering_event` holds no content and is the
  record of what the account was billed for.
- **There is no identifier on this path**, deliberately. The account comes from the token the gate
  already verified, so there is nothing here for a client to get wrong and no shape in which this
  Mac could name another account.
- **`?before=<RFC 3339 instant>` is optional and bounds what is deleted to content that happened at
  or before it.** Absent, the route deletes everything, which is what it did before this parameter
  existed — so it is additive under 8.1's "may add an **optional** request field" and a shipped
  client that sends none behaves identically. An unparseable value is `400 request.invalid`.
  Each table is bounded on its own notion of when the content happened: `occurred_at` on the live
  row, `source_occurred_at` on the training-snapshot copy, and `claimed_at` on a stored response
  body. **It exists because the Mac may deliver this delete long after the press**: its wipe queues
  an obligation when the gateway is unreachable, and without a bound that delivery would take content
  the user created *after* the press, which the press never promised. The client sends the instant of
  the press.
- **Safe to repeat**, which is what lets the Mac retry it from its queue: a second call finds nothing
  and answers `200` with zeroes. It is `404`-free for the same reason 4.6 is: a delete that is
  already true is not an error.
- **It records itself under a reason of its own.** `sonny.content_deletion` already carries `account`
  for a *closed* account's wipe, and filing this under that value would make every earlier content
  wipe read as a close the day the user does close their account.

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
`GET /v1/meta`, `GET /v1/health`, and SONNY-404's three, `DELETE /v1/tasks`,
`DELETE /v1/tasks/{task_id}/screenshots` and `DELETE /v1/account/content`.

**`DELETE /v1/tasks/{task_id}` reuses §16.2's path space for something else, and that is worth saying
plainly.** There is no task *resource* on this server. `task_id` is a client-minted key that content
and metering are filed under; `DELETE` removes everything filed under it. A reader arriving from
§16.2 should not expect a `GET` on the same path to exist. It does not.

---

## 5. Identity of a task, a session, and an entitlement

### 5.1 `task_id`

`task_id` is `CompletedTaskRecord.id`, **and the field exists** (corrected 2026-08-26, SONNY-288).
SONNY-115 merged on 2026-08-17 and added it: `public var id: String?`
(`grep -n 'public var id: String?' Sources/MacAgentCore/TaskHistoryStore.swift` → `53:` at
`728d1ea`). This paragraph read "Until SONNY-115 merges there is nothing to put in this field" — true
of `4a7d996`, where `CompletedTaskRecord` had no identifier and the type's own comment said so, and
false since. The gateway tickets no longer sit behind row D for this reason; that dependency is
satisfied, and it is the second of the two gaps SONNY-155 closed.

**The id must be minted when the task starts, not when its record is written.** `CompletedTaskRecord`
is written at completion, so an id that only appears in that initializer's default arrives after
every request the task made. The field takes an id as a parameter, defaulting to a fresh
`UUID().uuidString` evaluated per call (`TaskHistoryStore.swift:135-136` at `728d1ea`), so this is a
matter of the caller passing the dispatch-time id through rather than letting it default — but it is
the kind of thing that is cheap now and expensive after the gateway lands. SONNY-130 and SONNY-131
build the requests that need it.

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
  "issued_at": "2026-08-28T09:00:00Z",
  "expires_at": "2026-08-29T09:00:00Z",
  "grace_seconds": 259200,
  "skew_tolerance_seconds": 300
}
```

- Signed server-side with EdDSA (Ed25519), JWS compact serialization, the signing key named by the
  JWS header's `kid`. The client verifies against a public key set it ships with, and
  `GET /v1/meta` publishes the current set so an online client can learn a rotated key without an app
  update. The shipped set is the offline fallback. Rotation therefore never requires a release, and a
  client that has been offline for a long time still verifies against what it shipped with.
  **`GET /v1/meta` publishes the set now** (2026-09-03, SONNY-204), as
  `entitlement_keys: [{kid, alg, public_key}]`, with the public half derived from the private key at
  registration so the two cannot be configured into disagreement. This bullet read "**Two halves of
  that are built and one is not**" until then, naming rotation-without-a-release as "the one thing
  here that nothing yet delivers".
  **What is delivered is one key, and the overlap a rotation actually needs is not.** The set is an
  array by contract rather than by anticipation, and today it holds exactly the key this gateway
  signs with, because `EntitlementSigningKey` holds one. Publishing the incoming key *before* it
  signs and the retiring one for a while after — the three-independently-valid-deploys shape
  `providerCredentials` already gives provider credentials — is a change to the *signing* side, and
  it is **SONNY-401**. Until it lands a rotation is one deploy, and a Mac whose cached set predates
  the switch refuses every gated capability until it next reaches `/v1/meta` — up to the offline
  bound this section states, for a client that is offline across it.
  The shipped set is still **empty in every build today**, because no gateway has been deployed
  anywhere and there is therefore no key to hold the public half of; that refuses every gated
  capability, which is the direction 5.3.1 requires, and it affects no free capability at all.
- **`sub` is the identity that asked; what the claim *says* is the account's** (2026-08-28,
  SONNY-135). This field is written `<user id>` above and is the Supabase user id — the same `sub`
  the access token carries — while `plan` and `capabilities` are read from the account row that
  identity belongs to. The reason is a client obligation rather than a preference: the Mac must be
  able to check that a cached claim belongs to the session it is holding, or a claim cached before a
  sign-out keeps granting capabilities to whoever signs in next, and **the only identifier the Mac
  ever learns is `user.id` from 3.2's token response**. An account holding two linked identities
  (`docs/sonny-identity-linking-rule.md`) therefore receives a different claim under each, identical
  in content and distinct in binding.
- `capabilities` is a list of opaque capability keys. **Which capabilities are gated is row 18's
  (SONNY-23), not this contract's** — this contract fixes only that they are named strings in a list
  the client reads.
- `grace_seconds` and `skew_tolerance_seconds` are carried **in the claim**, not compiled into the
  app, so the server can change them without a release. **Both are now set** (2026-08-28,
  SONNY-135): **259,200 seconds of grace** — three days, sized to cover a weekend with no usable
  connection, which is the realistic worst case a paying user meets by accident — and **300 seconds
  of skew tolerance**, which is the size of an honest clock error rather than of a clock somebody
  set, and which is a tenth of a percent of the grace window and so cannot meaningfully extend it.
  **The tolerance is applied in both directions, which is the opposite of 3.5's rule and the
  reasoning is what inverts**: there the *server* judges a token against its own clock and grants
  tolerance only to one that looks expired, because a token from the future is either the server's
  clock being wrong or a forgery; here the *client* judges a claim the gateway signed, so `issued_at`
  cannot be attacker-chosen, and a claim that looks not-yet-valid means this Mac's clock is behind,
  which is exactly the error the tolerance exists for.
- **Revocation's bound is two numbers, not one, and this bullet used to give only the shorter**
  (corrected 2026-08-28, SONNY-135). For an **online** client the bound is the refresh cadence, not
  the lifetime: a cancelled subscription stops working at the next refresh — **8 hours**, a third of
  the claim's 24-hour life, so one missed refresh does not spend the grace window — because that
  refresh carries a fresh, signed, capability-less claim and nothing has to expire for it to take
  effect. For an **offline** client nothing can be delivered, so the bound is the claim's own life
  **plus** the grace window: **96 hours** on a Mac that never reaches the network in that time, and
  immediate the moment it does. The original sentence — "revocation reaches a live client within the
  claim's lifetime, because that lifetime is the bound" — is true of the first case and understates
  the second by exactly the grace window it recommends in the same breath. The trade is deliberate:
  locking out a paying user on a plane is a certainty, while a revoked user who has also disconnected
  themselves from the service is a rarity, and the grace window buys the first at the cost of the
  second.

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

### 5.4 The screen-control allowance

`GET /v1/account/credits` returns **how many screen-control runs are left this period** — the single
number SONNY-17 says a user tracks, added by SONNY-212.

```json
{
  "plan": "<plan key>",
  "period_start": "2026-08-01T00:00:00.000Z",
  "period_end": "2026-09-01T00:00:00.000Z",
  "screen_control_runs_left": 97,
  "screen_control_runs_included": 100,
  "credits": { "allowance": 1000, "drawn": 30, "remaining": 970, "per_run": 10, "topped_up": 0 },
  "auto_top_up": { "offered": true, "opted_in": false, "attempts_left": 3 }
}
```

- **Screen control is the only line that draws on this pool.** Everything else is free and uncapped
  against it. A standing watcher's repeated checks were written down as an exception on SONNY-236
  and are not one: the founders decided on 2026-08-31 that **watchers are free and capped instead**,
  so a second currency never appears beside the run count.
- **Unsigned and uncached, which is the opposite of §5.3 and right for the opposite reason.** The
  entitlement claim is signed because the *client* enforces it offline, and it is honoured for four
  days past issue because an entitlement changes on the order of a subscription. A run count changes
  on the order of a run, so nothing offline can be enforced about it and a stored one is wrong in the
  direction that shows runs to somebody who has none.
- **Derived from §11's metering rather than from a ledger.** The draw is a query over
  `sonny.metering_event` restricted to `screen.analyze` rows that reached a provider, so the audit
  row *is* the charge and there is no second writer of the same fact. What that costs is that a
  change to the weights re-prices the period already under way; the reasoning, and why that is
  acceptable for a forward-looking estimate and would **not** be for a refusal, is in
  `server/src/credit/balance.ts`.
- **Every number is configuration.** Tiers, allowances, the credit weights and the value of one run
  arrive as `CREDIT_PLANS`, which this repository gives no default and refuses to start without. The
  tier *count* is configuration too: the product decision today is free plus one paid tier, and
  `plans` is a list of any length so a third is not a code change.
- **`credits` is diagnostic and is not a second number for a user.** It exists so the derivation can
  be sanity-checked against a measured cost, and `topped_up` is the one figure in it that is **not**
  derived from metering — it is what SONNY-215's purchases added to this period, carried separately
  so a founder checking a run count against a measured cost can subtract it. **One of the five is
  read by the Mac**: `remaining`, and only since SONNY-213, whose step boundary asks whether the
  account has actually run out — a question `screen_control_runs_left` cannot answer for a session
  whose own iterations have already been subtracted from it. (This bullet read *"the Mac reads the
  run count and ignores it"* until 2026-09-03; it stopped being true at SONNY-213 rather than here.)
  None of the five is rendered.
- **`auto_top_up` is a setting and not a number** (SONNY-215). `offered` is the deployment's answer —
  a top-up pack is configured and this gateway can charge — and `opted_in` is the user's. They are
  separate because the app does opposite things with them: nothing offered renders no control at all,
  and offered-but-not-opted-in renders one that is off. `attempts_left` is what the period's bound
  has not spent; the client reads it so a session does not ask for a purchase the gateway would
  refuse, and it is rendered nowhere. **A client that receives no `auto_top_up` object reads all
  three as off/zero**, which is the fail-closed direction on the axis that matters: a field lost in a
  rewrite must not be able to make a user look as though they consented to a charge.
- **Buying more runs is `POST /v1/account/credits/top-up`, and its first refusal is the consent**
  (SONNY-215). It recomputes the balance from the account's own metering rows, so "I am low" is not
  something a caller declares; it refuses unless the account has opted in, unless the deployment
  sells a pack, unless `screen_control_runs_left` is zero, unless the period has an attempt left, and
  unless there is a customer at the provider to charge. It answers this same body, so a caller needs
  no second read to see what it bought. It carries §9's idempotency guarantees like every other
  `POST`, and is the one route in this contract where they are about money — **with the exception
  §9.2's own release list creates, which is worth stating here because this is the route it would
  cost the most** (PR #196's F5): a repeat on one key replays a stored `topup.declined` or
  `topup.unconfirmed`, and does **not** replay a `500 server.error`, because that code is released
  rather than stored. What stops that being a second charge is not idempotency at all — an order this
  gateway created and has not resolved is resolved by the next attempt rather than replaced (PR
  #196's F1), so the charge is made once whatever the key does.
- **Turning the setting on or off is `PUT /v1/account/credits/auto-top-up`**, body
  `{"enabled": true|false}` with no default — a request that omits it is `400 request.invalid` rather
  than being read as either value. It answers this same body too, so the surface showing the switch
  and the number beside it cannot be one request apart.
- Authenticated, not metered, not charged against the spend cap, and rate limited like every other
  authenticated route — charging a user for asking how much is left would make the question spend the
  answer. **That covers the two top-up routes as well, and for the purchase it is worth saying out
  loud**: the charge is at the payment provider and against a plan's allowance, and §9's cap is an
  operator's anti-abuse ceiling on calls. SONNY-212 and SONNY-213 each declined to merge the two.
  Metering a purchase would also write it into the very table the balance is derived from, so a
  top-up would draw down the allowance it had just bought.

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
rebase at `692c904`; the largest JSON body across all fifteen of its fixtures, 3,512,879 bytes, was
measured at `e260575`. The branch merged to `main` at `4a7d996`, where `maximumImageBytes` is still
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

**None of the three is implemented, and that is owed work rather than a changed obligation** (updated
2026-08-28, SONNY-131). `grep -rn 'gzip\|Content-Encoding\|compress' server/src/` finds nothing.
**SONNY-317 owns all three plus the client switch, in one branch**, because the
end-to-end test needs both sides at once. Nothing is reachable today: no client compresses, so a
request decompressor built alone would be a code path nothing exercises — which is the shape PR
#139's own F11 deleted a guard for.

The client still does not compress, and that is now a measured decision rather than an open question
(updated 2026-08-26, SONNY-288 — this line read "SONNY-146 (filed, Backlog)", and that ticket
completed on 2026-08-18). SONNY-146 measured 29–35% lossless recovery from deflating the finished
vision body at `e260575` — SONNY-114's fixture head, kept verbatim because a compression ratio
cannot be restated at another SHA, and not an ancestor of `main` (6.1 carries the same stamp and its
post-rebase pair `692c904`). It then built the encoder and a per-endpoint switch:
`Sources/MacAgentCore/HTTPBodyCompression.swift`, and `compressesRequestBody` on the vision client,
defaulting to `false` (`grep -n 'compressesRequestBody: Bool = false'
Sources/MacAgentCore/VisionModelClient.swift` → `131:` at `728d1ea`). It was off because the route
the client talked to then answered a gzip-encoded body with a `500`, measured live against it rather
than assumed.

**That sentence used to end "the switch travels with the endpoint, so SONNY-131 flips both in one
edit when the client is repointed at Sonny's own gateway", and it was wrong in a way that would have
cost that ticket a working route** (corrected 2026-08-28, SONNY-131; found by SONNY-130 at PR #139's
F9). It assumed the gateway accepts the encoding *because this section obliges it to*. It does not,
and Fastify with no decompressor hands a gzip-encoded body to the JSON parser as bytes, which fails
as a malformed body — a `400` on every screen-control request, from a change that reads like a
one-line optimisation. **Flipping it is two edits and the server's is first**, and the half that
matters is the one the paragraph above names: the size limits apply to the *decoded* body, because a
limit applied to compressed bytes is not the limit this contract sets.

SONNY-131 repointed the client and left compression off, so the switch itself is gone with the old
client — `SonnyBackendClient` builds every request now and does not compress. `HTTPBodyCompression`,
the encoder SONNY-146 built and measured, is unchanged and has no caller; SONNY-317 is where it gets
one. Requiring the server to accept the encoding before any client sends it means the client can
adopt it later without touching this contract or its version, which is exactly what section 8's
additive rule is for.

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

**One code carries a sixth field, and no other does**: `version.unsupported` adds `upgrade_url`
(section 8.3, built by SONNY-204), because it is the one refusal whose recovery is outside the app —
and because a client that is refused for being too old must not have to parse `/v1/meta`'s document,
whose shape may have moved since it shipped, to find out where to go. It is additive under 8.1 and
2.1: the key is **absent** on every other error rather than present and null.

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
| Request body did not arrive in time | 408 | `request.timeout` | **Retryable** (SONNY-322). The gateway bounds how long a caller may take to deliver a request — section 12 — and this is what it answers when that bound is passed. **Its own code rather than `request.invalid`, because the two need opposite behaviour from a client**: this is a transient network condition and sending the same body again may well succeed, where `request.invalid` means a request that was wrong and will be wrong again. Reachable on `POST /v1/transcriptions` from the route's own body-read bound, and on any route from the server-wide delivery bound. Retryable **with the same key** — 9.2's release set carries it, so the answer is not stored and a repeat genuinely re-runs |
| Unknown or foreign task id | 404 | `resource.not_found` | Never means "nothing was stored" (4.6) |
| Idempotency key reused with a different body | 409 | `idempotency.conflict` | Section 9 |
| Account already holds a live subscription | 409 | `entitlement.already_subscribed` | `POST /v1/billing/checkout` only (SONNY-211). A server-side guard against a second subscription on one account, not a state an ordinary client should reach — the app knows its own entitlement and should not offer Subscribe. Client copy is SONNY-136's |
| Account holds no subscription to manage | 409 | `entitlement.no_subscription` | `POST /v1/billing/portal` only (SONNY-216). The mirror of the row above, and like it a state an ordinary client should not reach — the app knows its own entitlement and should not offer Manage subscription. **Not an error at the provider**: it is what a signed-in user who never subscribed looks like, which is most accounts. Client copy is SONNY-136's |
| No top-up was made for this account | 409 | `topup.not_permitted` | `POST /v1/account/credits/top-up` only (SONNY-215). **One code for five refusals** — the deployment sells no pack, the account has not opted in, it is not actually low, the period's attempts are spent, or there is no customer at the provider to charge — because a client does the same thing about all five: do not retry, and let the gate refuse as it would have. Which one it was is logged and never sent. The one this code exists to guarantee is the consent, and it is checked before anything else is read |
| The provider did not complete the charge | 402 | `topup.declined` | `POST /v1/account/credits/top-up` only (SONNY-215). The provider answered and did not charge — a declined card, no payment method on file, or an authentication challenge an off-session charge cannot answer. Its own status because the fix is the user's payment method rather than their settings, and collapsing it into the row above is a distinction a later surface could not recover |
| The provider's answer could not be read | 502 | `topup.unconfirmed` | `POST /v1/account/credits/top-up` only (SONNY-215). The charge was attempted and its answer could not be read, so **money may have moved and nothing was granted for it**. **Not retryable, which is why it is not `provider.unavailable`**: a client told to retry would buy a second pack to recover from a first one it cannot see. The provider's order id is recorded server-side for an operator to resolve |
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

**What the comparison reads, and what an unreadable header means** (added 2026-09-03, SONNY-204,
from building it). §2.2 gives the header as "marketing version plus build". Only the marketing
version is compared — build metadata is not ordered, so `1.0+7` and `1.0+412` are one version — and
**one, two or three numeric components are all accepted**, because `SonnyClientIdentity.version`
builds the header from `CFBundleShortVersionString`, which is `1.0` in the shipping bundle: a parser
demanding three would refuse the only build a user runs. A prerelease suffix is dropped rather than
ordered below its release, because this product has no prerelease channel to order.

**A request carrying no version, an unreadable one, or the header twice is served, and is never
treated as too old.** Every caller that is not the Mac app sends none — a load balancer's liveness
probe, the payment provider's signed delivery to `POST /v1/billing/webhook`, a deploy script's own
health check — so refusing them would turn a version policy into an outage at the moment somebody
first set a real minimum. Nothing is lost by that direction, because this gate is a courtesy to an
old client rather than a boundary: what protects every route is the `Auth` column of 4.1, which none
of this touches, and a caller that omits the header reaches only the modern API it could have called
anyway.

**`minimum_supported_client` and `recommended_client` are the deployment's, and both are `0.0.0`
until a founder sets them.** No client can compare below `0.0.0`, so a gateway that has been told
nothing refuses nobody and warns nobody. That is 8.4's rule applied to a default: a minimum above
zero that nobody decided is a minimum that was never given a deprecation period.

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
  returns the stored response. **Except when that response was a retryable failure, and except when
  the request asked not to be stored** — see the decisions below.
- **A metering event is written at most once per idempotency key, ever.** That single sentence is
  what makes a client retry unable to double-bill a user, and it is the reason the key is required
  rather than optional.
- The same key presented with a *different* body is `409 idempotency.conflict`. It is not silently
  treated as new, because the shapes that produce it are a client bug or a replay, and both are
  worth surfacing.
- A key seen while its original request is still in flight gets `409 idempotency.conflict` with
  `retryable: true` and a `Retry-After`, rather than a second upstream call.

#### Three decisions, and the third arrived later

The first two are the founder's, taken on 2026-08-28 when this was built (SONNY-300). The third is
SONNY-134's, taken on 2026-08-28 when PR #148's review measured what this section costs section 10.1
(F1).

**A stored *retryable* failure is released rather than replayed.** The four sentences above and
section 9.3 cannot both be read literally: 9.3 marks `limit.rate`, `provider.unavailable`,
`provider.timeout`, `server.error` and `server.unavailable` retryable *with the same key*, and
replaying a stored one of those makes every such retry safe but useless — a `429` becomes a
twenty-four-hour ban on that operation and a `503` during a deploy freezes everything in flight for a
day. So a response carrying one of those codes gives the key back, and a retry with it genuinely
re-runs. `auth.token_expired` is released for the same reason, because 3.3 makes it the one `401` a
client answers by refreshing and retrying the original request.

**What that does not cost is the money guarantee**, which is the point of separating the two. The
metering claim is a mark on the key that a release does not clear, so the re-attempt finds it taken
and writes no second event. The re-attempt's own usage therefore goes unbilled — the direction the
second bullet above chooses deliberately, since "unable to double-bill a user" errs toward the user.

**An incognito response body is not stored, so a repeat of an incognito call re-runs** (SONNY-134,
2026-08-28). This table holds the served response for twenty-four hours, which makes it the one place
in the gateway keeping response content outside the route that produced it — and until PR #148's
review the key store had no notion of `retention` at all. Measured: `POST /v1/plan` with
`retention: "none"` and an `Idempotency-Key` left the content store empty, correctly, and left the
model's reply verbatim in `sonny.idempotency_key`, outside the content clock, outside consent, and
outside what a `DELETE /v1/tasks/{task_id}` can reach. Section 10.1's promise and this section's
first bullet cannot both hold for such a request, and **10.1 wins: it is the promise the user was
given**, and its rule is that the guarantee is enforced where the storing happens rather than at the
call site.

**Exactly one of the four bullets above changes, and only for `retention: "none"`.** The claim, the
lease, the fencing token and the fingerprint are written as for any other request, so a concurrent
repeat still gets its `409`, a key reused with a different body still conflicts, and
`metering_claimed_at` still makes the metering event at-most-once. What a client loses is the replay:
a repeat inside the window re-executes, so the provider is called a second time and — because the
metering claim survives, exactly as it does for the released retryable above — **that second call is
unbilled and the gateway pays for it.** That is the same trade the first decision already makes,
bounded here to incognito retries. The rule is keyed on an explicit `"none"` and not on "anything
that is not `standard`", because the four auth routes carry no content and have no `retention` field
to declare; widening it would strip replay from them for nothing.

**A `POST` carrying no `Idempotency-Key` is served, not refused.** 9.1 makes the header the client's
obligation and the Mac client sends it on every `POST`; enforcing it server-side would refuse a shape
no shipping client produces. Such a request has no at-most-once guarantee, because there is no key
for one to be about. A key longer than 255 characters is `400 request.invalid`.

**One place conflict detection is weaker than "different body" suggests**, stated because it is
invisible from the outside: on `POST /v1/transcriptions` alone the body is `multipart/form-data` and
is consumed inside the handler, so the comparison is made on the declared body length rather than on
the body. Two different recordings of exactly the same encoded length sent under one key are read as
the same body and the first response is replayed instead of a 409 being raised. It fails in the safe
direction — a replay never bills twice and never calls a provider twice.

**A route that answers with a stream gets none of this, and no error says so.** A streamed response
cannot be stored, so its key is released instead: the repeat re-runs and calls the provider a second
time. Every guarantee above is silently absent for such a route while the request still succeeds. No
route streams today and section 4 defines none — SONNY-125 measured streaming as *ruled out* for the
vision route, because a response that starts streaming and then outruns a limit arrives as a
truncated body under a `200` rather than as a diagnosable failure. This is written down because the
guarantees above are inherited by every `POST` a later ticket adds, and a streaming one would inherit
the machinery and none of the promise.

**A claim also has a lease, and a request that outlives it may be joined by a second.** The lease is
what stops a process killed mid-request from holding its key forever. A holder past it keeps its own
consistency — a superseded holder's write is refused rather than landing on its successor's claim —
but while both run the provider can be called twice for one key, which is what the fourth bullet
above exists to avoid. The interval that has to fit inside the lease is the whole request, from the
claim to the response being sent.

**Every route's interval is now bounded, and each bound sits inside the lease** (SONNY-322). **This
paragraph is where that arithmetic lives**; section 12 states the upload bound as a timeout and points
back here rather than repeating the derivation, and the gateway's own code cites this section from
both constants. The lease is **180 seconds**.

- The **JSON routes** are bounded by section 12's total deadline — 105 s at the longest, so 75 s
  inside the lease.
- **`POST /v1/transcriptions`** was the one that was not: its body is `multipart/form-data` read
  inside the handler, after the claim is taken and outside the deadline the route applies to its
  upstream call, so a stalled upload held its claim indefinitely. That read has a **90 s** bound of
  its own, and **90 + 75 = 165** — fifteen seconds inside the lease, which is the tightest of the two
  and the one the lease is sized for.

**The 90 is section 12's client timeout for that route, and the lease was sized to fit it** (founders,
2026-09-05). The first version of this had a 30 s bound derived the other way round — the lease held
fixed at 120 and the upload solved for — which inverted section 12's governing rule on the one route
where the upload is the slow part, the server giving up at a third of the budget its own client waits.
The direction of the derivation is the part worth carrying: the lease answers to nothing outside the
gateway, so it is the side that moves.

**What that does not do is close the fourth bullet outright, and the earlier version of this
paragraph implied it did.** It said "a stalled upload is the one shape that can reach this", which
was a subtraction claim the code's own neighbouring comment already contradicted: the JSON routes'
margin is fifteen seconds, not infinity. Bounding the upload removes the *unbounded* shape and leaves
the bounded ones. **The case the lease actually exists for is untouched by any deadline**: a process
killed mid-request runs no timer at all, so its claim is still taken over on expiry, and the fencing
token is still what keeps that survivable rather than corrupting.

### 9.3 What is safe to retry

| Request | Safe to retry | Why |
|---|---|---|
| any `GET` | yes, always | No side effect, nothing metered |
| `POST /v1/plan`, `/research/synthesize`, `/search`, `/transcriptions`, `/screen/analyze` | yes, with the same key | Section 9.2 |
| `POST /v1/auth/refresh` | yes, with the same key | Rotation plus the overlap window (3.3) means a lost response does not cost the session |
| `POST /v1/auth/email/start` | yes, with the same key | Without the key, a retry sends a second code and races the first |
| `POST /v1/auth/email/verify` | **no** | A code is single-use by design (SONNY-127). The idempotency record returns the original *result*, including the original failure; it does not un-consume a code. **Except for the retryable failures 9.2 carves out** — those release the key, so a retry genuinely re-runs against a code that may already be consumed, which is one more reason this row says no |
| `POST /v1/auth/oauth/google`, `POST /v1/auth/oauth/apple` | **open** | These flows typically carry a single-use provider authorization code, in which case they behave like `email/verify` rather than like `email/start`. SONNY-129 settles it when it settles the body shape (3.6), and records which |
| `POST /v1/auth/signout` | yes | Revoking an already-revoked family succeeds |
| `DELETE /v1/tasks/{task_id}`, `DELETE /v1/account` | yes | Naturally idempotent; a second delete succeeds with `requests_deleted: 0` |
| `DELETE /v1/tasks`, `DELETE /v1/tasks/{task_id}/screenshots` | yes | Naturally idempotent for the same reason (SONNY-404). A repeat of the batch answers the same `tasks_not_found` and deletes nothing the first pass took; a repeat of the screenshot clear answers `screenshots_deleted: 0` |
| `DELETE /v1/account/content` | yes | Naturally idempotent (SONNY-404). A repeat finds nothing and answers `200` with zeroes; it closes nothing, so there is no state a second call could destroy |

**Retry is decided by `code`, never by status.** Several statuses carry more than one code with
opposite semantics, which is the whole reason section 7's taxonomy keys off `code` — and a client
that retried on status would retry `provider.rejected`, a 502 whose retry is guaranteed to fail
identically.

- Retryable: `limit.rate` (after `Retry-After`), `provider.unavailable`, `provider.timeout`,
  `request.timeout`, `server.error`, `server.unavailable`, `client.offline`, and
  `auth.token_expired` after exactly one refresh.
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

Two rules the contract fixes, **both built by SONNY-134 on 2026-08-28**:

1. **Enforced where the storing happens, not at the call site.** A flag the client sets and the
   server is trusted to remember to check is a request, not a guarantee. Built as three layers:
   `server/src/content/hook.ts` refuses before it reads a body, decodes a capture or opens a
   connection; `sonny.retained_content` carries a `CHECK` admitting exactly one value of
   `retention`, so the insert is refused even when something above it is wrong; and a request that
   declared *no* `retention` stores nothing either, which is 2.4.2's rule arriving at the storage
   layer rather than a second one.
2. **Structurally excluded from training snapshots, not filtered by a query.** If an incognito run
   can reach a snapshot because someone dropped a `WHERE` clause, the guarantee is not one. The
   snapshot builder's `FROM` names `sonny.retained_content` and nothing else, so **there is no
   `retention` filter in it to drop**: deleting every predicate in the build statement widens the
   snapshot to every consenting account's content and still cannot reach one incognito run.
   `server/test/content.db.test.ts` runs exactly that unfiltered statement and asserts it, which is
   what "pin it with a test" asked for.

**Metering runs either way.** Incognito changes what is stored, never what is billed. A metering
design that dropped these events would silently make those runs free, and it is the case most likely
to be dropped by accident — which is why SONNY-133 carries an acceptance criterion for it.

The accepted cost, recorded so it is not later read as a defect: a user reporting that an incognito
run misbehaved cannot be diagnosed from stored data. That is the feature working.

**A second accepted cost, found by PR #148's review and paid deliberately** (F1, 2026-08-28). §9.2's
key store keeps the served response for twenty-four hours, which is storing — so for
`retention: "none"` it keeps none, and a repeat of an incognito call re-executes instead of replaying.
§9.2 carries the full record and what it does and does not cost; the short version is that only the
replay changes, and the second provider call it can cause goes unbilled to the user. **Every place
this gateway stores anything now reads the same one function**, because two readings of `retention`
would let the two stores disagree about what the user asked for, and the one that got it wrong would
be the one nobody was looking at.

### 10.2 Training consent

`training_consent` is a field on the **user record**, values `"granted"` and `"not_granted"`,
defaulting to `"not_granted"` — so a user whose consent was never written is excluded. **SONNY-127
built the field and deliberately did not build the write path** (updated 2026-08-26, SONNY-288 — this
line assigned it both). Consent is captured on the website, so the write path is an authenticated
endpoint the website calls, and what was owed was the gate rather than an in-app toggle; that gate is
SONNY-203's and closed on 2026-08-22. **SONNY-134 made the snapshot builder honour it on 2026-08-28**, twice over: the builder joins
`sonny.account` and requires `training_consent`, and a trigger on `sonny.training_snapshot_member`
refuses a row for a non-consenting or closed account anyway — because training on the content of a
user who did not consent is not a defect that can be repaired afterwards, and one predicate in one
statement is a thin thing to rest that on. The `DEFAULT false` below is what excludes a user whose
consent was never written, and it is asserted as its own case rather than folded in with one who
declined.

**Known divergence: the two values above name no column, because the tree stores this as a boolean**
(recorded 2026-08-27, SONNY-297 — recorded, not reconciled). The column is `training_consent boolean
NOT NULL DEFAULT false` (`server/src/db/migrations/0002_accounts_and_identities.sql:28` at
`554d85a`), so nothing anywhere holds the string `"granted"` or the string `"not_granted"`.

**The guarantee is identical, which is why this is a divergence and not a defect.** `DEFAULT false`
*is* the `"not_granted"` default, `NOT NULL` *is* the absence of a third state that could be mistaken
for consent, and the migration's own comment states it in this section's terms rather than the
database's (`:25-27`). What differs is the spelling, and the spelling has no wire encoding to
protect, because the field does not cross the boundary — which the paragraph headed *It never
appears on a request* states, and which is checkable rather than asserted.

**Re-measured on 2026-08-28 (SONNY-134), and two of the three figures moved**, because that ticket
is the first thing that ever reads this column for its intended purpose. What the old wording rested
on — one file, one reader, both incidental — was a property of nothing having used it yet, so it was
never going to survive the ticket the column was created for. What actually protects the field is the
third figure, and it is unchanged:

- `training_consent` now appears in **four** files under `server/src`
  (`grep -rl training_consent server/src | wc -l` → 4 at `d04c462`): migrations `0002` and `0013`,
  and `content/snapshot.ts` and `content/query.ts`. **This was one.** None of the four is a route
  handler, which is the property that mattered and which the count of one was standing in for; the
  two new readers are the snapshot builder's `WHERE` clause and the support lookup, and neither puts
  the value on a wire.
- in **no** file under `Sources/` or `Tests/` (`grep -rl 'training_consent\|trainingConsent' Sources
  Tests | wc -l` → 0 at `d04c462`), so no client type has a field for it to decode into. **This is
  unchanged, and it is the one that binds**: whatever the server reads it for, the app has nothing to
  decode it into.
- and no query can return it implicitly. There is still **no star-select anywhere in the server**
  (`grep -rniE 'select +\*' server/src` exits **1** and prints nothing, read with nothing between the
  command and `$?`, at `d04c462`). The enumeration of files holding `select` is dropped rather than
  restated: it stood at six, then seven, and is fourteen now, and a list that has to be rewritten by
  every ticket that adds a query is a list that will eventually be wrong quietly. The star-select
  check is the one that does the work and does not grow.

**One thing that check nearly caught was itself.** The first draft of `content/query.ts`' header
spelled the literal form out while explaining why there must not be one, and the grep answered with
that sentence — a violation report that was a description of the report. It is written as
"star-select" there now, which is the same trap `CLAUDE.md` records for a slash-star inside a line
comment and for a citation that escapes its own parentheses.

Its readers are the snapshot builder above, the support lookup, and a database test asserting the
default and the NOT NULL (`server/test/linking.db.test.ts:773-783`), which reaches the column through
Postgres rather than through this contract.

**Which side moves is not settled here, and nothing waits on it.** Restating this section as a
boolean and leaving the tree alone are both available, and changing either side's code was out of
scope for the ticket that recorded this. Whoever settles it is amending a contract twelve tickets
were written against and owes section 14 a row. Until then a reader of this section knows both
shapes and that they mean the same thing, which is what a recorded divergence is for and what a
silent reconciliation would have destroyed: the string values are what SONNY-127 was written
against, and rewriting them here would leave nothing to say they had ever been the contract.

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

**Built on 2026-08-28 by SONNY-133** as `sonny.metering_event`
(`server/src/db/migrations/0012_metering_records_what_every_call_cost.sql`). Six rows below moved as
it was built; each says how, and section 14 carries the row.

| Field | Type | Source | Notes |
|---|---|---|---|
| `event_id` | string | server | |
| `request_id` | string | server | Same value as the `Sonny-Request-Id` header |
| `idempotency_key` | string, nullable | client header | One event per key, ever (9.2). **Nullable since 2026-08-28**: 9.2 serves a `POST` carrying no key, and such a request is metered anyway — dropping the event would make it free — with no at-most-once guarantee, because there is no key for one to be about |
| `account_id` | string | server | From the authenticated session. **Named `user_id` until 2026-08-28**; the column is `account_id` because section 5 makes the account the billable identity and one person can hold two Supabase users on one account |
| `occurred_at` | timestamp | server | |
| `route` | enum | server | `plan`, `research.synthesize`, `transcription`, `search`, `screen.analyze` |
| `provider` | string, nullable | server | Which provider actually served it. Required for failover accounting (SONNY-132) and never returned to the client. **Nullable since 2026-08-28**: a request refused before any upstream call has no provider, and naming one would be an invention |
| `failed_over` | string list | server | **Added 2026-08-28.** The providers tried before the one that served, from `ProviderAttribution.failedOver` (SONNY-132). A failover spends a second upstream call, and nothing else records that it happened |
| `model` | string, nullable | server | Server-side only, for the same reason. Nullable on a refusal, and on `search`, which is a provider with no model |
| `input_tokens` | int, nullable | provider | |
| `output_tokens` | int, nullable | provider | |
| `total_tokens` | int, nullable | provider | |
| `token_source` | enum, nullable | server | `reported` or `estimated`, mirroring `AIUsageTokenSource` (`TaskUsage.swift:20`). **Nullable since 2026-08-28**, and `screen.analyze`'s normal state: that route reports tokens only when the provider did and estimates nothing, so a null here is an absence and never a measured zero |
| `image_bytes` | int, nullable | server | `screen.analyze` only |
| `image_pixel_width` | int, nullable | client | `screen.analyze` only. Vision token cost tracks pixels, not bytes |
| `image_pixel_height` | int, nullable | client | |
| `image_media_type` | string, nullable | client | **Added 2026-08-28.** Which of 4.5 rule 2's two formats this capture was. Roughly half of real captures are each, and the byte figure beside it cannot be read without knowing which |
| `audio_duration_seconds` | number, nullable | provider or server | `transcription` only. Maps to `AIUsageRecord.audioDurationSeconds` |
| `request_bytes` | int, nullable | server | Decoded size. **Nullable since 2026-08-28**: null when the request declared no `Content-Length`, where `0` would read as an empty body. Nothing in the gateway decodes a `Content-Encoding` (6.4), so a declared length *is* the decoded size |
| `response_bytes` | int, nullable | server | **Nullable since 2026-08-28**: null for a payload that is neither a string nor a buffer, which no route produces today |
| `duration_ms` | int | server | Total, server-observed |
| `upstream_duration_ms` | int, nullable | server | Time waiting on the provider. **Nullable since 2026-08-28**: null when no upstream call was made, where `0` would read as a provider that answered instantly |
| `outcome` | enum | server | `ok`, `provider_error`, `server_error`, `refused`, `client_cancelled` |
| `task_id` | string, nullable | client | Section 5.1 |
| `session_id` | string, nullable | client | Section 5.2 |
| `session_iteration` | int, nullable | client | |
| `retention` | enum, nullable | client | `standard` or `none`. Recorded so an incognito run's *usage* is visible while its content is not. **Nullable since 2026-08-28**: a request refused before its body was read declared none |
| `client_version` | string, nullable | client header | Bounded at 100 characters before it is stored, because a header is caller-controlled |

**Which requests produce an event, decided when it was built** (SONNY-133, 2026-08-28). A metered
route is one of the five above; every other `POST` this gateway serves is declared unmetered by name,
so a sixth content-bearing route fails a population test until somebody classifies it either way.

| request | event |
|---|---|
| metered route, authenticated, holding the key's claim | yes, if this key's one metering claim is free (9.2) |
| metered route, authenticated, carrying no `Idempotency-Key` | yes, unconditionally |
| metered route, authenticated, replayed from the key store | no — the original wrote it, and this one ran nothing |
| metered route, `409 idempotency.conflict` | no — and this one is not merely "free": taking the key's one claim would leave the request that *is* doing the work with nothing to spend |
| refused at the auth gate (`401`) | no — `account_id` comes from the authenticated session, and the gate runs before the body is read |
| an unmetered route | no |

**The event is written before the response is flushed**, on the same hook the idempotency key's own
bookkeeping uses and one place after it. The obvious home was after the response, and two things
moved it: a process killed in that window drops a billing record for a provider call already paid
for, which is exactly the direction this section exists to close; and nothing downstream can observe
an after-the-response write, measured on Node v22 in both directions — a client's promise resolves
before an async `onResponse` hook finishes, so "the client has its answer" and "the call is
recorded" were unordered. The cost is one local `INSERT` on a request that already makes two database
round trips for its key, beside a provider call section 12 measures in tens of seconds. A caller who
disconnects while the handler is still running never reaches that hook at all, and is written from
the response's `close` instead — which is the one path `outcome: client_cancelled` comes from.

**`outcome`'s five values, against the four SONNY-131 proposed.** That ticket's hand-over named
`served`, `client_cancelled`, `provider_failed` and `refused_before_upstream`; each maps onto a value
above without loss — `ok`, `client_cancelled`, `provider_error`, `refused` — and `server_error` is
the fifth its four had nowhere to put, this gateway's own bug rather than a provider's or a refusal.
The distinction that proposal insisted on survives in full and is why `refused` and `provider_error`
are separate: a `413` over the image ceiling, a `400` on validation and a `502` from a route with no
configured adapter all happen before anything is spent, and an event that could not tell them from a
failed provider call would bill for a request that never left the gateway. The mapping is keyed on
the error `code` and never on a status, which is 9.3's own rule — `502` carries two codes with
opposite meanings.

**Per-session screen-control cost** — the figure SONNY-17's credit weight waits on — is the sum over
events sharing a `session_id`. Nothing in the product records it today: `AIUsageCallKind`
(`TaskUsage.swift:3-6`) has exactly three cases, `planner`, `webResearchSynthesis` and
`transcription`, and none is vision. That is not an inference from one file: grepping all thirteen
vision-path files under `Sources/` — `VisionModelClient.swift`, `VisionSessionRunner.swift`,
`VisionSessionEnvironment.swift`, `VisionSessionContainment.swift`, `VisionSessionPromptBuilder.swift`,
`VisionSessionJournalStore.swift`, `VisionSessionCapabilityAdapter.swift`, `VisionSessionTypes.swift`,
`AgentViewModel+VisionSession.swift`, `ScreenCaptureService.swift`, `LocalRedactionService.swift`,
`RedactedCaptureEncoder.swift` and `ScreenActionSynthesizer.swift` — for `usageRecorder`,
`AIUsageRecord` or `TaskUsageRecording` returns zero matches in every one of them at `4a7d996`. The
four production recording sites in the whole repo are `OpenAIPlanner.swift:82`,
`CerebrasPlanner.swift:97`, `WebResearchSynthesizer.swift:359` and `OpenAITranscriber.swift:102`.

So this shape is defined rather than mirrored from an existing one, and the vision route is the
reason the metering exists.

Two things it must not lose:

- **The local per-task summary keeps working.** `TaskUsageRecorder` feeds
  `AgentViewModel.taskUsageSummary`. Server-side metering is the billable truth; where the two
  disagree the server is authoritative, and the local summary must not silently go blank. SONNY-130
  and SONNY-133 both carry this. **"A live UI surface" was wrong when this was written and is
  corrected here** (2026-08-28, SONNY-133): no view reads that property — PR #144's F1 measured it,
  and Settings → Usage says so in the product's own words. What the sentence protects is unchanged
  and is now pinned end to end by
  `PlannerConstructionTests.whatARunRecordsReachesThePublishedUsageSummary`; the surface itself is
  SONNY-214's. **Two honest reasons the two sides differ**, recorded so a difference is not chased as
  a defect: a call refused before any upstream is on the server's side only, because the client
  records beside a reply it received; and a retry that genuinely re-ran under one key is metered once
  server-side (9.2) and counted twice locally, because the client saw two calls.
- **Usage outlives content.** The two clocks are the point (10.3). Nothing in the gateway deletes or
  ages a metering row, and the table holds no content column at all — asserted as the whole column
  set rather than as a search for likely names, so adding one fails a test rather than a review.
- **A founder can read it without a UI.** `npm run usage -- sessions | routes | span`, over
  `server/src/metering/query.ts`. It is a command and not a surface by decision (2026-08-28): the
  usage UI is SONNY-214's, and what this row owes is the pre-launch measurement SONNY-17's numbers
  come from. It prints tokens, bytes, pixels, iterations, durations and outcomes, and never a price.

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
| `POST /v1/account/credits/top-up` | 24 s | 30 s | 40 s |
| auth, account, meta, health, delete | 10 s | 15 s | 20 s |

SONNY-404's three deletes are in that last row and take no row of their own: they are the same
database work as 4.6's, over more rows or over fewer columns, and none of them calls a provider.

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

**The last row is five routes rather than one, and until SONNY-425 nothing applied it to any of
them.** `POST /v1/auth/email/start`, `/email/verify`, `/refresh`, `/signout` and `DELETE /v1/account`
now run their provider work inside both deadlines, at the numbers above, through the same wrapper the
model routes have used since SONNY-130 — and the 10 s is the bound the Supabase adapter sets on each
request it makes, read from this table rather than written as a literal that matched it by accident.
**Two of the five do not answer `504 provider.timeout` when the deadline elapses, and both are
decisions this table does not override.** `/email/start` answers its uniform `200` whatever happens,
because section 3.6 makes that response identical for an address with an account and one without, and
a status that varied with what happened downstream would be that oracle in a slower form.
`DELETE /v1/account` answers `204`: by the time its provider work runs the account is closed and
committed, the caller can no longer be attributed to it, and a `5xx` would describe an outcome that is
not the one on disk while inviting a retry that cannot get through — the revocation stays owed and is
reported by the operator command, which is what that route already does for a provider failure.

**The four content-deletion routes are wired too, and not by that wrapper** (SONNY-428).
`DELETE /v1/tasks/{task_id}`, `DELETE /v1/tasks`, `DELETE /v1/tasks/{task_id}/screenshots` and
`DELETE /v1/account/content` now run under this row's **total** deadline. The upstream half does not
apply to them: none calls a provider, so there is no socket to bound and a signal there would be a
number nothing reads.

**What bounds them is Postgres's own `statement_timeout`, and the reason it is not the wrapper is a
rule this document's own history produced.** Every one of the four does its work on a pooled
connection the handler leased, and the wrapper is a `Promise.race` — when the deadline wins it
*abandons* the work, which then goes on issuing statements on a connection already released to the
next request. That is the defect PR #212 found on `DELETE /v1/account` and the rule it left behind:
**a deadline around work that holds a database connection is never a race that abandons.** The
cooperative poll that route uses does not transfer either, because its work is a loop of provider
calls with gaps to poll in and a deletion is a fixed sequence of set-based statements whose time is
spent *inside* a statement. So the budget is handed to the backend, which is the one thing that can
end a running statement: the remaining budget is set before each statement, an exhausted one is
refused without a round trip, and a cancelled statement rejects with `57014`, rolls back, and leaves
the connection healthy — the work is over before the caller is answered. Transaction control is
exempt, because a `ROLLBACK` this bound refused would return a poisoned connection to the pool.
A timeout is `504 provider.timeout`, retryable, which §4.6 makes honest: every one of these routes is
safe to repeat.

**Two routes the row names are still deliberately not wired, each for its own reason** (SONNY-425).
`GET /v1/health` and `GET /v1/meta` await nothing at all — no database, no provider, no network — so
a deadline around either is a timer that cannot fire, and the row's numbers are true of them only in
the sense that any bound is.

**Three of the five `/v1/account/*` routes are wired now, by a third shape** (SONNY-434; five, not
the four this paragraph said until PR #235's fresh review counted — the fifth is
`DELETE /v1/account/content`, one of the four content-deletion routes above:
`git grep -nE 'app\.(get|put|post|delete)\((CREDITS_PATH|AUTO_TOP_UP_PATH|TOP_UP_PATH|"/v1/account/)' <sha> -- server/src`
→ 5 at `__FIX_SHA__`, run from the repository root, since the same pathspec from inside `server/`
answers 0 for the reason `CLAUDE.md`'s clean-zero rule names).
`GET /v1/account/entitlements`, `GET /v1/account/credits` and `PUT /v1/account/credits/auto-top-up`
wait on the database rather than on a provider, and the pool bounds every statement they issue — the
paragraph below is that bound, **and it holds beneath the budget**: each statement runs under the
smaller of the budget's remainder and the pool's ten seconds (PR #235's fresh review, F1, found the
remainder *replacing* the pool's value for the statement, so an eleven-second statement completed
inside the budget that was cancelled at ten outside it; a `SET` replaces a session setting, it does
not cap it). What they were owed until this ticket was the *total* half of this row, because a
per-statement bound cannot stop several statements summing past 15 s. They could not take the
deletion routes' wrapper: their stores lease connections *internally* (SONNY-300's seam), so the
handler never holds a client to wrap, and the read behind `GET /v1/account/credits` is six statements
on one lease. So the handler declares §12's total for its request, and every lease its stores take
inside it reads what is left of that budget and hands it, capped at the pool's bound, to the same
per-statement `statement_timeout` the deletion routes use — one budget for the whole handler, across
however many leases it takes, **and the time a lease spends queued for a free pooled connection is
inside it in both senses**: what is left is read once the connection is in hand, because the
per-statement wrapper anchors its own deadline when it is entered, after that wait (PR #235's first
review measured the other order at `834a8c75`, a pre-rebase head, as 1401 ms granted against a
1000 ms budget at a 400 ms wait); and the wait itself is cut at the budget's end — a request whose
lease is still queued when its budget runs out is answered `504 provider.timeout` then, and the
connection the pool later hands that request goes straight back with nothing run on it (the fresh
review's F3 measured a 1000 ms budget answering at 2996 ms behind a three-second holder, and at
5003 ms as a `500` when the pool's own five-second connect timeout won). **The pool's connect
timeout inside a declared budget is answered as that same `504`**, because inside a budget that wait
is the wait the budget bounds; outside one it is untouched. The consent switch takes two leases, its
write and the re-read it answers with, and a budget per lease would have been thirty seconds wearing
this row's fifteen. A statement cancelled inside it answers `504 provider.timeout`, retryable, and
that is honest for all three: the two reads cost nothing to repeat, and the setting is idempotent —
a retry writes the same value again. **What that `504` does not say on the consent switch** (the
fresh review's F2): its two leases are two transactions, the write autocommits on the first, and a
budget that runs out in the re-read — or in the wait for its connection — answers `504` with the
setting already written. The Mac's one automatic retry ordinarily converges on the `200`; a retry
that also times out leaves the app's toggle showing off while the gateway holds consent, until the
next read. One lease in one transaction would roll the write back with the timeout; that touches
`CreditStore`'s seam (SONNY-300) and is recorded on SONNY-434 for the founders rather than taken.
**Outside a declared budget nothing changed**: the gate's own admit and settle on the same
entitlement store, and the charge route's reads on the same credit store, stay on the pool's
per-statement bound, because `POST /v1/account/credits/top-up` has its own row above and its own
answer when that elapses, and a second bound with a different answer on the same handler would be
two promises about one request. What SONNY-428 did composes with it for the deletion routes: a
per-statement budget those routes set for their own work, on top of a pool-wide default that is
restored the moment they clear it — **not the tighter of the two winning** there, because the
innermost `SET` governs in either direction, which the paragraph below measures; the account routes'
leases take the smaller of the two by construction, since their remainder starts at fifteen seconds
and the derivation below gives their statements ten. **The fourth was `POST /v1/account/credits/top-up`,
which is nothing of the kind — it charges at the payment provider — and it has its own row above**
(SONNY-430).

**The top-up row, and why its numbers are what they are** (SONNY-430). The charge is a draft order
and then a finalize, each bounded at twelve seconds inside `server/src/billing/polar.ts`, so the
route's 24 s upstream is that constant doubled rather than a number picked to fit. A third HTTP call
exists — the read-back the finalize makes when the provider answers `412`, meaning the order is no
longer a draft — and it **shares the finalize's budget instead of taking a third**; until SONNY-430 it
took its own, so one top-up could spend thirty-six seconds against a row that allowed fifteen. Thirty-six
was never available as a row either: the client's timeout here is 40 s and is derived on the Mac from
those same two calls, so a 36 s upstream would want a total above the client's and invert this
section's governing rule. Folding the charge into the last row instead was rejected as the unsafe
direction — three calls inside 10 s is about 3.3 s each, and `server/src/billing/polar.ts` will only
say that eight seconds "is not obviously above a healthy charge", so 3.3 is well under a bound nobody
has been able to call generous; a charge aborted mid-flight is recorded as unconfirmed, granting
nothing for money that may have moved. **The hedge is deliberate and this sentence used to drop it**
(PR #220's O3): nobody on this project has yet watched a real card authorisation through this
provider, so "below a healthy authorisation" is a measurement no one here has taken.

**This route does not answer `504 provider.timeout` when its deadline elapses, and that is the third
such decision this table does not override.** It answers **`502 topup.unconfirmed`**, which section
7.2 marks not retryable. At the instant the total deadline elapses a charge may be in flight, and
`provider.timeout` invites the retry that buys a second pack — the defect PR #196 found and closed.
The deadline bounds the *answer* and never the work: the attempt row already carries the provider's
order id, written before anything can charge, so the charge that outran the deadline settles that row
and the account's next attempt resolves it rather than starting again.

**Underneath all of that, the pool sets a `statement_timeout`, and it is the only bound in this
document the database itself enforces** (SONNY-427). Every other number here is a timer this process
owns, which is why every other one can be outrun by a statement that never returns: a stalled or
lock-blocked query holds the request past whatever the handler promised, and no deadline written in
JavaScript can reach inside it. The gateway builds exactly one pool, and every connection it hands
out carries **10 000 ms** — **this row's own `upstream`**, not a number chosen here. The derivation is
the row: for a route with a provider, `upstream` bounds the one external wait and the five seconds
left to `total` are the handler's own margin; for a route whose slow work is the database, the
statement *is* that wait, so it takes the same number and leaves the same margin. Routes on the
longer rows are held by it too and lose nothing — their database work is a gate read, a metering
write, an idempotency claim, none of which is meant to approach ten seconds.

**Its reach is every statement issued on that pool**: each route handler's own work, the gate's
attribution read that runs before every authenticated request, and the content-expiry sweeper, which
leases from the same pool. **It deliberately does not reach the migration runner or the operator
commands**, which each open a connection of their own — a backfill that legitimately runs for minutes
must not be cut at ten seconds, and `server/README.md`'s still-owed `lock_timeout` decision is about
that other end of the same stall and is not discharged by this.

**What it bounds is a statement, and saying so precisely matters twice.** It cannot bound
*composition* — a handler issuing several statements can still sum past this row's `total`, which is
what SONNY-434 closes for the three account routes above and what stays true of every route that
declares no budget of its own — and it cannot bound a transaction sitting *idle* between
statements, which is a different setting and a different failure. What it does bound is the one thing
nothing else could: a single statement, including one queued behind another connection's lock, which
is where a migration's `ACCESS EXCLUSIVE` puts every reader.

**It is carried in the connection's startup parameters, and that is a mechanism rather than a
detail.** A route may set a tighter or wider budget on a connection it has leased and clear it with
`RESET statement_timeout` on the way out. `RESET` restores a parameter to the value it would have had
with no `SET` in the session — which a startup parameter supplies and a `SET` issued after connecting
does not. Had this bound been applied the second way, the first route to clear its own budget would
have taken this one off that connection for every later request that leased it, leaving a connection
indistinguishable from one that was never bounded. The two shapes are identical to read and differ
only in production. The composition that follows is that the innermost `SET` governs, wider or
narrower, and `RESET` returns to this bound rather than to none.

**One deployment shape would switch this off without failing loudly, and it is named rather than
left to be discovered.** A host that refuses the parameter at connection time — a transaction-mode
connection pooler in front of Postgres is the shape that does — would leave the gateway with no
statement bound, and the pool is lazy, so nothing fails at boot: `GET /v1/health` answers `200` and
the first authenticated request is where it surfaces. This project's documented `DATABASE_URL` is a
*session* pooler, which passes startup parameters through, so the shape is avoided rather than
handled; the manual check that would catch it is the lock row in
`docs/sonny-manual-test-checklist.md`, whose rollback-and-retry step is a real control.

**One bound is the server's alone and is not in the table, because it is not a deadline** (SONNY-322).
Nothing limited how long a caller could take to *deliver* a request — Fastify disables the underlying
option by default, and this project had never turned it back on — so a caller that sent headers and
then dribbled or withheld the body held a connection indefinitely, which is reachable without signing
in on the sign-in routes. The gateway now bounds request delivery at **120 seconds**, which is the
longest client timeout in the table above: past that instant no client is still waiting for any
route's answer, so no request a shipping client would have waited for is refused. It bounds receiving
the request and not running the handler, so it neither replaces nor constrains any deadline in the
table, and it is enforced coarsely — the runtime checks for expired connections on a sweep, so the
refusal lands tens of seconds late. A caller cut off this way gets `408 request.timeout` carrying section
7.1's envelope, which 7.2 marks retryable and 9.2's release set keeps unstored, so the retry it
invites genuinely re-runs.

**`POST /v1/transcriptions` bounds its own body read at 90 seconds**, which is that route's client
timeout in the table above (founders, 2026-09-05). It is the one route whose body is read inside its
handler rather than parsed before it, so it is the one route where the upload is not already covered
— and it is bounded precisely, on a timer the gateway owns, because the server-wide bound above is
enforced far too coarsely to hold anything. The 90 does not come from the deadlines in this table:
those bound a handler and this bounds an upload, and the two are **added** rather than compared.
**What they are added for, and against what, is section 9.2's**, which carries that arithmetic and is
the section the gateway's code cites from both constants; it is not restated here, because two copies
of a derivation are two things to keep in step and this document has already had them disagree.

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
  takes was SONNY-131's, and it took the second and third together** (2026-08-28): the session aborts
  at the failing iteration, keeps every action it has already taken, and reports it as
  `VisionSessionInterrupted`, which carries how far it got. **It adds no retry of its own**, because
  the shared client has already spent §9.3's whole per-code attempt budget before the failure reaches
  the loop — a second loop would multiply those ceilings on the longest route in this table, and
  would mint a fresh idempotency key per attempt, which §9.1 forbids. The token-expiry case is
  invisible: the shared client refreshes once and replays, which is §7.2 case 1a working. **The
  paragraph this replaces described the pre-SONNY-131 tree** — "there is no retry at all:
  `VisionSessionRunner.runLoop()` has no `catch`" — which was a true reading of `4a7d996` and is a
  stale one now; the file-line it cited has moved with the `catch` that ends it.

---

## 13. What this contract deliberately leaves open

Each item names the ticket that closes it, and nothing here was a gap that was overlooked. **Some of
it has since been answered, and the table now says which.** The `Status` column was added on
2026-08-26 (SONNY-288) because a table headed "what is still open" is read as current, and it had
stopped being so. Of its nineteen rows, **four had been answered outright, three had been answered in
part, one had acquired an owner, and eleven were still open** — and one of the four also attributed
the refresh overlap window to a ticket that section 3.3 already said does not own it. Four plus three
plus one plus eleven is the nineteen; every row below carries which of the four it is.

**The `Status` column is a board reading, not a contract term.** It was resolved against Plane and
against the tree at `728d1ea` on 2026-08-26, and it goes stale the way any board reading does; the
`Open` and `Owner` columns are the durable halves. **Decided** does not mean built — it means the
question this contract left open has an answer, recorded where the row says. **Open** means it has
none.

**Three rows have been resolved again since, and each carries its own date**, which is what a column
resolved at one instant has to do once it is amended at another: on 2026-08-28, SONNY-134's
retention window and its snapshot-lineage row both moved from Open to Decided and built; on
2026-08-30, the host row was amended when the founders dropped the deploymind stage (SONNY-373).
Every other row is still the 2026-08-26 reading and has not been re-checked; a reader comparing two
rows should read the date on each rather than the heading above both.

| Open | Owner | Status, resolved 2026-08-26 at `728d1ea` |
|---|---|---|
| The host, and proving a 4,200,000-byte body lands on it, and that a request may sit 105 s on a slow upstream | SONNY-125 | **Decided; both proofs re-owed on the real host.** The founder chose a VM over serverless on 2026-08-21 — deploymind, then Oracle Cloud, then AWS, with Supabase keeping auth and Postgres (`docs/sonny-row-12-host-decision.md` §12.2); **amended 2026-08-30 (SONNY-373): the founders dropped the deploymind stage, leaving Oracle Cloud then AWS** (§12.4). SONNY-125 is Done. Both proofs passed, but against Supabase Edge Functions — the host that decision then moved away from — so they are the evidence the choice was made against rather than a measurement of the shipping host, and §12.2 says every Edge ceiling stops binding. On the shipping host they are unmade: nothing has been deployed remotely, and `server/scripts/deploy.sh` refuses `staging` and `production` (`grep -n 'exit 3' server/scripts/deploy.sh` → `395:` at `f675b3b`). The first real remote deploy is recorded as owed on SONNY-126 |
| **Who builds `GET /v1/meta`, the `410 version.unsupported` gate, and the deprecation headers** | **SONNY-204**; the Mac's half is **SONNY-402** | **Decided and built, server-side** (2026-09-03). All three landed together — `server/src/routes/meta.ts`, `server/src/version/gate.ts`, `server/src/version/policy.ts` — with `MINIMUM_SUPPORTED_CLIENT`, `RECOMMENDED_CLIENT` and `UPGRADE_URL` as the deployment's own policy, and the gate installed before the auth gate so an outdated client is not sent round a refresh loop by an expired token. **Both bounds default to `0.0.0`, which disarms the gate**: shipping it refuses nobody until a founder sets a real minimum, because 8.4 makes raising the minimum past a version that had no deprecation period a breach of this contract and a default carries no deprecation period. The Mac calls none of it yet (SONNY-402, Backlog). This row read "**Owned, not built**" until 2026-09-03 and "**nobody yet** — SONNY-155, Backlog, untriaged" until 2026-08-26 (4.1) |
| Whether the OAuth sign-in calls are replay-safe (9.3) | SONNY-129, alongside the body shape | **Open.** SONNY-129 is in Backlog |
| Server language, framework, database, deploy path, migrations, credential rotation | SONNY-126 | **Decided.** SONNY-126 closed 2026-08-21: TypeScript on Node >= 22, Fastify, Zod, Postgres via `pg`, a plain-SQL migration runner that refuses a file carrying no `-- @rollback` half (`ls server/src/db/migrations/*.sql \| wc -l` → 10), a containerized deploy path coupled to no host, and credential rotation as an ordered list so a rotation is three independently valid deploys (`server/README.md`). Two acceptance criteria — health on staging and production, a migration rolled back on staging — were deferred by the founder on 2026-08-21 because no remote environment exists; that is the row above |
| The per-user spend-cap mechanism, and what happens when two requests from one user race it | SONNY-125 names it, SONNY-135 implements it | **Named, demonstrated and now built** (2026-08-28). SONNY-125 settled the mechanism — reserve-then-settle in one statement, with the race and its residuals worked through against Postgres 17 (`docs/sonny-row-12-host-decision.md` §9, §9.3, §9.5); it is a property of Postgres, not of a host, so it survived the move off Edge Functions intact. SONNY-135 implemented that one rather than a second beside it: `sonny.usage_period` with the conditional `UPDATE`, `sonny.usage_reservation` with an expiry and a sweep whose per-period aggregation is §9.5's first residual closed, and a settle that takes a boolean rather than an amount, which is why §9.5's *second* residual cannot arise while one metered call is one unit. The race is held by a forced interleaving and a fifty-way battery against a real Postgres, with the naive read-then-write committed beside them as a control |
| The identity-linking rule, and how it survives Hide My Email relay addresses | SONNY-127 | **Decided and built.** The key is `(provider, subject)`, never the email address; the rule is `docs/sonny-identity-linking-rule.md`, pinned by `server/test/linking.db.test.ts`, and the relay case is its §4. Decided 2026-08-21, with rule 2 amended by founder decision on 2026-08-22 to flag rather than link. SONNY-127 closed 2026-08-23. What remains is not the rule but surfacing `link_hint`, which is SONNY-128's and SONNY-129's (3.6) |
| Sign-in code lifetime, rate limits, and the refresh overlap window's length | SONNY-127 for the first two; **the platform's** for the third | **Decided, all three.** A code lives 600 s and the four rate limits are set (3.6). The overlap window was never SONNY-127's: under the 2026-08-21 decision to serve auth from Supabase Auth it is the platform's, and it is 10 seconds (3.3, and section 14's 2026-08-21 row). This row still named SONNY-127 for it until 2026-08-26, contradicting 3.3 |
| Literal user-facing copy for every `code` in section 7 | SONNY-128 (sign-in), SONNY-136 (everything else) | **Open.** SONNY-128 is In Progress; SONNY-136 is in Backlog |
| The audio duration cap and its refusal | SONNY-130 | **Open.** Backlog |
| Vision mid-loop failure behaviour: retry, abort, or a new typed error | SONNY-131 | **Decided and built** (2026-08-28). **Abort at the failing iteration, keeping what the session already did, reported as a new typed error** — `VisionSessionInterrupted`, whose declaration in `VisionSessionRunner.swift` carries the reasoning. No retry at this level, because `SonnyBackendClient` has already spent §9.3's whole per-code attempt budget before the failure reaches the loop and a second loop would multiply those ceilings while minting a fresh idempotency key per attempt, which §9.1 forbids. The token-expiry case §12 names is invisible: the shared client refreshes once and replays |
| Failover trigger, fallback order, and whether the user is told | SONNY-132 | **Open.** Backlog |
| Per-provider retention and training configuration values | SONNY-132, with SONNY-110's answer landing in it | **Open.** Both in Backlog |
| The exact retention window inside 30–90 days | SONNY-134 | **Decided and built** (2026-08-28). **Thirty days**, the short end of the founder's own range, confirmed by him at the start of SONNY-134's implementation because the ticket recorded it as a recommendation and nothing had settled it. It is `CONTENT_RETENTION_DAYS` in `server/src/config.ts`, defaulted to 30 and bounded 1–365, and `sonny.retained_content.expires_at` is written from it **at insert** — so a row carries the window it was stored under and raising the setting cannot extend the life of content already held |
| Snapshot lineage's concrete shape, and what the support lookup may see | SONNY-134 | **Decided and built** (2026-08-28). **Lineage:** `sonny.training_snapshot` (label, window, routes, builder version, its own nullable `expires_at`) and `sonny.training_snapshot_member`, which holds a **copy** of the content plus the `content_id` it came from — a copy because the live store is on the 30-day clock and a snapshot is not, and `content_id` deliberately **not** a foreign key, because `ON DELETE CASCADE` would let ordinary expiry empty a sealed snapshot. Every deletion path reaches members and records which snapshots it touched in `sonny.content_deletion`. **Support lookup:** account state and usage read freely; content only through a command that refuses without an operator and a reason and writes a `sonny.content_access` row — stated in the code as a discipline and a trace rather than a boundary, since anyone who can run it holds `DATABASE_URL` |
| `grace_seconds` and `skew_tolerance_seconds` **as carried in the entitlement claim (5.3)** | SONNY-135 | **Decided and built** (2026-08-28). **259,200 s of grace and 300 s of tolerance**, both carried in the claim and both argued at 5.3 against the 24-hour lifetime and the 8-hour refresh they sit beside; the tolerance is applied in both directions, which 5.3 explains is the inverse of 3.5's rule for a reason that inverts with it. **Not the token-expiry clock skew of 3.5**, which is a different value, was SONNY-127's, and is set at 30 s — the two share a name and this row used to be read as covering both |
| Which capability keys are gated | SONNY-23 (row 18) | **Open.** Backlog |
| Plans, prices, allowances, credit weights | SONNY-17 planned it; **SONNY-212** implements | **Split: the shape is decided, the numbers are not.** Free plus exactly one paid tier, screen control as the only paid line, auto-top-up opt-in and off by default — founder, 2026-08-16, ratified 2026-08-21, and SONNY-17 closed that day as a planning ticket. The numbers are deliberately unset: they wait on a measured per-session screen-control cost that nothing records today (SONNY-133, Backlog) and on SONNY-162's web-research cost. They land on SONNY-212, Backlog, and the dollar amounts are the founders' own |
| Whether requests are compressed on the wire | SONNY-146 built the encoder; **SONNY-317** wires it in | **Answered: not today, and the mechanism is half-built.** SONNY-146 closed 2026-08-18 with the gzip encoder and a per-endpoint switch, defaulted off because the route the client talked to then answered a gzip-encoded body with a `500` (6.4). **This row said SONNY-131 flips it when the client is repointed, and that was the same wrong sentence 6.4 carried**: the gateway implements no decompression, so flipping the client alone is a `400` on every request. SONNY-131 repointed the client and left it off; SONNY-317 owns both sides |
| Enterprise or team entitlements | SONNY-107 (row 19) | **Open.** Backlog |

---

## 14. Changes to this document

A change here is a change to what twelve tickets were written against, so it carries a date, a
reason, the ticket that prompted it, and — from the back-fill of 2026-08-27 onward — the commit it
landed in. Rows sit at their date. **The log was append-only until 2026-08-27**, when four rows dated
2026-08-21 and 2026-08-22 were written into the middle of it; the paragraphs below are that
back-fill's record of itself, which is the thing this section was not doing.

The log starts once the document is merged. Iteration inside SONNY-124's own branch — including its
pre-merge review round — is part of "created" and does not get a row; a changelog that recorded the
author's own drafting would bury the changes a downstream session actually has to notice.

**The back-fill of 2026-08-27 (SONNY-297).** Between 2026-08-21 and 2026-08-26 this section recorded
nothing while **seven** commits amended the document, and three of the four rows written from them
change something a downstream ticket reads — 3.6's new `link_hint` field, 3.6's narrowed disclosure
of the three sign-in-code errors, and 3.1's verification gate. Every one of the seven dated itself in
place in the body, which is why nothing looked wrong to anyone reading a paragraph; this section is
the index a reader consults to find them, and it did not list one. What the back-fill establishes,
and what it does not, is worth separating, because a log that has been written after the fact invites
more trust than one that has not:

- **The population was closed when the rows were written, and that is the one completeness claim
  available here.** Twelve commits had ever touched this file
  (`git log --format='%h' -- docs/sonny-backend-api-contract.md | wc -l` → 12 at `554d85a`, the head
  this branch is based on; `--follow` answers the same 12, and `--diff-filter=R` over the same path
  answers 0, so no rename hides an earlier one), and every one is an ancestor of `origin/main`. So no
  amendment to *this file* escaped the list. The count grows with every later amendment, this one
  included; what the back-fill rests on is that it was closed at `554d85a`. **It was re-measured
  there rather than carried across a rebase**: the back-fill was written against `9ac586b`, PR #137
  merged beneath it, and the same command answers the same 12 — which is what says that merge
  amended nothing here and owes no row, rather than anyone's word for it. Which commit each row
  covers: **2026-08-17** is `25f75eb` with its pre-merge review round `5727da1`; **2026-08-21 (the
  JWT row)** is `778e441`, which wrote that row; the four back-filled rows name their own commits;
  **2026-08-26** is `4aa50ec` and **2026-08-27 (SONNY-130)** is `adba172`. The check on all twelve:
  `for t in 25f75eb 5727da1 778e441 7445fb0 d0cdfb1 1db893e 8d54bac 5c24df5 a12ef99 f0745f4 4aa50ec
  adba172; do git merge-base
  --is-ancestor $t origin/main; printf '%s %s  ' "$t" "$?"; done` → `0` for all twelve, run
  2026-08-27 at `554d85a`. **Every SHA this section cites passes it**, not only those twelve — 17
  distinct tokens (`sed -n '/^## 14\./,$p' docs/sonny-backend-api-contract.md | grep -ohE
  '\b[0-9a-f]{7,40}\b' | sort -u | wc -l` → 17), the other five being `9ac586b`, `4a7d996`,
  `310f893`, `6b72909` and `554d85a`, each `0` under the same loop. Unlike the count in the header,
  this one covers commit citations, which is why the two are kept apart.
- **It does not establish that a row's summary is the whole of its diff.** A back-filled row is one
  session's reading of a commit it did not make. The commit is cited so a reader can go to the diff
  instead of trusting the reading, and the *reason* in such a row is inferred from that diff and its
  commit message rather than from the conversation that decided it.
- **Nor was the wider search run.** A change to what this contract *means* that was settled somewhere
  else — a ticket, the changelog, a decision document — and never brought into this file would not
  appear as a commit on this path, and nothing here went looking for one. This section indexes
  amendments to this file, and that is the whole of what it now claims.
- **One shape moved in the seven.** No fenced example body was touched by any of them, and exactly
  one markdown table row was — `1db893e`'s, four added and none removed, which is 3.6's new two-value
  `link_hint` table rather than an edit to an existing row. Run 2026-08-27 at `554d85a`:

````
for s in 7445fb0 d0cdfb1 1db893e 8d54bac 5c24df5 a12ef99 f0745f4; do
  d=$(git show $s --format= -- docs/sonny-backend-api-contract.md)
  printf '%s fence=%s row+=%s row-=%s\n' "$s" \
    "$(printf '%s\n' "$d" | grep -cE '^[+-]```')" \
    "$(printf '%s\n' "$d" | grep -cE '^\+\|')" \
    "$(printf '%s\n' "$d" | grep -cE '^-\|')"
done
````

→ `fence=0` for all seven; `row+`/`row-` are `0`/`0` for six and `4`/`0` for `1db893e`.

**One pair of rows is out of date order, and it is left that way rather than moved.** The 2026-08-27
SONNY-130 row sits above the 2026-08-26 SONNY-288 row. That was not a rebase artifact: SONNY-288's
row merged at `310f893`, which is an ancestor of `6b72909`, the commit SONNY-130's branch was cut
from (`git merge-base --is-ancestor 310f893 6b72909`, read with nothing between it and `$?`, exits
`0`), so the row it belonged after was already present when `adba172` inserted above it. Both are
byte-identical to the versions their own branches merged. Recording the inversion costs a reader one
sentence; rewriting two merged rows to tidy it would cost more than it buys, and this section is a
record rather than a tidy list.

| Date | Change | Ticket |
|---|---|---|
| 2026-08-17 | Created, at `main` `4a7d996` | SONNY-124 |
| 2026-08-21 | **3.1 — the access token is a JWT rather than opaque.** Founder decision of 2026-08-21 to serve auth from Supabase Auth, which issues JWTs. The client's obligation not to decode it or decide anything from it is unchanged and is now carried by this contract rather than by the encoding. Three things this does **not** change, checked against the platform rather than assumed: 3.3's rotation, overlap and reuse detection are exactly what Supabase Auth does (10-second reuse interval; reuse beyond it revokes the whole family), 3.2's response shape is unchanged, and 3.6's three code failures are unchanged — the gateway derives them from its own issuance record because the provider returns one error for all three. | SONNY-127 |
| 2026-08-21 | **3.3 — the refresh overlap window is the platform's and 10 seconds, not SONNY-127's to set; and 3.1 gains, then reassigns, the note that nothing verifies a presented access token.** Two commits, both PR #87 review findings: `7445fb0`, then `d0cdfb1`. 3.3 had read "the overlap's length is SONNY-127's to set", written before the 2026-08-21 decision to serve auth from Supabase Auth; under that decision the window is the platform's. The 10 seconds is the figure the row above already names, so only the *ownership* was new — which is the half a reader of that row alone would not have. 3.1's note (F2) first said verification was SONNY-128's and was corrected the same day (second round, F5) to SONNY-203, because SONNY-128 is the client half and its never-touch list forbids `server/`, so it could never have supplied it; `d0cdfb1` added the HS256 pin with it. **No shape changed** in either commit: no fenced example body and no table row moved. Back-filled 2026-08-27 (SONNY-297). | SONNY-127 |
| 2026-08-22 | **3.6 — `link_hint`, a new optional field on the token response** (`1db893e`). The one shape this document gained between 2026-08-21 and 2026-08-26. Present when the server can see a reason to suspect a sign-in belongs with an existing account and cannot prove one; advisory, naming no account and carrying no identifier, because naming one would answer "does this address have an account?" to anyone who can reach the endpoint. Two values, `relay_address_may_belong_to_existing_account` and `verified_email_matches_existing_account`. A client that ignores it is correct and gets two accounts; there is no failure mode in ignoring it, only a worse experience, and neither the field nor the prompt merges anything. **3.2's fenced token-response example does not show the field**, and this row does not change that — it is stated so a reader of 3.2 alone does not conclude the field does not exist. Surfacing it is SONNY-128's and SONNY-129's. It did reach its reader without this section's help: the client decodes it and pins that it changes nothing (`SonnyBackendClient.swift:705` and `SonnyAccountServiceTests.swift:192`, `aTokenResponseCarryingALinkHintStillSignsInNormally`, at `554d85a`). Back-filled 2026-08-27 (SONNY-297). | SONNY-127 |
| 2026-08-22 | **3.6 — the three sign-in-code errors, and the per-address rate-limit refusal, are disclosed only to a caller who can be seen to have requested the code.** Two commits: `8d54bac`, widened by `5c24df5` after measurement. The three distinct codes were an account-existence oracle and a working one — one unauthenticated request per address, carrying a code known to be wrong and never calling `email/start`, returned `auth.code_used` for a mailbox whose owner had signed in, `auth.code_expired` for one that had asked and not used, and `auth.code_invalid` for an address with nothing; reproduced against a real database, still reading `auth.code_used` after 400 simulated days, and unbounded across 200 addresses probed from one source. Everyone outside the flow now gets `auth.code_invalid`, gated on the issuance's recorded source matching the caller's and on the issuance being recent; `5c24df5` put the per-address refusal behind the same gate, because answering `429` to every caller made the attempt *count* readable. **What a client in the flow sees is unchanged**, which is why nothing on SONNY-128 moved; what narrowed is what a caller who never called `email/start` can learn. The residual is stated in place rather than implied: the match is on a salted hash of `request.ip`, so co-tenants behind one public address share a source, and a proxy with `TRUSTED_PROXIES` unset collapses every caller to one. The unconditional fix is a flow token across `email/start` and `email/verify` — two request/response shapes, SONNY-128's, not built. **No fenced example body and no table row moved.** Back-filled 2026-08-27 (SONNY-297). | SONNY-127 |
| 2026-08-22 | **3.1 — access-token verification exists, the gate is deny-by-default, and a signed-out access token keeps verifying for one hour and thirty seconds.** Two commits: `a12ef99`, corrected by `f0745f4`. The token is verified as HS256 with the algorithm pinned, checking `iss`, `aud` and `exp` and trusting `sub` as the user id, and that `sub` is then attributed to a live Sonny account, so a cryptographically perfect token naming a closed one is refused. **The gate is deny-by-default**, which makes 4.1's `Auth` column a list of the routes that are *public* while everything else is challenged — so a route added without a thought about authentication refuses everyone rather than serving quietly. **What verification cannot do is un-issue a token**: an access token is self-contained, so signing out revokes the refresh family while the access token keeps verifying until its own `exp` plus 3.5's 30-second skew tolerance. `f0745f4` is that correction — the paragraph had said "one hour" where the honest figure is one hour and thirty seconds on Supabase's default lifetime. A closed account is refused immediately on every request; the remaining window is SONNY-237's. **No shape changed**: 4.1's table was not edited, only the meaning its `Auth` column already carried made explicit, and no fenced example body moved. Back-filled 2026-08-27 (SONNY-297). | SONNY-203 |
| 2026-08-27 | **4.4 — the audio duration cap exists, and 6.1's byte limit is now the backstop it was described as.** The one sentence 4.4 wrote in the present tense about work that had not happened — "there is no maximum duration today ... the duration cap and its user-facing refusal are SONNY-130's" — was true when written and is not now. 180 seconds, enforced on the Mac before a byte is sent, with the refusal's exact wording recorded. **No shape changed**: no endpoint, request body, response body, header, error `code`, size limit or timeout in this document moved, and 6.1's 10 MiB is unchanged. The stale `AudioCommandRecorder.swift:32-38` citation is restamped at `6b72909`, where the settings block is `:34-39`. | SONNY-130 |
| 2026-08-26 | **13 — every row resolved against the board and the tree, and nine body statements corrected. No shape changed.** Section 13 was a "what is still open" table with no status column, which a reader takes as current; of its nineteen rows four had been answered outright, three in part, one had acquired an owner, eleven were still open, and one of the four also attributed the refresh overlap window to SONNY-127 where 3.3 already said it is the platform's. The `Open` and `Owner` columns are unchanged; a dated `Status` column was added and marked a board reading rather than a contract term. **The nine**, all one class — a present-tense sentence about work that has since happened: **1**, the host choice is no longer held, it was made on 2026-08-21; **3.5**, the clock skew is set at 30 s and was never SONNY-135's to set, which 3.1 already contradicted; **3.6**, the code lifetime and the four rate limits are set; **3.6**, the claim that an OAuth sign-in lands on the same account as an email sign-in, which the `link_hint` table directly above it contradicted and which is false under the 2026-08-22 rule; **3.6**, `GET /v1/health` is built rather than being SONNY-126's to shape; **4.1**, `/v1/meta`'s owner is SONNY-204, not "nobody yet"; **5.1**, `CompletedTaskRecord.id` exists rather than waiting on SONNY-115; **6.4**, SONNY-146 is complete rather than filed and in Backlog; **10.2**, SONNY-127 built the `training_consent` field and deliberately did not build its write path. Nothing SONNY-128 or SONNY-129 codes against moved: no endpoint, request body, response body, header, error `code`, size limit or timeout in this document was touched, and all sixteen fenced example bodies are byte-identical to their previous versions. The header now states which parts of this document are live contract, which are a dated snapshot at `4a7d996`, and which are a board reading. | SONNY-288 |
| 2026-08-28 | **6.4's forward-looking sentence is corrected, 12's third rule is answered, and 13's two rows follow both.** §6.4 said the client's `compressesRequestBody` switch "travels with the endpoint, so SONNY-131 flips both in one edit when the client is repointed at Sonny's own gateway". That reads as a one-line optimisation and is a `400` on **every** screen-control request: the gateway implements no request decompression, and Fastify hands a gzip-encoded body to the JSON parser as bytes. Found by SONNY-130 (PR #139, F9) and left as a note on SONNY-131; corrected here because a note on a ticket is not where the next reader meets it. §6.4's obligation is unchanged — the server still **must** accept the encoding — and it now says plainly that none of its three parts is implemented and that **SONNY-317** owns all of them together with the client switch, because the end-to-end test needs both sides at once. §12's third rule — "which of retry, abort-with-partial-history, or a new typed error the session takes is SONNY-131's" — is answered: **abort at the failing iteration, keep what the session did, report it as a typed error**, with no retry at the loop level because §9.3's per-code budget is already spent one layer down and a second loop would mint a fresh idempotency key per attempt, which §9.1 forbids. Section 13's mid-loop row moves from Open to Decided-and-built, and its compression row's owner moves from SONNY-131 to SONNY-317 with the wrong sentence named. **No shape changed**: no endpoint, request body, response body, header, error `code`, size limit or timeout in this document moved — §4.5, §6.1's table and §12's table are byte-identical, and `/v1/screen/analyze` was already in all three. Landed in `b3c2021`, whose own tree carries this row with the reference unfilled — the row names the commit the change landed in, and that commit cannot contain its own hash. | SONNY-131 |
| 2026-08-28 | **11 — the metering event is built, and the section now describes a table rather than a plan.** `sonny.metering_event` exists (`server/src/db/migrations/0012_metering_records_what_every_call_cost.sql`), every one of the five model routes writes to it, and the vision route — which recorded usage nowhere at all — is the reason the section exists. Six rows of 11's table moved: `user_id` is **renamed `account_id`**, because section 5 makes the account the billable identity and one person can hold two Supabase users on one account; `failed_over` and `image_media_type` are **added**, the first because a failover spends a second upstream call nothing else records and the second because half of real captures are each format and the byte figure cannot be read without knowing which; and `idempotency_key`, `provider`, `model`, `token_source`, `request_bytes`, `response_bytes`, `upstream_duration_ms`, `retention` and `client_version` become **nullable**, each with the null's meaning stated in its own row — the alternative in every case was a zero or an invented value that reads as a measurement. Three things are stated that 11 left open and building it settled: which requests produce an event at all (a table of six cases, of which the `409` row is the one that is not merely "free"), that SONNY-131's four proposed outcome values map onto 11's five without loss, and that the founder query path is a **command** (`npm run usage`) rather than a surface — the usage UI is SONNY-214's. 11's "a live UI surface" is corrected: no view reads `taskUsageSummary`, which PR #144's F1 measured; the rule it protects is unchanged and is now pinned end to end by a test. **No shape changed on the wire**: 11 is what the *server records*, not a request or a response — no endpoint, request body, response body, header, error `code`, size limit or timeout in this document moved, and 2.4, 4.5 and 12's tables are byte-identical. | SONNY-133 |
| 2026-08-27 | **14 — the four rows dated 2026-08-21 and 2026-08-22 are back-filled, and 10.2 records a known divergence.** This section had recorded nothing since 2026-08-21 while seven commits amended the document; the rows were written from those diffs by a session that made none of the changes, and the preamble now states the population they came from, the one completeness claim that population supports, and the two it does not. **No shape changed by this row's own work.** 10.2 gains a divergence record: this document names `training_consent`'s values `"granted"` and `"not_granted"` where the tree has `training_consent boolean NOT NULL DEFAULT false` (`server/src/db/migrations/0002_accounts_and_identities.sql:28` at `554d85a`). The guarantee is identical, the field crosses no boundary so the two names have no wire encoding to protect, and it is **recorded rather than reconciled** — which side moves is unsettled and owed a row of its own when someone settles it. The header's SHA census is corrected from four to six: `6b72909` was added to 4.4 on 2026-08-27 by `adba172` without that sentence or its ancestry loop moving, and `554d85a` is the stamp on 10.2's new evidence. **PR #137 merged beneath this row while it was open and owes no row of its own**, which is a reading of the population rather than anyone's word for it: it changed no line of this file, and the commit count over this path is the same 12 at `554d85a` as at `9ac586b`. | SONNY-297 |
| 2026-08-28 | **5.3 — the two values it left open are set, `sub`'s meaning is stated, and its revocation-bound sentence is corrected.** `grace_seconds` is **259,200** and `skew_tolerance_seconds` is **300**, both carried in the claim as this section already required and both argued in place against the 24-hour lifetime and 8-hour refresh cadence they sit beside; 13's row for them moves from Open to Decided-and-built. **The tolerance is applied in both directions, which is the inverse of 3.5's rule**, and the inversion is argued rather than asserted: there the server judges a token against its own clock and a token from the future is either the server's clock being wrong or a forgery, while here the client judges a claim the gateway *signed*, so `issued_at` cannot be attacker-chosen and a not-yet-valid claim means this Mac's clock is behind. **`sub` is the identity that asked and the claim's content is the account's** — this section already wrote the field as `<user id>`, and the reason it must stay one is a client obligation: the Mac has to check that a cached claim belongs to the session it holds or a claim cached before a sign-out grants to whoever signs in next, and `user.id` from 3.2 is the only identifier the Mac ever learns. **The revocation-bound bullet is corrected**: "within the claim's lifetime, because that lifetime is the bound" is true of an online client, whose real bound is the shorter 8-hour refresh, and understates an offline one by exactly the grace window the same sentence recommends — the offline bound is lifetime **plus** grace, 96 hours, and it is now stated as two numbers. Two further statements of fact rather than of intent: `GET /v1/meta` is not built, so rotation-without-a-release is promised here and delivered by nothing yet (SONNY-204, Backlog); and the client's shipped key set is **empty** in every build, because no gateway has been deployed to have signed anything, which refuses every gated capability and affects no free one. **The fenced payload example changed** — the two zeroes became the two set values and the illustrative instants moved to the lifetime the values describe — and it is the only fenced body touched; no endpoint, request body, response body, header, error `code`, size limit or timeout moved. 13's spend-cap row also moves from named-not-implemented to built. | SONNY-135 |
| 2026-08-28 | **9.2 — two founder decisions recorded, and one implementation limit stated.** The gateway implemented no `Idempotency-Key` handling at all until this ticket, so 9.2 had never been built against; building it surfaced a conflict between 9.2's first sentence and 9.3's retryable list that cannot be resolved by reading either more carefully. A stored *retryable* failure is now released rather than replayed, so a same-key retry re-runs — without which a `429` is a twenty-four-hour ban on that operation and a `503` during a deploy freezes every request in flight. The at-most-once metering guarantee is untouched and is what makes the release safe: the claim survives it, so the re-attempt cannot bill again. A `POST` with no key is served rather than refused, because 9.1 is the client's obligation and the only client meets it. And conflict detection on `POST /v1/transcriptions` is by declared body length rather than by body, because a multipart body is consumed inside the handler and buffering it would take 6.1's audio ceiling away from the guard that fires while the part is still streaming. **No shape changed**: no endpoint, request body, response body, header, error `code`, size limit or timeout in this document moved. **9.3's `email/verify` row gains one clause and is the only table cell edited** — it read "the idempotency record returns the original *result*, including the original failure", which the carve-out above makes untrue for the retryable subset, and a reader arriving at 9.3 alone would have taken the pre-decision behaviour. This row claimed 9.3 was byte-identical until PR #142's review found the contradiction that claim was concealing (F3). Two further limits are now stated in 9.2 rather than left to a code comment: a streaming response gets none of these guarantees, and a claim's lease can be outlived on the one route whose body read is unbounded. | SONNY-300 |
| 2026-08-28 | **10 — retention is built, and the two questions 13 left open under it are answered.** The content store exists (`server/src/db/migrations/0013_content_is_kept_on_its_own_clock.sql`) and holds request text, voice audio, redacted screenshots, the served response and provider error bodies. **The content clock is 30 days**, confirmed by the founder on 2026-08-28 from the 30–90 range his 2026-08-16 decision names — 10.3 and 11's own header had both been assuming it in prose while nothing had settled it, so 13's row moves from Open to Decided and built. **Snapshot lineage's shape and the support lookup's reach**, 13's other SONNY-134 row, are answered in that row and in `server/README.md`. Two sentences elsewhere in this document stopped being true and are corrected where they live rather than only here: 4.6 and 10.1 described SONNY-134's rules in the future tense, and `routes/auth.ts`' own comment said `DELETE /v1/account` "does not reach retained content", which it now does — content, training-snapshot membership, and the account's stored idempotency response bodies (SONNY-319, filed by SONNY-300 and closed here). **Two things this row does not claim.** 10.2's boolean-versus-strings divergence is unchanged and still recorded rather than reconciled; honouring the field was SONNY-134's and the spelling was not. And 10.1's `retention` field, 2.4's table and 2.4.2's no-default rule are untouched — the client's half shipped with SONNY-130 and SONNY-131 and this ticket is the server keeping the promise it already made. **No shape changed on the wire**: no request body, response body, header, error `code`, size limit or timeout moved, and 4.6's response shape is served exactly as written — the one new route, `DELETE /v1/tasks/{task_id}`, was already in 4.1's table and in 4.6 with SONNY-134 named as its owner. | SONNY-134 |
| 2026-08-28 | **9.2 gains a third decision, and 10.1 a second accepted cost: an incognito response body is not stored, so a repeat of an incognito call re-runs.** PR #148's review measured what 10.1 and 9.2 cost each other (F1): the key store keeps the served response for twenty-four hours and had no notion of `retention`, so `POST /v1/plan` with `retention: "none"` and an `Idempotency-Key` left the content store empty and left **the model's reply verbatim** in `sonny.idempotency_key` — outside the content clock, outside consent, and outside what `DELETE /v1/tasks/{task_id}` reaches. The two promises cannot both hold for such a request and 10.1 wins, because it is the one the user was given and because its own rule is that the guarantee lives where the storing happens. **Exactly one of 9.2's four bullets changes and only for `retention: "none"`** — the claim, the lease, the fencing token and the fingerprint are unchanged, so the `409`s and the at-most-once metering guarantee are untouched; what goes is the replay, and the second provider call a retry then makes is unbilled, which is the same trade 9.2's first decision already makes. Keyed on an explicit `"none"` rather than on "not `standard`", so the four auth routes keep replay. **No shape changed on the wire**: no endpoint, request body, response body, header, error `code`, size limit or timeout moved, and 2.4's table and 2.4.2's no-default rule are byte-identical — a client cannot tell this apart from a retry that re-ran for any other reason, which 9.3 already permits. | SONNY-134 |
| 2026-08-30 | **4.1 gains two routes, and one of them is the first entry in this table no client ever calls.** `POST /v1/billing/checkout` is an ordinary authenticated route: it hands a signed-in caller the hosted checkout link with its own account id on it. `POST /v1/billing/webhook` is the payment provider talking to the gateway rather than the Mac talking to it, so its `Auth` cell says **a mechanism** — an HMAC signature over the exact bytes of the body — rather than `yes` or `none`. **It is in this table because `server/src/auth/gate.ts`'s deny-by-default list is derived from this column and 2.2 names this column the single source of truth**: a route present in that list and absent from this table would make the gate's own stated invariant false, and would leave seven genuinely public routes beside one that grants paid entitlements with nothing to tell them apart. It is deliberately **absent from 2.2's convenience list**, which exists so a client does not attach an access token to a call made before it has one — no client makes this call, and naming it there would invite one to try. **No shape changed for any client**: no existing endpoint, request body, response body, header, error `code`, size limit or timeout in this document moved, 5.3's claim is byte-identical, and both new rows are additive. What 5.3's claim now *carries* can change without this document changing — a payment failure opens a grace window and the claim's capability list empties when it closes — which is 16.4's grace period reaching the mechanism 5.3 already described. | SONNY-211 |
| 2026-08-30 | **7.2 gains one code: `entitlement.already_subscribed`, 409, on `POST /v1/billing/checkout` alone.** A second defence beside the entitlement-side refusal that SONNY-211's review (PR #178, F1) required: `sonny.entitlement` holds one subscription per account, so a second subscription's events overwrote the first's and cancelling the duplicate revoked access the other was still billing for. The webhook side refuses that and is what actually holds the property; this code is the checkout route declining to hand a link to an account already live on a subscription. **What it does not close is stated rather than implied**: `checkoutUrlFor` returns a *static* link, so two tabs obtained theirs before any subscription existed and neither asks the route again — the concurrent races are closed by the webhook-side refusal, not here, and the complete checkout-side answer is a per-user checkout session, recorded as a residual. **No existing shape moved**: no endpoint, request body, response body, header, size limit or timeout changed, and no existing `code` changed meaning — §8.2's breaking-change rule is about changing what a code means, and this adds one. A client that does not yet map it falls back to its generic handling, which is correct for a refusal it should not be able to provoke; the copy is SONNY-136's. | SONNY-211 |
| 2026-08-31 | **4.1 gains `POST /v1/billing/portal`, 7.2 gains `entitlement.no_subscription`, and the gateway makes its first outbound call to a payment provider.** An authenticated route that mints a hosted customer-portal session and returns its URL, so a subscriber can change a payment method, read invoices or cancel. **The outbound call is a deliberate reversal of a property SONNY-211 established** — its record states the hosted checkout "needs no provider API credential and makes no outbound request", and both halves of that stop being true here. The reason is identity, not convenience: the provider's *static* portal authenticates the human by emailing a one-time code to the address on their **provider** record, and `docs/sonny-identity-linking-rule.md:14` states that Sonny's identity key "is never the email address" — §2 of that document records Sign in with Apple returning `abc123@privaterelay.appleid.com`. So a Hide My Email user, or anyone whose Sonny sign-in and provider checkout used different addresses, could not reach their own billing portal at all, with no error this gateway can surface and no recovery the app can offer. A credential is a cost the founders manage by rotating it; that one is a cost the user pays and nobody can fix. **The lookup needs no new state**: `checkoutUrlFor` already sends the account id as `customer_external_id`, so the provider's customer carries it as `external_id` and `external_customer_id` resolves it — no read of `sonny.entitlement`, no column, no migration. **`entitlement.no_subscription` is the mirror of `entitlement.already_subscribed`** and is deliberately not an error condition: it is what a signed-in user who never subscribed looks like, which is most accounts, and the app is expected to know its own entitlement and not offer the control. The other three failures reuse 7.2's existing `provider.timeout`, `provider.unavailable` and `provider.rejected` unchanged. **No existing shape moved**: no endpoint, request body, response body, header, size limit or timeout in this document changed, no existing `code` changed meaning, 5.3's claim is byte-identical, and both new rows are additive. The portal route is **absent from 2.2's convenience list** and challenged by the gate — `gate.test.ts` and `billing.test.ts` each assert it. | SONNY-216 |
| 2026-09-02 | **No shape moved, and one clause of the row above needs its scope read.** `POST /v1/billing/portal` now reads `sonny.entitlement` before it calls the provider, answering an account this gateway has recorded no subscription for with the existing `entitlement.no_subscription` and no outbound call (SONNY-387). **Nothing in this document changed**: no endpoint, request body, response body, header, error `code`, size limit or timeout moved, both 409 paths return byte-identical bodies — same status, same `code`, same `message`, same `retryable`, which `billing.test.ts` asserts rather than this row asserting it — and 7.2's row for that code is untouched, since the code's meaning is the same fact about the same account whichever side learned it. This row exists for the sentence in the 2026-08-31 row reading *"**The lookup needs no new state**: … no read of `sonny.entitlement`, no column, no migration."* That remains true of what it describes — the *provider-side customer lookup*, which still resolves by `external_customer_id` and still needs no stored state — but it is the sentence a reader greps to answer "does the portal route touch the entitlement table", and read that way it now answers wrongly: the route does, on every request, and no column or migration was added. The 2026-08-31 row stays verbatim as the dated record it is; this is the correction, at the end of the log where the next reader meets it. | SONNY-387 |
| 2026-09-03 | **Section 8 is built, and it gains three paragraphs recording what building it decided; 7.1 gains one field on one code.** `GET /v1/meta`, the `410 version.unsupported` gate on every route, and 8.4's `Sonny-Deprecation` / `Sonny-Deprecation-Info` headers all exist (SONNY-204) — 4.1's owner note, 5.3's key-set bullet and 13's row each said they did not, and each is corrected where it lives. **The one wire change is additive**: `version.unsupported`'s error body carries `upgrade_url`, which 8.3 already required "an `upgrade_url` in the error body" and 7.1 did not show; the key is absent on every other error rather than present and null, so no existing response moved. **No endpoint, request body, header, size limit, timeout or existing `code` changed meaning**, and `GET /v1/meta` was already in 4.1's table, in 2.2's unauthenticated list and in `auth/gate.ts`'s `PUBLIC_ROUTES` — its entry needed no edit when the handler landed, which is the property that list claims. **Three things 8 left implicit are now stated in 8.3, because the implementation had to choose them**: only the marketing version is compared and one-to-three components are accepted, since the shipping bundle sends `1.0+1`; a request with no version, an unreadable one, or the header twice is **served** and never treated as too old, because every non-app caller sends none and this gate is a courtesy rather than a boundary; and both bounds default to `0.0.0`, which disarms the gate, because 8.4 makes a minimum that had no deprecation period a breach and a default carries none. **What is still not built**: the Mac calls none of this (**SONNY-402**), and the published key set holds one key rather than a rotation overlap (**SONNY-401**), both recorded at 5.3 and 13. | SONNY-204 |
| 2026-09-03 | **4.1 gains three routes — two new and one that was missing — 5.4 grows two fields, and 7.2 gains three codes.** `PUT /v1/account/credits/auto-top-up` records a user's consent to automatic charges and changes nothing else; `POST /v1/account/credits/top-up` is the one route in this contract that **moves money**, and it refuses on the absence of that consent before it reads anything else. **The third row is a correction rather than an addition**: `GET /v1/account/credits` has been served since SONNY-212 and was never listed in 4.1, which is a gap in the one table 2.2 names as the single source of truth for which endpoints carry a Bearer token and from which `server/src/auth/gate.ts`'s deny-by-default list is derived — the same invariant the 2026-08-30 row states, failing quietly in the other direction. It is listed now, beside the two routes that would otherwise have documented a feature whose read half was undocumented. **5.4's body grows `credits.topped_up` and an `auto_top_up` object**, both additive under 2.1, and the section's bullet reading *"the Mac reads the run count and ignores it"* is corrected: it stopped being true at SONNY-213, whose step boundary reads `credits.remaining` because the run count cannot answer whether a session already spending its own run has actually run out. **7.2 gains `topup.not_permitted` (409), `topup.declined` (402) and `topup.unconfirmed` (502, not retryable).** The first is one code for five refusals — no pack configured, no consent, not actually low, the period's attempts spent, no customer at the provider — because a client does nothing different about any of them and what separates them is what an operator needs, which the route logs. The second is its own status because "your card" and "your settings" are different problems with different fixes, and a later surface could not recover the distinction if they were collapsed here. The third is **not** `provider.unavailable`, and the difference is the whole of why it exists: the charge may have gone through, so a client told to retry would buy a second pack to recover from a first one it cannot see. **No existing shape moved**: no endpoint, request body, response body, header, size limit or timeout changed, no existing `code` changed meaning, and 5.3's claim is byte-identical — the allowance is not on it, for the reason 5.4 already gives. | SONNY-215 |
| 2026-09-04 | **5.4 grows `auto_top_up.price` and `last_top_up`, and one sentence about §9 is corrected.** Both fields are additive under 2.1 and carry the founders' decision of 2026-09-03: the switch that authorises a standing charge names what it costs, and the account section carries a record of the last charge — a price and a date, with no per-charge confirmation and nothing explaining why either is there. Money crosses as **minor units and an ISO 4217 code**, never a formatted string, because a symbol and a decimal separator are locale decisions and §7.1 makes the words the client's. **The correction is to the top-up route's idempotency sentence**, which said a retry "replays the stored answer rather than buying a second pack" without qualification (PR #196's F5): that is true of the codes §9.2 stores and false of `server.error`, which `idempotency/hook.ts` releases. What actually stops a second charge is not the key — an order this gateway created and has not resolved is resolved by the account's next attempt rather than replaced (PR #196's F1) — and the sentence now says so. **No existing shape moved**: no endpoint, request body, header, size limit or timeout changed, no existing `code` changed meaning, and 5.3's claim is byte-identical. | SONNY-215 |
| 2026-09-05 | **4.1 gains one route, and nothing else in this document moves.** `GET /v1/billing/payment-state` answers `{ "payment": "current" | "past_due" }` for the authenticated caller's own account, from `sonny.entitlement.past_due_since` and no provider call (SONNY-380). **It exists because 5.3's claim cannot say this and deliberately will not.** §16.4 keeps every capability through a payment failure's grace window on purpose, so the claim minted for a customer whose card was declined is byte-identical to a healthy one's — `plan` and `capabilities`, which `entitlement/store.ts` returns on every path — and the Mac read `Active` for the length of the window, the provider's own dunning email being the customer's only notice. Adding a status field to the claim was **offered and declined** (SONNY-216, 2026-08-31, restated by the founders 2026-09-05): the claim is 4.1 and 5.3, 8.2 items 1–3 make changing its shape a `/v2` question, and that is not a trade worth making for a status word. So the word travels on its own route, **unsigned — and it is affordable to be unsigned only because it decides nothing**: no capability, gate or refusal reads it, `admitRequest` and `claimFactsFor` are untouched, and a caller who forged it would change a word on one line and a label on one control on their own screen. **Additive under 8.1** — a new endpoint, no request field, no response field on an existing shape, no `code`, no size limit and no deadline moved, and 5.3's claim is byte-identical. **The one bound this row sets for later**: `payment` is a wire enum, so 8.2 item 7 governs it. The Mac carries the required unknown fallback from this route's first release and renders an unrecognised value as *nothing about payment*, falling back to what the claim proves — which is the right answer for a value an old build cannot interpret and the wrong one if the new value means something worse than `past_due`. So a third value needs 8.4's deprecation ladder behind it rather than a minor bump. **Client timeout is the auth row's 20 s** (§12), unchanged: this route makes no outbound call and is one indexed `SELECT`. | SONNY-380 |
| 2026-09-05 | **No shape moved and no code was added; two routes now answer a code this table already assigned them.** `POST /v1/auth/refresh` and `POST /v1/auth/signout` answered `500 server.error` when the auth provider could not be reached, where 7.2 case 5 assigns `502 provider.unavailable` — and their neighbour `POST /v1/auth/email/verify`, on the same branch of the same file, already answered it correctly (SONNY-311). Three routes, one condition, two answers. **This is the implementation being brought to the document rather than the document changing**: 7.2's case 5 row is untouched, `provider.unavailable` means what it has always meant, and no endpoint, request body, response body, header, size limit or timeout moved. It is logged because it is caller-observable — a status and a `code` change on two routes — and because 3.6's sign-out paragraph now states a second answer that paragraph did not have. **`retryable` was already `true` on the `500`**, so a client keying off that field was never stranded and nothing in a client's behaviour has to change; `SonnyBackendError` already carries `providerUnavailable`, and the Mac's sign-out already clears the Mac whether or not the call succeeds, reporting a server-side failure as `clearedLocallyOnly`. What was wrong is the code, the disagreement between neighbours, and — on sign-out — a `500` that read as Sonny breaking when the login service was down. The condition became reachable when SONNY-307 landed the concrete Supabase adapter; before it, every `AuthProvider` was a test fake and none raised it from these two methods. | SONNY-311 |
| 2026-09-05 | **12 gains a request-delivery bound, and 9.2's lease paragraph is corrected — no shape a client sends or receives moved.** Nothing bounded how long a caller could take to deliver a request: the framework disables the option by default and this project had never set it, so a caller that sent headers and then withheld the body held a connection, a request and — on `POST /v1/transcriptions` alone — an idempotency claim, indefinitely, and the sign-in routes make that reachable without an account (SONNY-322). Delivery is now bounded at **120 s**, which is 12's own longest *client* timeout, so nothing a shipping client would still have been waiting for is refused; the bound is on receiving a request and not on running a handler, so no server deadline in 12's table moved and 8.1's rule about deadlines is not engaged. The transcription route's body read gains a 30 s bound of its own, which is what makes 9.2's lease arithmetic true rather than assumed: 30 + 75 = 105 against a 120 s lease, the same fifteen seconds of margin the JSON routes already had. **The correction is to 9.2's closing paragraph**, which read *"a stalled upload is the one shape that can reach this"* — a subtraction claim the gateway's own adjacent comment already contradicted, since the JSON routes' margin is fifteen seconds rather than infinity. Bounding the upload removes the unbounded shape and leaves the bounded ones, and the case the lease exists for — a process killed mid-request, which runs no timer — is untouched. **One new response is observable**: a request cut off for late delivery answers `408` carrying 7.1's envelope with the existing `request.invalid`, which is the rule 7.2 already applies to a 4xx it does not name individually; **no code was added to 7.2** and no existing `code` changed meaning. | SONNY-322 |
| 2026-09-05 | **7.2 gains `request.timeout` (408, retryable), 9.3 lists it, 12 gains a per-route upload bound, and two client-error statuses are put back.** Corrections to the SONNY-322 row above, from PR #208's review, landing in the same branch before either merged. **F1:** the delivery bound answered `408 request.invalid`, which is the code this contract assigns a *malformed* request — and the Mac decides retryability from the code, so a body that was merely late was told it could not be retried and rendered as a request Sonny could not send. `request.timeout` is a **narrowing of the `request.*` family** under 8.1, and the Mac maps it in the same branch, so no shipped client meets an unknown code. **F2:** that answer was also outside 9.2's release set, so it was stored and replayed for twenty-four hours — a complete, valid retry under the same key got a day-old timeout with no upstream call, which is precisely the "wrong answer to a correct request" 9.2's first decision exists to prevent. It is in the release set now. **F3:** the socket-level handler answered `408` to **every** client error, so a malformed request was told it had been too slow and a header block over the runtime's limit lost its `431` — two existing response classes had silently moved, which the row above did not record. The framework's three-way classification is restored inside 7.1's envelope, and both doors now call one mapping rather than each implementing a rule. **F4, the founders' decision of 2026-09-05:** `POST /v1/transcriptions`' body-read bound rises from 30 s to **90 s**, this section 12's own client timeout for that route, because the first derivation held the gateway's internal idempotency lease fixed and solved for the upload — inverting 12's governing rule on the one route where the upload is the slow part, and refusing a three-minute recording on a weak connection. The lease rose to 180 s to make room, at the same 15-second margin; the accepted cost is that a process killed mid-request holds its key a minute longer. **No request shape, response shape, header or size limit changed**, and no existing `code` changed meaning. | SONNY-322 |
| 2026-09-06 | **3.6 — a signed-out access token stops verifying, and nothing else in this document moves.** An access token is self-contained and this gateway verifies it locally (3.1), so signing out revoked the *refresh* family and left the presented access token working until its own `exp` plus 3.5's tolerance — an hour and thirty seconds on Supabase's default, and on a shared Mac a working session left behind by someone who pressed Sign out. `POST /v1/auth/signout` now records the token's provider-side session and every authenticated route refuses it with `401 auth.token_revoked`, which 7.2 already assigns that meaning. **No shape changed**: no endpoint, request body, response body, header, error `code`, size limit or timeout in this document moved, no `code` changed meaning, and none was added — 8.2's breaking list is about changing what a code means, and a state that used to be served being refused is the gate keeping 3.3's own promise rather than a new one. **Two exclusions are stated in 3.6 rather than left to be discovered.** The sign-out route stays reachable with a revoked token, because the record is written before the provider call and a 9.3 retry of a `502` must still reach the provider; and a token carrying no session claim cannot be keyed on, so it keeps the old window. | SONNY-237 |
