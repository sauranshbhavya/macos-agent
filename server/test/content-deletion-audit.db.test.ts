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
import type { MeteringEvent } from "../src/metering/event.js";
import { writeMeteringEvent } from "../src/metering/store.js";
import {
  afterAllUnderHangBackstop,
  beforeAllUnderHangBackstop,
  beforeEachUnderHangBackstop,
  itUnderHangBackstop,
} from "./support/backstop.js";
import { testConfig } from "./support/config.js";
import { rebuildSchema } from "./support/schema.js";
import { accessTokenFor } from "./support/tokens.js";
import { recordSessionTheGatewayStarted } from "./support/gateway-session.js";
import { WithoutOAuth } from "./support/without-oauth.js";

/**
 * An account wipe and the record of it commit together or not at all (SONNY-436), and the wipe holds
 * the account's idempotency keys only at its very end (PR #242's review, F1).
 *
 * **The defect.** Every account wipe — `DELETE /v1/account/content`, `DELETE /v1/account`, and the
 * closed-account sweep that finishes the second — cleared the account's stored idempotency response
 * bodies as a statement of its own, which committed, and only then opened the transaction that
 * deletes the content and writes the `sonny.content_deletion` row. A cancel between the two left the
 * bodies gone and no row naming them, and the next attempt found nothing left to clear and recorded
 * `stored_responses: 0` beside bodies that had been removed. §12's statement deadline on the content
 * route makes that cancel an ordinary `504` rather than a rare error. The fix hands the clear to
 * `deleteContentForAccount`, which runs it inside its own transaction — last, just before the record,
 * so the key rows it locks are held for milliseconds rather than for the whole wipe.
 *
 * **Every wait is placed by construction rather than by timing.** Another connection, the holder,
 * takes a lock one of the wipe's statements needs. The test polls Postgres's own `pg_stat_activity`
 * until the wipe's backend is waiting on a lock in exactly that statement. The wipe issues its
 * statements one after another on one connection, and nothing but the test can end that wait while
 * the lock is held. Two points are used:
 *
 * - **At the record** (`AT_THE_RECORD`): the holder takes `SHARE` on `sonny.content_deletion`, so the
 *   wipe waits in its `INSERT` there. Every unit — snapshot copies, content, the clear — has run by
 *   then, and only the record is left. The three cancel tests stop the wipe there and cancel it with
 *   `pg_cancel_backend`. That raises Postgres's `57014`, the same code §12's `statement_timeout`
 *   raises, so the content route answers the `504` a real deadline would.
 * - **In the content phase** (`IN_THE_CONTENT_PHASE`): the holder takes `FOR UPDATE` on the account's
 *   content rows, so the wipe waits in its content `DELETE`. It has not reached the clear yet. The
 *   waiter test runs a replay and a metering claim on one of the account's keys from there, and
 *   asserts neither waits.
 *
 * **What each cancel test reads, in a deliberate order.**
 * - First the property the ticket names: after the cancel, every table the wipe reaches is exactly as
 *   it was before the request, and no deletion row exists.
 * - Then the recovery, a retry or the sweep's next pass: it clears and records the real counts and
 *   leaves every table empty.
 * - Last, what the wipe looked like while it waited, which says *why*: it held the write locks of
 *   every unit, the clear's on `sonny.idempotency_key` among them, so all of them were in its open
 *   transaction, and no other connection could see any of it gone.
 *
 * On `main`'s two-unit code the first assertion fails. On the clear-first order this branch had
 * before, the waiter test fails.
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

/** The body every seeded key stores, which a replay has to answer with. */
const STORED_BODY = '{"output_text":"something the user said"}';

/**
 * How long a wait for a backend to reach the point being observed may take before the test says it
 * never got there.
 *
 * **A precondition, and it fails in wording of its own** — `statement-timeout.db.test.ts` carries
 * the reasoning in full: a wait whose only failure signal is the hang backstop can never count as a
 * mutation kill, because that backstop's wording is declared untrusted. It is met in milliseconds on
 * any tree where the work reaches Postgres at all.
 */
const BLOCK_OBSERVED_MS = 10_000;

/**
 * How long the test waits for a held wipe to answer once it is cancelled or released. Thirty seconds,
 * inside the backstop's sixty with `BLOCK_OBSERVED_MS` beside it, for `statement-timeout.db.test.ts`'s
 * reason: this fires first, in its own words, and the backstop never sees it.
 */
const ANSWER_OR_ADMIT_HUNG_MS = 30_000;

/**
 * A lock the holder takes, and the statement the wipe is then seen waiting in.
 *
 * `lock` runs inside the holder's open transaction; `waitsIn` is the start of the wipe's statement
 * text as `pg_stat_activity` shows it while that lock stops it.
 */
interface HoldPoint {
  readonly lock: string;
  readonly waitsIn: string;
}

/** After every unit, before the record. See the header. */
const AT_THE_RECORD: HoldPoint = {
  lock: "LOCK TABLE sonny.content_deletion IN SHARE MODE",
  waitsIn: "INSERT INTO sonny.content_deletion",
};

/** Inside the content phase, before the clear. See the header. */
const IN_THE_CONTENT_PHASE: HoldPoint = {
  lock: `SELECT 1 FROM sonny.retained_content WHERE account_id = '${ACCOUNT}' FOR UPDATE`,
  waitsIn: "DELETE FROM sonny.retained_content",
};

/**
 * The tables a wipe writes, by the name `pg_locks` gives them. Holding `RowExclusiveLock` on one means
 * the wipe's open transaction has written it; the deletion table is the one it has not reached while
 * it waits for the record.
 */
const WIPE_WRITES = [
  "content_deletion",
  "idempotency_key",
  "retained_content",
  "training_snapshot",
  "training_snapshot_member",
];

/** The gate verifies tokens locally, and the account close's drain calls nothing that matters here. */
class UnusedAuthProvider extends WithoutOAuth implements AuthProvider {
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

/** One metered call on `key`, written out in full so a field added to the event fails to compile. */
function meteringEvent(key: string): MeteringEvent {
  return {
    requestId: randomUUID(),
    idempotencyKey: key,
    accountId: ACCOUNT,
    route: "plan",
    provider: "openai",
    failedOver: [],
    model: "a-planning-model",
    inputTokens: 10,
    outputTokens: 2,
    totalTokens: 12,
    tokenSource: "reported",
    imageBytes: null,
    imagePixelWidth: null,
    imagePixelHeight: null,
    imageMediaType: null,
    audioDurationSeconds: null,
    requestBytes: 200,
    responseBytes: 40,
    durationMs: 120,
    upstreamDurationMs: 100,
    outcome: "ok",
    taskId: "task-0",
    sessionId: null,
    sessionIteration: null,
    retention: "standard",
    clientVersion: "1.0.0+412",
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

const EMPTIED_AND_RECORDED: AccountState = {
  storedBodies: 0,
  contentRows: 0,
  snapshotMembers: 0,
  snapshotMemberCount: 0,
  deletionRows: 1,
};

/** What a held wipe looked like from outside, read while it waited. */
interface WhileWaiting {
  /** The tables in `WIPE_WRITES` its open transaction has written, sorted. */
  readonly writeLocks: readonly string[];
  /** What another connection could see of the account at that moment. */
  readonly visible: AccountState;
}

type Settled<T> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly error: unknown };

/** How a replay or a metering claim went while the wipe was held. */
type WaiterOutcome<T> =
  | { readonly kind: "completed"; readonly value: T }
  | { readonly kind: "failed"; readonly error: unknown }
  | { readonly kind: "waited"; readonly query: string };

function settle<T>(work: Promise<T>): Promise<Settled<T>> {
  return work.then(
    (value) => ({ ok: true as const, value }),
    (error: unknown) => ({ ok: false as const, error }),
  );
}

describeDb("an account wipe and the record of it commit together (SONNY-436)", () => {
  /** Seeds, observes, cancels. Never the connection the wipe runs on. */
  let observer: pg.Client;
  /** The only connection the wipe under test runs on, so its backend is the one to watch and cancel. */
  let wipeClient: pg.Client;
  let wipePid: number;
  /** The replay and the metering claim run here, so their backend is the one to watch for a wait. */
  let waiterClient: pg.Client;
  let waiterPid: number;
  /** Takes the lock that stops the wipe at a chosen point. */
  let holder: pg.Client;

  async function connected(): Promise<{ client: pg.Client; pid: number }> {
    const client = new pg.Client({ connectionString: url });
    await client.connect();
    const { rows } = await client.query<{ pid: number }>("SELECT pg_backend_pid() AS pid");
    return { client, pid: rows[0]!.pid };
  }

  beforeAllUnderHangBackstop(async () => {
    observer = new pg.Client({ connectionString: url });
    await observer.connect();
    await rebuildSchema(observer);
    ({ client: wipeClient, pid: wipePid } = await connected());
    ({ client: waiterClient, pid: waiterPid } = await connected());
    holder = new pg.Client({ connectionString: url });
    await holder.connect();
  });
  afterAllUnderHangBackstop(async () => {
    await holder.end();
    await waiterClient.end();
    await wipeClient.end();
    await observer.end();
  });
  beforeEachUnderHangBackstop(async () => {
    await observer.query(
      `TRUNCATE sonny.retained_content, sonny.training_snapshot, sonny.training_snapshot_member,
                sonny.content_deletion, sonny.idempotency_key, sonny.metering_event`,
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
    // Signed in through the gateway, which is what makes the token below one it honours (SONNY-129).
    await recordSessionTheGatewayStarted(observer, SUPABASE_USER, ACCOUNT);
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
        body: Buffer.from(STORED_BODY),
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
   * Start a wipe, stop it at `point`, run `whileHeld` there, and release it.
   *
   * The lock is released in `finally` whatever happens, so a failed precondition cannot leave the
   * next test's wipe waiting on this one's holder. The wipe's own outcome is handed back unawaited:
   * a cancelled wipe answers while the lock is still held, and a released one only afterwards.
   */
  async function withTheWipeHeld<T, R>(
    point: HoldPoint,
    start: () => Promise<T>,
    whileHeld: (running: Promise<Settled<T>>) => Promise<R>,
  ): Promise<{ readonly result: R; readonly running: Promise<Settled<T>> }> {
    await holder.query("BEGIN");
    try {
      await holder.query(point.lock);
      // Settled into a value at once, so a rejection that arrives while the test is still waiting
      // for the lock is held here rather than reported as unhandled.
      const running = settle(start());
      const waiting = await waitUntilTheWipeWaitsIn(point);
      expect(
        waiting,
        `the wipe never reached ${point.waitsIn} while the holder's lock was taken, so there was no point to stop it at`,
      ).toBe(true);
      return { result: await whileHeld(running), running };
    } finally {
      await holder.query("ROLLBACK").catch(() => {});
    }
  }

  /** Stop the wipe after every unit and before the record, cancel it there, and report what was left. */
  async function cancelAtTheRecord<T>(start: () => Promise<T>): Promise<{
    readonly before: AccountState;
    readonly whileWaiting: WhileWaiting;
    readonly settled: Settled<T>;
    readonly after: AccountState;
  }> {
    const before = await accountState();
    const { result } = await withTheWipeHeld(AT_THE_RECORD, start, async (running) => {
      const whileWaiting = await observeTheWaitingWipe();
      const { rows } = await observer.query<{ cancelled: boolean }>(
        "SELECT pg_cancel_backend($1) AS cancelled",
        [wipePid],
      );
      expect(rows[0]!.cancelled).toBe(true);
      const settled = await answeredOrHung(running, "the cancelled wipe");
      // Read while the lock is still held, so nothing but the cancel can have shaped it.
      return { whileWaiting, settled, after: await accountState() };
    });
    return { before, ...result };
  }

  async function answeredOrHung<T>(running: Promise<Settled<T>>, what: string): Promise<Settled<T>> {
    const outcome = await Promise.race([
      running,
      new Promise<"hung">((resolve) => setTimeout(() => resolve("hung"), ANSWER_OR_ADMIT_HUNG_MS).unref()),
    ]);
    if (outcome === "hung") {
      throw new Error(`${what} never answered, so nothing after it is a measurement`);
    }
    return outcome;
  }

  /**
   * Poll Postgres's own view until the wipe's backend is waiting on a lock in `point`'s statement.
   *
   * A progress signal rather than a clock. Bounded, so a wipe that never gets there fails the
   * assertion above in its own words rather than hanging.
   */
  async function waitUntilTheWipeWaitsIn(point: HoldPoint): Promise<boolean> {
    const giveUpAt = Date.now() + BLOCK_OBSERVED_MS;
    for (;;) {
      const { rows } = await observer.query<{ wait: string | null; query: string }>(
        "SELECT wait_event_type AS wait, query FROM pg_stat_activity WHERE pid = $1",
        [wipePid],
      );
      const row = rows[0];
      if (row?.wait === "Lock" && row.query.trimStart().startsWith(point.waitsIn)) return true;
      if (Date.now() >= giveUpAt) return false;
      await new Promise((resolve) => setTimeout(resolve, 10).unref());
    }
  }

  async function observeTheWaitingWipe(): Promise<WhileWaiting> {
    const { rows } = await observer.query<{ locks: string[] }>(
      `SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}') AS locks
         FROM pg_locks l
         JOIN pg_class c ON c.oid = l.relation
         JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE l.pid = $1 AND l.granted AND l.mode = 'RowExclusiveLock'
          AND n.nspname = 'sonny' AND c.relname = ANY($2::text[])`,
      [wipePid, WIPE_WRITES],
    );
    return { writeLocks: rows[0]!.locks, visible: await accountState() };
  }

  /**
   * Run `work` on the waiter's connection while the wipe is held, and say whether it finished or was
   * seen waiting on a lock.
   *
   * **By construction, and no statement limit is set.** The holder's lock is on a table the replay and
   * the metering claim never touch, so the only lock either could wait on is one the held wipe took.
   * While the wipe is held nothing releases it, so a waiter that waits keeps waiting, and the poll is
   * certain to see it. Bounded, so work that neither finishes nor waits fails in its own words.
   */
  async function completesWithoutWaitingOnTheWipe<T>(work: () => Promise<T>): Promise<WaiterOutcome<T>> {
    let settled: Settled<T> | undefined;
    void settle(work()).then((result) => {
      settled = result;
    });
    const giveUpAt = Date.now() + BLOCK_OBSERVED_MS;
    for (;;) {
      if (settled !== undefined) {
        return settled.ok ? { kind: "completed", value: settled.value } : { kind: "failed", error: settled.error };
      }
      const { rows } = await observer.query<{ wait: string | null; query: string }>(
        "SELECT wait_event_type AS wait, query FROM pg_stat_activity WHERE pid = $1",
        [waiterPid],
      );
      const row = rows[0];
      if (row?.wait === "Lock") return { kind: "waited", query: row.query };
      if (Date.now() >= giveUpAt) {
        throw new Error("the waiter neither finished nor was seen waiting on a lock, so nothing was measured");
      }
      await new Promise((resolve) => setTimeout(resolve, 10).unref());
    }
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

  /**
   * Held at the record, the wipe has written every table but the record's, and nobody else sees it.
   * The clear-first order and this one agree here, since both have run every unit by then.
   */
  const waitingAtTheRecord = (before: AccountState): WhileWaiting => ({
    writeLocks: ["idempotency_key", "retained_content", "training_snapshot", "training_snapshot_member"],
    visible: before,
  });

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
      const { before, whileWaiting, settled, after } = await cancelAtTheRecord(() =>
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
      expect(await accountState()).toEqual(EMPTIED_AND_RECORDED);

      // Why: every unit had run, the clear included, and all of it was still inside the waiting
      // transaction, invisible to anyone else.
      expect(whileWaiting).toEqual(waitingAtTheRecord(before));
    } finally {
      await served.close();
    }
  });

  itUnderHangBackstop("DELETE /v1/account cancelled between the units leaves the wipe whole for the sweep, which records every body", async () => {
    const served = app();
    try {
      const { before, whileWaiting, settled, after } = await cancelAtTheRecord(() =>
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
      expect(row.snapshotRows).toBe(CONTENT_ROWS);
      expect(await accountState()).toEqual(EMPTIED_AND_RECORDED);

      expect(whileWaiting).toEqual(waitingAtTheRecord(before));
    } finally {
      await served.close();
    }
  });

  itUnderHangBackstop("the closed-account sweep cancelled between the units leaves nothing half-done, and its next pass records every body", async () => {
    await observer.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [ACCOUNT]);

    const { before, whileWaiting, settled, after } = await cancelAtTheRecord(() =>
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
    expect(row.snapshotRows).toBe(CONTENT_ROWS);
    expect(await accountState()).toEqual(EMPTIED_AND_RECORDED);

    expect(whileWaiting).toEqual(waitingAtTheRecord(before));
  });

  itUnderHangBackstop("a wipe held in its content phase makes neither a replay nor a metering claim on the account's key wait, and still records every body", async () => {
    // **PR #242's review, F1.** With the clear first, the wipe locked this key before its content
    // phase, so both calls below waited on the wipe — past their own ten-second statement bound, a
    // metering event was lost and a replay answered `500`. The clear now runs last.
    //
    // **What the replay answers.** The wipe has not committed, so the replay sees the stored response
    // and answers it: what a replay answers on `main` whenever no clear has committed. On `main`
    // itself a wipe had already committed its clear before this phase, so the same replay there
    // finds the body gone and re-claims the key — the half-done state SONNY-436 exists to remove.
    const key = "audit-row-key-0";
    const event = meteringEvent(key);
    const served = app();
    try {
      const { result, running } = await withTheWipeHeld(
        IN_THE_CONTENT_PHASE,
        () => served.inject({ method: "DELETE", url: "/v1/account/content", headers: authorization }),
        async () => {
          const replay = await completesWithoutWaitingOnTheWipe(() =>
            claimKey(waiterClient, {
              accountScope: ACCOUNT,
              key,
              route: "POST /v1/plan",
              fingerprint: "sha256:aaa",
            }),
          );
          // **The property, asserted as each call returns**, so a waiter still pending cannot sit under
          // the next one on the same connection and be read as that one's wait.
          expect(replay, "the replay waited on the wipe's lock on its key").toMatchObject({ kind: "completed" });
          const metering = await completesWithoutWaitingOnTheWipe(() =>
            writeMeteringEvent(waiterClient, event, key),
          );
          expect(metering, "the metering claim waited on the wipe's lock on its key").toMatchObject({
            kind: "completed",
          });
          return { replay, metering, whileWaiting: await observeTheWaitingWipe() };
        },
      );

      // The replay answered the stored response, and the metering claim was taken and its event written.
      expect(result.replay.kind === "completed" ? result.replay.value : undefined).toMatchObject({
        kind: "replay",
        response: { status: 200 },
      });
      const replayed = result.replay.kind === "completed" ? result.replay.value : undefined;
      expect(replayed?.kind === "replay" ? replayed.response.body.toString("utf8") : undefined).toBe(STORED_BODY);
      expect(result.metering.kind === "completed" ? result.metering.value : undefined).toBe("written");
      const { rows: metered } = await observer.query<{ events: string; claimed: boolean }>(
        `SELECT (SELECT count(*) FROM sonny.metering_event WHERE request_id = $1)::text AS events,
                (SELECT metering_claimed_at IS NOT NULL FROM sonny.idempotency_key
                  WHERE account_scope = $2 AND idempotency_key = $3) AS claimed`,
        [event.requestId, ACCOUNT, key],
      );
      expect(metered[0]).toEqual({ events: "1", claimed: true });

      // **Released, the wipe still takes every body** — the replayed one and the metered one included —
      // and records it, and the metering claim survives the clear as a claim always does.
      const settled = await answeredOrHung(running, "the released wipe");
      if (!settled.ok) throw settled.error;
      expect(settled.value.statusCode).toBe(200);
      expect(settled.value.json()).toMatchObject({
        requests_deleted: CONTENT_ROWS,
        stored_responses_deleted: STORED_RESPONSES,
      });
      const row = await theOnlyDeletionRow();
      expect(row.storedResponses).toBe(STORED_RESPONSES);
      expect(row.snapshotRows).toBe(CONTENT_ROWS);
      expect(await accountState()).toEqual(EMPTIED_AND_RECORDED);
      const { rows: stillClaimed } = await observer.query<{ claimed: boolean }>(
        `SELECT metering_claimed_at IS NOT NULL AS claimed FROM sonny.idempotency_key
          WHERE account_scope = $1 AND idempotency_key = $2`,
        [ACCOUNT, key],
      );
      expect(stillClaimed[0]!.claimed).toBe(true);

      // Why: in its content phase the wipe had written the snapshot copies and was writing the content,
      // and had not touched `sonny.idempotency_key` at all.
      expect(result.whileWaiting.writeLocks).toEqual(["retained_content", "training_snapshot", "training_snapshot_member"]);
    } finally {
      await served.close();
    }
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
