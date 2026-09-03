/**
 * Contract §8's version arithmetic: what a `Sonny-Client-Version` header means, and which of §8's
 * bands the caller who sent it is in (SONNY-204).
 *
 * §8 is the part of the contract this document calls "expensive to add later", and the reason is
 * this file rather than the endpoint: once a client ships, the only thing the server can say to it
 * is something that client already knows how to read. §8.3's whole argument is that a `410` is that
 * something — "a status the client can recognise without understanding anything else about the
 * response, which is the property that matters, because by definition this client predates whatever
 * changed."
 *
 * **What a version is here.** §2.2 gives the header as "marketing version plus build, e.g.
 * `1.0.0+412`", and the Mac's own `SonnyClientIdentity.version` builds it as
 * `CFBundleShortVersionString + "+" + CFBundleVersion` — which is **`1.0+1`** for the packaged app
 * today (`Packaging/Info.plist`), two components and not three. So a parser that demanded three
 * would refuse the only build a user actually runs. One, two or three numeric components are
 * accepted and the missing ones read as zero.
 *
 * **Build metadata is dropped, per semver, because it is not ordered.** `1.0+7` and `1.0+412` are
 * the same marketing version; the build number is for a crash report, not for a comparison.
 *
 * **A prerelease suffix is dropped too, and that is a decision rather than an oversight.** Semver
 * orders `1.0.0-beta` *below* `1.0.0`; this gateway reads them as equal. There is no prerelease
 * channel in this product — nothing ships a `-beta` build and no ladder exists to order them
 * against — so the only thing the semver reading would do today is refuse a hand-built
 * `1.0.0-something` that is in every other respect the current version. If a channel is ever added,
 * this is the line that decides what it means, and it is a breaking change to the *gate* rather
 * than to the wire.
 */

/** A marketing version, normalised to three components. Build and prerelease metadata are gone. */
export interface MarketingVersion {
  readonly major: number;
  readonly minor: number;
  readonly patch: number;
}

/**
 * The version below which nothing can be, and therefore the value that disarms the gate.
 *
 * Every component of a parsed version is a non-negative integer, so no client can compare below
 * this one. `config.ts` defaults both bounds to it, which is what makes an untold deployment's gate
 * inert rather than a lockout — see `requireClientVersionPolicy` for why that direction.
 */
export const ZERO_VERSION: MarketingVersion = { major: 0, minor: 0, patch: 0 };

/**
 * One to three numeric components, each at most nine digits.
 *
 * Anchored at both ends and with no unbounded quantifier, so a caller-supplied header cannot make
 * this expensive: there is nothing here to backtrack over. The nine-digit bound is what keeps a
 * component inside `Number.MAX_SAFE_INTEGER` after `Number()`, so two absurd versions still compare
 * as the integers they are written as rather than as two equal floats.
 */
const VERSION_PATTERN = /^(\d{1,9})(?:\.(\d{1,9}))?(?:\.(\d{1,9}))?$/;

/**
 * The longest header value this parser looks at, in characters.
 *
 * The pattern above already refuses anything longer in linear time; this is the cheaper refusal in
 * front of it, and it matches the 100 `metering/hook.ts` bounds the same header to when it stores
 * one. §2.2's example is nine characters.
 */
const MAXIMUM_VERSION_LENGTH = 100;

/**
 * `"1.0.0+412"` → `{1, 0, 0}`; anything this parser cannot read → `undefined`.
 *
 * **`undefined` is "I do not know what version this is", and it is never "too old".** The bands
 * below turn it into `unknown`, which is served. See `bandFor` for why that direction.
 */
export function parseMarketingVersion(raw: string): MarketingVersion | undefined {
  const trimmed = raw.trim();
  if (trimmed.length === 0 || trimmed.length > MAXIMUM_VERSION_LENGTH) return undefined;
  // Build metadata first, then prerelease: semver writes them in that order (`1.0.0-beta+exp`), so
  // cutting at `+` before `-` is what leaves `1.0.0-beta` for the second cut to reach.
  const withoutBuild = trimmed.split("+", 1)[0] ?? "";
  const core = withoutBuild.split("-", 1)[0] ?? "";
  const match = VERSION_PATTERN.exec(core);
  if (!match) return undefined;
  return {
    major: Number(match[1]),
    minor: match[2] === undefined ? 0 : Number(match[2]),
    patch: match[3] === undefined ? 0 : Number(match[3]),
  };
}

/** Negative, zero or positive, the way every comparator is. */
export function compareVersions(left: MarketingVersion, right: MarketingVersion): number {
  if (left.major !== right.major) return left.major - right.major;
  if (left.minor !== right.minor) return left.minor - right.minor;
  return left.patch - right.patch;
}

/** The canonical three-component form. What `/v1/meta` publishes and what a message quotes. */
export function formatVersion(version: MarketingVersion): string {
  return `${String(version.major)}.${String(version.minor)}.${String(version.patch)}`;
}

/** The two bounds §8.3 and §8.4 name, parsed, plus the text `/v1/meta` publishes them as. */
export interface VersionBounds {
  readonly minimum: MarketingVersion;
  readonly recommended: MarketingVersion;
  readonly minimumText: string;
  readonly recommendedText: string;
}

/**
 * The deployment's version policy.
 *
 * **`armed` is a discriminant and not a convenience.** §8.3 requires an `upgrade_url` in the `410`'s
 * body and §8.4 requires one in `Sonny-Deprecation-Info`, so a deployment that can refuse or deprecate
 * a client and has nowhere to send it is a deployment that tells a user "you must update" and gives
 * them no way to. Splitting the type is what makes the gate's use of the URL a check the compiler
 * runs rather than a non-null assertion — `requireClientVersionPolicy` refuses to build an armed
 * policy without one, and the gate's first line returns on a disarmed one.
 *
 * A disarmed policy may still carry a URL: an operator who has set `UPGRADE_URL` and left both
 * bounds at zero has configured a real value, and `/v1/meta` publishes it either way.
 */
export type ClientVersionPolicy =
  | (VersionBounds & { readonly armed: false; readonly upgradeUrl: string | null })
  | (VersionBounds & { readonly armed: true; readonly upgradeUrl: string });

/**
 * Which of §8's bands a caller is in.
 *
 * - `unsupported` — below `minimum_supported_client`. §8.3's `410`.
 * - `deprecated` — at or above the minimum and below `recommended_client`. §8.4's headers.
 * - `current` — at or above the recommended version. Nothing is added to the response.
 * - `unknown` — no header, an unreadable one, or the same header twice. **Served, like `current`.**
 */
export type VersionBand = "unknown" | "unsupported" | "deprecated" | "current";

/**
 * The band for one request's header value.
 *
 * **An absent or unreadable header is `unknown` and is served, which is the whole of the fail-open
 * decision this gate makes.** §2.2 puts `Sonny-Client-Version` on every request, and every caller
 * that is not the Mac app sends none: a load balancer's liveness probe on `/v1/health`, the payment
 * provider's signed delivery to `/v1/billing/webhook` (§4.1 — "the one row in this table no client
 * ever calls"), `deploy.sh local`'s own health check, and a founder with `curl`. Refusing those
 * would turn a version policy into an outage, and it would do it at the exact moment somebody first
 * set `MINIMUM_SUPPORTED_CLIENT` to a real number.
 *
 * **Nothing is lost by fail-open, because this gate is not a security boundary.** It is a courtesy
 * to an old client: §8.3's argument is that a definite `410` beats "a parse failure, an empty plan,
 * or a spinner that never resolves". A caller that omits the header gets the modern API — which it
 * could have called anyway, since every route's real protection is `auth/gate.ts` and it is
 * unaffected by any of this.
 *
 * **A repeated header is `unknown` rather than resolved.** Fastify hands a repeated header back as
 * an array; picking the first or the last would be choosing which of two claims to believe about a
 * caller who has made two.
 */
export function bandFor(
  header: string | readonly string[] | undefined,
  policy: ClientVersionPolicy,
): VersionBand {
  if (typeof header !== "string") return "unknown";
  const version = parseMarketingVersion(header);
  if (version === undefined) return "unknown";
  if (compareVersions(version, policy.minimum) < 0) return "unsupported";
  if (compareVersions(version, policy.recommended) < 0) return "deprecated";
  return "current";
}
