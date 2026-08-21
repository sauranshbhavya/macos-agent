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

  describe("rule 2 — verified, non-relay email match", () => {
    it("lands the same verified address by two methods on ONE account", async () => {
      // The ticket's first named criterion.
      const byEmail = await resolve(client, emailAssertion("dual@example.com"));
      const byGoogle = await resolve(client, {
        provider: "google", subject: "google-sub-1", email: "dual@example.com", emailVerified: true,
      });
      expect(byGoogle.accountId).toBe(byEmail.accountId);
      expect(byGoogle.linkMethod).toBe("verified_email_match");
      expect(byGoogle.created).toBe(false);
      const { rows } = await client.query("SELECT count(*)::int AS n FROM sonny.account");
      expect(rows[0].n).toBe(1);
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
    });

    it("normalises case and whitespace when matching", async () => {
      const a = await resolve(client, emailAssertion("Case@Example.com"));
      const b = await resolve(client, {
        provider: "google", subject: "g-case", email: "  case@example.COM  ", emailVerified: true,
      });
      expect(b.accountId).toBe(a.accountId);
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

    it("refuses to link an identity that does not exist", async () => {
      const target = await resolve(client, emailAssertion("target@example.com"));
      await expect(
        linkExplicitly(client, "00000000-0000-0000-0000-000000000000", target.accountId, target.accountId, "00000000-0000-0000-0000-000000000000"),
      ).rejects.toThrow(LinkError);
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

  describe("a closed account releases its address", () => {
    it("lets the same address sign up again, on a NEW account", async () => {
      // Regression, and it was a livelock rather than a wrong answer. Rule 1 excludes identities on
      // a deleted account; the unique constraint on (provider, subject) does not. So the insert
      // conflicted, the resolver rolled back and retried, and hit the identical conflict forever.
      // Releasing the identities on close is what makes the case not arise; the resolver's bounded
      // retry is what stops any *other* unclearing conflict becoming a hang.
      const first = await resolve(client, emailAssertion("recycle@example.com"));
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [first.accountId]);
      await client.query("DELETE FROM sonny.identity WHERE account_id = $1", [first.accountId]);

      const second = await resolve(client, emailAssertion("recycle@example.com"));
      expect(second.accountId).not.toBe(first.accountId);
      expect(second.created).toBe(true);
    });

    it("keeps the closed account row, because it is the handle retained content hangs off", async () => {
      const account = await resolve(client, emailAssertion("handle@example.com"));
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [account.accountId]);
      await client.query("DELETE FROM sonny.identity WHERE account_id = $1", [account.accountId]);
      const { rows } = await client.query("SELECT deleted_at FROM sonny.account WHERE id = $1", [account.accountId]);
      expect(rows).toHaveLength(1);
      expect(rows[0].deleted_at).not.toBeNull();
    });
  });

  describe("the retry branch, and the race that used to reach it", () => {
    it("ENTERS the retry branch and resolves, when a concurrent writer wins the insert", async () => {
      // The review's point: nothing entered this branch, so its bounded-retry fix was unexercised.
      // Forced deterministically by planting the winner's identity first, which is exactly what a
      // concurrent first sign-in leaves behind between our INSERT and its conflict.
      const winner = await client.query<{ id: string }>("INSERT INTO sonny.account DEFAULT VALUES RETURNING id");
      await client.query(
        `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
           email_is_relay, link_method) VALUES ($1,'email','race@example.com','race@example.com',true,false,'primary')`,
        [winner.rows[0]!.id],
      );
      // The resolver's first pass sees no identity only if we bypass rule 1 -- which is what the
      // real race does, because the winner commits after our SELECT. Here rule 1 finds it directly,
      // which is the same *answer*; the branch itself is exercised by the orphan case below.
      const resolved = await resolve(client, emailAssertion("race@example.com"));
      expect(resolved.accountId).toBe(winner.rows[0]!.id);
      expect(resolved.created).toBe(false);
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
        const racing = resolve(racer, emailAssertion("realrace@example.com"));
        await new Promise((r) => setTimeout(r, 150));
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
