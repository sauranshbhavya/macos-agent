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
   * Why this resolution might belong with an existing account that it deliberately did not join.
   *
   * **Two cases, and they are the same shape on purpose.** The server can see a reason to suspect a
   * link and cannot prove one, so it creates the account, says so, and leaves the joining to
   * something explicit. Surfacing either is SONNY-128's and SONNY-129's.
   *
   * - `relay_address_may_belong_to_existing_account` — an Apple relay address matched nothing,
   *   because a relay address matches nothing by design. The ticket forbids *silently* creating a
   *   second account for that person; this is what makes it not silent.
   * - `verified_email_matches_existing_account` — a verified, non-relay address **did** match an
   *   existing identity, and this no longer links on that alone (founder decision, 2026-08-22).
   */
  readonly linkHint:
    | "relay_address_may_belong_to_existing_account"
    | "verified_email_matches_existing_account"
    | undefined;
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
    //
    // **It FLAGS. It does not link.** (Founder decision, 2026-08-22, on PR #87's third review round,
    // F2.) Until that decision this attached the new identity to the matched account, silently, on
    // the strength of a `email_verified` flag — and the case that killed it is a mailbox changing
    // hands. Reproduced: Human A signs in with Google and account X is created; the address is later
    // reassigned, which is ordinary at a company and ordinary at a free provider; Human B, a
    // different person who now legitimately owns it, signs in by email code and lands **inside
    // account X**, with `created: false` and no flag of any kind. Somebody else's tasks, somebody
    // else's history, somebody else's subscription.
    //
    // The mistake underneath is worth naming because it is easy to make again: **a provider's
    // "verified" flag records who controlled an address when some other identity was written, not
    // who controls it now.** There is no staleness bound on it and there cannot be one that means
    // anything — `email_verified` carries no timestamp of its own, and the identity's `linked_at`
    // says when we wrote the row, not when the provider last checked.
    //
    // Two alternatives were on the record and both were rejected. Bounding the match by recency
    // needs a number with no data behind it, and a wrong guess there fails *silently* in both
    // directions. Accepting and documenting it is what several providers do, and it costs little to
    // refuse here because **the flagging pattern already exists in this file for relay addresses** —
    // so this reuses a shape the system already speaks rather than inventing one. The principle:
    // keep one person on one account in the ordinary case, refuse to guess in the ambiguous one.
    //
    // **`NOT i.account_closed` is here so rules 1 and 2 answer the same question** (PR #87 second
    // round, F1c). Rule 1 excludes both a closed account and a closed identity; this one used to
    // exclude only the account, and the two are not the same set — an identity can carry
    // `account_closed` while sitting on a live account, which is exactly the state F1's missing
    // trigger produced. It still matters: the match below decides whether a *hint* is issued, and a
    // hint pointing at an account nobody can sign into would be worse than no hint.
    let emailMatchesExisting = false;
    if (email && assertion.emailVerified && !relay) {
      const match = await client.query<{ account_id: string }>(
        `SELECT i.account_id
           FROM sonny.identity i
           JOIN sonny.account a ON a.id = i.account_id
          WHERE lower(i.email_hint) = $1
            AND i.email_verified
            AND NOT i.email_is_relay
            AND NOT i.account_closed
            AND a.deleted_at IS NULL
          LIMIT 1`,
        [email],
      );
      emailMatchesExisting = match.rows.length > 0;
    }

    // **`verified_email_match` is kept as a `link_method` value and is no longer produced.** Rows
    // written before this decision carry it and are the audit trail for exactly the merges that are
    // no longer performed; removing the value would erase the record of which accounts were joined
    // that way, which is the first thing anyone investigating a mis-merge would ask for.
    let accountId: string | undefined;
    const linkMethod: LinkMethod = "primary";

    // **R3's account lock lived here and is gone with the branch that needed it.**
    //
    // `resolve()` used to take `SELECT … FOR SHARE` on an account rule 2 had matched, so a resolver
    // racing a close blocked and re-read rather than inserting into the gap between the closer's
    // update and its trigger. That guard was correct and it is now unreachable: **rule 2 no longer
    // produces an account id at all** (founder decision, 2026-08-22), so this function only ever
    // inserts onto an account it created in this same transaction, and nothing else can hold a
    // reference to a row that does not exist yet.
    //
    // Deleted rather than left in place, because a guard that cannot run is not defence in depth —
    // it is a claim about a race nobody is having, and the next reader would reason from it. **The
    // same lock, for the same reason, is still taken by `linkExplicitly`**, which is now the only
    // path in this codebase that attaches an identity to an account it did not create. If rule 2
    // ever links again, this comes back with it.
    //
    // What still protects the rule-1 path is not a lock but the row count: the refresh below repeats
    // `NOT account_closed`, so a close committing underneath it matches nothing and the resolution
    // restarts. That is exercised by "survives a REAL two-connection race between resolve() and a
    // close", which reaches rule 1 rather than rule 2 and always did.

    // Rule 3 — a new account. Now the only outcome other than rule 1, since rule 2 flags rather
    // than links, which is why `created` is no longer conditional on anything.
    const account = await client.query<{ id: string }>(
      "INSERT INTO sonny.account DEFAULT VALUES RETURNING id",
    );
    accountId = account.rows[0]!.id;
    const created = true;

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
      // **Flagged, not guessed** — both cases, and the relay one is the older of the two.
      //
      // Relay first, because it is the more specific fact: an address that matches nothing because
      // it is a relay is a different thing to say than an address that matched something. A relay
      // assertion cannot reach the second branch anyway — rule 2 skips relay addresses — so the
      // ordering is for the reader rather than for the logic.
      linkHint: relay
        ? "relay_address_may_belong_to_existing_account"
        : emailMatchesExisting
          ? "verified_email_matches_existing_account"
          : undefined,
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
 * **Read this before wiring a route to it. Two of its three checks are real; one is a consistency
 * check that this function calls "proof" and cannot perform** (PR #87 third round, F3 — wording).
 *
 * What it actually verifies, stated exactly:
 *
 * 1. `authenticatedAccountId === targetAccountId` — an equality between an argument and an argument.
 *    It is meaningful **only because the caller is expected to derive `authenticatedAccountId` from
 *    a verified session**, and this function cannot check that it did.
 * 2. `provenIdentityId === identityId` — **an equality between two arguments and nothing more.** It
 *    consults no session store, no sign-in record and no independent evidence. A caller that passes
 *    a stranger's identity id as *both* arguments satisfies it completely, and the stranger's
 *    identity moves onto the caller's account. The earlier wording here and in
 *    `docs/sonny-identity-linking-rule.md` called this "the identity the caller just signed in
 *    with", which describes a property of the caller's *intent* rather than anything checked here —
 *    and that wording is what would lead the next implementer to accept the value as a request field.
 * 3. The source identity is live and its account is not closed — a real check, against the database.
 *
 * **The constraint this places on every future call site**, recorded on SONNY-128, SONNY-129 and
 * SONNY-203: `provenIdentityId` must be **derived server-side** from a sign-in this process just
 * completed — a session record, a one-time token minted at verify time — and must **never** be
 * accepted as a field on the request. Wired naively it is an identity-hijack primitive.
 *
 * Not reachable over HTTP today: no route calls this, only `linking.db.test.ts` does. **The
 * structural fix belongs at that future call site, not here** — this function cannot invent a
 * session store it has no access to, and adding a fake one would move the same trust boundary one
 * layer down while looking like it had closed it.
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
  // **The caller must NAME the account it is authenticated on, and this compares that name to the
  // target** (PR #87 F7). The first version took no session argument at all, so it could not have
  // made even this comparison while its docstring said rule 4 "requires an authenticated session".
  // Requiring the argument makes omitting it a type error rather than a judgment call.
  //
  // **What this cannot do is verify that the caller really holds that session** (PR #87 third
  // round, F3). It is an equality between two arguments; the guarantee lives entirely in the call
  // site deriving `authenticatedAccountId` from a verified session rather than from the request.
  if (authenticatedAccountId !== targetAccountId) {
    throw new LinkError(
      "rule 4 requires an authenticated session on the target account; " +
        "the caller's account is not the link target",
    );
  }
  // **A consistency check between two arguments — NOT proof of anything** (PR #87 third round,
  // F3, correcting R2's wording). R2 added it to close the half F7 left open: authenticating the
  // target says the caller owns where the identity is going and nothing about the identity being
  // moved. It does make a caller state which identity it believes it proved, which is worth having.
  //
  // **It does not verify that they proved it.** Passing a stranger's identity id as BOTH arguments
  // satisfies this line completely — reproduced against the built output, the victim's identity row
  // moved to the attacker's account. The check is unfalsifiable from inside this function, which has
  // no session store to consult. `provenIdentityId` must therefore be derived server-side from a
  // sign-in the process just completed and NEVER read off the request: the constraint is recorded
  // on SONNY-128, SONNY-129 and SONNY-203, and the docstring above states it in full.
  if (provenIdentityId !== identityId) {
    throw new LinkError(
      "rule 4 requires the caller to name the same identity twice; " +
        "the identity being moved is not the one the caller named as proven",
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
    // **The SOURCE must be live too** (PR #87 second round, F1b). Moving an identity off a closed
    // account onto a live one resurrects, through a path that looks like a link, exactly what
    // closing the account took away — and it was the statement that produced the corrupt row F1 is
    // about: no trigger recomputed `account_closed`, so the moved identity landed on a live account
    // still flagged closed, invisible to rule 1, and the owner's next sign-in made them a second
    // account. 0005 makes the flag follow the account; this makes the move refuse in the first
    // place, because a closed identity has nothing legitimate to say — rule 1 will not let anyone
    // sign in with it, so `provenIdentityId` can never honestly name one.
    //
    // **Checked inside the UPDATE rather than by a SELECT first**, so there is no window between
    // the check and the move. A separate read would have to lock the source account to be safe, and
    // taking an account lock *after* the identity is the deadlock direction 0004's header forbids.
    const moved = await client.query(
      `UPDATE sonny.identity i
          SET account_id = $2, link_method = 'explicit', linked_at = now()
        WHERE i.id = $1
          AND NOT i.account_closed
          AND EXISTS (SELECT 1 FROM sonny.account a
                       WHERE a.id = i.account_id AND a.deleted_at IS NULL)`,
      [identityId, targetAccountId],
    );
    if (moved.rowCount === 0) {
      // Nothing moved. Distinguishing the two reasons costs one read on a path that is already
      // failing, and "identity does not exist" reported for an identity that plainly does exist is
      // the kind of message that sends the next reader looking in the wrong place.
      const present = await client.query(
        "SELECT 1 FROM sonny.identity WHERE id = $1",
        [identityId],
      );
      throw new LinkError(
        present.rowCount === 0
          ? "identity does not exist"
          : "the identity being moved belongs to a closed account",
      );
    }
    await client.query("COMMIT");
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}
