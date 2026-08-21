import type pg from "pg";

/**
 * The identity-linking rule. `docs/sonny-identity-linking-rule.md` is the reasoning; this is the
 * implementation, and the two are meant to be read together.
 *
 * The one-line version: **the identity key is `(provider, subject)`, never the email address.**
 */

export const providers = ["email", "google", "apple"] as const;
export type Provider = (typeof providers)[number];

export type LinkMethod = "primary" | "verified_email_match" | "explicit";

export interface Assertion {
  readonly provider: Provider;
  /** The provider's stable identifier. For `email`, the normalised address. */
  readonly subject: string;
  readonly email: string | undefined;
  /** Whether the *provider* verified the address. An unverified assertion never links. */
  readonly emailVerified: boolean;
  readonly supabaseUserId?: string | undefined;
}

export interface Resolution {
  readonly accountId: string;
  readonly identityId: string;
  readonly linkMethod: LinkMethod;
  readonly created: boolean;
  /**
   * Set when an account was created for an assertion whose address could not be matched *because it
   * is a relay*. The ticket forbids silently creating a second account for that person; this is what
   * makes it not silent. Surfacing it is SONNY-128's and SONNY-129's.
   */
  readonly linkHint: "relay_address_may_belong_to_existing_account" | undefined;
}

/**
 * Apple's Hide My Email relay domain.
 *
 * Matched on the domain rather than a pattern over the local part, because the local part is opaque
 * and Apple does not document its shape. A list rather than a single constant because Apple has
 * historically served more than one relay domain, and the failure of missing one is the failure this
 * whole rule exists to prevent.
 */
const RELAY_DOMAINS = ["privaterelay.appleid.com", "icloud.com.privaterelay.appleid.com"] as const;

export function isRelayAddress(email: string | undefined): boolean {
  if (!email) return false;
  const at = email.lastIndexOf("@");
  if (at === -1) return false;
  const domain = email.slice(at + 1).toLowerCase();
  return RELAY_DOMAINS.some((relay) => domain === relay);
}

/**
 * Lowercase and trim. **Plus-tags are deliberately kept**, and domain-specific rules (Gmail's dots)
 * deliberately not applied — see the rule document §5. Where normalisation is a judgment call it
 * errs toward *not* merging, because merging accounts is the failure being prevented.
 */
export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

/**
 * The key a **rate limit** is counted against, which is deliberately NOT `normalizeEmail`.
 *
 * **The two normalisations exist for opposite reasons and their safe directions are opposite**
 * (PR #87 F4). The identity key must not merge — merging two addresses joins two accounts, so where
 * it is a judgment call it errs toward keeping them apart. A rate-limit key must merge as
 * aggressively as the *mailbox* does, because the thing being protected is the mailbox: `a+1@x`,
 * `a+2@x` and `A@X` all deliver to one inbox, so counting them separately means a 3-per-address cap
 * that never binds — three requests each, forever, from one attacker with a text editor.
 *
 * So this strips the plus-tag and lowercases, and `normalizeEmail` does neither. The first version
 * used one function for both and inherited the wrong direction for this side.
 *
 * Gmail's dot-folding is deliberately not applied: it is one provider's policy, and applying it
 * everywhere would merge distinct mailboxes at other providers into one budget — which is a denial
 * of service against those users rather than a defence.
 */
export function rateLimitEmailKey(email: string): string {
  const lowered = email.trim().toLowerCase();
  const at = lowered.lastIndexOf("@");
  if (at <= 0) return lowered;
  const local = lowered.slice(0, at);
  const domain = lowered.slice(at + 1);
  const plus = local.indexOf("+");
  return `${plus === -1 ? local : local.slice(0, plus)}@${domain}`;
}

/** Cheap structural check. Deliverability is the mail provider's answer, not a regex's. */
export function looksLikeEmail(value: string): boolean {
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > 254) return false;
  const at = trimmed.indexOf("@");
  if (at <= 0 || at !== trimmed.lastIndexOf("@")) return false;
  const domain = trimmed.slice(at + 1);
  return domain.length >= 3 && domain.includes(".") && !/\s/.test(trimmed);
}

/**
 * Resolve an assertion to an account, creating one if the rule says to.
 *
 * Runs in one transaction: two concurrent first-ever sign-ins for the same subject must not produce
 * two accounts, and the unique constraint on `(provider, subject)` is what makes the race safe —
 * the loser sees the winner's row rather than inserting a duplicate.
 */
export class IdentityConflict extends Error {}

export async function resolve(
  client: pg.Client,
  assertion: Assertion,
  attempt = 0,
): Promise<Resolution> {
  const email = assertion.email ? normalizeEmail(assertion.email) : undefined;
  const relay = isRelayAddress(email);

  await client.query("BEGIN");
  try {
    // Rule 1 — the identity key. Already known: that account, no matter what the email says now.
    const existing = await client.query<{ id: string; account_id: string; link_method: LinkMethod }>(
      `SELECT i.id, i.account_id, i.link_method
         FROM sonny.identity i
         JOIN sonny.account a ON a.id = i.account_id
        WHERE i.provider = $1 AND i.subject = $2
          AND NOT i.account_closed AND a.deleted_at IS NULL`,
      [assertion.provider, assertion.subject],
    );
    if (existing.rows[0]) {
      // Refresh the hint and the Supabase user, both of which legitimately change over time.
      // **The row count is checked** (PR #87 R6). The predicate repeats `NOT account_closed`, so a
      // close committed between the SELECT above and this UPDATE matches nothing — and without the
      // check this function would have gone on to return a closed account as a successful sign-in.
      const refreshed = await client.query(
        `UPDATE sonny.identity
            SET email_hint = COALESCE($2, email_hint),
                email_verified = $3,
                email_is_relay = $4,
                supabase_user_id = COALESCE($5, supabase_user_id)
          WHERE id = $1 AND NOT account_closed`,
        [existing.rows[0].id, email ?? null, assertion.emailVerified, relay, assertion.supabaseUserId ?? null],
      );
      if (refreshed.rowCount === 0) {
        await client.query("ROLLBACK");
        if (attempt >= 1) throw new IdentityConflict("identity closed while resolving");
        return resolve(client, assertion, attempt + 1);
      }
      await client.query("COMMIT");
      return {
        accountId: existing.rows[0].account_id,
        identityId: existing.rows[0].id,
        linkMethod: existing.rows[0].link_method,
        created: false,
        linkHint: undefined,
      };
    }

    // Rule 2 — a verified, non-relay address matching an existing verified, non-relay identity.
    // Every clause is load-bearing: an unverified assertion is an attacker's claim, and a relay
    // address matches nothing real, so both fall through to rule 3 rather than linking.
    let accountId: string | undefined;
    let linkMethod: LinkMethod = "primary";
    if (email && assertion.emailVerified && !relay) {
      const match = await client.query<{ account_id: string }>(
        `SELECT i.account_id
           FROM sonny.identity i
           JOIN sonny.account a ON a.id = i.account_id
          WHERE lower(i.email_hint) = $1
            AND i.email_verified
            AND NOT i.email_is_relay
            AND a.deleted_at IS NULL
          LIMIT 1`,
        [email],
      );
      if (match.rows[0]) {
        accountId = match.rows[0].account_id;
        linkMethod = "verified_email_match";
      }
    }

    // **R3: lock the account before inserting an identity onto it.**
    //
    // `FOR SHARE` conflicts with the `FOR NO KEY UPDATE` that a concurrent `UPDATE ... SET
    // deleted_at` takes, so a resolver racing a close **blocks here and then re-reads** rather than
    // inserting into the gap between the closer's update and its trigger. Without it the insert
    // landed after the trigger had already marked everything, leaving an identity live on a closed
    // account — invisible to sign-in, occupying the address, permanent.
    //
    // Rule 3's brand-new account needs no lock: nothing else can hold a reference to a row this
    // transaction has not inserted yet.
    if (accountId) {
      const still = await client.query<{ deleted_at: Date | null }>(
        "SELECT deleted_at FROM sonny.account WHERE id = $1 FOR SHARE",
        [accountId],
      );
      if (!still.rows[0] || still.rows[0].deleted_at !== null) {
        // It closed while we were deciding. Start again: rule 2 will no longer match it, and the
        // assertion will get its own account.
        await client.query("ROLLBACK");
        if (attempt >= 1) throw new IdentityConflict("target account closed while resolving");
        return resolve(client, assertion, attempt + 1);
      }
    }

    // Rule 3 — a new account.
    let created = false;
    if (!accountId) {
      const account = await client.query<{ id: string }>(
        "INSERT INTO sonny.account DEFAULT VALUES RETURNING id",
      );
      accountId = account.rows[0]!.id;
      created = true;
    }

    const identity = await client.query<{ id: string }>(
      `INSERT INTO sonny.identity
         (account_id, provider, subject, email_hint, email_verified, email_is_relay,
          supabase_user_id, link_method)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
       ON CONFLICT (provider, subject) WHERE NOT account_closed DO NOTHING
       RETURNING id`,
      [accountId, assertion.provider, assertion.subject, email ?? null,
       assertion.emailVerified, relay, assertion.supabaseUserId ?? null, linkMethod],
    );

    if (!identity.rows[0]) {
      // Lost the race with a concurrent first sign-in for this same subject. The winner's row is
      // the answer; ours would have been a duplicate account. Rolling back discards the account we
      // speculatively created, which is why the INSERT and the account creation share one
      // transaction.
      //
      // **Bounded, and the bound is the point.** The first version retried unboundedly, which is
      // fine for a genuine race — the winner is visible on the next pass — and a livelock for a
      // conflict that does not clear. One did: rule 1 excludes identities on a *deleted* account
      // while the unique constraint does not, so signing up again with an address whose account had
      // been closed spun forever. Closing an account now releases its identities, so the case no
      // longer arises; the bound stays because an unbounded retry on a condition you have not
      // enumerated is a hang waiting for a cause.
      await client.query("ROLLBACK");
      if (attempt >= 1) {
        throw new IdentityConflict(
          `identity (${assertion.provider}, subject) exists but did not resolve; ` +
            "it may belong to an account this rule excludes",
        );
      }
      return resolve(client, assertion, attempt + 1);
    }

    await client.query("COMMIT");
    return {
      accountId,
      identityId: identity.rows[0].id,
      linkMethod,
      created,
      // Flagged, not guessed: a relay address that produced a brand-new account is exactly the
      // "does not silently create a second one" case.
      linkHint: created && relay ? "relay_address_may_belong_to_existing_account" : undefined,
    };
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}

export class LinkError extends Error {}

/**
 * Rule 4 — the only path that joins two *existing* accounts.
 *
 * **Both ends must be proven.** `authenticatedAccountId` is the account the caller has a session on
 * and must equal the target; `provenIdentityId` is the identity the caller just signed in with and
 * must equal the one being moved. Authenticating only the target — which is what this did before
 * PR #87 R2 — says the caller owns the destination and nothing about what is being moved there. Without that equality this is a primitive for moving anyone's identity onto anyone's
 * account. The parameter is required rather than optional so a caller cannot omit it and get the
 * old, unchecked behaviour.
 *
 * Moves `identity` onto `targetAccountId`; the vacated account is left for the caller to close,
 * because deleting it here would destroy content the retention ticket owns.
 */
export async function linkExplicitly(
  client: pg.Client,
  identityId: string,
  targetAccountId: string,
  authenticatedAccountId: string,
  provenIdentityId: string,
): Promise<void> {
  // **The check the docstring promises, actually performed** (PR #87 F7). The first version took no
  // session at all and could not have made it, while both this comment and the rule document said
  // rule 4 "requires an authenticated session on one of them" — a claim SONNY-129 would have routed
  // this primitive while reading. Requiring the caller to name the authenticated account makes the
  // claim true, and makes calling it without one a type error rather than a judgment call.
  if (authenticatedAccountId !== targetAccountId) {
    throw new LinkError(
      "rule 4 requires an authenticated session on the target account; " +
        "the caller's account is not the link target",
    );
  }
  // **The source must be freshly proven too** (PR #87 R2). F7 closed the target half and left this
  // one open: authenticating the target says the caller owns where the identity is going, and
  // nothing about the identity being moved. Without this, a caller signed in on their own account
  // could name a stranger's identity and take it. `provenIdentityId` is the identity the caller
  // just completed a sign-in with, and it must be the one being moved.
  if (provenIdentityId !== identityId) {
    throw new LinkError(
      "rule 4 requires the source identity to have been freshly proven by this caller; " +
        "the identity being moved is not the one that was proven",
    );
  }
  await client.query("BEGIN");
  try {
    // `FOR SHARE`, for the same reason `resolve` takes it (PR #87 R3): between this check and the
    // UPDATE below, a concurrent close would otherwise let an identity be moved onto an account
    // that no longer exists — the identical TOCTOU, one function over.
    const target = await client.query(
      "SELECT 1 FROM sonny.account WHERE id = $1 AND deleted_at IS NULL FOR SHARE",
      [targetAccountId],
    );
    if (target.rowCount === 0) {
      // A deleted account must never gain identities: it would resurrect an account the user asked
      // to remove, and do it through a path that looks like a sign-in.
      throw new LinkError("target account does not exist or is deleted");
    }
    const moved = await client.query(
      `UPDATE sonny.identity
          SET account_id = $2, link_method = 'explicit', linked_at = now()
        WHERE id = $1`,
      [identityId, targetAccountId],
    );
    if (moved.rowCount === 0) throw new LinkError("identity does not exist");
    await client.query("COMMIT");
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}
