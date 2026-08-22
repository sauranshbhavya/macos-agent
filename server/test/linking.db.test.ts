import pg from "pg";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { IdentityConflict, LinkError, isRelayAddress, linkExplicitly, normalizeEmail, rateLimitEmailKey, resolve } from "../src/auth/identity.js";
import { up } from "../src/db/migrate.js";

/**
 * The identity-linking rule, pinned. `docs/sonny-identity-linking-rule.md` is the reasoning.
 *
 * Against a real Postgres, because the rule's correctness lives in a unique constraint and a
 * transaction, not in TypeScript. A mock would prove the code calls the database, which is not the
 * claim being made.
 */
const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

describeDb("the identity-linking rule", () => {
  let client: pg.Client;

  beforeAll(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await client.query("DROP SCHEMA IF EXISTS sonny CASCADE");
    await client.query("DROP SCHEMA IF EXISTS sonny_meta CASCADE");
    await up(client);
  });
  afterAll(async () => { await client.end(); });
  beforeEach(async () => {
    await client.query("TRUNCATE sonny.identity, sonny.account RESTART IDENTITY CASCADE");
  });

  const emailAssertion = (address: string, supabaseUserId?: string) => ({
    provider: "email" as const,
    subject: normalizeEmail(address),
    email: address,
    emailVerified: true,
    supabaseUserId,
  });

  describe("rule 1 — the identity key is (provider, subject)", () => {
    it("lands the same subject on one account, twice", async () => {
      const first = await resolve(client, emailAssertion("a@example.com"));
      const second = await resolve(client, emailAssertion("a@example.com"));
      expect(second.accountId).toBe(first.accountId);
      expect(second.created).toBe(false);
      const { rows } = await client.query("SELECT count(*)::int AS n FROM sonny.account");
      expect(rows[0].n).toBe(1);
    });

    it("matches on subject even when the asserted address has changed", async () => {
      // The point of a stable subject: Apple's `sub` survives the user hiding or changing their
      // address, and rule 1 must not be fooled by the address moving.
      const sub = "apple-sub-stable-1";
      const first = await resolve(client, {
        provider: "apple", subject: sub, email: "real@example.com", emailVerified: true,
      });
      const second = await resolve(client, {
        provider: "apple", subject: sub, email: "abc@privaterelay.appleid.com", emailVerified: true,
      });
      expect(second.accountId).toBe(first.accountId);
      expect(second.created).toBe(false);
    });

    it("treats the same subject under two providers as two identities", async () => {
      // A Google `sub` and an Apple `sub` could collide as strings; they are different people's
      // identifiers in different namespaces and must never be matched across providers.
      const a = await resolve(client, { provider: "google", subject: "shared-123", email: undefined, emailVerified: false });
      const b = await resolve(client, { provider: "apple", subject: "shared-123", email: undefined, emailVerified: false });
      expect(b.accountId).not.toBe(a.accountId);
    });
  });

  describe("rule 2 — a verified, non-relay email match FLAGS rather than links", () => {
    it("does NOT merge the same verified address reached by two methods — it flags", async () => {
      // **This test asserted the opposite until the founder's decision of 2026-08-22** (PR #87
      // third round, F2), and it was the ticket's own first named acceptance criterion: "same email
      // by two methods lands on one account". That criterion is superseded, deliberately and on the
      // record, by the case the third review round reproduced — see the recycled-mailbox test below.
      const byEmail = await resolve(client, emailAssertion("dual@example.com"));
      const byGoogle = await resolve(client, {
        provider: "google", subject: "google-sub-1", email: "dual@example.com", emailVerified: true,
      });
      expect(byGoogle.accountId).not.toBe(byEmail.accountId);
      expect(byGoogle.created).toBe(true);
      expect(byGoogle.linkMethod).toBe("primary");
      // Not silent: the hint is what makes this a refusal to guess rather than a failure to notice.
      expect(byGoogle.linkHint).toBe("verified_email_matches_existing_account");
      const { rows } = await client.query("SELECT count(*)::int AS n FROM sonny.account");
      expect(rows[0].n).toBe(2);
    });

    it("does not merge two DIFFERENT humans when a mailbox is recycled", async () => {
      // **The case that forced the decision, reproduced by the third review round.** Human A signs
      // in with Google and account X is created. The address is later reassigned — a departing
      // employee's mailbox reissued, a free provider recycling a handle — and Human B, who now
      // legitimately owns it, signs in by email code. Under the old rule they landed *inside*
      // account X, with `created: false` and no flag: somebody else's tasks, somebody else's
      // subscription.
      //
      // The mistake underneath is that `email_verified` records who controlled an address when some
      // OTHER identity was written, not who controls it now — and there is no timestamp on it that
      // could bound that.
      const humanA = await resolve(client, {
        provider: "google", subject: "google-sub-recycled", email: "shared@example.com", emailVerified: true,
      });
      // ... the mailbox changes hands ...
      const humanB = await resolve(client, emailAssertion("shared@example.com"));

      expect(humanB.accountId).not.toBe(humanA.accountId);
      expect(humanB.created).toBe(true);
      expect(humanB.linkHint).toBe("verified_email_matches_existing_account");
      // Human A's account is untouched — the identity did not move, and nothing was added to it.
      const { rows } = await client.query(
        "SELECT count(*)::int AS n FROM sonny.identity WHERE account_id = $1", [humanA.accountId],
      );
      expect(rows[0].n).toBe(1);
    });

    it("flags only when there is something to flag", async () => {
      // The hint has to be absent for an address nobody has seen, or it means nothing when present.
      const alone = await resolve(client, emailAssertion("nobody-else@example.com"));
      expect(alone.linkHint).toBeUndefined();
      expect(alone.created).toBe(true);
    });

    it("does not flag on an UNVERIFIED assertion either", async () => {
      // An unverified address is an attacker's claim. Flagging it would hand the attacker a signal
      // that the address is in use — the account-existence oracle this branch spends real effort
      // avoiding on `email/start`, reintroduced through the sign-in response.
      await resolve(client, emailAssertion("quiet@example.com"));
      const guess = await resolve(client, {
        provider: "google", subject: "g-quiet", email: "quiet@example.com", emailVerified: false,
      });
      expect(guess.linkHint).toBeUndefined();
    });

    it("REFUSES to link an unverified assertion, and makes its own account", async () => {
      // The takeover direction. An unverified address is an attacker's claim, not a fact, and
      // joining an account on it is the known pre-account-takeover pattern.
      const owner = await resolve(client, emailAssertion("victim@example.com"));
      const attacker = await resolve(client, {
        provider: "google", subject: "attacker-sub", email: "victim@example.com", emailVerified: false,
      });
      expect(attacker.accountId).not.toBe(owner.accountId);
      expect(attacker.linkMethod).toBe("primary");
      expect(attacker.created).toBe(true);
    });

    it("does not link to a deleted account", async () => {
      const gone = await resolve(client, emailAssertion("gone@example.com"));
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [gone.accountId]);
      const fresh = await resolve(client, {
        provider: "google", subject: "g-after-delete", email: "gone@example.com", emailVerified: true,
      });
      expect(fresh.accountId).not.toBe(gone.accountId);
      expect(fresh.created).toBe(true);
      // And no hint either: a hint pointing at an account nobody can sign into is worse than none,
      // because SONNY-128 would offer the user a link they cannot complete.
      expect(fresh.linkHint).toBeUndefined();
    });

    it("normalises case and whitespace when deciding whether to flag", async () => {
      // The matching itself still normalises — it decides whether a hint is issued rather than
      // whether accounts merge, and a hint that missed `Case@Example.com` vs `case@example.com`
      // would be silent in exactly the case it exists for.
      const a = await resolve(client, emailAssertion("Case@Example.com"));
      const b = await resolve(client, {
        provider: "google", subject: "g-case", email: "  case@example.COM  ", emailVerified: true,
      });
      expect(b.accountId).not.toBe(a.accountId);
      expect(b.linkHint).toBe("verified_email_matches_existing_account");
    });

    it("keeps plus-tags distinct, because merging is the failure being prevented", async () => {
      const plain = await resolve(client, emailAssertion("user@example.com"));
      const tagged = await resolve(client, emailAssertion("user+work@example.com"));
      expect(tagged.accountId).not.toBe(plain.accountId);
    });
  });

  describe("Hide My Email — the case the obvious rule gets wrong", () => {
    it("does not link a relay address, FLAGS it, and offers a link hint", async () => {
      // The ticket's second named criterion: "an Apple relay address for a user who already has an
      // email account does not SILENTLY create a second one". It does create one — the server
      // cannot know the two are the same human — but it is detected, flagged and surfaced.
      const existing = await resolve(client, emailAssertion("person@example.com"));
      const viaApple = await resolve(client, {
        provider: "apple", subject: "apple-sub-relay", email: "xyz789@privaterelay.appleid.com",
        emailVerified: true,
      });

      expect(viaApple.accountId).not.toBe(existing.accountId);
      expect(viaApple.created).toBe(true);
      expect(viaApple.linkHint).toBe("relay_address_may_belong_to_existing_account");

      const { rows } = await client.query(
        "SELECT email_is_relay FROM sonny.identity WHERE id = $1", [viaApple.identityId],
      );
      expect(rows[0].email_is_relay).toBe(true);
    });

    it("lands two Apple sign-ins with a relay address on ONE account", async () => {
      // Because the key is `sub`, not the address. This is what stops the relay case compounding
      // into a new account on every press of the button.
      const first = await resolve(client, {
        provider: "apple", subject: "apple-sub-9", email: "aaa@privaterelay.appleid.com", emailVerified: true,
      });
      const second = await resolve(client, {
        provider: "apple", subject: "apple-sub-9", email: "aaa@privaterelay.appleid.com", emailVerified: true,
      });
      expect(second.accountId).toBe(first.accountId);
      expect(second.linkHint).toBeUndefined();
    });

    it("never sets a link hint when no account was created", async () => {
      const first = await resolve(client, {
        provider: "apple", subject: "apple-sub-10", email: "bbb@privaterelay.appleid.com", emailVerified: true,
      });
      expect(first.linkHint).toBeDefined();
      const again = await resolve(client, {
        provider: "apple", subject: "apple-sub-10", email: "bbb@privaterelay.appleid.com", emailVerified: true,
      });
      expect(again.linkHint).toBeUndefined();
    });

    it("recognises the relay domains and nothing that merely resembles them", async () => {
      expect(isRelayAddress("a@privaterelay.appleid.com")).toBe(true);
      expect(isRelayAddress("a@PrivateRelay.AppleID.com")).toBe(true);
      // A lookalike domain an attacker controls must not be treated as a relay -- that would make
      // it exempt from rule 2's matching and is the wrong direction to be wrong in.
      expect(isRelayAddress("a@privaterelay.appleid.com.evil.test")).toBe(false);
      expect(isRelayAddress("a@notprivaterelay.appleid.com")).toBe(false);
      expect(isRelayAddress("privaterelay.appleid.com")).toBe(false);
      expect(isRelayAddress(undefined)).toBe(false);
    });
  });

  describe("rule 4 — explicit linking, the only path that joins two accounts", () => {
    it("moves an identity onto the target account and records why", async () => {
      const primary = await resolve(client, emailAssertion("owner@example.com"));
      const viaApple = await resolve(client, {
        provider: "apple", subject: "apple-sub-link", email: "ccc@privaterelay.appleid.com", emailVerified: true,
      });
      await linkExplicitly(client, viaApple.identityId, primary.accountId, primary.accountId, viaApple.identityId);

      const { rows } = await client.query(
        "SELECT account_id, link_method FROM sonny.identity WHERE id = $1", [viaApple.identityId],
      );
      expect(rows[0].account_id).toBe(primary.accountId);
      expect(rows[0].link_method).toBe("explicit");

      // And the previously-separate identity now resolves to the primary account.
      const again = await resolve(client, {
        provider: "apple", subject: "apple-sub-link", email: "ccc@privaterelay.appleid.com", emailVerified: true,
      });
      expect(again.accountId).toBe(primary.accountId);
    });

    it("refuses to link onto a deleted account", async () => {
      const dead = await resolve(client, emailAssertion("dead@example.com"));
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [dead.accountId]);
      const other = await resolve(client, emailAssertion("other@example.com"));
      await expect(linkExplicitly(client, other.identityId, dead.accountId, dead.accountId, other.identityId)).rejects.toThrow(LinkError);
    });

    it("REFUSES when the caller's session is not on the target account", async () => {
      // The check the docstring and the rule document both claimed and the function did not make
      // (PR #87 F7). Without it this is a primitive for moving anyone's identity onto anyone's
      // account, and SONNY-129 would have routed it while reading the comment that promised the
      // check.
      const mine = await resolve(client, emailAssertion("mine@example.com"));
      const theirs = await resolve(client, emailAssertion("theirs@example.com"));
      const loose = await resolve(client, {
        provider: "apple", subject: "apple-hijack", email: "eee@privaterelay.appleid.com", emailVerified: true,
      });
      await expect(
        linkExplicitly(client, loose.identityId, theirs.accountId, mine.accountId, loose.identityId),
      ).rejects.toThrow(LinkError);
      const { rows } = await client.query("SELECT account_id FROM sonny.identity WHERE id = $1", [loose.identityId]);
      expect(rows[0].account_id).not.toBe(theirs.accountId);
    });

    it("REFUSES to move an identity the caller did not just prove", async () => {
      // PR #87 R2. F7 closed the target half and left this one open: authenticating the target says
      // the caller owns the destination and nothing about what is being moved there, so a caller
      // signed in on their own account could name a stranger's identity and take it.
      const mine = await resolve(client, emailAssertion("attacker@example.com"));
      const strangerIdentity = await resolve(client, emailAssertion("stranger@example.com"));
      const myOwn = await resolve(client, {
        provider: "apple", subject: "apple-mine", email: "fff@privaterelay.appleid.com", emailVerified: true,
      });
      await expect(
        // caller is signed in on their own account (target ok) and names the stranger's identity
        linkExplicitly(client, strangerIdentity.identityId, mine.accountId, mine.accountId, myOwn.identityId),
      ).rejects.toThrow(LinkError);
      const { rows } = await client.query(
        "SELECT account_id FROM sonny.identity WHERE id = $1", [strangerIdentity.identityId],
      );
      expect(rows[0].account_id).not.toBe(mine.accountId);
    });

    it("PINS that provenIdentityId is a consistency check and NOT proof of ownership", async () => {
      // **A characterization test: it asserts the unsafe behaviour on purpose** (PR #87 third
      // round, F3). The existing tests cover only the MISMATCHED case — caller names identity A and
      // moves identity B — which passes whether the check is proof or a tautology. The exploitable
      // case is the matched-but-unowned one, and nothing exercised it.
      //
      // `provenIdentityId !== identityId` compares two caller-supplied arguments to each other. Pass
      // a stranger's identity id as BOTH and the check is satisfied completely. This test exists so
      // that (a) the property is written down where the next implementer will meet it, and (b) if
      // anyone ever makes this a real check, THIS test fails and forces them to read why it was here.
      //
      // **Not reachable over HTTP**: no route calls `linkExplicitly`. The structural fix is a
      // constraint on the future call site, recorded on SONNY-128, SONNY-129 and SONNY-203 —
      // `provenIdentityId` must be derived server-side from a just-completed sign-in and never read
      // off the request. It is deliberately NOT fixed inside this function, which has no session
      // store to consult and would only move the trust boundary one layer down.
      const attacker = await resolve(client, emailAssertion("attacker-tautology@example.com"));
      const stranger = await resolve(client, emailAssertion("stranger-tautology@example.com"));

      await linkExplicitly(
        client,
        stranger.identityId,      // the identity being moved — the attacker does not own it
        attacker.accountId,       // the target — the attacker does own this
        attacker.accountId,       // authenticatedAccountId, equal to the target, so check 1 passes
        stranger.identityId,      // "proven" — the same value as the first argument, so check 2 passes
      );

      const { rows } = await client.query(
        "SELECT account_id FROM sonny.identity WHERE id = $1", [stranger.identityId],
      );
      // It moved. That is the point being pinned, not a behaviour being endorsed.
      expect(rows[0].account_id).toBe(attacker.accountId);
    });

    it("refuses to link an identity that does not exist", async () => {
      const target = await resolve(client, emailAssertion("target@example.com"));
      await expect(
        linkExplicitly(client, "00000000-0000-0000-0000-000000000000", target.accountId, target.accountId, "00000000-0000-0000-0000-000000000000"),
      ).rejects.toThrow(LinkError);
    });

    it("REFUSES to move an identity that a CLOSED account left behind", async () => {
      // PR #87 second round, F1b. This was the statement that produced the corrupt row: moving a
      // closed account's identity onto a live one resurrected, through a path that looks like a
      // link, exactly what closing the account took away. It is refused outright now — rule 1 will
      // not sign anyone in with a closed identity, so `provenIdentityId` can never honestly name
      // one, and a link that could only ever be called with a lie is not a link.
      const live = await resolve(client, emailAssertion("keeper@example.com"));
      const doomed = await resolve(client, {
        provider: "apple", subject: "apple-closed-src", email: "hhh@privaterelay.appleid.com", emailVerified: true,
      });
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [doomed.accountId]);

      await expect(
        linkExplicitly(client, doomed.identityId, live.accountId, live.accountId, doomed.identityId),
      ).rejects.toThrow(/closed account/);

      const { rows } = await client.query(
        "SELECT account_id, account_closed FROM sonny.identity WHERE id = $1", [doomed.identityId],
      );
      expect(rows[0].account_id).toBe(doomed.accountId);   // did not move
      expect(rows[0].account_closed).toBe(true);
    });

    it("refuses even when the flag disagrees with the account, because it checks BOTH", async () => {
      // The guard is `NOT account_closed` **and** an EXISTS on a live account, and this is what the
      // second half is for. `account_closed` is denormalised, so a database that has ever been in a
      // state 0005 repairs — or a future statement nobody has written yet — can carry a false flag
      // over a genuinely deleted account. The flag is cleared here by hand to prove the account
      // itself is still consulted rather than merely trusted.
      const live = await resolve(client, emailAssertion("keeper2@example.com"));
      const doomed = await resolve(client, emailAssertion("lied@example.com"));
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [doomed.accountId]);
      await client.query("UPDATE sonny.identity SET account_closed = false WHERE id = $1", [doomed.identityId]);

      await expect(
        linkExplicitly(client, doomed.identityId, live.accountId, live.accountId, doomed.identityId),
      ).rejects.toThrow(LinkError);
      const { rows } = await client.query("SELECT account_id FROM sonny.identity WHERE id = $1", [doomed.identityId]);
      expect(rows[0].account_id).toBe(doomed.accountId);
    });
  });

  describe("the flag follows the account, on every statement that can move either", () => {
    it("RECOMPUTES account_closed when an identity moves to another account", async () => {
      // **PR #87 second round, F1a — the defect this migration exists for.** 0004 derived the flag
      // on INSERT and set it on close, and left the third way it can change: the identity moving.
      // Reproduced against a real database before the fix — the row below landed on a LIVE account
      // still carrying `account_closed = true`.
      //
      // Moved with raw SQL rather than through `linkExplicitly`, which now refuses this outright:
      // the two fixes are independent and this one is the trigger's, so it is exercised on its own.
      const live = await resolve(client, emailAssertion("home@example.com"));
      const orphan = await resolve(client, {
        provider: "apple", subject: "apple-moves", email: "iii@privaterelay.appleid.com", emailVerified: true,
      });
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [orphan.accountId]);
      expect((await client.query(
        "SELECT account_closed FROM sonny.identity WHERE id = $1", [orphan.identityId],
      )).rows[0].account_closed).toBe(true);

      await client.query("UPDATE sonny.identity SET account_id = $2 WHERE id = $1",
        [orphan.identityId, live.accountId]);

      const { rows } = await client.query(
        "SELECT account_id, account_closed FROM sonny.identity WHERE id = $1", [orphan.identityId],
      );
      expect(rows[0].account_id).toBe(live.accountId);
      expect(rows[0].account_closed).toBe(false);

      // **And the consequence, which is the whole reason it matters.** With a stale flag, rule 1
      // could not see this identity, so the next sign-in with the same `(provider, subject)` made
      // the person a SECOND account — the failure this entire ticket exists to prevent, reached
      // from the one path that is supposed to prevent it.
      const again = await resolve(client, {
        provider: "apple", subject: "apple-moves", email: "iii@privaterelay.appleid.com", emailVerified: true,
      });
      expect(again.accountId).toBe(live.accountId);
      expect(again.created).toBe(false);
      const live_accounts = await client.query(
        "SELECT count(*)::int AS n FROM sonny.account WHERE deleted_at IS NULL",
      );
      expect(live_accounts.rows[0].n).toBe(1);
    });

    it("CLEARS account_closed when an account is reopened", async () => {
      // PR #87 second round, F10. The close trigger only ever set the flag, so undoing a mistaken
      // closure — `deleted_at = NULL`, the only way an account is ever reopened — left every
      // identity on it flagged closed. Rule 1 excludes those, so the reopened account's owner would
      // sign in and be handed a *new* account: the same two-accounts failure, from the other side.
      const account = await resolve(client, emailAssertion("undo@example.com"));
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [account.accountId]);
      expect((await client.query(
        "SELECT account_closed FROM sonny.identity WHERE account_id = $1", [account.accountId],
      )).rows[0].account_closed).toBe(true);

      await client.query("UPDATE sonny.account SET deleted_at = NULL WHERE id = $1", [account.accountId]);
      expect((await client.query(
        "SELECT account_closed FROM sonny.identity WHERE account_id = $1", [account.accountId],
      )).rows[0].account_closed).toBe(false);

      const back = await resolve(client, emailAssertion("undo@example.com"));
      expect(back.accountId).toBe(account.accountId);
      expect(back.created).toBe(false);
    });

    it("reports a missing account as a FOREIGN KEY violation, not a NOT NULL one", async () => {
      // PR #87 second round, F12. `SELECT … INTO` assigns NULL when nothing matches, so the derive
      // trigger turned "there is no such account" into `23502 not_null_violation` against a column
      // the caller never wrote — an error that sends the reader to the wrong table entirely. The
      // trigger now leaves the flag alone and lets the foreign key say what is actually wrong.
      const failure = await client.query(
        `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
           email_is_relay, link_method)
         VALUES ('00000000-0000-0000-0000-000000000000','email','ghost@example.com',
                 'ghost@example.com',true,false,'primary')`,
      ).then(() => undefined, (error: { code?: string }) => error);
      expect(failure?.code).toBe("23503");
    });

    it("keeps rule 2 in step with rule 1 about a closed identity", async () => {
      // PR #87 second round, F1c. Rule 1 excludes a closed identity AND a closed account; rule 2
      // excluded only the account. Where they disagreed about the same row — which is precisely the
      // state F1's missing trigger produced — rule 1 would refuse to sign that identity in while
      // rule 2 would happily attach a *different* sign-in to the account holding it, on the strength
      // of the email hint the closed row still carries.
      const account = await resolve(client, emailAssertion("split-rule@example.com"));
      await client.query(
        "UPDATE sonny.identity SET account_closed = true WHERE id = $1", [account.identityId],
      );

      const viaGoogle = await resolve(client, {
        provider: "google", subject: "g-split-rule", email: "split-rule@example.com", emailVerified: true,
      });
      expect(viaGoogle.accountId).not.toBe(account.accountId);
      expect(viaGoogle.linkMethod).toBe("primary");
      expect(viaGoogle.created).toBe(true);
    });
  });

  describe("the separation the whole design exists for", () => {
    it("lets two identities on one account carry two different Supabase user ids", async () => {
      // Supabase creates a second `auth.users` for a relay address because it matches nothing. If
      // the account WERE the Supabase user, this case could not be represented at all — the person
      // would hold two accounts and one subscription.
      const primary = await resolve(client, emailAssertion("split@example.com", "11111111-1111-1111-1111-111111111111"));
      const viaApple = await resolve(client, {
        provider: "apple", subject: "apple-sub-split", email: "ddd@privaterelay.appleid.com",
        emailVerified: true, supabaseUserId: "22222222-2222-2222-2222-222222222222",
      });
      await linkExplicitly(client, viaApple.identityId, primary.accountId, primary.accountId, viaApple.identityId);

      const { rows } = await client.query(
        "SELECT DISTINCT supabase_user_id FROM sonny.identity WHERE account_id = $1 ORDER BY 1",
        [primary.accountId],
      );
      expect(rows).toHaveLength(2);
    });
  });

  describe("the rate-limit key normalises OPPOSITE to the identity key", () => {
    it("merges plus-tags and casing, which the identity key must not", async () => {
      // PR #87 F4. One mailbox, one budget: `a+1@x`, `a+2@x` and `A@X` all deliver to the same
      // inbox, so counting them separately means a 3-per-address cap that never binds. The identity
      // key must do the opposite, because merging two addresses joins two accounts.
      expect(rateLimitEmailKey("a+1@example.com")).toBe("a@example.com");
      expect(rateLimitEmailKey("a+anything@example.com")).toBe("a@example.com");
      expect(rateLimitEmailKey("  A@Example.COM ")).toBe("a@example.com");
      expect(rateLimitEmailKey("a@example.com")).toBe("a@example.com");
      // and the identity key keeps them apart, on the same inputs
      expect(normalizeEmail("a+1@example.com")).not.toBe(normalizeEmail("a@example.com"));
    });

    it("does not fold dots, which would merge distinct mailboxes at most providers", () => {
      // Gmail folds them; nobody else does. Applying one provider's policy everywhere would put
      // two unrelated users on one budget, which is a denial of service against them.
      expect(rateLimitEmailKey("a.b@example.com")).toBe("a.b@example.com");
    });

    it("leaves a malformed value alone rather than inventing structure", () => {
      expect(rateLimitEmailKey("no-at-sign")).toBe("no-at-sign");
    });
  });

  describe("a closed account frees its address without giving up its identities", () => {
    it("lets the same address sign up again, on a NEW account", async () => {
      // Regression, and it was a livelock rather than a wrong answer. Rule 1 excludes identities on
      // a deleted account; the unique constraint on (provider, subject) did not. So the insert
      // conflicted, the resolver rolled back and retried, and hit the identical conflict forever.
      //
      // **Nothing is deleted here any more, and the describe name used to say it was** (PR #87
      // second round, F8-adjacent). 0003 released the rows and 0004 replaced that with marking: the
      // partial unique index covers only `NOT account_closed`, so a marked row stops occupying the
      // address while staying readable. These two tests planted the release by hand with a `DELETE`
      // and so were still describing the migration that had been superseded — they close the
      // account and let the trigger do what it really does now.
      const first = await resolve(client, emailAssertion("recycle@example.com"));
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [first.accountId]);

      const second = await resolve(client, emailAssertion("recycle@example.com"));
      expect(second.accountId).not.toBe(first.accountId);
      expect(second.created).toBe(true);
      // and the first identity is still there, marked — the audit trail 0004 keeps.
      const { rows } = await client.query(
        "SELECT account_closed FROM sonny.identity WHERE account_id = $1", [first.accountId],
      );
      expect(rows).toHaveLength(1);
      expect(rows[0].account_closed).toBe(true);
    });

    it("keeps the closed account row, because it is the handle retained content hangs off", async () => {
      const account = await resolve(client, emailAssertion("handle@example.com"));
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [account.accountId]);
      const { rows } = await client.query("SELECT deleted_at FROM sonny.account WHERE id = $1", [account.accountId]);
      expect(rows).toHaveLength(1);
      expect(rows[0].deleted_at).not.toBeNull();
    });
  });

  describe("the retry branch, and the race that used to reach it", () => {
    it("finds a planted identity through rule 1, without needing the retry branch at all", async () => {
      // **This test's name used to claim it ENTERED the retry branch, and its own body said it did
      // not** (PR #87 second round, F8). Planting the winner's row first means rule 1 finds it on
      // the first pass, so the `ON CONFLICT` is never reached — the same *answer* by a different
      // route, which is worth keeping and is not what the old name said. The real thing is the test
      // below, which forces the conflict with two connections.
      const winner = await client.query<{ id: string }>("INSERT INTO sonny.account DEFAULT VALUES RETURNING id");
      await client.query(
        `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
           email_is_relay, link_method) VALUES ($1,'email','race@example.com','race@example.com',true,false,'primary')`,
        [winner.rows[0]!.id],
      );
      const resolved = await resolve(client, emailAssertion("race@example.com"));
      expect(resolved.accountId).toBe(winner.rows[0]!.id);
      expect(resolved.created).toBe(false);
    });

    it("REALLY enters the ON CONFLICT retry, and the second pass resolves", async () => {
      // PR #87 second round, F8. The branch is reachable and nothing reached it, so its bounded
      // retry was code nobody had executed. This forces it deterministically rather than hopefully:
      //
      //   1. the winner opens a transaction and inserts the identity, WITHOUT committing;
      //   2. the resolver starts on its own connection. Rule 1's SELECT sees nothing — the winner's
      //      row is uncommitted — and rule 2 matches nothing, so it creates an account and inserts;
      //   3. that INSERT meets the winner's uncommitted row and **blocks on it**, which is how
      //      Postgres handles `ON CONFLICT` against a transaction still in flight;
      //   4. the winner commits, the insert resolves to DO NOTHING, `identity.rows[0]` is undefined,
      //      and the retry branch runs.
      //
      // Step 3 is what makes this a proof rather than an assumption: the resolver's promise is
      // asserted to be still pending while the winner holds its transaction open, and a resolver
      // that took rule 1's path would have settled long before.
      const winner = new pg.Client({ connectionString: url });
      const racer = new pg.Client({ connectionString: url });
      await winner.connect();
      await racer.connect();
      try {
        const account = await client.query<{ id: string }>("INSERT INTO sonny.account DEFAULT VALUES RETURNING id");
        await winner.query("BEGIN");
        await winner.query(
          `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
             email_is_relay, link_method)
           VALUES ($1,'email','conflict@example.com','conflict@example.com',true,false,'primary')`,
          [account.rows[0]!.id],
        );

        let settled = false;
        const racing = resolve(racer, emailAssertion("conflict@example.com"))
          .then((value) => { settled = true; return value; });
        await new Promise((r) => setTimeout(r, 200));
        expect(settled).toBe(false);        // blocked on the winner's uncommitted row

        await winner.query("COMMIT");
        const result = await racing;

        expect(result.accountId).toBe(account.rows[0]!.id);   // the winner's account, not its own
        expect(result.created).toBe(false);
        // The account the losing pass speculatively created was rolled back with it, which is why
        // the INSERT and the account creation share one transaction.
        const accounts = await client.query("SELECT count(*)::int AS n FROM sonny.account");
        expect(accounts.rows[0].n).toBe(1);
      } finally {
        await winner.end();
        await racer.end();
      }
    });

    it("an identity inserted onto an ALREADY-closed account cannot occupy the address", async () => {
      // This test used to assert the stuck state was merely *loud*: an identity on a closed account
      // was invisible to rule 1 and visible to the unique constraint, so the resolver failed with
      // IdentityConflict and the address stayed unusable. Under 0004 the state cannot arise —
      // `identity_insert_derives_closed` marks the row at insert time, so it never occupies the
      // partial unique index, and the address stays available. That is the fix, so the assertion
      // changed with it.
      const closed = await client.query<{ id: string }>("INSERT INTO sonny.account DEFAULT VALUES RETURNING id");
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [closed.rows[0]!.id]);
      await client.query(
        `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
           email_is_relay, link_method) VALUES ($1,'email','stuck@example.com','stuck@example.com',true,false,'primary')`,
        [closed.rows[0]!.id],
      );
      const marked = await client.query(
        "SELECT account_closed FROM sonny.identity WHERE subject = 'stuck@example.com'",
      );
      expect(marked.rows[0].account_closed).toBe(true);

      const fresh = await resolve(client, emailAssertion("stuck@example.com"));
      expect(fresh.created).toBe(true);
    });

    it("survives a REAL two-connection race between resolve() and a close", async () => {
      // **The previous version of this test did not race** (PR #87 R10). Both halves ran on one
      // `pg.Client`, which serialises its queries, so they executed in sequence — and its only
      // assertion was `toBeTruthy()`, which cannot fail for a uuid. It would have passed against
      // the very defect it was named for.
      //
      // This one uses two connections and holds the closer's transaction open across the resolver's
      // insert window, which is the interleaving that stranded an identity. `SELECT ... FOR SHARE`
      // in resolve() is what makes the resolver block on the closer's row lock and re-read, instead
      // of inserting into the gap.
      const victim = await resolve(client, emailAssertion("realrace@example.com"));

      const closer = new pg.Client({ connectionString: url });
      const racer = new pg.Client({ connectionString: url });
      await closer.connect();
      await racer.connect();
      try {
        await closer.query("BEGIN");
        await closer.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [victim.accountId]);

        // Starts while the closer still holds the row lock, so it must block rather than proceed.
        let settled = false;
        const racing = resolve(racer, emailAssertion("realrace@example.com"))
          .then((value) => { settled = true; return value; });
        await new Promise((r) => setTimeout(r, 150));
        // **The assertion this test was missing** (PR #87 third round, F9). Without it, the test
        // says only what the FINAL state is, and a future regression that stopped blocking here
        // could reach the same final state by a different route and pass — the ON-CONFLICT test
        // next door already carries this line, and this file's own comments record a race test that
        // silently stopped racing once before. Asserting the promise is still pending is what makes
        // "it blocked on the closer" a measured fact rather than the test's title.
        expect(settled).toBe(false);
        await closer.query("COMMIT");

        const result = await racing;
        // Whichever way it went, it must NOT have landed on the account that was closing.
        expect(result.accountId).not.toBe(victim.accountId);
        expect(result.created).toBe(true);
      } finally {
        await closer.end();
        await racer.end();
      }

      // And the address is still usable afterwards, which is what "not stranded" means.
      const after = await resolve(client, emailAssertion("realrace@example.com"));
      expect(after.accountId).toBeTruthy();
      const live = await client.query(
        "SELECT count(*)::int AS n FROM sonny.identity WHERE subject = 'realrace@example.com' AND NOT account_closed",
      );
      expect(live.rows[0].n).toBe(1);
    });

    it("MARKS identities however the account was closed, keeping them and their audit trail", async () => {
      // The structural fix, and 0004's correction to it: 0003 DELETEd these rows, which broke the
      // close handler's own read of supabase_user_id and destroyed link_method. They are marked now.
      const account = await resolve(client, emailAssertion("sweeper@example.com"));
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [account.accountId]);

      const { rows } = await client.query(
        "SELECT account_closed, link_method, supabase_user_id FROM sonny.identity WHERE account_id = $1",
        [account.accountId],
      );
      expect(rows).toHaveLength(1);            // kept, not deleted
      expect(rows[0].account_closed).toBe(true);
      expect(rows[0].link_method).toBe("primary"); // audit trail survives

      // and the address is free again, because the partial index only covers live identities
      const reused = await resolve(client, emailAssertion("sweeper@example.com"));
      expect(reused.created).toBe(true);
    });

    it("marks identities on a SECOND deleted_at update too", async () => {
      // 0003 guarded on `OLD.deleted_at IS NULL`, so an operator correcting a timestamp, or a retry,
      // skipped the trigger and left identities live on a closed account.
      const account = await resolve(client, emailAssertion("twice@example.com"));
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [account.accountId]);
      await client.query("UPDATE sonny.identity SET account_closed = false WHERE account_id = $1", [account.accountId]);
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [account.accountId]);
      const { rows } = await client.query(
        "SELECT account_closed FROM sonny.identity WHERE account_id = $1", [account.accountId],
      );
      expect(rows[0].account_closed).toBe(true);
    });
  });

  describe("training consent", () => {
    it("defaults to not-consented", async () => {
      const account = await resolve(client, emailAssertion("consent@example.com"));
      const { rows } = await client.query(
        "SELECT training_consent, training_consent_updated_at FROM sonny.account WHERE id = $1",
        [account.accountId],
      );
      expect(rows[0].training_consent).toBe(false);
      expect(rows[0].training_consent_updated_at).toBeNull();
    });

    it("cannot be null — there is no third state to mistake for consent", async () => {
      const account = await resolve(client, emailAssertion("notnull@example.com"));
      await expect(
        client.query("UPDATE sonny.account SET training_consent = NULL WHERE id = $1", [account.accountId]),
      ).rejects.toThrow();
    });
  });
});
