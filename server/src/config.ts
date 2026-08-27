import { isIP } from "node:net";
import { z } from "zod";
import type { SupabaseJwtPolicy } from "./auth/token.js";

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
  readonly supabaseJwtSecret: string | undefined;
  readonly supabaseJwtIssuer: string | undefined;
  readonly supabaseJwtAudience: string;
  readonly openAIBaseUrl: string;
  readonly openAITextModel: string;
  readonly openAITranscriptionModel: string;
  readonly searchBaseUrl: string;
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

  return {
    environment: value.SONNY_ENV,
    port: value.PORT,
    host: value.HOST,
    buildId: value.SONNY_BUILD_ID,
    databaseUrl: value.DATABASE_URL,
    logLevel: value.LOG_LEVEL,
    trustProxy: parseTrustedProxies(value.TRUSTED_PROXIES),
    rateLimitSalt: value.RATE_LIMIT_SALT ?? "",
    supabaseJwtSecret: value.SUPABASE_JWT_SECRET,
    supabaseJwtIssuer: value.SUPABASE_JWT_ISSUER,
    supabaseJwtAudience: value.SUPABASE_JWT_AUDIENCE,
    openAIBaseUrl: value.OPENAI_BASE_URL,
    openAITextModel: value.OPENAI_TEXT_MODEL,
    openAITranscriptionModel: value.OPENAI_TRANSCRIPTION_MODEL,
    searchBaseUrl: value.SEARCH_BASE_URL,
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
 * The verification policy, or a startup failure naming what is missing.
 *
 * Separate from `loadConfig` for the reason `requireRateLimitSalt` is: a deployment that mounts no
 * authenticated route should not be forced to hold a signing secret, and one that does must not be
 * able to start without a real value. **Every failure here is a startup failure rather than a
 * request-time one** — a gateway that boots and then refuses every request looks, from outside,
 * exactly like a gateway whose users have all been signed out.
 */
export function requireSupabaseJwtPolicy(config: Config): SupabaseJwtPolicy {
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
  if (secret.length < MIN_JWT_SECRET_LENGTH) {
    // The LENGTH is reported and the value is not. A length is not a secret, and "too short" with no
    // number is a message that cannot be acted on.
    throw new ConfigError(
      `SUPABASE_JWT_SECRET is ${secret.length} characters; at least ${MIN_JWT_SECRET_LENGTH} are ` +
        "required. Anyone holding this secret can mint a token for any user, so a guessable one is " +
        "a forgery key rather than a weak password. Supabase's own project secret is longer than " +
        "this floor, so a value this short is a stand-in rather than the real thing.",
    );
  }
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
  return { secret, issuer, audience: config.supabaseJwtAudience };
}
