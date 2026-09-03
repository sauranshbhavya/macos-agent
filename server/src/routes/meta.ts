import type { FastifyInstance } from "fastify";
import { isoSeconds, publicKeyMaterial, type EntitlementSigningKey } from "../entitlement/claim.js";
import type { ClientVersionPolicy } from "../version/policy.js";

/**
 * `GET /v1/meta` — contract §8.3 (SONNY-204).
 *
 * The one call a client makes before it knows anything: what this gateway speaks, which clients it
 * still serves, where to send a user whose build it does not, what time it is here, and which public
 * keys an entitlement claim may be signed with. §8.3 makes it "on launch and on any `410`", and
 * explicitly **not** per request.
 *
 * **Unauthenticated and mounted unconditionally**, both for reasons already settled elsewhere.
 * §2.2's list and `auth/gate.ts`'s `PUBLIC_ROUTES` have carried `GET /v1/meta` since SONNY-203 — a
 * client that has to sign in before it can be told its build is too old to sign in with is a client
 * in a loop. And `app.ts`'s standing argument is that the route table must not change shape with the
 * environment: a deployment missing a signing key answers here with an empty key set, which is a
 * true statement about that deployment, rather than a `404` the client reads as "no such route".
 *
 * **It is not exempt from the version gate, and §8.3 says so in as many words** — a client below the
 * minimum gets the `410` "on every endpoint, including `/v1/meta` itself answering honestly". That
 * is why §8.3 also requires `upgrade_url` in the *error* body: the one thing such a client needs is
 * in the refusal, so it never has to parse a `/v1/meta` document whose shape may have moved since it
 * shipped. `version/gate.ts` is registered before every route and covers this one like any other.
 */
export interface MetaRouteDeps {
  /** The minor version this build serves. `app.ts`'s `API_VERSION`, §2.3's `Sonny-Api-Version`. */
  readonly apiVersion: string;
  readonly policy: ClientVersionPolicy;
  /**
   * The key this gateway signs entitlement claims with, when it has one.
   *
   * `undefined` on a health-only deployment, which mounts no authenticated route and therefore
   * signs nothing. §5.3.1 makes an empty set refuse every *gated* capability on the Mac and affect
   * no free one, which is the direction that document requires.
   */
  readonly signingKey?: EntitlementSigningKey | undefined;
  /** Tests only. Nothing a deployment sets. */
  readonly now?: (() => Date) | undefined;
}

/**
 * §5.3's key set, as the client reads it.
 *
 * `alg` is `EdDSA` on every entry because that is the only algorithm this gateway signs with —
 * `entitlementSigningKeyFrom` refuses a key that is not Ed25519 rather than letting a P-256 key sign
 * claims under an `EdDSA` header. It is on the wire anyway, because a client selecting a key by
 * `kid` still has to know what to verify with, and because a second algorithm arriving one day is an
 * additive change to this array rather than a new field on it (§8.1).
 */
interface EntitlementKey {
  readonly kid: string;
  readonly alg: "EdDSA";
  readonly public_key: string;
}

export function registerMetaRoute(app: FastifyInstance, deps: MetaRouteDeps): void {
  const now = deps.now ?? (() => new Date());

  /**
   * Derived once at registration rather than per request.
   *
   * The public half is computed from the private key, so it cannot be configured into disagreement
   * with what actually signs — `publicKeyMaterial`'s own docstring carries that argument. Nothing
   * about it varies per request, and re-exporting an SPKI DER on every call would be work done to
   * produce the same string.
   *
   * **One entry today, and an array by contract rather than by anticipation.** §5.3 calls this "a
   * public key set" and says `/v1/meta` "publishes the current set so an online client can learn a
   * rotated key without an app update"; this gateway signs with exactly one key
   * (`ENTITLEMENT_SIGNING_KEY`), so the current set has one member. Publishing a *retired* or a
   * not-yet-signing key beside it — the overlap that makes a rotation three independently valid
   * deploys, the way `providerCredentials` does for provider keys — needs the signing side to hold
   * more than one key too, and that is a change to `EntitlementSigningKey` rather than to this
   * route. Filed rather than half-built here.
   */
  const entitlementKeys: readonly EntitlementKey[] =
    deps.signingKey === undefined
      ? []
      : [
          {
            kid: deps.signingKey.keyId,
            alg: "EdDSA",
            public_key: publicKeyMaterial(deps.signingKey),
          },
        ];

  app.get("/v1/meta", async (_request, reply) => {
    // The same `no-store` `/v1/health` sets, and for a sharper reason than liveness has: every
    // field here is a thing a client is asking about *because* it may have changed, and a cached
    // `minimum_supported_client` is a client that keeps believing it is supported after it stopped
    // being — which is the one failure §8.4's whole deprecation ladder exists to prevent.
    reply.header("Cache-Control", "no-store");
    return {
      api_version: deps.apiVersion,
      // Normalised to three components, not echoed as configured: `1.0` and `1.0.0` are the same
      // bound, and a client comparing strings should never have to know that.
      minimum_supported_client: deps.policy.minimumText,
      recommended_client: deps.policy.recommendedText,
      upgrade_url: deps.policy.upgradeUrl,
      // §2.1's timestamp form — RFC 3339, UTC, `Z`, whole seconds — through the same helper §5.3's
      // claim instants use, so two documents from this gateway cannot disagree about what an
      // instant looks like. §3.5 makes the `Date` *header* the authoritative clock; this field is
      // the same clock in the form a client that reads JSON already parses.
      server_time: isoSeconds(now()),
      entitlement_keys: entitlementKeys,
    };
  });
}
