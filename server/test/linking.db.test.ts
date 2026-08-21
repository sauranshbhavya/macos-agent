import pg from "pg";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { LinkError, isRelayAddress, linkExplicitly, normalizeEmail, resolve } from "../src/auth/identity.js";
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
      await linkExplicitly(client, viaApple.identityId, primary.accountId);

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
      await expect(linkExplicitly(client, other.identityId, dead.accountId)).rejects.toThrow(LinkError);
    });

    it("refuses to link an identity that does not exist", async () => {
      const target = await resolve(client, emailAssertion("target@example.com"));
      await expect(
        linkExplicitly(client, "00000000-0000-0000-0000-000000000000", target.accountId),
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
      await linkExplicitly(client, viaApple.identityId, primary.accountId);

      const { rows } = await client.query(
        "SELECT DISTINCT supabase_user_id FROM sonny.identity WHERE account_id = $1 ORDER BY 1",
        [primary.accountId],
      );
      expect(rows).toHaveLength(2);
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
