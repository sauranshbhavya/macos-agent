import { randomUUID } from "node:crypto";
import pg from "pg";
import { describe, expect } from "vitest";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import { recentContentDeletions } from "../src/content/query.js";
import { contentExpiryFrom, type RetainedContent } from "../src/content/record.js";
import { buildTrainingSnapshot } from "../src/content/snapshot.js";
import {
  ClosedAccountSweepFailed,
  insertRetainedContent,
  sweepClosedAccountContent,
} from "../src/content/store.js";
import {
  claimKey,
  completeClaim,
  deleteStoredResponsesForAccount,
} from "../src/idempotency/store.js";
import {
  afterAllUnderHangBackstop,
  beforeAllUnderHangBackstop,
  beforeEachUnderHangBackstop,
  itUnderHangBackstop,
} from "./support/backstop.js";
import { testConfig } from "./support/config.js";
import { rebuildSchema } from "./support/schema.js";
import { accessTokenFor } from "./support/tokens.js";

/**
 * An account wipe and the record of it commit together or not at all (SONNY-436).
 *
 * **The defect.** Every account wipe — `DELETE /v1/account/content`, `DELETE /v1/account`, and the
 * closed-account sweep that finishes the second — cleared the account's stored idempotency response
 * bodies as a statement of its own, which committed, and only then opened the transaction that
 * deletes the content and writes the `sonny.content_deletion` row. A cancel between the two left the
 * bodies gone and no row naming them, and the next attempt found nothing left to clear and recorded
 * `stored_responses: 0` beside bodies that had been removed. §12's statement deadline on the content
 * route makes that cancel an ordinary `504` rather than a rare error. The fix hands the clear to
 * `deleteContentForAccount`, which runs it inside its own transaction.
 *
 * **How the cancel is placed, by construction rather than by timing.** Another connection holds row
 * locks on the account's content, so the wipe's content `DELETE` cannot finish; the test waits until
 * Postgres's own `pg_stat_activity` shows the wipe's backend waiting on a lock in exactly that
 * statement, and only then cancels that backend with `pg_cancel_backend`. By then the clear has
 * already run — the wipe issues its statements one after another on one connection — and nothing
 * but the cancel can end the wait while the lock is held. So the cancel lands between the two units
 * every time, and no sleep or threshold decides where. The cancel is Postgres's `57014`, the same
 * code §12's `statement_timeout` raises, so the content route answers the `504` a real deadline would.
 *
 * **Three things are read, and the order they are asserted in is deliberate.** First the property
 * the ticket names: after the cancel, every table the wipe reaches is exactly as it was before the
 * request, and no deletion row exists. Then the retry: it clears and records the real count. Last,
 * two observations taken while the wipe was waiting, which say *why* — the waiting backend still
 * holds the write lock the clear takes on `sonny.idempotency_key`, so the clear is in its open
 * transaction, and no other connection can yet see a body gone. On the pre-fix code the first
 * assertion is the one that fails, which is the one a reader should see.
 *
 * Skips without `DATABASE_URL`, like every other `*.db.test.ts`; the run announces that once, loudly,
 * from `global-setup.ts`.
 */

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const ACCOUNT = "5b2d0c8e-1c5a-4a9f-9f6b-2b6f5f2a7436";
const SUPABASE_USER = "5f6c2c4e-8f2a-4a0f-9a11-2b6f5f2a7436";

/** Two of each, so a count of one cannot pass for "all of them". */
const CONTENT_ROWS = 2;
const STORED_RESPONSES = 2;

/**
 * How long a wait for the wipe to reach the lock may take before the test says it never got there.
 *
 * **A precondition, and it fails in wording of its own** — `statement-timeout.db.test.ts` carries
 * the reasoning in full: a wait whose only failure signal is the hang backstop can never count as a
 * mutation kill, because that backstop's wording is declared untrusted. It is met in milliseconds on
 * any tree where the request reaches Postgres at all.
 */
const BLOCK_OBSERVED_MS = 10_000;

/**
 * How long the test waits for the cancelled wipe to answer. Thirty seconds, inside the backstop's
 * sixty with `BLOCK_OBSERVED_MS` beside it, for `statement-timeout.db.test.ts`'s reason: this fires
 * first, in its own words, and the backstop never sees it.
 */
const ANSWER_OR_ADMIT_HUNG_MS = 30_000;

/** The gate verifies tokens locally, and the account close's drain calls nothing that matters here. */
class UnusedAuthProvider implements AuthProvider {
  async sendEmailCode() {
    return { providerRequestId: undefined };
  }
  async verifyEmailCode(): Promise<VerifiedSession> {
    throw new Error("not used here");
  }
  async refresh(): Promise<VerifiedSession> {
    throw new Error("not used here");
  }
  async signOut() {}
  async userFromAccessToken(): Promise<string> {
    throw new Error("not used here");
  }
  async signOutAllForUser() {}
  async deleteUser() {}
}

function content(taskId: string): RetainedContent {
  return {
    requestId: randomUUID(),
    accountId: ACCOUNT,
    taskId,
    sessionId: "session-1",
    sessionIteration: 1,
    route: "screen.analyze",
    retention: "standard",
    expiresAt: contentExpiryFrom(new Date(), 30),
    provider: "vision",
    providerRequestId: "req_vision_1",
    requestText: "Decide the next action.",
    voiceAudio: null,
    voiceAudioMediaType: null,
    voiceAudioFilename: null,
    screenshot: Buffer.from("a-redacted-capture"),
    screenshotMediaType: "image/jpeg",
    responseStatus: 200,
    responseContentType: "application/json",
    responseBody: Buffer.from('{"output_text":"click the invoice"}'),
    providerErrorStatus: null,
    providerErrorBody: null,
  };
}

/** Everything a wipe of `ACCOUNT` reaches, counted. Equal before and after means nothing was done. */
interface AccountState {
  readonly storedBodies: number;
  readonly contentRows: number;
  readonly snapshotMembers: number;
  readonly snapshotMemberCount: number;
  readonly deletionRows: number;
}

/** What a waiting wipe looked like from outside, read at the moment the test saw it wait. */
interface WhileWaiting {
  /** The waiting backend holds the lock the clear's `UPDATE` takes, so the clear is in its transaction. */
  readonly holdsTheClearsLock: boolean;
  /** Stored bodies another connection can still see. */
  readonly visibleStoredBodies: number;
}

type Settled<T> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly error: unknown };

describeDb("an account wipe and the record of it commit together (SONNY-436)", () => {
  /** Seeds, observes, cancels. Never the connection the wipe runs on. */
  let observer: pg.Client;
  /** The only connection the wipe under test runs on, so its backend is the one to watch and cancel. */
  let wipeClient: pg.Client;
  let wipePid: number;
  /** Holds row locks on the account's content, which is what stops the wipe mid-way. */
  let holder: pg.Client;

  beforeAllUnderHangBackstop(async () => {
    observer = new pg.Client({ connectionString: url });
    await observer.connect();
    await rebuildSchema(observer);
    wipeClient = new pg.Client({ connectionString: url });
    await wipeClient.connect();
    const { rows } = await wipeClient.query<{ pid: number }>("SELECT pg_backend_pid() AS pid");
    wipePid = rows[0]!.pid;
    holder = new pg.Client({ connectionString: url });
    await holder.connect();
  });
  afterAllUnderHangBackstop(async () => {
    await holder.end();
    await wipeClient.end();
    await observer.end();
  });
  beforeEachUnderHangBackstop(async () => {
    await observer.query(
      `TRUNCATE sonny.retained_content, sonny.training_snapshot, sonny.training_snapshot_member,
                sonny.content_deletion, sonny.idempotency_key`,
    );
    await observer.query("DELETE FROM sonny.identity WHERE account_id = $1", [ACCOUNT]);
    await observer.query("DELETE FROM sonny.account WHERE id = $1", [ACCOUNT]);
    await observer.query(
      "INSERT INTO sonny.account (id, training_consent, training_consent_updated_at) VALUES ($1, true, now())",
      [ACCOUNT],
    );
    await observer.query(
      `INSERT INTO sonny.identity (account_id, provider, subject, link_method, supabase_user_id)
       VALUES ($1, 'email', 'audit-row@example.test', 'primary', $2)`,
      [ACCOUNT, SUPABASE_USER],
    );
    for (let row = 0; row < CONTENT_ROWS; row += 1) {
      await insertRetainedContent(observer, content(`task-${row}`));
    }
    const built = await buildTrainingSnapshot(observer, { label: "audit-row-corpus" });
    expect(built.memberCount).toBe(CONTENT_ROWS);
    for (let key = 0; key < STORED_RESPONSES; key += 1) {
      await storeAResponse(`audit-row-key-${key}`);
    }
  });

  /** One completed idempotency key for `ACCOUNT`, holding a response body. */
  async function storeAResponse(key: string): Promise<void> {
    const claimed = await claimKey(observer, {
      accountScope: ACCOUNT,
      key,
      route: "POST /v1/plan",
      fingerprint: "sha256:aaa",
    });
    if (claimed.kind !== "claimed") throw new Error(`the key ${key} was not claimable`);
    await completeClaim(
      observer,
      { accountScope: ACCOUNT, key, token: claimed.token },
      {
        status: 200,
        body: Buffer.from('{"output_text":"something the user said"}'),
        contentType: "application/json",
        requestId: "r",
      },
    );
  }

  async function accountState(): Promise<AccountState> {
    const { rows } = await observer.query<{
      stored_bodies: string;
      content_rows: string;
      snapshot_members: string;
      snapshot_member_count: string;
      deletion_rows: string;
    }>(
      `SELECT
         (SELECT count(*) FROM sonny.idempotency_key
           WHERE account_scope = $1 AND response_body IS NOT NULL)::text AS stored_bodies,
         (SELECT count(*) FROM sonny.retained_content WHERE account_id = $1)::text AS content_rows,
         (SELECT count(*) FROM sonny.training_snapshot_member WHERE account_id = $1)::text AS snapshot_members,
         (SELECT coalesce(sum(member_count), 0) FROM sonny.training_snapshot)::text AS snapshot_member_count,
         (SELECT count(*) FROM sonny.content_deletion WHERE account_id = $1)::text AS deletion_rows`,
      [ACCOUNT],
    );
    const row = rows[0]!;
    return {
      storedBodies: Number(row.stored_bodies),
      contentRows: Number(row.content_rows),
      snapshotMembers: Number(row.snapshot_members),
      snapshotMemberCount: Number(row.snapshot_member_count),
      deletionRows: Number(row.deletion_rows),
    };
  }

  /**
   * Start a wipe, stop it inside its content `DELETE`, cancel it there, and report what was left.
   *
   * The lock is released in `finally` whatever happens, so a failed precondition cannot leave the
   * next test's wipe waiting on this one's holder.
   */
  async function cancelBetweenTheUnits<T>(start: () => Promise<T>): Promise<{
    readonly before: AccountState;
    readonly whileWaiting: WhileWaiting;
    readonly settled: Settled<T>;
    readonly after: AccountState;
  }> {
    const before = await accountState();
    await holder.query("BEGIN");
    try {
      await holder.query("SELECT 1 FROM sonny.retained_content WHERE account_id = $1 FOR UPDATE", [
        ACCOUNT,
      ]);

      // Settled into a value at once, so a rejection that arrives while the test is still waiting
      // for the lock is held here rather than reported as unhandled.
      const running: Promise<Settled<T>> = start().then(
        (value) => ({ ok: true as const, value }),
        (error: unknown) => ({ ok: false as const, error }),
      );

      const waiting = await waitUntilTheWipeWaitsInTheContentDelete();
      expect(
        waiting,
        "the wipe never reached the content DELETE while the content rows were locked, so there was no point between the units to cancel at",
      ).toBe(true);

      const whileWaiting = await observeTheWaitingWipe();

      const { rows } = await observer.query<{ cancelled: boolean }>(
        "SELECT pg_cancel_backend($1) AS cancelled",
        [wipePid],
      );
      expect(rows[0]!.cancelled).toBe(true);

      const outcome = await Promise.race([
        running,
        new Promise<"hung">((resolve) => setTimeout(() => resolve("hung"), ANSWER_OR_ADMIT_HUNG_MS).unref()),
      ]);
      if (outcome === "hung") {
        throw new Error("the cancelled wipe never answered, so nothing after the cancel is a measurement");
      }

      // Read while the lock is still held, so nothing but the cancel can have shaped it.
      const after = await accountState();
      return { before, whileWaiting, settled: outcome, after };
    } finally {
      await holder.query("ROLLBACK").catch(() => {});
    }
  }

  /**
   * Poll Postgres's own view until the wipe's backend is waiting on a lock in the content `DELETE`.
   *
   * A progress signal rather than a clock. Bounded, so a wipe that never gets there fails the
   * assertion above in its own words rather than hanging.
   */
  async function waitUntilTheWipeWaitsInTheContentDelete(): Promise<boolean> {
    const giveUpAt = Date.now() + BLOCK_OBSERVED_MS;
    for (;;) {
      const { rows } = await observer.query<{ wait: string | null; query: string }>(
        "SELECT wait_event_type AS wait, query FROM pg_stat_activity WHERE pid = $1",
        [wipePid],
      );
      const row = rows[0];
      if (row?.wait === "Lock" && row.query.trimStart().startsWith("DELETE FROM sonny.retained_content")) {
        return true;
      }
      if (Date.now() >= giveUpAt) return false;
      await new Promise((resolve) => setTimeout(resolve, 10).unref());
    }
  }

  async function observeTheWaitingWipe(): Promise<WhileWaiting> {
    const { rows } = await observer.query<{ holds: boolean; visible: string }>(
      `SELECT EXISTS (SELECT 1 FROM pg_locks
                       WHERE pid = $1 AND granted AND mode = 'RowExclusiveLock'
                         AND relation = 'sonny.idempotency_key'::regclass) AS holds,
              (SELECT count(*) FROM sonny.idempotency_key
                WHERE account_scope = $2 AND response_body IS NOT NULL)::text AS visible`,
      [wipePid, ACCOUNT],
    );
    return { holdsTheClearsLock: rows[0]!.holds, visibleStoredBodies: Number(rows[0]!.visible) };
  }

  /** The whole app over the wipe's own connection, so every statement the route issues is on it. */
  const app = () =>
    buildApp(testConfig({ databaseUrl: url }), {
      provider: new UnusedAuthProvider(),
      withConnection: async (work) => work(wipeClient),
    });

  const authorization = { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` };

  /** The one deletion row for `ACCOUNT`, refusing to guess when there is not exactly one. */
  async function theOnlyDeletionRow() {
    const rows = await recentContentDeletions(observer, { accountId: ACCOUNT, limit: 10 });
    expect(rows).toHaveLength(1);
    return rows[0]!;
  }

  itUnderHangBackstop("DELETE /v1/account/content cancelled between the units leaves nothing half-done, and its retry records every body", async () => {
    const seeded: AccountState = {
      storedBodies: STORED_RESPONSES,
      contentRows: CONTENT_ROWS,
      snapshotMembers: CONTENT_ROWS,
      snapshotMemberCount: CONTENT_ROWS,
      deletionRows: 0,
    };
    const served = app();
    try {
      const { before, whileWaiting, settled, after } = await cancelBetweenTheUnits(() =>
        served.inject({ method: "DELETE", url: "/v1/account/content", headers: authorization }),
      );
      expect(before).toEqual(seeded);

      // **The property.** Before the fix `storedBodies` read 0 here: the bodies had gone in a
      // statement of their own, and nothing recorded them.
      expect(after).toEqual(before);

      // The cancel is Postgres's 57014, which this route answers exactly as it answers §12's own
      // deadline — the `504` whose retry is the next half of this test.
      if (!settled.ok) throw settled.error;
      expect(settled.value.statusCode).toBe(504);
      expect(settled.value.json().error.code).toBe("provider.timeout");

      const retry = await served.inject({
        method: "DELETE",
        url: "/v1/account/content",
        headers: authorization,
      });
      expect(retry.statusCode).toBe(200);
      // **The count the retry records is the real one.** Before the fix it was 0.
      expect(retry.json()).toMatchObject({
        requests_deleted: CONTENT_ROWS,
        stored_responses_deleted: STORED_RESPONSES,
      });
      const row = await theOnlyDeletionRow();
      expect(row.reason).toBe("account_content");
      expect(row.storedResponses).toBe(STORED_RESPONSES);
      expect(row.contentRows).toBe(CONTENT_ROWS);
      expect(row.snapshotRows).toBe(CONTENT_ROWS);
      expect(await accountState()).toEqual({
        storedBodies: 0,
        contentRows: 0,
        snapshotMembers: 0,
        snapshotMemberCount: 0,
        deletionRows: 1,
      });

      // Why: the clear had run and was still inside the waiting transaction, invisible to anyone else.
      expect(whileWaiting).toEqual({ holdsTheClearsLock: true, visibleStoredBodies: STORED_RESPONSES });
    } finally {
      await served.close();
    }
  });

  itUnderHangBackstop("DELETE /v1/account cancelled between the units leaves the wipe whole for the sweep, which records every body", async () => {
    const served = app();
    try {
      const { before, whileWaiting, settled, after } = await cancelBetweenTheUnits(() =>
        served.inject({ method: "DELETE", url: "/v1/account", headers: authorization }),
      );

      // The close committed before the wipe began, by design, so the account row is the one thing
      // that moves; everything the wipe reaches is untouched.
      expect(after).toEqual(before);
      const { rows: closed } = await observer.query<{ closed: boolean }>(
        "SELECT deleted_at IS NOT NULL AS closed FROM sonny.account WHERE id = $1",
        [ACCOUNT],
      );
      expect(closed[0]!.closed).toBe(true);

      // The route catches a failed wipe and answers 204, because the close is committed and the
      // caller can no longer retry; the sweep is what finishes it.
      if (!settled.ok) throw settled.error;
      expect(settled.value.statusCode).toBe(204);

      const swept = await sweepClosedAccountContent(observer, deleteStoredResponsesForAccount);
      expect(swept?.accountId).toBe(ACCOUNT);
      expect(swept?.storedResponses).toBe(STORED_RESPONSES);
      const row = await theOnlyDeletionRow();
      expect(row.reason).toBe("account");
      expect(row.storedResponses).toBe(STORED_RESPONSES);
      expect(row.contentRows).toBe(CONTENT_ROWS);

      expect(whileWaiting).toEqual({ holdsTheClearsLock: true, visibleStoredBodies: STORED_RESPONSES });
    } finally {
      await served.close();
    }
  });

  itUnderHangBackstop("the closed-account sweep cancelled between the units leaves nothing half-done, and its next pass records every body", async () => {
    await observer.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [ACCOUNT]);

    const { before, whileWaiting, settled, after } = await cancelBetweenTheUnits(() =>
      sweepClosedAccountContent(wipeClient, deleteStoredResponsesForAccount),
    );

    expect(after).toEqual(before);
    // Named, so the sweeper defers this account rather than stopping — and the cancel, not something
    // else, is why.
    expect(settled.ok).toBe(false);
    const error = settled.ok ? undefined : settled.error;
    expect(error).toBeInstanceOf(ClosedAccountSweepFailed);
    expect((error as ClosedAccountSweepFailed).accountId).toBe(ACCOUNT);
    expect(((error as ClosedAccountSweepFailed).cause as { code?: string }).code).toBe("57014");

    const next = await sweepClosedAccountContent(wipeClient, deleteStoredResponsesForAccount);
    expect(next?.storedResponses).toBe(STORED_RESPONSES);
    const row = await theOnlyDeletionRow();
    expect(row.reason).toBe("account");
    expect(row.storedResponses).toBe(STORED_RESPONSES);
    expect(row.contentRows).toBe(CONTENT_ROWS);

    expect(whileWaiting).toEqual({ holdsTheClearsLock: true, visibleStoredBodies: STORED_RESPONSES });
  });

  itUnderHangBackstop("DELETE /v1/account/content?before bounds the stored bodies it clears and records by claimed_at", async () => {
    // **The cutoff reaches the clear through `deleteContentForAccount` now**, rather than being handed
    // to it by the route, so it is held here: nothing else in the suite asserted which bodies a
    // bounded wipe takes (SONNY-404's `?before` tests check content and snapshot copies only).
    await observer.query(
      "UPDATE sonny.idempotency_key SET claimed_at = now() - interval '1 hour' WHERE idempotency_key = $1",
      ["audit-row-key-0"],
    );
    const cutoff = new Date(Date.now() - 30 * 60 * 1000);
    const served = app();
    try {
      const response = await served.inject({
        method: "DELETE",
        url: `/v1/account/content?before=${encodeURIComponent(cutoff.toISOString())}`,
        headers: authorization,
      });
      expect(response.statusCode).toBe(200);
      expect(response.json().stored_responses_deleted).toBe(1);

      const { rows } = await observer.query<{ idempotency_key: string }>(
        `SELECT idempotency_key FROM sonny.idempotency_key
          WHERE account_scope = $1 AND response_body IS NOT NULL ORDER BY idempotency_key`,
        [ACCOUNT],
      );
      expect(rows.map((row) => row.idempotency_key)).toEqual(["audit-row-key-1"]);
      expect((await theOnlyDeletionRow()).storedResponses).toBe(1);
    } finally {
      await served.close();
    }
  });
});
