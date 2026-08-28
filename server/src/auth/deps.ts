import {
  ConfigError,
  requireEntitlementSigningKey,
  requireRateLimitSalt,
  requireSpendCapUnits,
  requireSupabaseAuthCredentials,
  requireSupabaseJwtPolicy,
  type Config,
} from "../config.js";
import { pooledConnections } from "../db/pool.js";
import type { AuthDeps } from "../routes/auth.js";
import { SupabaseAuthProvider } from "./supabase.js";

/**
 * Environment → the `AuthDeps` the process hands `buildApp`, or nothing at all (SONNY-307).
 *
 * **Why this is a module rather than ten lines in `server.ts`.** `server.ts` calls `main()` at
 * import, so importing it to test it starts a listening server. The decision below has three
 * outcomes and each one needs a test, so it lives where a test can reach it.
 *
 * ## The three shapes, and the rule that picks one
 *
 * | environment holds                     | outcome                                              |
 * |---------------------------------------|------------------------------------------------------|
 * | none of the three Supabase auth names | `undefined` — health-only, and a supported deployment |
 * | some of them                          | `ConfigError` at startup, naming every missing name   |
 * | all of them                           | `AuthDeps` — the auth routes mount                    |
 *
 * **Health-only stays supported and is not a fallback.** `app.ts` takes `auth` as optional precisely
 * so "a deployment that mounts no auth route needs no provider, no rate-limit salt and no JWT
 * secret", and `deploy.sh local` prints which of the two states the container is in. Nothing here
 * narrows that: an environment carrying none of these names produces exactly the server that shipped
 * before this ticket. The gate is still installed in that shape and still refuses every protected
 * route — `registerAuthGate` runs unconditionally — so health-only is a *smaller* server, never an
 * opener one.
 *
 * **A partial environment refuses rather than degrading, and that is the whole point of the middle
 * row.** An operator who sets two of the three names has said what they want; quietly serving
 * health-only would answer `404 resource.not_found` to every sign-in, which is indistinguishable
 * from the bug SONNY-307 exists to fix and was measured reading exactly that way. The failure is
 * `ConfigError` → `exit 78` (EX_CONFIG) with the missing names printed, which is `config.ts`'s own
 * stated property: "a missing credential is a startup failure with a named variable, not a server
 * that runs and fails on the first real request."
 *
 * **Why the trigger is the three Supabase names and not the whole set.** `DATABASE_URL` is also
 * required for auth, but it is not a *signal* of intent: a gateway running health-only while a
 * migration runs legitimately holds one, and treating it as intent would make that shape refuse to
 * start. `RATE_LIMIT_SALT` is the same. The three below mean sign-in and nothing else, so they are
 * the question, and `DATABASE_URL` and `RATE_LIMIT_SALT` are then requirements the answer carries.
 *
 * **`SUPABASE_JWT_AUDIENCE` is deliberately not one of them**: it has a default, so its presence
 * says nothing about intent, and an environment setting only that would otherwise refuse to start
 * over a variable that changes nothing.
 *
 * **`SUPABASE_SERVICE_ROLE_KEY` was a fourth trigger and is no longer one** (founder decision of
 * 2026-08-27, option (c), taken at PR #137's review). Nothing calls the one method that uses it, so
 * requiring it made every sign-in deployment hold the project's most dangerous credential in order
 * to use none of it. It is still read, still passed to the adapter when set, and no longer a reason
 * to refuse a start. Two consequences a reader should expect: an environment carrying **only** that
 * name is health-only rather than a refusal, because it now says nothing about intent; and
 * `deleteUser` throws `ServiceRoleKeyNotConfigured` if a future caller reaches it without one.
 * `config.ts`'s `requireSupabaseAuthCredentials` carries the full argument.
 */

/**
 * The names whose presence means "this deployment intends to serve sign-in".
 *
 * Kept as data rather than as four `if`s so the message below can enumerate what is missing, which
 * is the difference between an operator fixing one variable and an operator guessing at four.
 */
// **Two counts in this file's prose were left at "four" by the sweep that changed six others**
// (PR #137 review, N1) — in the file whose entire subject is that count. The list below is the
// count: `AUTH_INTENT.length` is what the code reads and what a reader should trust, and any
// sentence naming a number is a copy of it that can go stale independently.
const AUTH_INTENT: readonly (readonly [name: string, read: (config: Config) => unknown])[] = [
  ["SUPABASE_JWT_SECRET", (config) => config.supabaseJwtSecret],
  ["SUPABASE_JWT_ISSUER", (config) => config.supabaseJwtIssuer],
  ["SUPABASE_ANON_KEY", (config) => config.supabaseAnonKey],
];

/**
 * Everything auth needs beyond the three triggers above, in the order an operator would fix them.
 *
 * **SONNY-135 added the last three, and they are required here rather than at the route for the
 * reason this whole module exists**: an operator who has configured sign-in has said what they
 * want, and a gateway that mounts authenticated routes it cannot check entitlements or spend for is
 * the "looks healthy, fails every request" shape the middle row of the table above refuses. The
 * spend cap in particular has to be a startup requirement rather than a defaulted one — SONNY-16
 * recorded a leaked token billing the founder as an accepted cost, and a cap whose absence means
 * "uncapped" is that cost with a mechanism in front of it doing nothing.
 *
 * `SPEND_CAP_UNITS` is read through `!== undefined` rather than by the truthiness test the other
 * four use, because **`0` is a legitimate value here and the others have no such value**: an
 * operator setting it to zero has said this deployment spends nothing, and a presence sweep that
 * treated that as missing would refuse to start over an answer somebody gave.
 */
const AUTH_ALSO_REQUIRED: readonly (readonly [name: string, read: (config: Config) => unknown])[] = [
  ["DATABASE_URL", (config) => config.databaseUrl],
  ["RATE_LIMIT_SALT", (config) => config.rateLimitSalt],
  ["ENTITLEMENT_SIGNING_KEY", (config) => config.entitlementSigningKey],
  ["ENTITLEMENT_SIGNING_KEY_ID", (config) => config.entitlementSigningKeyId],
  ["SPEND_CAP_UNITS", (config) => config.spendCapUnits !== undefined],
];

export interface AuthWiring {
  readonly deps: AuthDeps;
  /** Drains the connection pool. Called from the process's own shutdown path, not by `buildApp`. */
  readonly close: () => Promise<void>;
}

/** Does this environment say anything at all about sign-in? */
export function intendsAuth(config: Config): boolean {
  return AUTH_INTENT.some(([, read]) => Boolean(read(config)));
}

/**
 * Build the wiring, refuse, or answer `undefined` for a health-only deployment.
 *
 * **Every validation the `require*` functions perform still runs**, and they all run *before* a pool
 * is opened: `requireSupabaseJwtPolicy` checks the secret's length floor and that the issuer parses
 * as an http(s) URL, `requireRateLimitSalt` refuses an empty salt, `requireSupabaseAuthCredentials`
 * names the two API keys, and — since SONNY-135 — `requireEntitlementSigningKey` refuses a key that
 * is not base64 PKCS#8 DER or is not Ed25519, and `requireSpendCapUnits` refuses an unset cap. **The
 * count is not written here**, because a sentence naming one is a copy of the call list below that
 * can go stale independently, which is the mistake this file's own `AUTH_INTENT` comment records
 * being made twice. The presence sweep below is not a replacement for any of them — it exists to
 * report *all* the missing names in one message instead of one per restart, and to distinguish
 * "nothing configured" from "half configured", which no individual `require*` can see.
 */
export function authWiringFrom(config: Config): AuthWiring | undefined {
  if (!intendsAuth(config)) return undefined;

  const missing = [...AUTH_INTENT, ...AUTH_ALSO_REQUIRED]
    .filter(([, read]) => !read(config))
    .map(([name]) => name);
  if (missing.length > 0) {
    // Both forms are written out rather than assembled from a plural `s`, because the pronoun has
    // to agree too and the first version got exactly that wrong: "one variable is missing:
    // RATE_LIMIT_SALT. Set them" (PR #137 review, residual 1). This message is the whole of what an
    // operator gets at `exit 78`, so it is worth reading like something a person wrote.
    const subject =
      missing.length === 1
        ? `one variable is missing: ${missing[0]}. Set it`
        : `${missing.length} variables are missing: ${missing.join(", ")}. Set them`;
    throw new ConfigError(
      `this deployment is configured for sign-in but ${subject}, or unset every Supabase auth ` +
        "variable to run a health-only gateway — those are the two supported shapes, and a partial " +
        "one would answer 404 to every sign-in while looking healthy. Values are omitted " +
        "deliberately; see server/.env.example for the expected shape.",
    );
  }

  // Order matters only in that these throw before anything is opened: a refused configuration must
  // not leave a pool behind, and a `ConfigError` raised after `pooledConnections` would.
  const policy = requireSupabaseJwtPolicy(config);
  const { anonKey, serviceRoleKey } = requireSupabaseAuthCredentials(config);
  requireRateLimitSalt(config);
  // The presence sweep above says the key is *there*; this says it parses as an Ed25519 PKCS#8 key.
  // A malformed one would otherwise be discovered by `buildApp`, which is after the pool is open —
  // and by a deployment whose first symptom is every client rejecting every claim.
  requireEntitlementSigningKey(config);
  requireSpendCapUnits(config);

  const provider = new SupabaseAuthProvider({
    // The issuer *is* the auth base URL — one variable, so the project this gateway calls and the
    // project whose tokens it accepts cannot be configured apart. `policy.issuer` rather than
    // `config.supabaseJwtIssuer` on purpose: it is the same string past the URL validation above,
    // so the adapter cannot be handed something `requireSupabaseJwtPolicy` would have refused.
    authUrl: policy.issuer,
    anonKey,
    serviceRoleKey,
  });

  // Non-null by the sweep above; `config.databaseUrl` is `string | undefined` on the type.
  const pool = pooledConnections(config.databaseUrl!);

  return {
    deps: { provider, withConnection: pool.withConnection },
    close: pool.close,
  };
}
