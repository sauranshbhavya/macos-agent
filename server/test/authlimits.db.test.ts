import pg from "pg";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  CODE_LIFETIME_SECONDS, FAILURE_DISCLOSURE_SECONDS, classifyFailure, consumeLatest,
  invalidateLive, recordIssue,
} from "../src/auth/codes.js";
import {
  CODE_REQUEST_PER_ADDRESS, CODE_REQUEST_PER_SOURCE, CODE_VERIFY_PER_SOURCE,
  bucketKey, consume, sweep,
} from "../src/auth/ratelimit.js";
import { up } from "../src/db/migrate.js";

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;
const SALT = "test-salt-not-a-secret";

describeDb("rate limits and the code lifecycle", () => {
  let client: pg.Client;

  beforeAll(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await up(client);
  });
  afterAll(async () => { await client.end(); });
  beforeEach(async () => {
    await client.query("TRUNCATE sonny.auth_rate_limit, sonny.sign_in_code_issue");
  });

  describe("rate limiting", () => {
    it("allows up to the ceiling and refuses the one after it, with a Retry-After", async () => {
      const bucket = bucketKey("addr", "a@example.com", SALT);
      const verdicts = [];
      for (let i = 0; i < CODE_REQUEST_PER_ADDRESS.max + 1; i += 1) {
        verdicts.push(await consume(client, bucket, CODE_REQUEST_PER_ADDRESS));
      }
      expect(verdicts.slice(0, CODE_REQUEST_PER_ADDRESS.max).every((v) => v.allowed)).toBe(true);
      const refused = verdicts.at(-1)!;
      expect(refused.allowed).toBe(false);
      expect(refused.retryAfterSeconds).toBeGreaterThan(0);
      expect(refused.retryAfterSeconds).toBeLessThanOrEqual(CODE_REQUEST_PER_ADDRESS.windowSeconds);
    });

    it("never exceeds the ceiling under concurrency", async () => {
      // The property the single-statement increment exists for. A read-then-write here lets two
      // racing callers both see the old count and both write, which is how a limit of three becomes
      // a limit of "three, usually" — and an auth endpoint is where that would be probed on purpose.
      const bucket = bucketKey("addr", "race@example.com", SALT);
      const results = await Promise.all(
        Array.from({ length: 40 }, () => consume(client, bucket, CODE_REQUEST_PER_ADDRESS)),
      );
      expect(results.filter((r) => r.allowed)).toHaveLength(CODE_REQUEST_PER_ADDRESS.max);
      const { rows } = await client.query<{ count: number }>(
        "SELECT count FROM sonny.auth_rate_limit WHERE bucket = $1", [bucket],
      );
      expect(rows[0]!.count).toBe(CODE_REQUEST_PER_ADDRESS.max);
    });

    it("keeps address and source buckets independent", async () => {
      // One office behind one address must not lock out a second person there, and one caller must
      // not be able to spend another address's budget.
      const addr = bucketKey("addr", "indep@example.com", SALT);
      const src = bucketKey("src", "203.0.113.7", SALT);
      for (let i = 0; i < CODE_REQUEST_PER_ADDRESS.max; i += 1) {
        await consume(client, addr, CODE_REQUEST_PER_ADDRESS);
      }
      expect((await consume(client, addr, CODE_REQUEST_PER_ADDRESS)).allowed).toBe(false);
      expect((await consume(client, src, CODE_REQUEST_PER_SOURCE)).allowed).toBe(true);
    });

    it("starts a fresh budget in the next window", async () => {
      const bucket = bucketKey("addr", "window@example.com", SALT);
      const now = new Date("2026-08-21T10:00:00Z");
      for (let i = 0; i < CODE_REQUEST_PER_ADDRESS.max; i += 1) {
        await consume(client, bucket, CODE_REQUEST_PER_ADDRESS, now);
      }
      expect((await consume(client, bucket, CODE_REQUEST_PER_ADDRESS, now)).allowed).toBe(false);
      const later = new Date(now.getTime() + CODE_REQUEST_PER_ADDRESS.windowSeconds * 1000);
      expect((await consume(client, bucket, CODE_REQUEST_PER_ADDRESS, later)).allowed).toBe(true);
    });

    it("stores no raw address or source, only a salted hash", async () => {
      await consume(client, bucketKey("addr", "private@example.com", SALT), CODE_REQUEST_PER_ADDRESS);
      const { rows } = await client.query<{ bucket: string }>("SELECT bucket FROM sonny.auth_rate_limit");
      expect(rows[0]!.bucket).not.toContain("private@example.com");
      expect(rows[0]!.bucket).toMatch(/^addr:[0-9a-f]{64}$/);
    });

    it("produces different buckets for the same value under different salts", async () => {
      // Without a salt an email hash is one rainbow-table lookup from the address.
      expect(bucketKey("addr", "x@example.com", "salt-a"))
        .not.toBe(bucketKey("addr", "x@example.com", "salt-b"));
    });

    it("keeps email/start's and email/verify's SOURCE budgets in separate buckets", async () => {
      // **PR #87 sixth round: a stated property with no guard.** `ratelimit.ts` says in bold that
      // the verify source limit gets "its own bucket kind, not shared with `email/start`'s" —
      // because two ceilings counted against one counter is one limit, whichever is smaller. Nothing
      // in `test/` mentioned `verifysrc` at all, and changing `bucketKey("verifysrc", …)` to
      // `bucketKey("src", …)` in the route left the suite green at 162/162.
      //
      // The shipped behaviour that mutant would have caused is real: a user who verifies ten times
      // could no longer request a sign-in code, because verify would have eaten `email/start`'s
      // budget. Asserted on the property — two kinds over one value must not collide — rather than
      // on the string, so it survives a rename.
      const source = "203.0.113.55";
      expect(bucketKey("verifysrc", source, SALT)).not.toBe(bucketKey("src", source, SALT));

      // And behaviourally, over the real table: spending one budget must not spend the other.
      const start = bucketKey("src", source, SALT);
      const verify = bucketKey("verifysrc", source, SALT);
      for (let i = 0; i < CODE_REQUEST_PER_SOURCE.max; i += 1) {
        expect((await consume(client, start, CODE_REQUEST_PER_SOURCE)).allowed).toBe(true);
      }
      expect((await consume(client, start, CODE_REQUEST_PER_SOURCE)).allowed).toBe(false);
      // The verify budget is untouched, which is the whole of the property.
      expect((await consume(client, verify, CODE_VERIFY_PER_SOURCE)).allowed).toBe(true);
    });

    it("refuses to build a bucket with no salt configured", () => {
      expect(() => bucketKey("addr", "x@example.com", "")).toThrow(/salt/);
    });

    it("sweeps windows that are past", async () => {
      const bucket = bucketKey("addr", "old@example.com", SALT);
      await consume(client, bucket, CODE_REQUEST_PER_ADDRESS, new Date("2026-01-01T00:00:00Z"));
      expect(await sweep(client, new Date("2026-06-01T00:00:00Z"))).toBe(1);
    });
  });

  describe("the code lifecycle, and the three failures Supabase collapses into one", () => {
    const address = "codes@example.com";
    /** The source that asked for the code. Every "legitimate caller" case below presents it. */
    const OURS = "srchash";
    const THEIRS = "a-different-caller";

    it("classifies a wrong code against a live issuance as invalid", async () => {
      await recordIssue(client, address, OURS);
      expect(await classifyFailure(client, address, new Date(), OURS)).toBe("auth.code_invalid");
    });

    it("classifies an expired issuance as expired", async () => {
      const past = new Date(Date.now() - (CODE_LIFETIME_SECONDS + 60) * 1000);
      await recordIssue(client, address, OURS, past);
      expect(await classifyFailure(client, address, new Date(), OURS)).toBe("auth.code_expired");
    });

    it("classifies a consumed issuance as used", async () => {
      await recordIssue(client, address, OURS);
      expect(await consumeLatest(client, address)).toBe(true);
      expect(await classifyFailure(client, address, new Date(), OURS)).toBe("auth.code_used");
    });

    it("classifies an address that was never issued a code as invalid, not used", async () => {
      // An account-existence oracle would be the bug here: "used" for a known address and
      // "invalid" for an unknown one tells an attacker which addresses have accounts.
      expect(await classifyFailure(client, "never-seen@example.com", new Date(), OURS))
        .toBe("auth.code_invalid");
    });

    it("prefers used over expired when a consumed code has also aged out", async () => {
      const past = new Date(Date.now() - (CODE_LIFETIME_SECONDS + 60) * 1000);
      const { id } = await recordIssue(client, address, OURS, past);
      await client.query("UPDATE sonny.sign_in_code_issue SET consumed_at = now() WHERE id = $1", [id]);
      expect(await classifyFailure(client, address, new Date(), OURS)).toBe("auth.code_used");
    });

    describe("the disclosure gate — the three codes are an account-existence oracle", () => {
      // **PR #87 fifth round, F1.** Reproduced before the fix: one unauthenticated request per
      // address carrying a code known to be wrong, never calling `email/start`, returned
      // `auth.code_used` for a mailbox whose owner had signed in, `auth.code_expired` for one that
      // had asked and never used, and `auth.code_invalid` for addresses with nothing. Everything
      // below is that attack, at the level of the function that answered it.

      it("tells a caller who did NOT originate the code nothing but code_invalid", async () => {
        // The used case, which is the one that names an account.
        await recordIssue(client, address, OURS);
        await consumeLatest(client, address);
        expect(await classifyFailure(client, address, new Date(), OURS)).toBe("auth.code_used");
        expect(await classifyFailure(client, address, new Date(), THEIRS)).toBe("auth.code_invalid");
      });

      it("tells the same to a caller offering no source at all", async () => {
        // Absent rather than wrong. `undefined === row.source_hash` must never be true, and the
        // parameter is optional so an omission is the safe answer rather than a type error.
        await recordIssue(client, address, OURS);
        await consumeLatest(client, address);
        expect(await classifyFailure(client, address, new Date())).toBe("auth.code_invalid");
      });

      it("makes an unknown address and a known one INDISTINGUISHABLE to a stranger", async () => {
        // The oracle stated as the property rather than as three separate cases: whatever the
        // mailbox's history, a caller who did not ask for the code gets the same answer.
        await recordIssue(client, "has-account@example.com", OURS);
        await consumeLatest(client, "has-account@example.com");
        const expired = new Date(Date.now() - (CODE_LIFETIME_SECONDS + 60) * 1000);
        await recordIssue(client, "asked-never-used@example.com", OURS, expired);

        const answers = await Promise.all(
          ["has-account@example.com", "asked-never-used@example.com", "nobody@example.com"]
            .map((mailbox) => classifyFailure(client, mailbox, new Date(), THEIRS)),
        );
        expect(answers).toEqual(["auth.code_invalid", "auth.code_invalid", "auth.code_invalid"]);
      });

      it("stops disclosing once the issuance is old, even to the caller who made it", async () => {
        // The signal has to decay: before this, an address that signed in once answered
        // `auth.code_used` 400 simulated days later, so having an account was a permanent fact
        // anyone could read. `FAILURE_DISCLOSURE_SECONDS` is one code lifetime past expiry.
        const ancient = new Date(Date.now() - (FAILURE_DISCLOSURE_SECONDS + 60) * 1000);
        const { id } = await recordIssue(client, address, OURS, ancient);
        await client.query("UPDATE sonny.sign_in_code_issue SET consumed_at = now() WHERE id = $1", [id]);
        expect(await classifyFailure(client, address, new Date(), OURS)).toBe("auth.code_invalid");

        // ...and just inside the window it still does, so the bound is a bound and not an off switch.
        const recent = new Date(Date.now() - (FAILURE_DISCLOSURE_SECONDS - 60) * 1000);
        await client.query(
          "UPDATE sonny.sign_in_code_issue SET issued_at = $2 WHERE id = $1", [id, recent]);
        expect(await classifyFailure(client, address, new Date(), OURS)).toBe("auth.code_used");
      });

      it("gives an attacker who calls email/start first nothing either", async () => {
        // The obvious way around a source check: ask for a code yourself so the row carries YOUR
        // source. It does not work, and the reason is the invalidate-then-record in `issueCode` —
        // the attacker's own request becomes the latest row, live and unconsumed, which classifies
        // `auth.code_invalid` whoever the mailbox belongs to.
        await recordIssue(client, address, OURS);
        await consumeLatest(client, address);                    // the victim signed in
        await invalidateLive(client, address);
        await recordIssue(client, address, THEIRS);              // the attacker asks for a code
        expect(await classifyFailure(client, address, new Date(), THEIRS)).toBe("auth.code_invalid");
      });
    });

    it("consumes a code exactly once under concurrency", async () => {
      // Replay, done properly: two verifies of the same code arriving together must mint one
      // session, not two. The single UPDATE with `consumed_at IS NULL` is the guarantee.
      await recordIssue(client, address, "srchash");
      const results = await Promise.all(
        Array.from({ length: 12 }, () => consumeLatest(client, address)),
      );
      expect(results.filter(Boolean)).toHaveLength(1);
    });

    it("refuses to consume an expired issuance", async () => {
      const past = new Date(Date.now() - (CODE_LIFETIME_SECONDS + 60) * 1000);
      await recordIssue(client, address, "srchash", past);
      expect(await consumeLatest(client, address)).toBe(false);
    });

    it("makes the newest code the only live one", async () => {
      // The founder's own manual-test item: request a second code before using the first, and
      // confirm which one works. The answer is the newest, and it is decided here rather than by
      // whichever the provider happens to accept.
      await recordIssue(client, address, "srchash");
      const invalidated = await invalidateLive(client, address);
      expect(invalidated).toBe(1);
      await recordIssue(client, address, "srchash");
      expect(await consumeLatest(client, address)).toBe(true);
      // and the older one cannot then be consumed
      expect(await consumeLatest(client, address)).toBe(false);
    });

    it("stores no code value anywhere", async () => {
      // The gateway must never hold the secret it did not issue. Asserted structurally rather than
      // by inspection: the table has no column that could carry one.
      await recordIssue(client, address, "srchash");
      const { rows } = await client.query<{ column_name: string }>(
        `SELECT column_name FROM information_schema.columns
          WHERE table_schema = 'sonny' AND table_name = 'sign_in_code_issue'`,
      );
      const names = rows.map((r) => r.column_name).sort();
      expect(names).toEqual(
        ["consumed_at", "expires_at", "id", "issued_at", "mailbox_key", "source_hash"],
      );
    });
  });
});
