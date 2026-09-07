import { isIP } from "node:net";
import { z } from "zod";
import type { AcceptedJwtSecret, SupabaseJwtPolicy } from "./auth/token.js";
import { entitlementSigningKeyFrom, type EntitlementSigningKey } from "./entitlement/claim.js";
import {
  ZERO_VERSION,
  compareVersions,
  formatVersion,
  parseMarketingVersion,
  type ClientVersionPolicy,
} from "./version/policy.js";
import {
  CreditCatalogueError,
  parseCreditCatalogue,
  type CreditCatalogue,
} from "./credit/catalogue.js";
import {
  parseRouteChain,
  providerDataPolicies,
  type ModelRoute,
  type ProviderDataPolicy,
} from "./model/provider-router.js";

/**
 * Environment → typed configuration, validated once at startup.
 *
 * Two properties this file exists to guarantee, both of which the ticket names:
 *
 * 1. **No credential is ever read from anywhere but the process environment.** There is no
 *    config file, no default value for any secret, and no fallback. A missing credential is a
 *    startup failure with a named variable, not a server that runs and fails on the first real
 *    request.
 * 2. **Every provider supports two live credentials at once**, so one can be retired while the
 *    other serves. See `providerCredentials` below for why that is a list rather than a pair of
 *    named fields.
 */

/** The three places this server runs. Orthogonal to *which host* carries them (see README). */
export const environments = ["local", "staging", "production"] as const;
export type Environment = (typeof environments)[number];

/** The providers whose credentials this gateway holds. From row 12's plan §4.4. */
export const providers = ["openai", "anthropic", "cerebras", "tavily", "vision"] as const;
export type Provider = (typeof providers)[number];

/**
 * Credentials for one provider, newest first.
 *
 * **A list rather than `primary`/`secondary`, and the reason is the rotation itself.** With two
 * named fields, retiring the primary means editing two variables in one step — the new key into
 * `primary` and the old one into `secondary` — and any deploy that catches those half-applied has
 * either a duplicated key or a missing one. With an ordered list the rotation is three independent
 * deploys, each valid on its own: add the new key at position 2, promote it to position 1, drop the
 * old one. At no point is the server without a working credential, which is what "no downtime"
 * actually requires.
 *
 * Index 0 is the credential used for new requests. Later entries stay accepted so in-flight work
 * and any provider-side caching keyed to the old credential keep working through the overlap.
 */
export interface ProviderCredentials {
  readonly provider: Provider;
  readonly keys: readonly string[];
}

const nonEmpty = z.string().trim().min(1);

const schema = z.object({
  SONNY_ENV: z.enum(environments),
  PORT: z.coerce.number().int().min(1).max(65535).default(8080),
  HOST: nonEmpty.default("0.0.0.0"),
  /** Build identifier surfaced by GET /v1/health. Injected at image build time. */
  SONNY_BUILD_ID: nonEmpty.default("dev"),
  /** Postgres connection string. Supabase's, per the 2026-08-21 decision. */
  DATABASE_URL: nonEmpty.optional(),
  LOG_LEVEL: z.enum(["fatal", "error", "warn", "info", "debug", "trace"]).default("info"),
  /**
   * Which proxies to believe about the client address, as a comma-separated list of CIDRs or IPs.
   *
   * **A boolean had no safe setting** (PR #87 F4). `false` behind a load balancer makes every
   * request report the balancer's address, so the per-source rate limit collapses into one global
   * bucket and one attacker exhausts everyone's budget. `true` makes `request.ip` read from
   * `X-Forwarded-For`, which any caller can set, so the same attacker gets an unlimited supply of
   * fresh identities. Naming the proxies is what makes the header trustworthy exactly as far as it
   * is: Fastify walks the chain and stops at the first hop that is not on this list.
   *
   * Empty means trust nothing, which is correct with no proxy in front and is the default.
   *
   * **Not a hop count.** An earlier draft offered one and the parser no longer produces it, so the
   * docstring was advertising a form that would have been parsed as a one-element CIDR list and
   * silently matched nothing (PR #87 R15). A count also says "believe the last N hops" without
   * saying who they are, which is the boolean's act of faith one step smaller.
   */
  TRUSTED_PROXIES: z.string().trim().default(""),
  /**
   * Salt for the rate-limit bucket hashes (SONNY-127). **No default, deliberately.** The buckets
   * hash email addresses, and an unsalted hash of an address is one rainbow-table lookup from the
   * address itself — so a development default would be a real weakness that works everywhere and
   * is never noticed. Required only where the auth routes are mounted; `loadConfig` therefore
   * accepts its absence and `requireRateLimitSalt` is what refuses at the point of use.
   */
  RATE_LIMIT_SALT: nonEmpty.optional(),

  /**
   * How long retained request and response content is kept, in days (SONNY-134). Contract §10.3.
   *
   * **Thirty, confirmed by the founder on 2026-08-28** — the short end of the 30–90 range his
   * retention decision of 2026-08-16 names, and the number this repository's prose had already been
   * assuming in three places while nothing had settled it. It is configurable because the range is
   * the founder's to move within, and it is bounded at both ends because neither a zero nor a value
   * outside the disclosed range should be reachable by a typo in an environment file.
   *
   * **Changing it never reaches content already stored.** `sonny.retained_content.expires_at` is
   * written from this value at insert, so a row carries the window it was kept under; raising the
   * setting applies to what arrives afterwards and cannot silently extend the life of a screenshot
   * a user was told would be gone in thirty days. `content/record.ts` states the same thing beside
   * the function that computes it.
   *
   * The *other* clock has no variable here at all, deliberately: derived metrics and usage are kept
   * indefinitely (§10.3), and a number naming their lifetime would be a lifetime nothing enforces.
   */
  CONTENT_RETENTION_DAYS: z.coerce.number().int().min(1).max(365).default(30),

  /**
   * How often the running gateway sweeps expired content, in seconds.
   *
   * Hourly by default, which is far more often than a thirty-day clock needs and is chosen for what
   * it does to the *evidence*: a sweep logs every pass, so an operator reading a fresh deployment's
   * output sees within the hour whether expiry runs at all, rather than inferring it from an absence
   * of complaints a month later. The floor of sixty seconds exists so a misconfiguration cannot turn
   * this into a busy loop against the database.
   */
  CONTENT_EXPIRY_SWEEP_SECONDS: z.coerce.number().int().min(60).max(86_400).default(3600),

  /**
   * The Ed25519 private key the entitlement claim is signed with (SONNY-135), as base64 of its
   * PKCS#8 DER:
   *
   *   openssl genpkey -algorithm ed25519 -outform DER | base64
   *
   * **No default, for the same reason `RATE_LIMIT_SALT` and `SUPABASE_JWT_SECRET` have none, and
   * the consequence here is the sharpest of the three.** A development default would be a working
   * *minting* key for every entitlement claim, shipped in the repository, and anyone holding it
   * could grant themselves any capability on any deployment that had not changed it. Base64 of DER
   * rather than PEM because a PEM is multi-line and an environment variable is not.
   *
   * Required wherever an authenticated route is mounted; `requireEntitlementSigningKey` refuses at
   * the point of use, and `auth/deps.ts` names it alongside everything else a sign-in deployment
   * needs so an operator fixes them in one pass.
   */
  ENTITLEMENT_SIGNING_KEY: nonEmpty.optional(),
  /**
   * Which key that is, as the `kid` in every claim's JWS header (contract §5.3).
   *
   * A name rather than a fingerprint, so rotation reads as a rotation: a client holding two public
   * keys picks by `kid` and verifies claims signed by either, which is what lets a key be replaced
   * without a client release. It has no default because a shared default across two environments
   * would have two different keys answering to one name, which is the one thing `kid` exists to
   * prevent.
   */
  ENTITLEMENT_SIGNING_KEY_ID: nonEmpty.optional(),
  /**
   * The per-account, per-period spend cap for an account whose entitlement row names no cap of its
   * own — in units, where **one metered call is one unit** (`entitlement/store.ts` carries why the
   * unit is a call and what it does and does not bound).
   *
   * **No default, and this is the variable most likely to be read as a product decision, so:** it
   * is a deployment's own ceiling on how much a single credential can spend before something says
   * no, not a plan's allowance. Plans, prices and allowances are SONNY-212's, and this repository
   * sets none of them — which is exactly why there is no number here. An operator choosing 1000 for
   * their own gateway has not created a tier.
   *
   * Required wherever an authenticated route is mounted. **The alternative was to treat "unset" as
   * "uncapped", and that is the failure this whole requirement exists to prevent**: SONNY-16
   * recorded a leaked token billing the founder as an accepted cost, and a cap that quietly does
   * not apply is that cost with a mechanism in front of it.
   */
  SPEND_CAP_UNITS: z.coerce.number().int().min(0).optional(),

  /**
   * The plan catalogue: every tier, every allowance and every credit weight this deployment bills
   * against, as one JSON document (SONNY-212).
   *
   * **No default, and this is the variable the whole of row 13's pricing arrives through.** Twelve
   * files under `server/src` promise that the numbers land on SONNY-212 rather than in them, and
   * this is where they land — outside the repository. An operator writes it; nothing here writes a
   * tier name, an allowance or a weight.
   *
   * The shape, parsed and argued in `credit/catalogue.ts`:
   *
   * ```json
   * {
   *   "runCredits": <credits one screen-control run is worth>,
   *   "defaultPlan": "<the key an account with no plan falls to>",
   *   "weights": { "perSession": <n>, "perIteration": <n>, "perMegapixel": <n> },
   *   "plans": [{ "key": "<opaque key>", "monthlyCredits": <n> }]
   * }
   * ```
   *
   * `plans` is a list of **any** length. The product decision today is free plus one paid tier
   * (founder, 2026-08-16), and the tier *count* is still configuration because a decision that is
   * true today is exactly the kind that becomes a release-time input.
   *
   * Required wherever an authenticated route is mounted, for `SPEND_CAP_UNITS`' reason: an unset
   * catalogue has no safe reading. Treating it as "no allowance" locks every user out of the one
   * paid feature and treating it as "unlimited" is SONNY-16's leaked-token cost with a mechanism in
   * front of it doing nothing.
   */
  CREDIT_PLANS: nonEmpty.optional(),

  /**
   * The Supabase project's **JWT secret**, which is what every access token this gateway accepts is
   * signed with (SONNY-203; founder decision of 2026-08-21, Sauransh with Bhavya).
   *
   * **Gateway-only.** It never reaches the Mac app and it is never written down in this repository —
   * `npm run check:secrets` carries `SUPABASE_JWT_SECRET` on its name-anchored list precisely
   * because a project secret has no vendor prefix and the variable name is the only thing that can
   * catch it. A shared HMAC secret is a *signing* key as much as a verifying one: anyone holding it
   * can mint a token for any user, so it belongs in exactly one process.
   *
   * No default, like `RATE_LIMIT_SALT` and for the same reason — a development default here would be
   * a working forgery key that ships everywhere and is never noticed. Optional at load and required
   * at the point of use, so a deployment mounting no authenticated route need not invent one;
   * `requireSupabaseJwtPolicy` is what refuses.
   */
  SUPABASE_JWT_SECRET: nonEmpty.optional(),
  /**
   * The **one** overlap slot, so that rotating the secret above does not sign every user out
   * (SONNY-238).
   *
   * A Supabase access token is verified locally against `SUPABASE_JWT_SECRET`, so replacing that
   * value invalidates every token signed with the old one at the instant the new one deploys. With
   * this slot the rotation is three independent deploys, each valid on its own, the way a provider
   * credential's is — `server/README.md`'s "Rotating the Supabase JWT secret with no sign-out" walks
   * them.
   *
   * **The direction is the mirror of a provider credential's.** A provider key is one this gateway
   * *sends*, so that list is "what to try". This is one Supabase *signs* with and this gateway only
   * verifies, so this list is "what to accept" and the overlap has to straddle the moment Supabase's
   * own value changes: this slot holds the **incoming** secret in one deploy and the **retiring** one
   * in the next. A runbook written as "the retired secret" gets that backwards.
   *
   * **One slot and not an ordered list without end**, which is where this deliberately departs from
   * `providerCredentials` below. That function stops at the first gap, and a skipped gap costs a
   * provider key to try — harmless. A skipped *verifying* secret means every token signed with it is
   * refused, which is the sign-out this variable exists to prevent, arriving through its own fix. So
   * there is exactly one slot, and `SUPABASE_JWT_SECRET_1`, `_3` and anything else numbered is a
   * startup refusal rather than a silent skip. A rotation needs one overlap slot; a second would only
   * ever mean two rotations running at once, which is the state nobody should be able to reach by
   * accident.
   *
   * Requires `SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL` beside it. Held to the same length floor as the
   * secret above, for the same reason.
   */
  SUPABASE_JWT_SECRET_2: nonEmpty.optional(),
  /**
   * When the overlap ends — an ISO-8601 instant, after which `SUPABASE_JWT_SECRET_2` is no longer
   * accepted.
   *
   * **Required whenever that slot is set** (founder decision of 2026-08-30, Sauransh with Bhavya: a
   * retired secret gets a stated maximum overlap). Their own words on the half they left open were
   * that a number nothing checks is "better than nothing and worse than a check", so the number does
   * not live in the runbook alone — it lives here and `verifyAccessToken` reads it per request. The
   * retired secret therefore stops being a forgery key against this gateway at the stated instant,
   * with no deploy and nobody remembering, which is the realistic failure the ticket names.
   *
   * **Refused if it is more than `MAX_JWT_SECRET_OVERLAP_DAYS` away** at startup. That is the stated
   * maximum, made mechanical. Refused, too, if it names no slot: a deadline with no
   * `SUPABASE_JWT_SECRET_2` is a half-applied deploy, and the half that is missing is the secret.
   *
   * **An instant already past is not a startup failure.** It means the overlap is over, and the slot
   * is simply not accepted — the ending working rather than a misconfiguration. Refusing to boot on
   * it would turn a piece of leftover bookkeeping into every user being signed out, which is the
   * failure this whole variable exists to avoid and is strictly worse than the leftover: a retired
   * secret past its instant authorises nothing here.
   */
  SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: nonEmpty.optional(),
  /**
   * The project's auth URL — `https://<project-ref>.supabase.co/auth/v1` — compared exactly against
   * each token's `iss`.
   *
   * **Why check it at all when the signature already passed:** the signature proves the token was
   * minted by something holding this secret, and `iss` proves it was minted by the *project* this
   * gateway serves. They come apart the moment the same secret is ever reused across two Supabase
   * projects (staging and production configured from one copied value is the ordinary way that
   * happens), at which point a token from the wrong side verifies perfectly and names a user id this
   * gateway would look up in its own database.
   */
  SUPABASE_JWT_ISSUER: nonEmpty.optional(),
  /**
   * The `aud` every accepted token must carry. Supabase's own value for a signed-in user is
   * `authenticated`, which is the default here; it is configurable because it is a project setting
   * rather than a law, and a wrong value is a gateway that refuses every real token — loudly.
   */
  SUPABASE_JWT_AUDIENCE: nonEmpty.default("authenticated"),

  /**
   * Where the model routes send, and what they ask for (SONNY-130).
   *
   * **These four have defaults and the credentials above do not, and the difference is the point.**
   * A credential with a default is a weakness that works everywhere and is never noticed. An
   * endpoint and a model identifier are neither secret nor guessable-wrong: the defaults are exactly
   * what the Mac app compiled in before this gateway existed, so a deployment that sets none of them
   * behaves as the app used to, and one that sets them moves every user's traffic in a redeploy.
   *
   * That second half is SONNY-130's sixth requirement doing its job. The client is not allowed to
   * name a provider, a model or an endpoint, so all three are here — which is what turns SONNY-110's
   * move to a paid zero-retention route into a configuration change rather than an app release.
   */
  OPENAI_BASE_URL: nonEmpty.default("https://api.openai.com/v1"),
  OPENAI_TEXT_MODEL: nonEmpty.default("gpt-5.5"),
  OPENAI_TRANSCRIPTION_MODEL: nonEmpty.default("gpt-4o-mini-transcribe"),
  SEARCH_BASE_URL: nonEmpty.default("https://api.tavily.com"),

  /**
   * The second provider's endpoint and model (SONNY-132), on the same terms as OpenAI's above: a
   * default that is neither secret nor guessable-wrong, so a deployment that sets only
   * `ANTHROPIC_API_KEY` works, and one that wants a different model changes one variable.
   *
   * `ANTHROPIC_MAX_OUTPUT_TOKENS` has no counterpart on the OpenAI side because the Messages API
   * **requires** `max_tokens` on every request — there is no server-side default to inherit. 16000
   * is the value the API's own guidance gives for a non-streaming request: high enough for a plan or
   * a research note, low enough to stay inside the HTTP timeouts a non-streaming call has.
   *
   * **What that reasoning does not account for, stated rather than left to be discovered** (PR #143,
   * F10). `max_tokens` bounds thinking **plus** answer, and the configured default model runs
   * adaptive thinking when `thinking` is omitted, which it is here. So the effective ceiling on the
   * *answer* is lower than 16000 by an amount nothing in this file controls and nothing in this
   * branch measured — **this is hedged, not measured**, because no live round was run against a real
   * key. Hitting it is a `stop_reason: "max_tokens"`, which the adapter refuses rather than handing
   * the client a half-written JSON object; that refusal is a `provider.rejected`, so it does not
   * fail over. Latent today: the client hard-codes `reasoning_effort: "medium"`
   * (`SonnyModelGateway.swift`), and it becomes live if `/v1/research/synthesize` produces a long
   * note or the effort the client sends ever rises. The first real Anthropic round is where this
   * gets a number; raise this variable rather than re-deriving the reasoning if a plan ever comes
   * back truncated.
   */
  ANTHROPIC_BASE_URL: nonEmpty.default("https://api.anthropic.com/v1"),
  ANTHROPIC_TEXT_MODEL: nonEmpty.default("claude-opus-5"),
  ANTHROPIC_MAX_OUTPUT_TOKENS: z.coerce.number().int().min(1).max(200_000).default(16_000),

  /**
   * Cerebras's endpoint and model, moved off the Mac (SONNY-132).
   *
   * The defaults are exactly what `CerebrasPlanner` compiled in —
   * `https://api.cerebras.ai/v1/chat/completions` and `gpt-oss-120b` — so the provider behaves as
   * it did when it was reachable by `SONNY_PLANNER=cerebras`, with the credential now held here
   * instead of in the user's own environment.
   */
  CEREBRAS_BASE_URL: nonEmpty.default("https://api.cerebras.ai/v1"),
  CEREBRAS_TEXT_MODEL: nonEmpty.default("gpt-oss-120b"),

  /**
   * Which provider serves which route, in order (SONNY-132) — spec §16.5's "model routing
   * controlled server-side", as four variables rather than a code path.
   *
   * Each is a comma-separated provider list: the first entry serves, and the rest are what
   * `withFailover` tries when it answers `provider.unavailable`. Unset means
   * `provider-router.ts`'s `DEFAULT_ROUTE_CHAINS`, which reproduces SONNY-130's behaviour on any deployment
   * holding only an OpenAI key. Parsed and validated by `parseRouteChain`, which refuses an unknown
   * provider, a provider with no adapter for that route, and a repeated entry — each by name, at
   * startup, because none of those values is a secret and none of them can be fixed without knowing
   * which one is wrong.
   */
  MODEL_ROUTE_PLAN: z.string().trim().default(""),
  MODEL_ROUTE_SYNTHESIZE: z.string().trim().default(""),
  MODEL_ROUTE_TRANSCRIPTIONS: z.string().trim().default(""),
  MODEL_ROUTE_SEARCH: z.string().trim().default(""),
  /**
   * Where `POST /v1/screen/analyze` sends, and what it asks for (SONNY-131).
   *
   * Same rule as the four above, and the same defaults-for-these-and-not-for-credentials split: these
   * two are exactly what the Mac app compiled in before this gateway existed — `defaultEndpoint` and
   * `defaultModel` on `OpenCodeVisionModelClient`, plus the `SONNY_VISION_MODEL` override that the
   * contract's §1.3 says becomes server configuration — so a deployment that sets neither behaves as
   * the app used to.
   *
   * **This pair is the one SONNY-110 moves.** That ticket's requirement widened on 2026-08-16 to no
   * retention *and* no training rights over our data; making it a redeploy rather than an app release
   * is the whole reason the Mac's vision client no longer names a provider, a model or an endpoint.
   *
   * The credential is `VISION_API_KEY`, read by `providerCredentials` below — `vision` has been in
   * the `providers` list since SONNY-126, waiting for this route.
   */
  VISION_BASE_URL: nonEmpty.default("https://opencode.ai/zen/go/v1"),
  VISION_MODEL: nonEmpty.default("gpt-5.6-luna"),
  /**
   * The project's **anon / publishable** key, sent as the `apikey` header on every non-admin call
   * the sign-in adapter makes (SONNY-307).
   *
   * Supabase's edge requires it for any call to the project, so without it the adapter cannot reach
   * `/otp`, `/verify`, `/token`, `/logout` or `/user` at all. Publishable by design — a client app
   * would hold one too — which is why it is not on `scripts/check-secrets.sh`'s name-anchored list;
   * its value shape is a JWT, which that scanner's vendor patterns already catch.
   *
   * Optional at load and required at the point of use, like every other auth variable here:
   * `requireSupabaseAuthCredentials` is what refuses.
   */
  SUPABASE_ANON_KEY: nonEmpty.optional(),
  /**
   * The project's **service-role** key. Used by exactly one adapter method, `deleteUser`, which is
   * the `/admin/*` surface.
   *
   * **A real secret**: it bypasses every row-level policy in the project and can act as any user, so
   * it is gateway-only in the same sense `SUPABASE_JWT_SECRET` is, and `npm run check:secrets`
   * already carries this variable name on its name-anchored list — a service-role key has no vendor
   * prefix a value pattern could anchor on.
   */
  SUPABASE_SERVICE_ROLE_KEY: nonEmpty.optional(),

  /**
   * Which payment provider this deployment is wired to, and the **one variable whose presence means
   * "mount the billing routes"** (SONNY-211) — the same intent-trigger shape `auth/deps.ts` uses for
   * the three Supabase names, and for the same reason: a deployment that does no billing should not
   * have to invent a webhook secret, and one that intends billing should not start half-configured.
   *
   * **An enum with one value in it, on purpose.** Polar is the provider and the founders' decision
   * of 2026-08-30 is final; the same decision says the seam stays, because a merchant-of-record swap
   * is a business decision that can recur. So a second provider is a second word here and a second
   * file beside `billing/polar.ts`, rather than a rewrite — and until that word exists, a typo in
   * this variable is a named startup failure instead of a gateway that mounts nothing and says
   * nothing.
   */
  BILLING_PROVIDER: z.enum(["polar"]).optional(),
  /**
   * The webhook endpoint secret, from the provider's dashboard.
   *
   * **No default, for the reason `ENTITLEMENT_SIGNING_KEY` has none, and the consequence is the same
   * class.** This value is the only thing standing between anyone on the internet and a paid
   * entitlement: whoever holds it can sign a `subscription.active` delivery for any account. A
   * development default would be a working forgery key committed to the repository.
   * `npm run check:secrets` carries this name on its name-anchored list, because a webhook secret is
   * an opaque string with no vendor prefix a value pattern could anchor on.
   */
  BILLING_WEBHOOK_SECRET: nonEmpty.optional(),
  /**
   * The hosted checkout link a user is sent to in order to subscribe.
   *
   * Neither secret nor guessable-wrong, like the model endpoints above — and configuration rather
   * than code for the same reason: the sandbox link and the production link are different URLs, and
   * moving between them must be a redeploy rather than an app release.
   */
  BILLING_CHECKOUT_URL: nonEmpty.optional(),
  /**
   * An Organization Access Token for the payment provider's API, with the scope that mints a
   * customer portal session (SONNY-216).
   *
   * **The first provider API credential this gateway has ever held, and a deliberate reversal.**
   * SONNY-211 recorded that the hosted checkout "needs no provider API credential and makes no
   * outbound request" — a property, not an accident. A portal link cannot keep it: the provider's
   * static portal authenticates the human by emailing a one-time code to the address on their
   * *provider* record, and `docs/sonny-identity-linking-rule.md:14` says Sonny's identity key "is
   * never the email address", so a Hide My Email user could not reach their own billing portal at
   * all. `billing/polar.ts` carries the full argument.
   *
   * **No default, for the reason `BILLING_WEBHOOK_SECRET` has none.** `npm run check:secrets`
   * carries this name on its name-anchored list: an access token is an opaque provider-issued
   * string, so the name is the only thing that can catch it. Its rotation story is in
   * `server/README.md`.
   */
  BILLING_PROVIDER_ACCESS_TOKEN: nonEmpty.optional(),
  /**
   * The payment provider's API origin. Optional; the provider adapter defaults it.
   *
   * Configuration for the reason `BILLING_CHECKOUT_URL` is — the sandbox API and the production API
   * are different hosts, and moving between them must be a redeploy rather than a code change. The
   * *default* deliberately lives in `billing/polar.ts` rather than here, because that is the one
   * file allowed to know a vendor hostname.
   */
  BILLING_API_BASE_URL: nonEmpty.optional(),
  /**
   * What each of the provider's products is worth, as
   * `<product id>=<plan key>:<capability>|<capability>`, comma-separated.
   *
   * **This is the seam SONNY-212's numbers do not come through, and that is the point.** It names no
   * price and no allowance — it maps an opaque product id the provider issued onto the opaque plan
   * key and capability list `sonny.entitlement` has held since 0013. Which capability gates which
   * feature is row 18's (SONNY-23); what a plan costs is SONNY-212's.
   *
   * A subscription whose product is absent here grants nothing and is recorded `unmapped` in
   * `sonny.billing_event` — fail-closed, and visible, because the alternative to both is inventing a
   * capability list for a product nobody configured.
   */
  BILLING_PLANS: z.string().trim().default(""),
  /**
   * How long a payment failure's grace window runs, in days. **Fourteen.**
   *
   * Spec §16.4 requires grace handling and names no number, so this is a mechanism default the
   * founders may move rather than a decision this repository is making. Fourteen is chosen against
   * what the window is actually for: the provider retries a failed payment over roughly two weeks
   * and then tells us it has given up, at which point the entitlement is revoked by that event
   * rather than by this clock. So this bounds the case where the provider never tells us — and it
   * should be long enough that it is not the thing that cuts a paying customer off during a card
   * reissue, which is the ordinary reason a renewal fails.
   *
   * Bounded at both ends so neither a zero nor a year is reachable by a typo.
   */
  BILLING_GRACE_DAYS: z.coerce.number().int().min(1).max(60).default(14),

  /**
   * Contract §8.3's `minimum_supported_client` — the version below which every route answers
   * `410 version.unsupported` (SONNY-204).
   *
   * **Defaulted to `0.0.0`, which disarms the gate, and the direction is the whole decision.** No
   * client can compare below it, so a deployment that has said nothing about versions refuses
   * nobody. The alternative — defaulting to the current release — would have locked out every build
   * below it on the day this landed, including the `0.0+0` a bare `swift run MacAgent` reports
   * (`SonnyClientIdentity.version`, which has no bundle to read a version from). That is the
   * opposite direction to `DEFAULT_BODY_LIMIT_BYTES` and `PUBLIC_ROUTES`, both of which default to
   * the *restrictive* answer, and the difference is what each protects: those two fail closed
   * because a forgotten decision there serves something it should not, while a forgotten decision
   * here refuses a paying user who has done nothing wrong.
   *
   * It is also not a decision this repository may make on its own. §8.4: "Raising
   * `minimum_supported_client` past a version that was never given a deprecation period is itself a
   * breach of this contract." A default carries no deprecation period, so a default above zero
   * would ship a breach.
   */
  MINIMUM_SUPPORTED_CLIENT: nonEmpty.default("0.0.0"),
  /**
   * Contract §8.4's `recommended_client` — the version below which a served client also gets
   * `Sonny-Deprecation` and `Sonny-Deprecation-Info` (SONNY-204).
   *
   * "`minimum_supported_client` is a wall. `recommended_client` is a warning, and it exists so
   * nobody ever hits the wall by surprise." Equal to the minimum means the band is empty and no
   * client is ever warned.
   *
   * **Unset means "the same as the minimum", and it is optional rather than defaulted to `0.0.0`
   * for a reason found by running the built server rather than by reasoning** — with a `0.0.0`
   * default, setting `MINIMUM_SUPPORTED_CLIENT=2.0.0` and nothing else was **refused at startup**,
   * because a recommended version below the minimum describes no client. That is the most ordinary
   * configuration there is — arm the wall, no warning band yet — and the refusal's own message told
   * the operator to "set them equal to arm the wall with no warning period", which is precisely what
   * they should not have to type. The suite did not catch it because every armed fixture set both.
   *
   * The refusal it *should* make is untouched: an explicitly set `RECOMMENDED_CLIENT` below the
   * minimum is still a named startup failure. Absent is an answer; wrong is not.
   */
  RECOMMENDED_CLIENT: nonEmpty.optional(),
  /**
   * Where a user whose build is refused or deprecated is sent. §8.3's `upgrade_url`.
   *
   * Configuration rather than a constant for the reason `BILLING_CHECKOUT_URL` is: it is neither
   * secret nor guessable-wrong, and a staging gateway pointing at a production download page is a
   * mistake that should be a redeploy to fix rather than an image rebuild.
   *
   * **No default, and `requireClientVersionPolicy` refuses to arm the gate without it**, because
   * §8.3's actionable state is a button and a button needs somewhere to go. Absent while both
   * bounds are `0.0.0` is fine and is what every deployment looks like today.
   */
  UPGRADE_URL: nonEmpty.optional(),
});

export interface Config {
  readonly environment: Environment;
  readonly port: number;
  readonly host: string;
  readonly buildId: string;
  readonly databaseUrl: string | undefined;
  readonly logLevel: z.infer<typeof schema>["LOG_LEVEL"];
  readonly trustProxy: boolean | string[];
  readonly rateLimitSalt: string;
  readonly contentRetentionDays: number;
  readonly contentExpirySweepSeconds: number;
  readonly entitlementSigningKey: string | undefined;
  readonly entitlementSigningKeyId: string | undefined;
  readonly spendCapUnits: number | undefined;
  readonly creditPlans: string | undefined;
  readonly supabaseJwtSecret: string | undefined;
  readonly supabaseJwtSecret2: string | undefined;
  readonly supabaseJwtSecret2AcceptedUntil: string | undefined;
  readonly supabaseJwtIssuer: string | undefined;
  readonly supabaseJwtAudience: string;
  readonly openAIBaseUrl: string;
  readonly openAITextModel: string;
  readonly openAITranscriptionModel: string;
  readonly searchBaseUrl: string;
  readonly visionBaseUrl: string;
  readonly visionModel: string;
  readonly anthropicBaseUrl: string;
  readonly anthropicTextModel: string;
  readonly anthropicMaxOutputTokens: number;
  readonly cerebrasBaseUrl: string;
  readonly cerebrasTextModel: string;
  /** Which providers serve which route, in order. `MODEL_ROUTE_*`, validated at startup. */
  readonly routeChains: Readonly<Record<ModelRoute, readonly Provider[]>>;
  /**
   * What this deployment has been told about each provider's retention and training terms.
   *
   * §16.5's "provider-specific retention/training configuration", and **the field SONNY-110's
   * answer lands in**. Every provider defaults to `unknown` on both axes, which is the honest
   * current value rather than a placeholder: no vendor agreement has been read on this project's
   * behalf, and recording a vendor's published default here as though it were checked would be a
   * claim nobody made. `meetsZeroRetentionBar` is the predicate SONNY-110's answer switches on.
   */
  readonly dataPolicies: Readonly<Record<Provider, ProviderDataPolicy>>;
  readonly supabaseAnonKey: string | undefined;
  readonly supabaseServiceRoleKey: string | undefined;
  readonly billingProvider: "polar" | undefined;
  readonly billingWebhookSecret: string | undefined;
  readonly billingCheckoutUrl: string | undefined;
  readonly billingProviderAccessToken: string | undefined;
  readonly billingApiBaseUrl: string | undefined;
  readonly billingPlans: string;
  readonly billingGraceDays: number;
  /** §8.3's bound, as configured. `requireClientVersionPolicy` is what parses and checks it. */
  readonly minimumSupportedClient: string;
  /** §8.4's bound, as configured. `undefined` means the minimum, not `0.0.0`. */
  readonly recommendedClient: string | undefined;
  readonly upgradeUrl: string | undefined;
  readonly credentials: readonly ProviderCredentials[];
}

/**
 * Reads `<PROVIDER>_API_KEY` and `<PROVIDER>_API_KEY_2`, `_3`, … in order, stopping at the first
 * gap. Stopping at a gap rather than scanning a fixed range is deliberate: a typo'd `_4` with no
 * `_3` present should not silently become the second credential.
 *
 * Absent entirely is allowed and yields no entry for that provider. **This ticket builds no route
 * that calls a provider**, so requiring all five here would make the server unstartable for no
 * reason; the ticket that adds a provider route is where its credential becomes mandatory.
 */
export function providerCredentials(env: NodeJS.ProcessEnv): readonly ProviderCredentials[] {
  return providers
    .map((provider) => {
      const prefix = provider.toUpperCase();
      const keys: string[] = [];
      for (let index = 1; ; index += 1) {
        const name = index === 1 ? `${prefix}_API_KEY` : `${prefix}_API_KEY_${index}`;
        const value = env[name]?.trim();
        if (!value) break;
        keys.push(value);
      }
      return { provider, keys } as const;
    })
    .filter((entry) => entry.keys.length > 0);
}

export class ConfigError extends Error {}

/**
 * `""` -> false (trust nothing), anything else -> the comma-separated CIDR/IP list.
 *
 * **This docstring said "a bare number -> that many hops" and the function has never done that**
 * (PR #87 R15, then the second round's F3). R15 removed the hop-count form from the schema
 * docstring twelve lines above and left this one advertising it, so the file contradicted itself
 * about its own parser — and a reader who believed this line would set `TRUSTED_PROXIES=1`, which
 * parses as a one-element list containing the string "1" and matches no proxy that has ever
 * existed. Fixing one of a pair and missing its neighbour is the recurring shape here, which is why
 * the whole file was swept rather than the cited line edited.
 *
 * Returning `false` rather than an empty array matters: Fastify treats `[]` as a list that matches
 * nothing, which is the same behaviour, but `false` is the value its documentation describes for
 * "no proxy", and the two have differed across releases. Being explicit costs nothing.
 */
/**
 * Fastify's own named proxy sets, which `@fastify/proxy-addr` accepts alongside addresses. Passed
 * through rather than rejected: they are the documented way to say "the RFC1918 ranges" without
 * writing three CIDRs out, and refusing them would make this validation narrower than the thing it
 * is validating for.
 */
const NAMED_PROXY_SETS = new Set(["loopback", "linklocal", "uniquelocal"]);

/**
 * Is one entry something `@fastify/proxy-addr` can compile — an IP, a CIDR, or a named set?
 *
 * `net.isIP` returns 4, 6 or 0, which is the whole of the address check. The prefix is checked
 * against the family's own width, because `10.0.0.0/64` is not a v4 network and `proxy-addr` will
 * say so at a moment nobody is watching.
 */
export function isTrustedProxyEntry(entry: string): boolean {
  if (NAMED_PROXY_SETS.has(entry)) return true;
  const slash = entry.indexOf("/");
  if (slash === -1) return isIP(entry) !== 0;
  const address = entry.slice(0, slash);
  const prefix = entry.slice(slash + 1);
  const family = isIP(address);
  if (family === 0) return false;
  if (!/^\d{1,3}$/.test(prefix)) return false;
  const bits = Number(prefix);
  // **`/0` is rejected, and it is not an off-by-one** (PR #87 sixth round). `@fastify/proxy-addr`
  // refuses a full-range prefix — `TypeError: invalid range on address: 0.0.0.0/0` — so accepting it
  // here produced exactly the failure this validator was written to prevent: a raw third-party throw
  // inside the `Fastify(...)` constructor, before `app.ready()`, naming library internals instead of
  // the variable. Confirmed for `0.0.0.0/0`, `10.0.0.0/0`, `1.2.3.4/0`, `::/0`, `::1/0`, `fe80::/0`
  // and `0.0.0.0/00`; everything else compiles, including `10.0.0.0/008`.
  //
  // **And `/0` is the shape an operator reaches for on purpose**, not a typo: it is how you write
  // "trust everything", which is what someone wants when they are looking for the old boolean
  // `true`. That is why the message below says what it is rather than only that it is invalid.
  return bits > 0 && bits <= (family === 4 ? 32 : 128);
}

/**
 * Parse and **validate** `TRUSTED_PROXIES`.
 *
 * **Nothing validated these entries, and the failure was a third-party stack trace at startup**
 * (PR #87 third round, F5). The array went straight to `@fastify/proxy-addr`'s `compile()`, which
 * throws a raw `TypeError` **inside the `Fastify(...)` constructor** — before `app.ready()`, before
 * any logger this server configures, and naming library internals rather than the variable that is
 * actually wrong. A typo in one CIDR meant a gateway that would not start and a log that did not say
 * why, which defeats the property the top of this file exists for: a bad environment is a named
 * `ConfigError` identifying the variable, not a crash.
 *
 * The offending entry is named because there is no way to fix a list without knowing which element
 * is bad, and — unlike a credential — a proxy address is not a secret. `SONNY_ENV` and the rest are
 * deliberately reported without their values; this one is deliberately reported with it.
 */
export function parseTrustedProxies(raw: string): boolean | string[] {
  const trimmed = raw.trim();
  if (trimmed === "") return false;
  const entries = trimmed.split(",").map((entry) => entry.trim()).filter(Boolean);
  const bad = entries.filter((entry) => !isTrustedProxyEntry(entry));
  if (bad.length > 0) {
    throw new ConfigError(
      `TRUSTED_PROXIES contains ${bad.length} entry/entries that are not an IP address, a CIDR ` +
        `range or a named set: ${bad.map((entry) => JSON.stringify(entry)).join(", ")}. ` +
        `Expected a comma-separated list like 10.0.0.0/8,172.16.0.0/12, or one of ` +
        `${[...NAMED_PROXY_SETS].join(", ")}. A /0 prefix is refused specifically: there is no way ` +
        `to say "trust every proxy" here, because trusting every hop means any caller can choose ` +
        `its own apparent address, which is the setting this variable replaced. Left unchecked ` +
        `these reach Fastify's proxy-address parser, which throws inside the server constructor ` +
        `and names its own internals instead of this variable.`,
    );
  }
  return entries;
}

/**
 * The one overlap slot this gateway reads, and every other numbered spelling of it.
 *
 * `SUPABASE_JWT_SECRET` and `SUPABASE_JWT_SECRET_2` are read; `SUPABASE_JWT_SECRET_1`, `_3`, the
 * zero-padded `_02` and anything else numbered are read by nothing. **The padded spellings are the
 * point of the comparison being textual** — see `READ_JWT_SECRET_SLOT` below.
 */
const JWT_SECRET_SLOT = /^SUPABASE_JWT_SECRET_(\d+)$/;
/**
 * The slot suffix this gateway reads, **as text**.
 *
 * A string rather than a number, and compared with `!==` against the captured text rather than
 * through `Number()` (PR #218's F1). `Number("02") === 2`, so a numeric comparison read
 * `SUPABASE_JWT_SECRET_02` and `_002` as "the slot we read" and let them past the guard — while the
 * Zod schema reads the literal name and nothing else. The variable was then set, unread and
 * unreported: exactly the state the refusal below says it exists to prevent, reached through the
 * guard written to prevent it. Zero-padding an environment variable's index is an ordinary thing to
 * do in a compose file or a systemd unit, and nothing about the name looks wrong.
 */
const READ_JWT_SECRET_SLOT = "2";

/**
 * Refuse a numbered `SUPABASE_JWT_SECRET_<n>` this gateway does not read, rather than ignoring it
 * (SONNY-238).
 *
 * **Why this is a refusal and `providerCredentials` below stops at a gap in silence.** The two look
 * like the same list and fail in opposite directions. A provider key is one this gateway *sends*, so
 * a skipped `<PROVIDER>_API_KEY_4` costs a credential to try and the deployment carries on. A
 * *verifying* secret is one this gateway *accepts*, so a skipped `SUPABASE_JWT_SECRET_3` means every
 * token signed with it is refused — which is the sign-out this ticket exists to prevent, reached
 * through the fix for it, and reached silently: nothing in the logs, nothing in `/v1/health`, an
 * operator who set the variable and watched every user be signed out anyway.
 *
 * **In `loadConfig` rather than in `requireSupabaseJwtPolicy`.** Zod validates a fixed set of names
 * and ignores everything else, so a slot nobody reads is invisible to the schema and only the raw
 * environment can show it — the same reason `providerCredentials` takes `env`. And it is invalid
 * configuration whether or not this deployment mounts an authenticated route, unlike the *absence*
 * of a secret, which is deliberately fine at load and refused at the point of use.
 */
function refuseUnreadJwtSecretSlots(env: NodeJS.ProcessEnv): void {
  const unread = Object.keys(env)
    .map((name) => [name, JWT_SECRET_SLOT.exec(name)] as const)
    .filter(([name, match]) => {
      if (!match) return false;
      // An empty or whitespace-only value is nobody setting the slot, which is not a misconfiguration.
      if (!env[name]?.trim()) return false;
      // The captured TEXT, never its numeric value: `Number("02") === 2` and `"02" !== "2"`.
      return match[1] !== READ_JWT_SECRET_SLOT;
    })
    .map(([name]) => name)
    .sort();
  if (unread.length === 0) return;
  throw new ConfigError(
    `${unread.join(", ")} ${unread.length === 1 ? "is" : "are"} set and nothing reads ` +
      `${unread.length === 1 ? "it" : "them"}. This gateway accepts SUPABASE_JWT_SECRET and one ` +
      "overlap slot, SUPABASE_JWT_SECRET_2, and no others — a secret in a slot nothing reads would " +
      "leave every token signed with it refused, which is the sign-out an overlap exists to " +
      "prevent. Values are omitted deliberately; see server/.env.example for the expected shape.",
  );
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    // **Built from the variable name and the issue CODE, never from `issue.message`.**
    //
    // This is narrower than it first looks, and the first version of this file got it wrong.
    // Zod's message is safe for most issue kinds, but `invalid_enum_value` renders as
    // `Invalid enum value. Expected 'local' | 'staging' | 'production', received 'sk-abc...'` --
    // it quotes the value back. So a credential pasted into an enum-typed variable by mistake
    // would land in whatever collects this server's logs, at startup, in plain text. Since the
    // set of issue kinds Zod can produce grows with Zod, the rule is that no rendered message is
    // used at all rather than that the unsafe ones are filtered.
    const problems = parsed.error.issues
      .map((issue) => `${issue.path.join(".") || "(root)"} (${issue.code})`)
      .join("; ");
    throw new ConfigError(
      `invalid environment configuration -- ${problems}. ` +
        `Values are omitted deliberately; see server/.env.example for the expected shape.`,
    );
  }
  const value = parsed.data;

  // **`ALLOW_UNAUTHENTICATED_ACCOUNT_DELETE` and its production refusal stood here, and both are
  // gone with the reason they existed** (SONNY-203). The flag mounted `DELETE /v1/account` only
  // where a deployment opted in, because that route attributed its caller through a seam no adapter
  // implemented — a destructive primitive trusting a check that did not exist. Verification now
  // exists (`auth/token.ts`) and the gate applies it to every protected route, so the route is
  // mounted unconditionally and attributes its caller from a verified token. Removing the flag
  // rather than defaulting it off is the point: a flag left in place is a flag someone can set.

  refuseUnreadJwtSecretSlots(env);

  return {
    environment: value.SONNY_ENV,
    port: value.PORT,
    host: value.HOST,
    buildId: value.SONNY_BUILD_ID,
    databaseUrl: value.DATABASE_URL,
    logLevel: value.LOG_LEVEL,
    trustProxy: parseTrustedProxies(value.TRUSTED_PROXIES),
    rateLimitSalt: value.RATE_LIMIT_SALT ?? "",
    contentRetentionDays: value.CONTENT_RETENTION_DAYS,
    contentExpirySweepSeconds: value.CONTENT_EXPIRY_SWEEP_SECONDS,
    entitlementSigningKey: value.ENTITLEMENT_SIGNING_KEY,
    entitlementSigningKeyId: value.ENTITLEMENT_SIGNING_KEY_ID,
    spendCapUnits: value.SPEND_CAP_UNITS,
    creditPlans: value.CREDIT_PLANS,
    supabaseJwtSecret: value.SUPABASE_JWT_SECRET,
    supabaseJwtSecret2: value.SUPABASE_JWT_SECRET_2,
    supabaseJwtSecret2AcceptedUntil: value.SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL,
    supabaseJwtIssuer: value.SUPABASE_JWT_ISSUER,
    supabaseJwtAudience: value.SUPABASE_JWT_AUDIENCE,
    openAIBaseUrl: value.OPENAI_BASE_URL,
    openAITextModel: value.OPENAI_TEXT_MODEL,
    openAITranscriptionModel: value.OPENAI_TRANSCRIPTION_MODEL,
    searchBaseUrl: value.SEARCH_BASE_URL,
    visionBaseUrl: value.VISION_BASE_URL,
    visionModel: value.VISION_MODEL,
    anthropicBaseUrl: value.ANTHROPIC_BASE_URL,
    anthropicTextModel: value.ANTHROPIC_TEXT_MODEL,
    anthropicMaxOutputTokens: value.ANTHROPIC_MAX_OUTPUT_TOKENS,
    cerebrasBaseUrl: value.CEREBRAS_BASE_URL,
    cerebrasTextModel: value.CEREBRAS_TEXT_MODEL,
    routeChains: {
      plan: parseRouteChain("plan", value.MODEL_ROUTE_PLAN),
      synthesize: parseRouteChain("synthesize", value.MODEL_ROUTE_SYNTHESIZE),
      transcriptions: parseRouteChain("transcriptions", value.MODEL_ROUTE_TRANSCRIPTIONS),
      search: parseRouteChain("search", value.MODEL_ROUTE_SEARCH),
    },
    dataPolicies: providerDataPolicies(env),
    supabaseAnonKey: value.SUPABASE_ANON_KEY,
    supabaseServiceRoleKey: value.SUPABASE_SERVICE_ROLE_KEY,
    billingProvider: value.BILLING_PROVIDER,
    billingWebhookSecret: value.BILLING_WEBHOOK_SECRET,
    billingCheckoutUrl: value.BILLING_CHECKOUT_URL,
    billingProviderAccessToken: value.BILLING_PROVIDER_ACCESS_TOKEN,
    billingApiBaseUrl: value.BILLING_API_BASE_URL,
    billingPlans: value.BILLING_PLANS,
    billingGraceDays: value.BILLING_GRACE_DAYS,
    minimumSupportedClient: value.MINIMUM_SUPPORTED_CLIENT,
    recommendedClient: value.RECOMMENDED_CLIENT,
    upgradeUrl: value.UPGRADE_URL,
    credentials: providerCredentials(env),
  };
}

/** The credential new requests use. `undefined` when the provider has none configured. */
export function activeKey(config: Config, provider: Provider): string | undefined {
  return config.credentials.find((entry) => entry.provider === provider)?.keys[0];
}

/** Every credential still honoured for `provider`, newest first. */
export function acceptedKeys(config: Config, provider: Provider): readonly string[] {
  return config.credentials.find((entry) => entry.provider === provider)?.keys ?? [];
}

/**
 * The rate-limit salt, or a startup failure naming it.
 *
 * Separate from `loadConfig` so that a deployment running no auth route is not forced to invent a
 * salt, while one that mounts them cannot start without a real value. An empty salt is refused
 * rather than tolerated: `bucketKey` would otherwise hash addresses unsalted and nothing would say
 * so.
 */
export function requireRateLimitSalt(config: Config): string {
  if (!config.rateLimitSalt) {
    throw new ConfigError(
      "RATE_LIMIT_SALT is required wherever the auth routes are mounted. " +
        "Values are omitted deliberately; see server/.env.example for the expected shape.",
    );
  }
  return config.rateLimitSalt;
}

/**
 * The entitlement signing key, or a startup failure naming what is missing.
 *
 * **Same shape and same reason as `requireRateLimitSalt`**: absent at load so a health-only
 * deployment need not invent one, refused at the point of use so a deployment that mounts
 * authenticated routes cannot start without it. The alternative — mounting
 * `GET /v1/account/entitlements` and answering an error on the first real request — is the shape
 * `deps.ts` already argues against for the Supabase names: a gateway that looks healthy and fails
 * every client is worse than one that will not start.
 *
 * Both names are required together, and the message says both, because a key with no `kid` signs
 * claims no client can select a key for.
 */
export function requireEntitlementSigningKey(config: Config): EntitlementSigningKey {
  const missing = [
    config.entitlementSigningKey ? undefined : "ENTITLEMENT_SIGNING_KEY",
    config.entitlementSigningKeyId ? undefined : "ENTITLEMENT_SIGNING_KEY_ID",
  ].filter((name): name is string => name !== undefined);
  if (missing.length > 0) {
    throw new ConfigError(
      `${missing.join(" and ")} ${missing.length === 1 ? "is" : "are"} required wherever an ` +
        "authenticated route is mounted: the entitlement claim is signed with Ed25519 and named by " +
        "its key id (contract section 5.3). Generate a key with: openssl genpkey -algorithm " +
        "ed25519 -outform DER | base64. Values are omitted deliberately; see server/.env.example " +
        "for the expected shape.",
    );
  }
  // Non-null by the sweep above. `entitlementSigningKeyFrom` refuses a key that is not base64 PKCS#8
  // DER, and one that is not Ed25519, without ever putting the value in the message.
  return entitlementSigningKeyFrom(config.entitlementSigningKey!, config.entitlementSigningKeyId!);
}

/**
 * The entitlement signing key when this deployment has one, or `undefined` when it has neither name.
 *
 * **The tolerant door, for the one route that is mounted whatever the environment.**
 * `GET /v1/meta` publishes §5.3's public key set unconditionally — `app.ts`'s standing argument that
 * the route table must not change shape — so it needs a way to ask for the key that answers "there
 * is none" instead of refusing to start. A health-only deployment mounts no authenticated route,
 * signs nothing, and correctly publishes an empty set.
 *
 * **A half-configured pair is still a startup failure**, because it delegates: with one of the two
 * names set, `requireEntitlementSigningKey` raises its own message naming the missing one, and a
 * present-but-malformed key still fails here rather than on a client that cannot verify a claim.
 * Only *neither* is an answer.
 */
export function optionalEntitlementSigningKey(config: Config): EntitlementSigningKey | undefined {
  if (!config.entitlementSigningKey && !config.entitlementSigningKeyId) return undefined;
  return requireEntitlementSigningKey(config);
}

/**
 * Contract §8's version policy, or a startup failure naming what is wrong.
 *
 * **`requireCreditCatalogue`'s shape: unset is an answer, present-and-malformed is not.** Both
 * bounds have defaults, so this can never fail for absence; what it refuses is a value that is
 * there and cannot be honoured. Every one of the four refusals below is a deployment error that
 * would otherwise present as a product bug — a gateway refusing every client, or refusing none
 * while looking configured, or telling a user to update and giving them nowhere to go.
 *
 * Called unconditionally from `buildApp`, because `GET /v1/meta` and the version gate are both
 * mounted whatever the environment. So a typo in `MINIMUM_SUPPORTED_CLIENT` is a named startup
 * failure on every deployment, which is this file's standing property.
 */
export function requireClientVersionPolicy(config: Config): ClientVersionPolicy {
  const minimum = parseMarketingVersion(config.minimumSupportedClient);
  if (minimum === undefined) {
    throw new ConfigError(
      `MINIMUM_SUPPORTED_CLIENT is not a marketing version: expected one to three numeric ` +
        `components such as 1.0.0, optionally with a +build suffix, as the Mac sends in ` +
        `Sonny-Client-Version (contract section 2.2). Below this version every route answers 410 ` +
        `version.unsupported, so an unreadable one has no safe reading -- refusing nobody hides a ` +
        `policy somebody set, and refusing everybody is an outage. Leave it unset for 0.0.0, which ` +
        `refuses nobody deliberately. See server/.env.example for the expected shape.`,
    );
  }
  // Absent means the minimum: a deployment that arms the wall and names no warning band gets an
  // empty band, not a refusal. The schema's own docstring carries what that refusal cost.
  const recommended =
    config.recommendedClient === undefined
      ? minimum
      : parseMarketingVersion(config.recommendedClient);
  if (recommended === undefined) {
    throw new ConfigError(
      `RECOMMENDED_CLIENT is not a marketing version: expected one to three numeric components ` +
        `such as 1.0.0, optionally with a +build suffix. Below this version a client is served and ` +
        `told to update (contract section 8.4). Leave it unset for 0.0.0, which warns nobody. See ` +
        `server/.env.example for the expected shape.`,
    );
  }
  if (compareVersions(recommended, minimum) < 0) {
    throw new ConfigError(
      `RECOMMENDED_CLIENT (${formatVersion(recommended)}) is below MINIMUM_SUPPORTED_CLIENT ` +
        `(${formatVersion(minimum)}), which describes no client that can exist: contract section ` +
        `8.4 makes the recommended version the warning a client gets BEFORE it reaches the wall, so ` +
        `every version it would warn is already refused. Set them equal to arm the wall with no ` +
        `warning period.`,
    );
  }

  const bounds = {
    minimum,
    recommended,
    minimumText: formatVersion(minimum),
    recommendedText: formatVersion(recommended),
  } as const;

  const armed =
    compareVersions(minimum, ZERO_VERSION) > 0 || compareVersions(recommended, ZERO_VERSION) > 0;
  const upgradeUrl = config.upgradeUrl === undefined ? null : checkedUpgradeUrl(config.upgradeUrl);

  if (!armed) return { ...bounds, armed: false, upgradeUrl };
  if (upgradeUrl === null) {
    throw new ConfigError(
      `UPGRADE_URL is required once MINIMUM_SUPPORTED_CLIENT or RECOMMENDED_CLIENT is above ` +
        `0.0.0. Contract section 8.3 puts an upgrade_url in the 410 body and section 8.4 puts one ` +
        `in Sonny-Deprecation-Info, because the state those describe is "a definite, actionable ` +
        `state that the app can render as 'Sonny needs an update' with a button" -- and a button ` +
        `needs somewhere to go. See server/.env.example for the expected shape.`,
    );
  }
  return { ...bounds, armed: true, upgradeUrl };
}

/**
 * The upgrade URL, checked for the two things that make it usable.
 *
 * **Parsed rather than pattern-matched**, so `https://example.test/download` passes and
 * `example.test/download` — which has no scheme and is what an operator types — is refused here
 * instead of becoming a relative link inside whatever renders it.
 *
 * **The scheme is restricted to http and https**, which is narrower than "a valid URL" for a reason
 * that is about the Mac and not about this gateway: §8.3's actionable state is a button, so
 * something on the client eventually opens this, and `NSWorkspace.open` will happily launch a
 * `file:` path or a custom scheme registered by any installed app. That makes an operator's typo a
 * local action rather than a browser tab. This is a server-configured value and never a
 * caller-supplied one, so it is not a wire attack surface; it is a mistake this refuses to carry.
 *
 * The value is named in the message, unlike a credential: a URL is not a secret and there is no way
 * to fix one without seeing which one is wrong.
 */
function checkedUpgradeUrl(raw: string): string {
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    throw new ConfigError(
      `UPGRADE_URL is not a URL: ${JSON.stringify(raw)}. Expected an absolute http or https URL ` +
        `such as https://example.test/download -- a bare host with no scheme is the usual cause.`,
    );
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new ConfigError(
      `UPGRADE_URL must be http or https, not ${JSON.stringify(parsed.protocol)}: ` +
        `${JSON.stringify(raw)}. It is the address a user is sent to when their build is refused, ` +
        `so the client opens it -- and every other scheme is a local action on that user's Mac ` +
        `rather than a download page.`,
    );
  }
  return parsed.toString();
}

/**
 * The deployment's spend cap, or a startup failure naming it.
 *
 * **`0` is a legitimate value and `undefined` is not**, which is why this tests for `undefined`
 * rather than for falsiness: an operator setting `SPEND_CAP_UNITS=0` has said "this deployment
 * spends nothing", which is a real answer and a useful one while a gateway is being brought up. An
 * *unset* variable is not an answer, and treating it as "uncapped" would be the accepted-cost of
 * SONNY-16 with a mechanism in front of it doing nothing.
 */
export function requireSpendCapUnits(config: Config): number {
  if (config.spendCapUnits === undefined) {
    throw new ConfigError(
      "SPEND_CAP_UNITS is required wherever an authenticated route is mounted: it is the " +
        "per-account, per-period ceiling on metered calls, and an unset one would mean no ceiling " +
        "at all. It is this deployment's own ceiling and not a plan's allowance -- plans, prices " +
        "and allowances are SONNY-212's. See server/.env.example for the expected shape.",
    );
  }
  return config.spendCapUnits;
}

/**
 * The deployment's credit catalogue, or a startup failure naming it.
 *
 * **`requireSpendCapUnits`' shape and `requireEntitlementSigningKey`'s parse-at-startup rule, in one
 * function**, because this variable needs both: it may not be absent, and a value that is present
 * and malformed must fail here rather than on the first user who asks how many runs they have left.
 * `parseCreditCatalogue` is what refuses; this adds the name of the variable to fix.
 */
export function requireCreditCatalogue(config: Config): CreditCatalogue {
  if (config.creditPlans === undefined) {
    throw new ConfigError(
      "CREDIT_PLANS is required wherever an authenticated route is mounted: it carries every tier, " +
        "allowance and credit weight this deployment bills against, and an unset one has no safe " +
        "reading -- no allowance locks every user out of screen control, and unlimited is an " +
        "uncapped bill. This repository sets no plan, no price and no allowance of its own. See " +
        "server/.env.example for the expected shape.",
    );
  }
  try {
    return parseCreditCatalogue(config.creditPlans);
  } catch (error) {
    throw new ConfigError(
      error instanceof CreditCatalogueError
        ? error.message
        : `CREDIT_PLANS could not be read: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}

/**
 * The shortest secret this gateway will verify with.
 *
 * HS256's security is bounded by the key, not by the digest: a short secret is offline-guessable
 * against any token the holder has ever seen, and guessing it yields the ability to *mint* tokens
 * for any user rather than merely to read one. Supabase issues a JWT secret far longer than this, so
 * the floor only ever catches a human-chosen stand-in — which is exactly the value worth catching,
 * because it is the one somebody types in a hurry to get a local server started.
 */
export const MIN_JWT_SECRET_LENGTH = 32;

/**
 * The stated maximum overlap between the retiring JWT secret and its replacement, in days
 * (SONNY-238).
 *
 * **The founders decided on 2026-08-30 that there is a maximum and that it lives beside the rotation
 * steps rather than in someone's memory**; the number and whether anything checks it were left to
 * whoever built this, with their own note that a number nothing checks is "better than nothing and
 * worse than a check". So it is a constant the configuration enforces rather than a sentence in the
 * runbook, and `SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL` is what a deploy states against it.
 *
 * **Seven, and why that number.** The overlap only has to outlive the longest-lived access token
 * signed with the retiring secret: Supabase's default access-token lifetime is one hour, and
 * `auth/clock.ts` grants `EXPIRY_SKEW_TOLERANCE_SECONDS` past `exp` on top of it, so the functional
 * requirement is hours. Everything above that is slack for the humans doing three deploys, possibly
 * across a weekend. Seven days is two orders of magnitude of that slack and still short enough that a
 * retired secret left behind is a forgery key for days rather than forever — which is the failure the
 * ticket names as the realistic one.
 */
export const MAX_JWT_SECRET_OVERLAP_DAYS = 7;

/**
 * The verification policy, or a startup failure naming what is missing.
 *
 * Separate from `loadConfig` for the reason `requireRateLimitSalt` is: a deployment that mounts no
 * authenticated route should not be forced to hold a signing secret, and one that does must not be
 * able to start without a real value. **Every failure here is a startup failure rather than a
 * request-time one** — a gateway that boots and then refuses every request looks, from outside,
 * exactly like a gateway whose users have all been signed out.
 */
export function requireSupabaseJwtPolicy(
  config: Config,
  now: Date = new Date(),
): SupabaseJwtPolicy {
  const missing = [
    config.supabaseJwtSecret ? undefined : "SUPABASE_JWT_SECRET",
    config.supabaseJwtIssuer ? undefined : "SUPABASE_JWT_ISSUER",
  ].filter((name): name is string => name !== undefined);
  if (missing.length > 0) {
    throw new ConfigError(
      `${missing.join(" and ")} ${missing.length === 1 ? "is" : "are"} required wherever an ` +
        "authenticated route is mounted: without them no access token can be verified and every " +
        "protected route would refuse every caller. Values are omitted deliberately; see " +
        "server/.env.example for the expected shape.",
    );
  }
  const secret = config.supabaseJwtSecret!;
  const issuer = config.supabaseJwtIssuer!;
  refuseAShortJwtSecret("SUPABASE_JWT_SECRET", secret);
  // The issuer is not a secret — it is a public URL naming the project — so unlike every other
  // variable here it is reported with its value. A `iss` mismatch is otherwise invisible: every
  // token verifies against the secret and is then refused, which reads as "all my users are signed
  // out" rather than as a typo in one variable.
  let parsed: URL;
  try {
    parsed = new URL(issuer);
  } catch {
    throw new ConfigError(
      `SUPABASE_JWT_ISSUER must be the project's auth URL, e.g. ` +
        `https://<project-ref>.supabase.co/auth/v1 — got ${JSON.stringify(issuer)}, which is not a ` +
        "URL. It is compared exactly against each token's iss claim, so a project reference or a " +
        "bare hostname refuses every token that project issues.",
    );
  }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
    throw new ConfigError(
      `SUPABASE_JWT_ISSUER must be an http or https URL — got ${JSON.stringify(parsed.protocol)}.`,
    );
  }
  return {
    secrets: [
      // **Index 0 carries no end, and that is built here rather than configured.** An end on the
      // current secret would be a date after which this gateway refuses every token, which is the
      // outage an overlap exists to prevent. Only the overlap slot can carry one.
      { value: secret, acceptedUntil: undefined },
      ...overlapSecret(config, now),
    ],
    issuer,
    audience: config.supabaseJwtAudience,
  };
}

/**
 * The overlap slot as the verifier takes it, or nothing when no rotation is in flight (SONNY-238).
 *
 * Returns an array so the caller spreads it: a rotation is the exception, and the ordinary shape is
 * one secret with nothing after it.
 */
function overlapSecret(config: Config, now: Date): readonly AcceptedJwtSecret[] {
  const value = config.supabaseJwtSecret2;
  const until = config.supabaseJwtSecret2AcceptedUntil;

  // **Both or neither, and each direction is its own message.** A half-applied rotation deploy is the
  // realistic way one of these arrives alone, and which half is missing decides what an operator does
  // next — so telling them "one of these two is wrong" would be a message they have to guess at.
  if (value === undefined && until === undefined) return [];
  if (value === undefined) {
    throw new ConfigError(
      "SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL is set and SUPABASE_JWT_SECRET_2 is not, so the " +
        "deadline names no secret. Either the overlap secret is missing from this deploy or the " +
        "rotation is finished and the deadline is what is left over; set the secret or remove the " +
        "deadline. Values are omitted deliberately; see server/.env.example for the expected shape.",
    );
  }
  if (until === undefined) {
    throw new ConfigError(
      "SUPABASE_JWT_SECRET_2 is set without SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL. An accepted " +
        "secret with no end is a second key that can mint a token for any user, for as long as " +
        "nobody remembers to remove it — which is indistinguishable from never having rotated at " +
        `all (founder decision of 2026-08-30). Give it an instant at most ${MAX_JWT_SECRET_OVERLAP_DAYS} ` +
        "days away, ISO-8601, e.g. 2026-09-14T00:00:00Z.",
    );
  }

  refuseAShortJwtSecret("SUPABASE_JWT_SECRET_2", value);

  // **The same value in both slots is refused.** It reads as a live overlap in every log and every
  // configuration dump, and it is not one: retiring "the previous secret" then retires the current
  // one too, and the sign-out this variable exists to prevent happens on the deploy that was meant
  // to be safe. A no-op that looks like a working mechanism is worse than an absent one.
  if (value === secretOf(config)) {
    throw new ConfigError(
      "SUPABASE_JWT_SECRET_2 holds the same value as SUPABASE_JWT_SECRET, which is not an overlap: " +
        "there is one secret, and retiring the second slot retires the only one in use. A rotation " +
        "puts the incoming secret in one slot and the outgoing one in the other.",
    );
  }

  const acceptedUntil = parseOverlapDeadline(until);

  // **The stated maximum, made mechanical** (founder decision of 2026-08-30; the founders left the
  // number and whether anything checks it to whoever built this). The overlap only has to outlive the
  // longest-lived access token signed with the retiring secret — Supabase's default access-token
  // lifetime is an hour, and `auth/clock.ts` grants `EXPIRY_SKEW_TOLERANCE_SECONDS` past that — so
  // the functional need is measured in hours. Seven days is enough slack for three deploys done by
  // people across a weekend and short enough that a forgotten forgery key is measured in days.
  //
  // **What this does not prevent, said rather than implied:** it bounds the *remaining* overlap at
  // each startup, because this gateway does not know when the rotation began. An operator
  // redeploying every week with a fresh deadline extends the overlap indefinitely, and nothing here
  // sees that. What it does catch is the realistic mistake — a deadline typed months out, or a year
  // wrong — and it catches it at the moment somebody typed it.
  const maximum = new Date(now.getTime() + MAX_JWT_SECRET_OVERLAP_DAYS * 24 * 60 * 60 * 1000);
  if (acceptedUntil.getTime() > maximum.getTime()) {
    throw new ConfigError(
      `SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL is ${acceptedUntil.toISOString()}, more than ` +
        `${MAX_JWT_SECRET_OVERLAP_DAYS} days from now. That is the maximum overlap: the previous ` +
        "secret can mint a token for any user for as long as it is accepted, and a rotation needs " +
        "hours rather than months — one access-token lifetime plus the gate's skew tolerance. " +
        `The latest instant this deploy accepts is ${maximum.toISOString()}.`,
    );
  }

  // **An instant already past is not refused.** It means the overlap is over, and `verifyAccessToken`
  // stops accepting the secret on its own — which is the ending working. Refusing to boot on it would
  // turn leftover bookkeeping into every user being signed out, the exact failure this slot exists to
  // avoid, and it would buy nothing: a secret past its instant authorises nothing here.
  return [{ value, acceptedUntil }];
}

/**
 * An ISO-8601 instant **carrying an offset**, in the extended format, and nothing else.
 *
 * `Z` or `±HH:MM` is required rather than optional, which is the whole point of having a pattern
 * here at all. The three groups are the calendar date, checked below for a rollover the parser would
 * otherwise absorb.
 */
const ISO_INSTANT = /^(\d{4})-(\d{2})-(\d{2})T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

/**
 * The overlap's end, or a startup failure naming the value (SONNY-238; PR #218's F3).
 *
 * **`new Date(until)` alone accepted three spellings the refusal message promised it refused**, and
 * the message is the one an operator reads. `new Date("2026")` is the first instant of that year, so
 * a bare year in the past booted clean with the slot never accepted — an overlap dead on arrival.
 * `new Date("Sep 8 2026")` parsed, and is not an ISO-8601 instant by any reading. Worst of the three,
 * a **zone-less** spelling like `2026-09-08T00:00:00` is read in the *process's* local zone, so the
 * same string means a different instant on a host west of UTC than east of it — silently moving the
 * end of a second signing key's life by up to fourteen hours, on the one variable whose entire job is
 * to bound exactly that. A shape check is what makes the message true, and a false statement about
 * what a security boundary refuses is the class this repository keeps re-recording.
 *
 * **The calendar check is not the shape check and closes a fourth spelling.** ECMAScript's own ISO
 * parser absorbs a day-of-month overflow rather than rejecting it: `new Date("2026-02-30T00:00:00Z")`
 * is `2026-03-02`. The pattern above cannot see that — `30` is two digits — so the written fields are
 * compared against what the parser produced. Same family as the zone-less case: the operator wrote
 * one instant and the bound became another, with nothing saying so.
 *
 * **The value is reported and that is deliberate.** A deadline is not a secret — it is a date — and
 * a refusal that will not say what it read is one nobody can act on. Every message on this path that
 * touches a *secret* reports a length or a name and never a value; this one is the exception because
 * the thing it is about is public.
 */
function parseOverlapDeadline(until: string): Date {
  const shape = ISO_INSTANT.exec(until);
  if (!shape) {
    throw new ConfigError(
      "SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL must be an ISO-8601 instant carrying an offset, e.g. " +
        `2026-09-14T00:00:00Z or 2026-09-14T00:00:00-04:00 — got ${JSON.stringify(until)}. A bare ` +
        "year, a date with no time, or a time with no zone are all refused: this decides when a " +
        "second key that can mint a token for any user stops being accepted, and a spelling with no " +
        "zone would be read in whatever zone the container happens to run in.",
    );
  }
  const acceptedUntil = new Date(until);
  if (Number.isNaN(acceptedUntil.getTime())) {
    throw new ConfigError(
      `SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL is shaped like an instant but is not one — got ` +
        `${JSON.stringify(until)}, which names no moment in time. An unreadable deadline would ` +
        "leave the overlap with no end, because every comparison against it is false.",
    );
  }
  // **The written digits against the parsed fields, and `Date.UTC` is deliberately not on either
  // side.** It normalises exactly the way the parser does, so building a `Date` from the written
  // fields and comparing the two rolls both and reports agreement — which is what the first version
  // of this check did, and it accepted `2026-02-30T00:00:00Z` while claiming to refuse it. The
  // offset is undone first so that what is compared is the calendar date as written, whatever zone
  // it was written in.
  const [, year, month, day] = shape as unknown as [string, string, string, string];
  const asWritten = new Date(acceptedUntil.getTime() + offsetMillis(until));
  if (
    asWritten.getUTCFullYear() !== Number(year) ||
    asWritten.getUTCMonth() !== Number(month) - 1 ||
    asWritten.getUTCDate() !== Number(day)
  ) {
    throw new ConfigError(
      `SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL names a date that does not exist — got ` +
        `${JSON.stringify(until)}, which reads as ${acceptedUntil.toISOString()}. A day past the ` +
        "end of its month is rolled forward rather than refused by the date parser, so the bound " +
        "would silently be a different one from the bound you wrote.",
    );
  }
  return acceptedUntil;
}

/**
 * The offset a shape-checked instant declares, in milliseconds — `Z` is zero.
 *
 * Used only to recover the calendar date *as written* so it can be compared with the digits the
 * operator typed. Nothing else reads it: the instant itself is already absolute, and the sign is the
 * one this returns rather than the one applied to it — `2026-09-14T00:00:00-04:00` is the instant
 * `04:00Z`, so adding the declared offset back gets to `00:00` on the written day.
 */
function offsetMillis(until: string): number {
  if (until.endsWith("Z")) return 0;
  const sign = until.slice(-6, -5) === "-" ? -1 : 1;
  const hours = Number(until.slice(-5, -3));
  const minutes = Number(until.slice(-2));
  return sign * (hours * 60 + minutes) * 60 * 1000;
}

/** The current secret, read the one way `requireSupabaseJwtPolicy` has already proved is present. */
function secretOf(config: Config): string {
  return config.supabaseJwtSecret!;
}

/**
 * The length floor, applied identically to every accepted secret.
 *
 * **One function rather than a check per slot** (SONNY-238). The ticket's own words are that a
 * rotation which quietly relaxed a check for the second key would be worse than the sign-out it
 * avoids, and a floor written twice is a floor that can come apart. The LENGTH is reported and the
 * value is not: a length is not a secret, and "too short" with no number is a message that cannot be
 * acted on.
 */
function refuseAShortJwtSecret(name: string, secret: string): void {
  if (secret.length >= MIN_JWT_SECRET_LENGTH) return;
  throw new ConfigError(
    `${name} is ${secret.length} characters; at least ${MIN_JWT_SECRET_LENGTH} are ` +
      "required. Anyone holding this secret can mint a token for any user, so a guessable one is " +
      "a forgery key rather than a weak password. Supabase's own project secret is longer than " +
      "this floor, so a value this short is a stand-in rather than the real thing.",
  );
}

/**
 * The Supabase Auth **API** credentials, or a startup failure naming what is missing (SONNY-307).
 *
 * Separate from `requireSupabaseJwtPolicy` because the two answer different questions about the same
 * project, and a deployment can legitimately want one without the other. That function is about
 * *verifying* a token this gateway was handed — local, symmetric, no network. This one is about
 * *calling* the project: minting a code, exchanging it, rotating, signing out. A gateway that only
 * needs to check tokens needs no API key at all.
 *
 * **Same shape and same reason as `requireRateLimitSalt`**: absent at load so a health-only
 * deployment need invent nothing, refused at the point of use so a deployment that mounts sign-in
 * cannot start without real values. Every failure is a startup failure — a gateway that boots and
 * then answers 502 to every sign-in looks, from outside, exactly like a provider outage.
 *
 * **The auth base URL is not among these**, deliberately: it is `SUPABASE_JWT_ISSUER`, so the
 * project this gateway *calls* and the project whose tokens it *accepts* cannot be configured apart.
 * `auth/supabase.ts`'s `authUrl` docstring has the argument.
 *
 * **`SUPABASE_SERVICE_ROLE_KEY` is deliberately NOT required, and this is where it used to be**
 * (founder decision of 2026-08-27, option (c), taken at PR #137's review). It is the most dangerous
 * credential in the project — it bypasses every row-level policy and can act as any user — and
 * **exactly one method reaches for it**, `deleteUser`, which **no code path calls today**: the
 * account-closure route revokes sessions and deliberately keeps identities, and the ticket that
 * would call it is SONNY-196's. Requiring it meant every gateway that serves sign-in had to hold a
 * key nothing used, which is a standing risk bought for nothing — the whole of least privilege is
 * not holding a credential until something needs it. So a deployment mounting sign-in starts without
 * one, `deleteUser` fails at its own call site if it is ever invoked without one, and **the ticket
 * that lands a caller adds the name back to the required set and to `deploy.sh`'s passthrough in the
 * same change.** Setting it is still supported and still forwarded to the adapter; it is only no
 * longer refused for.
 */
export function requireSupabaseAuthCredentials(config: Config): {
  anonKey: string;
  serviceRoleKey: string | undefined;
} {
  if (!config.supabaseAnonKey) {
    throw new ConfigError(
      "SUPABASE_ANON_KEY is required wherever the sign-in routes are mounted: without it this " +
        "gateway cannot ask Supabase to send a code or exchange one. Values are omitted " +
        "deliberately; see server/.env.example for the expected shape.",
    );
  }
  return { anonKey: config.supabaseAnonKey, serviceRoleKey: config.supabaseServiceRoleKey };
}
