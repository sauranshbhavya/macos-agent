import { randomUUID } from "node:crypto";
import pg from "pg";
import { describe, expect, vi } from "vitest";
import {
  accountSupportView,
  contentForRequest,
  recentContentAccesses,
  recentContentDeletions,
  trainingSnapshots,
} from "../src/content/query.js";
import { contentExpiryFrom, type RetainedContent } from "../src/content/record.js";
import {
  deleteContentForAccount,
  deleteContentForTask,
  expireContentBatch,
  expireSnapshots,
  insertRetainedContent,
  sweepClosedAccountContent,
  taskOwnership,
} from "../src/content/store.js";
import { sweepExpiredContent } from "../src/content/expiry.js";
import {
  buildTrainingSnapshot,
  snapshotsHoldingTask,
  SNAPSHOT_MEMBER_SELECT,
} from "../src/content/snapshot.js";
import { rebuildSchema } from "./support/schema.js";
import {
  claimKey,
  completeClaim,
  deleteStoredResponsesForAccount,
} from "../src/idempotency/store.js";
import type { MeteringEvent } from "../src/metering/event.js";
import { insertMeteringEvent } from "../src/metering/store.js";
import { reportAccount, reportContent, reportDeletions } from "../src/support.js";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import { testConfig } from "./support/config.js";
import { accessTokenFor } from "./support/tokens.js";
import { afterAllUnderHangBackstop, afterEachUnderHangBackstop, beforeAllUnderHangBackstop, beforeEachUnderHangBackstop, itUnderHangBackstop } from "./support/backstop.js";

/** The gate verifies tokens locally, so no route driven here ever calls a provider. */
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

/**
 * Contract §10's tables against a real Postgres (SONNY-134).
 *
 * `content.test.ts` proves the *decisions* — which requests produce a row, what each field is set
 * to, that an incognito run reaches no store — against a store the test controls. This file proves
 * everything that is not TypeScript: the two clocks, an expiry that actually deletes, a delete that
 * reaches training snapshots, the CHECK and the trigger that make two of this ticket's guarantees
 * structural rather than procedural, and the SQL the support lookup is made of. A fake would prove
 * nothing about any of it, and three of them are the guarantees this whole ticket exists for.
 *
 * **Every age here is produced by back-dating a row, never by waiting** — the rule
 * `metering.db.test.ts` and `idempotency.db.test.ts` both state, and `CLAUDE.md` records as the
 * shape that manufactures false results. Where a test asserts that a timestamp did *not* move, the
 * row is back-dated a measurable distance first, because these tables encode `timestamptz` and two
 * writes in one second are indistinguishable.
 */

/**
 * A switch that makes `isStorable` wrong on purpose, for the one property no ordinary test can
 * reach (PR #148's cycle-2, G3).
 *
 * **F3's guarantee is composite and only half of it was pinned.** "If something above this is ever
 * wrong, the insert is refused rather than served" needs two things to be true: the store must bind
 * the retention it was given, and **the hook must give it the value it checked rather than a
 * literal**. The two existing pins call `insertRetainedContent` directly, so they hold the store
 * half and say nothing about the hook — a later simplification of `retention: declared` to
 * `retention: "standard"` would keep every one of them green while quietly restoring the defect,
 * because with a *correct* guard the two are indistinguishable at run time.
 *
 * So the guard is made incorrect, which is the only way the difference becomes observable, and the
 * assertion is that the database refuses the row. Off by default: every other test in this file runs
 * against the real predicate.
 */
const guard = vi.hoisted(() => ({ forceStorable: false }));
vi.mock("../src/content/record.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/content/record.js")>();
  return {
    ...actual,
    isStorable: (retention: Parameters<typeof actual.isStorable>[0]) =>
      guard.forceStorable || actual.isStorable(retention),
  };
});

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const CONSENTING = "1a1d0c8e-1c5a-4a9f-9f6b-2b6f5f2a7701";
const DECLINED = "2a1d0c8e-1c5a-4a9f-9f6b-2b6f5f2a7702";
const NEVER_ASKED = "3a1d0c8e-1c5a-4a9f-9f6b-2b6f5f2a7703";
const OTHER = "4a1d0c8e-1c5a-4a9f-9f6b-2b6f5f2a7704";

const RETENTION_DAYS = 30;

/**
 * One retained call, complete, with every field carrying a value a test can recognise.
 *
 * Written out in full rather than built from partial defaults, so a column added to the table
 * without being added here fails to compile — `RetainedContent` is the shared shape and the insert
 * binds every one of its fields, the same discipline `metering.db.test.ts` applies to §11's row.
 */
function content(overrides: Partial<RetainedContent> = {}): RetainedContent {
  return {
    requestId: randomUUID(),
    accountId: CONSENTING,
    taskId: "task-1",
    sessionId: "session-1",
    sessionIteration: 1,
    route: "screen.analyze",
    // Bound explicitly by the writer since PR #148's F3, so the fixture has to carry it — and a
    // test that wants to prove the CHECK is a backstop overrides it to `"none"` and expects a
    // constraint violation from the real writer rather than from a hand-written statement.
    retention: "standard",
    expiresAt: contentExpiryFrom(new Date(), RETENTION_DAYS),
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
    ...overrides,
  };
}

function meteringEvent(overrides: Partial<MeteringEvent> = {}): MeteringEvent {
  return {
    requestId: randomUUID(),
    idempotencyKey: null,
    accountId: CONSENTING,
    route: "screen.analyze",
    provider: "vision",
    failedOver: [],
    model: "a-vision-model",
    inputTokens: 1900,
    outputTokens: 40,
    totalTokens: 1940,
    tokenSource: "reported",
    imageBytes: 1226,
    imagePixelWidth: 2406,
    imagePixelHeight: 1354,
    imageMediaType: "image/jpeg",
    audioDurationSeconds: null,
    requestBytes: 1635,
    responseBytes: 412,
    durationMs: 4218,
    upstreamDurationMs: 4100,
    outcome: "ok",
    taskId: "task-1",
    sessionId: "session-1",
    sessionIteration: 1,
    retention: "standard",
    clientVersion: "1.0.0+412",
    ...overrides,
  };
}

describeDb("the content store, its clocks, and what reaches training", () => {
  let client: pg.Client;

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await rebuildSchema(client);
  });
  afterAllUnderHangBackstop(async () => {
    await client.end();
  });
  beforeEachUnderHangBackstop(async () => {
    await client.query(
      `TRUNCATE sonny.retained_content, sonny.training_snapshot,
                sonny.training_snapshot_member, sonny.content_deletion,
                sonny.content_access, sonny.metering_event, sonny.idempotency_key`,
    );
    // `sonny.identity` cascades from the account, so the order matters and the delete is not a
    // TRUNCATE: other database suites in this run share the schema.
    await client.query("DELETE FROM sonny.identity WHERE account_id = ANY($1::uuid[])", [
      [CONSENTING, DECLINED, NEVER_ASKED, OTHER],
    ]);
    await client.query("DELETE FROM sonny.account WHERE id = ANY($1::uuid[])", [
      [CONSENTING, DECLINED, NEVER_ASKED, OTHER],
    ]);
    await client.query(
      `INSERT INTO sonny.account (id, training_consent, training_consent_updated_at) VALUES
         ($1, true,  now()),
         ($2, false, now()),
         ($3, false, NULL),
         ($4, true,  now())`,
      [CONSENTING, DECLINED, NEVER_ASKED, OTHER],
    );
  });

  const contentRows = async (): Promise<Record<string, unknown>[]> => {
    const { rows } = await client.query<Record<string, unknown>>(
      // Named columns rather than `SELECT *`, which this server has none of anywhere — §10.2's own
      // checkable claim about `training_consent` depends on that staying true.
      `SELECT request_id, account_id::text AS account_id, task_id, session_id, session_iteration,
              route, occurred_at, expires_at, retention, provider, provider_request_id,
              request_text, voice_audio, voice_audio_media_type, voice_audio_filename,
              screenshot, screenshot_media_type, response_status, response_content_type,
              response_body, provider_error_status, provider_error_body
         FROM sonny.retained_content ORDER BY occurred_at, request_id`,
    );
    return rows;
  };

  describe("the shape §10 asks for", () => {
    itUnderHangBackstop("stores every content kind, and names voice audio as its own column", async () => {
      // §10.3 requires voice audio to be named explicitly in what is stored. This asserts the
      // *column set*, so a redesign that folded the four kinds into one opaque blob fails here
      // rather than passing a review.
      const { rows: columns } = await client.query<{ column_name: string }>(
        `SELECT column_name FROM information_schema.columns
          WHERE table_schema = 'sonny' AND table_name = 'retained_content'
          ORDER BY column_name`,
      );
      const names = columns.map((column) => column.column_name);
      expect(names).toContain("voice_audio");
      expect(names).toContain("voice_audio_media_type");
      expect(names).toContain("screenshot");
      expect(names).toContain("request_text");
      expect(names).toContain("response_body");
      expect(names).toContain("provider_error_body");
      expect(names).toContain("provider_request_id");
    });

    itUnderHangBackstop("round-trips voice audio and a screenshot as bytes", async () => {
      const recording = Buffer.from([0x00, 0x01, 0xff, 0x7f, 0x00]);
      await insertRetainedContent(
        client,
        content({
          route: "transcription",
          sessionId: null,
          sessionIteration: null,
          screenshot: null,
          screenshotMediaType: null,
          voiceAudio: recording,
          voiceAudioMediaType: "audio/mp4",
          voiceAudioFilename: "dictation.m4a",
        }),
      );
      const row = (await contentRows())[0]!;
      // Byte-identical, including the NUL and the high byte — a `text` column would have destroyed
      // both, which is why this asserts the bytes rather than a length.
      expect(row["voice_audio"]).toEqual(recording);
      expect(row["voice_audio_filename"]).toBe("dictation.m4a");
    });

    itUnderHangBackstop("keeps a provider error body and the provider's own request id", async () => {
      await insertRetainedContent(
        client,
        content({
          providerErrorStatus: 400,
          providerErrorBody: '{"error":{"message":"rejected prompt: open the invoice"}}',
          providerRequestId: "req_openai_7781",
        }),
      );
      const row = (await contentRows())[0]!;
      expect(row["provider_error_body"]).toContain("open the invoice");
      expect(row["provider_request_id"]).toBe("req_openai_7781");
    });

    itUnderHangBackstop("writes one row per request id and never two", async () => {
      const requestId = randomUUID();
      await insertRetainedContent(client, content({ requestId }));
      // The second writer in `content/hook.ts` losing its race, or a retry of the insert.
      await insertRetainedContent(client, content({ requestId, taskId: "a-different-task" }));
      const rows = await contentRows();
      expect(rows).toHaveLength(1);
      expect(rows[0]!["task_id"]).toBe("task-1");
    });
  });

  describe("an incognito run cannot be stored, whatever the caller believes", () => {
    itUnderHangBackstop("refuses a row that says retention none, at the database", async () => {
      // **This is the guarantee, not a belt-and-braces check.** §10.1: "Enforced where the storing
      // happens, not at the call site." `content/hook.ts` refuses first; this is what is still true
      // when something above it is wrong, and it is the reason the redundant column exists.
      await expect(
        client.query(
          `INSERT INTO sonny.retained_content
             (request_id, account_id, route, expires_at, retention)
           VALUES ($1, $2, 'plan', now() + interval '30 days', 'none')`,
          [randomUUID(), CONSENTING],
        ),
      ).rejects.toThrow(/retention/);
      expect(await contentRows()).toHaveLength(0);
    });

    itUnderHangBackstop("cannot be reached by a snapshot build with every filter removed", async () => {
      // **§10.1's second rule, driven rather than described**: "structurally excluded from training
      // snapshots, not filtered by a query. If an incognito run can reach a snapshot because
      // someone dropped a WHERE clause, the guarantee is not one."
      //
      // The account here *has* consented, so consent is not what keeps the incognito run out. The
      // run is metered — its usage is in `sonny.metering_event` — and simply has no content row for
      // any query to find. Then the real builder's own statement is run with its entire WHERE
      // clause deleted, which is the strongest form of "somebody dropped the filter".
      await insertMeteringEvent(
        client,
        meteringEvent({ taskId: "incognito-task", retention: "none" }),
      );
      await insertRetainedContent(client, content({ taskId: "kept-task" }));

      const { rows } = await client.query<{ snapshot_id: string }>(
        `INSERT INTO sonny.training_snapshot (label, builder_version)
         VALUES ('unfiltered', 'test') RETURNING snapshot_id::text AS snapshot_id`,
      );
      const snapshotId = rows[0]!.snapshot_id;
      await client.query(
        `INSERT INTO sonny.training_snapshot_member
           (snapshot_id, content_id, account_id, task_id, request_id, route, source_occurred_at,
            request_text, voice_audio, voice_audio_media_type, voice_audio_filename, screenshot,
            screenshot_media_type, response_status, response_content_type, response_body,
            provider_error_status, provider_error_body)
         ${SNAPSHOT_MEMBER_SELECT}`,
        [snapshotId],
      );

      const { rows: members } = await client.query<{ task_id: string | null }>(
        "SELECT task_id FROM sonny.training_snapshot_member WHERE snapshot_id = $1",
        [snapshotId],
      );
      // The unfiltered build took everything there was, which is the point: it took one row, and
      // the incognito task is not it.
      expect(members.map((member) => member.task_id)).toEqual(["kept-task"]);
      // And the usage survived, because incognito changes what is stored and never what is billed.
      const { rows: metered } = await client.query<{ task_id: string }>(
        "SELECT task_id FROM sonny.metering_event WHERE task_id = 'incognito-task'",
      );
      expect(metered).toHaveLength(1);
    });
  });

  describe("the second storing place: sonny.idempotency_key", () => {
    /**
     * The whole app over this connection, with a stubbed provider so a route can actually succeed.
     *
     * **A successful response is required and this is not a detail** (PR #148's review, F1/F5). With
     * no credential the plan route answers `502 provider.unavailable`, which is one of §9.3's
     * retryable codes and is therefore *released* rather than stored — so a test built on it would
     * have found an empty `response_body` and passed whether or not the incognito guard existed.
     */
    const CREDENTIALS = [{ provider: "openai" as const, keys: ["sk-test-openai-key"] }];
    const SUPABASE_USER = "6f6c2c4e-8f2a-4a0f-9a11-2b6f5f2a7766";

    const app = () =>
      buildApp(testConfig({ databaseUrl: url, credentials: CREDENTIALS }), {
        provider: new UnusedAuthProvider(),
        withConnection: async (work) => work(client),
      });

    beforeEachUnderHangBackstop(async () => {
      await client.query(
        `INSERT INTO sonny.identity (account_id, provider, subject, link_method, supabase_user_id)
         VALUES ($1, 'email', $2, 'primary', $3)`,
        [CONSENTING, "second-store@example.test", SUPABASE_USER],
      );
      vi.stubGlobal("fetch", async () =>
        new Response(
          JSON.stringify({
            output_text: '{"secret":"THE-MODEL-REPLY"}',
            usage: { input_tokens: 10, output_tokens: 2, total_tokens: 12 },
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
      );
    });
    afterEachUnderHangBackstop(async () => {
      vi.unstubAllGlobals();
    });

    const plan = async (retention: "standard" | "none", key: string) =>
      app().inject({
        method: "POST",
        url: "/v1/plan",
        headers: {
          authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}`,
          "idempotency-key": key,
        },
        payload: {
          task_id: "task-second-store",
          retention,
          messages: [{ role: "user", text: "Open Safari" }],
          response_schema_name: "agent_plan",
          response_schema: { type: "object" },
        },
      });

    const storedBody = async (key: string): Promise<string | null> => {
      const { rows } = await client.query<{ state: string; body: Buffer | null }>(
        `SELECT state, response_body AS body FROM sonny.idempotency_key
          WHERE account_scope = $1 AND idempotency_key = $2`,
        [CONSENTING, key],
      );
      if (rows.length === 0) throw new Error("no idempotency row at all — the claim should survive");
      return rows[0]!.body === null ? null : rows[0]!.body.toString("utf8");
    };

    itUnderHangBackstop("keeps no response body for an incognito call, and keeps the row", async () => {
      // The measured defect, as a test. Before the fix this row's `response_body` held the model's
      // reply verbatim — outside the content clock, outside consent, and outside what a per-task
      // delete can reach.
      const key = randomUUID();
      const response = await plan("none", key);
      expect(response.statusCode).toBe(200);
      expect(response.body).toContain("THE-MODEL-REPLY");

      expect(await storedBody(key)).toBeNull();
      // `retained_content` is empty too, which is the guarantee the three layers already had.
      expect(await contentRows()).toHaveLength(0);
      // And the call is still metered, because incognito changes what is stored and not what is
      // billed — the row that survives is what makes that at-most-once.
      const { rows: metered } = await client.query<{ count: string }>(
        "SELECT count(*)::text AS count FROM sonny.metering_event WHERE task_id = 'task-second-store'",
      );
      expect(metered[0]!.count).toBe("1");
    });

    itUnderHangBackstop("keeps a standard call's response body, so the guard is not simply off", async () => {
      const key = randomUUID();
      await plan("standard", key);
      expect(await storedBody(key)).toContain("THE-MODEL-REPLY");
    });
  });

  describe("the retention CHECK is a backstop the production writer can actually trip", () => {
    itUnderHangBackstop("refuses an incognito row written through the real writer, not just a hand-written one", async () => {
      // **PR #148's F3.** The writer omitted the column, so every insert took the table's default
      // and the CHECK could only ever refuse a statement the gateway cannot emit. Now the declared
      // value is bound, so a wrong `isStorable` one layer up becomes a constraint violation.
      await expect(
        insertRetainedContent(client, content({ retention: "none" })),
      ).rejects.toThrow(/retention/);
      expect(await contentRows()).toHaveLength(0);
    });

    itUnderHangBackstop("refuses a row that declared nothing, which must not be stored either", async () => {
      // §2.4.2 at the storage layer, as a constraint rather than only as a guard: an explicit NULL
      // against a NOT NULL column with no default.
      await expect(
        insertRetainedContent(client, content({ retention: undefined })),
      ).rejects.toThrow(/retention/);
      expect(await contentRows()).toHaveLength(0);
    });

    itUnderHangBackstop("stores the declared value rather than a default, so the column is not decoration", async () => {
      await insertRetainedContent(client, content());
      expect((await contentRows())[0]!["retention"]).toBe("standard");
    });

    itUnderHangBackstop("refuses an incognito insert the HOOK sends when the guard above it is wrong", async () => {
      // **The hook-side half of F3's composite property** (PR #148's cycle-2, G3). The two tests
      // above drive the store directly and hold the store's half; this drives a real request through
      // the real app with `isStorable` forced true, which is the only way "if something above this
      // is ever wrong" becomes a state a test can be in.
      //
      // **What makes it fail on a hook simplification:** with the guard defeated the hook proceeds
      // to write. Passing the *declared* value sends `'none'` and the CHECK refuses it — no row, and
      // a logged failure. Passing a `"standard"` literal would store the incognito call instead, so
      // this test goes red on exactly the change no behavioural test can otherwise see.
      const SUPABASE_USER = "4f6c2c4e-8f2a-4a0f-9a11-2b6f5f2a7744";
      await client.query(
        `INSERT INTO sonny.identity (account_id, provider, subject, link_method, supabase_user_id)
         VALUES ($1, 'email', $2, 'primary', $3)`,
        [CONSENTING, "guard-failure@example.test", SUPABASE_USER],
      );
      vi.stubGlobal("fetch", async () =>
        new Response(
          JSON.stringify({ output_text: '{"steps":[]}', usage: { input_tokens: 1, output_tokens: 1 } }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
      );
      // The app's own log, captured, so the refusal is asserted rather than inferred from an absence.
      // An empty table proves nothing on its own: a hook that refused correctly leaves one too.
      const logged: string[] = [];
      const logStream = {
        write: (line: string) => {
          logged.push(line);
          return true;
        },
      } as unknown as NodeJS.WritableStream;

      const app = buildApp(
        testConfig({
          databaseUrl: url,
          credentials: [{ provider: "openai", keys: ["sk-test-openai-key"] }],
          logLevel: "error",
        }),
        { provider: new UnusedAuthProvider(), withConnection: async (work) => work(client) },
        { logStream },
      );

      guard.forceStorable = true;
      try {
        const response = await app.inject({
          method: "POST",
          url: "/v1/plan",
          headers: {
            authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}`,
            "idempotency-key": randomUUID(),
          },
          payload: {
            task_id: "guard-failure-task",
            retention: "none",
            messages: [{ role: "user", text: "Open Safari" }],
            response_schema_name: "agent_plan",
            response_schema: { type: "object" },
          },
        });
        await app.contentWritesSettled();
        // The caller is unaffected — a refused retention write never fails a response.
        expect(response.statusCode).toBe(200);
      } finally {
        guard.forceStorable = false;
        vi.unstubAllGlobals();
      }

      expect(await contentRows()).toHaveLength(0);
      const refusal = logged.join("");
      expect(refusal).toContain("content could not be retained for this request");
      // Named, so the row was refused by the retention constraint and not by something incidental.
      expect(refusal).toContain("retention");
    });
  });

  describe("training consent", () => {
    itUnderHangBackstop("takes only consenting accounts, and excludes one whose consent was never written", async () => {
      await insertRetainedContent(client, content({ accountId: CONSENTING, taskId: "yes" }));
      await insertRetainedContent(client, content({ accountId: DECLINED, taskId: "no" }));
      await insertRetainedContent(client, content({ accountId: NEVER_ASKED, taskId: "never" }));

      const built = await buildTrainingSnapshot(client, { label: "corpus-1" });
      expect(built.memberCount).toBe(1);
      const { rows } = await client.query<{ task_id: string; account_id: string }>(
        "SELECT task_id, account_id::text AS account_id FROM sonny.training_snapshot_member",
      );
      expect(rows).toEqual([{ task_id: "yes", account_id: CONSENTING }]);
    });

    itUnderHangBackstop("refuses a member for a non-consenting account even when the join is gone", async () => {
      // The second layer, and the reason there are two: training on the content of a user who did
      // not consent is not a defect that can be repaired afterwards, and one predicate in one
      // statement is a thin thing to rest that on.
      await insertRetainedContent(client, content({ accountId: DECLINED }));
      const { rows } = await client.query<{ snapshot_id: string }>(
        `INSERT INTO sonny.training_snapshot (label, builder_version)
         VALUES ('no-join', 'test') RETURNING snapshot_id::text AS snapshot_id`,
      );
      await expect(
        client.query(
          `INSERT INTO sonny.training_snapshot_member
             (snapshot_id, content_id, account_id, request_id, route, source_occurred_at)
           VALUES ($1, gen_random_uuid(), $2, 'r', 'plan', now())`,
          [rows[0]!.snapshot_id, DECLINED],
        ),
      ).rejects.toThrow(/training consent/);
    });

    itUnderHangBackstop("excludes a closed account even though its consent still says granted", async () => {
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [OTHER]);
      await insertRetainedContent(client, content({ accountId: OTHER, taskId: "closing" }));
      const built = await buildTrainingSnapshot(client, { label: "corpus-2" });
      expect(built.memberCount).toBe(0);
    });
  });

  describe("the two clocks", () => {
    itUnderHangBackstop("deletes content past its window and leaves the usage for the same call", async () => {
      // §10.3's whole point, as one test: the content goes, the record of what it cost does not.
      const requestId = randomUUID();
      await insertRetainedContent(client, content({ requestId }));
      await insertMeteringEvent(client, meteringEvent({ requestId }));
      await client.query(
        `UPDATE sonny.retained_content
            SET occurred_at = now() - interval '31 days', expires_at = now() - interval '1 day'`,
      );

      expect(await expireContentBatch(client, 500)).toBe(1);
      expect(await contentRows()).toHaveLength(0);
      const { rows } = await client.query<{ count: string }>(
        "SELECT count(*)::text AS count FROM sonny.metering_event WHERE request_id = $1",
        [requestId],
      );
      expect(rows[0]!.count).toBe("1");
    });

    itUnderHangBackstop("leaves content that has not reached its window", async () => {
      // The other direction, so the sweep is not merely "deletes everything".
      await insertRetainedContent(client, content());
      await client.query("UPDATE sonny.retained_content SET occurred_at = now() - interval '29 days'");
      expect(await expireContentBatch(client, 500)).toBe(0);
      expect(await contentRows()).toHaveLength(1);
    });

    itUnderHangBackstop("records what an expiry sweep took, which is what makes the clock observable", async () => {
      await insertRetainedContent(client, content());
      await client.query("UPDATE sonny.retained_content SET expires_at = now() - interval '1 day'");
      await expireContentBatch(client, 500);

      const deletions = await recentContentDeletions(client, { limit: 10 });
      expect(deletions).toHaveLength(1);
      expect(deletions[0]!.reason).toBe("expiry");
      expect(deletions[0]!.contentRows).toBe(1);
      // No account: a sweep spans them by construction.
      expect(deletions[0]!.accountId).toBeNull();
    });

    itUnderHangBackstop("clears a stored response past its window, on the sweep this branch built", async () => {
      // **PR #148's F2.** `pruneExpiredResponses` had no production call site, so three sentences on
      // this branch claimed a residual was "bounded by that table's own twenty-four hours" while
      // nothing enforced the bound. Measured then: a body back-dated thirty days survived a full
      // sweep. This is that measurement as a test, and it is on `sweepExpiredContent` rather than on
      // the prune directly — the defect was never in the function, it was that nothing called it.
      const key = "prune-me";
      const claimed = await claimKey(client, {
        accountScope: CONSENTING,
        key,
        route: "POST /v1/plan",
        fingerprint: "sha256:aaa",
      });
      if (claimed.kind !== "claimed") throw new Error("the key was not claimable");
      await completeClaim(
        client,
        { accountScope: CONSENTING, key, token: claimed.token },
        {
          status: 200,
          body: Buffer.from('{"output_text":"something the user said"}'),
          contentType: "application/json",
          requestId: "r",
        },
      );
      await client.query(
        "UPDATE sonny.idempotency_key SET response_expires_at = now() - interval '30 days'",
      );

      const swept = await sweepExpiredContent(client);
      expect(swept.storedResponses).toBe(1);

      const { rows } = await client.query<{ has_body: boolean; claimed: boolean }>(
        `SELECT response_body IS NOT NULL AS has_body, metering_claimed_at IS NOT NULL AS claimed
           FROM sonny.idempotency_key WHERE idempotency_key = $1`,
        [key],
      );
      // The payload is gone and **the row is not**, which is the whole reason this is a prune rather
      // than a delete: the row carries the claim that makes §9.2's metering guarantee true.
      expect(rows[0]!.has_body).toBe(false);
    });

    itUnderHangBackstop("leaves a stored response still inside its window", async () => {
      // The other direction, so the prune is not merely "clears everything it can reach".
      const key = "keep-me";
      const claimed = await claimKey(client, {
        accountScope: CONSENTING,
        key,
        route: "POST /v1/plan",
        fingerprint: "sha256:aaa",
      });
      if (claimed.kind !== "claimed") throw new Error("the key was not claimable");
      await completeClaim(
        client,
        { accountScope: CONSENTING, key, token: claimed.token },
        { status: 200, body: Buffer.from("{}"), contentType: "application/json", requestId: "r" },
      );

      const swept = await sweepExpiredContent(client);
      expect(swept.storedResponses).toBe(0);
      const { rows } = await client.query<{ has_body: boolean }>(
        "SELECT response_body IS NOT NULL AS has_body FROM sonny.idempotency_key WHERE idempotency_key = $1",
        [key],
      );
      expect(rows[0]!.has_body).toBe(true);
    });

    itUnderHangBackstop("writes no record for a sweep that found nothing", async () => {
      // A timer that recorded every pass would bury the passes that did something under thousands
      // that did not, and the log line is where "the timer fired" is answered.
      expect(await expireContentBatch(client, 500)).toBe(0);
      expect(await recentContentDeletions(client, { limit: 10 })).toHaveLength(0);
    });

    itUnderHangBackstop("takes more than one batch when there is more than one batch to take", async () => {
      for (let index = 0; index < 3; index += 1) {
        await insertRetainedContent(client, content({ taskId: `task-${index}` }));
      }
      await client.query("UPDATE sonny.retained_content SET expires_at = now() - interval '1 day'");
      // A batch size of one, so the loop in `sweepExpiredContent` has to run more than once for the
      // table to empty — which is the property, rather than "the sweep deleted three rows".
      expect(await expireContentBatch(client, 1)).toBe(1);
      expect(await contentRows()).toHaveLength(2);
      const swept = await sweepExpiredContent(client);
      expect(swept.contentRows).toBe(2);
      expect(await contentRows()).toHaveLength(0);
    });

    itUnderHangBackstop("leaves a snapshot alone until it reaches a clock of its own", async () => {
      await insertRetainedContent(client, content());
      const built = await buildTrainingSnapshot(client, { label: "no-clock" });
      expect(built.memberCount).toBe(1);
      // Every snapshot this branch builds carries no expiry unless one is asked for, because
      // §10.3 names no number and no founder has set one. NULL is skipped, not treated as expired.
      expect(await expireSnapshots(client)).toBe(0);
      expect(await trainingSnapshots(client)).toHaveLength(1);

      await client.query("UPDATE sonny.training_snapshot SET expires_at = now() - interval '1 day'");
      expect(await expireSnapshots(client)).toBe(1);
      expect(await trainingSnapshots(client)).toHaveLength(0);
      // The members went with it, and the content it was copied from did not.
      const { rows } = await client.query<{ count: string }>(
        "SELECT count(*)::text AS count FROM sonny.training_snapshot_member",
      );
      expect(rows[0]!.count).toBe("0");
      expect(await contentRows()).toHaveLength(1);
    });
  });

  describe("a snapshot holds a copy, not a pointer", () => {
    itUnderHangBackstop("survives the content it was built from expiring", async () => {
      // The reason a member copies rather than references, in one test. If this ever fails, the two
      // clocks have collapsed into one and a training corpus quietly empties at thirty days.
      const recording = Buffer.from("the-user-said-something");
      await insertRetainedContent(
        client,
        content({ route: "transcription", voiceAudio: recording, screenshot: null }),
      );
      await buildTrainingSnapshot(client, { label: "corpus-3" });

      await client.query("UPDATE sonny.retained_content SET expires_at = now() - interval '1 day'");
      expect(await expireContentBatch(client, 500)).toBe(1);
      expect(await contentRows()).toHaveLength(0);

      const { rows } = await client.query<{ voice_audio: Buffer; content_id: string }>(
        "SELECT voice_audio, content_id::text AS content_id FROM sonny.training_snapshot_member",
      );
      expect(rows).toHaveLength(1);
      expect(rows[0]!.voice_audio).toEqual(recording);
      // And the lineage still names the row it came from, which no longer exists — which is what
      // makes a deletion request traceable after the live store has moved on.
      expect(rows[0]!.content_id).toMatch(/^[0-9a-f-]{36}$/);
    });

    itUnderHangBackstop("records the window and the routes that selected it", async () => {
      await insertRetainedContent(client, content({ route: "plan", taskId: "in-window" }));
      await insertRetainedContent(client, content({ route: "search", taskId: "wrong-route" }));
      const since = new Date(Date.now() - 60 * 60 * 1000);
      await buildTrainingSnapshot(client, { label: "corpus-4", since, routes: ["plan"] });

      const [snapshot] = await trainingSnapshots(client);
      expect(snapshot!.routes).toEqual(["plan"]);
      expect(snapshot!.memberCount).toBe(1);
      expect(snapshot!.sealedAt).not.toBeNull();
      const { rows } = await client.query<{ task_id: string }>(
        "SELECT task_id FROM sonny.training_snapshot_member",
      );
      expect(rows.map((row) => row.task_id)).toEqual(["in-window"]);
    });

    itUnderHangBackstop("honours the window's bounds rather than taking everything", async () => {
      await insertRetainedContent(client, content({ taskId: "old" }));
      await client.query("UPDATE sonny.retained_content SET occurred_at = now() - interval '10 days'");
      await insertRetainedContent(client, content({ taskId: "new" }));

      await buildTrainingSnapshot(client, {
        label: "corpus-5",
        since: new Date(Date.now() - 24 * 60 * 60 * 1000),
      });
      const { rows } = await client.query<{ task_id: string }>(
        "SELECT task_id FROM sonny.training_snapshot_member",
      );
      expect(rows.map((row) => row.task_id)).toEqual(["new"]);
    });
  });

  describe("delete by task", () => {
    itUnderHangBackstop("removes the content, reaches the snapshots, and says which ones", async () => {
      await insertRetainedContent(client, content({ taskId: "doomed" }));
      await insertRetainedContent(client, content({ taskId: "kept" }));
      const built = await buildTrainingSnapshot(client, { label: "corpus-6" });
      expect(built.memberCount).toBe(2);

      const outcome = await deleteContentForTask(client, {
        accountId: CONSENTING,
        taskId: "doomed",
      });
      expect(outcome.contentRows).toBe(1);
      expect(outcome.snapshotRows).toBe(1);
      expect(outcome.snapshotsTouched).toEqual([built.snapshotId]);

      // The live store kept the other task.
      const remaining = await contentRows();
      expect(remaining.map((row) => row["task_id"])).toEqual(["kept"]);
      // And so did the snapshot, whose count was corrected rather than left describing a
      // membership it no longer has.
      expect((await trainingSnapshots(client))[0]!.memberCount).toBe(1);
      expect(await snapshotsHoldingTask(client, { accountId: CONSENTING, taskId: "doomed" })).toEqual(
        [],
      );
    });

    itUnderHangBackstop("records the deletion with the snapshots it touched", async () => {
      // §4.6's traceability, read back the way a founder would read it.
      await insertRetainedContent(client, content({ taskId: "doomed" }));
      const built = await buildTrainingSnapshot(client, { label: "corpus-7" });
      await deleteContentForTask(client, { accountId: CONSENTING, taskId: "doomed" });

      const deletions = await recentContentDeletions(client, { limit: 10 });
      expect(deletions[0]!.reason).toBe("task");
      expect(deletions[0]!.taskId).toBe("doomed");
      expect(deletions[0]!.snapshotsTouched).toEqual([built.snapshotId]);
      expect(reportDeletions(deletions)).toContain(built.snapshotId);
    });

    itUnderHangBackstop("records a delete that found nothing, because that is a success", async () => {
      const outcome = await deleteContentForTask(client, {
        accountId: CONSENTING,
        taskId: "never-existed",
      });
      expect(outcome.contentRows).toBe(0);
      expect(await recentContentDeletions(client, { limit: 10 })).toHaveLength(1);
    });

    itUnderHangBackstop("never reaches another account's rows even when a task id collides", async () => {
      await insertRetainedContent(client, content({ accountId: CONSENTING, taskId: "shared" }));
      await insertRetainedContent(client, content({ accountId: OTHER, taskId: "shared" }));
      const outcome = await deleteContentForTask(client, {
        accountId: CONSENTING,
        taskId: "shared",
      });
      expect(outcome.contentRows).toBe(1);
      const remaining = await contentRows();
      expect(remaining).toHaveLength(1);
      expect(remaining[0]!["account_id"]).toBe(OTHER);
    });

    itUnderHangBackstop("leaves the metering event, because usage is on the other clock", async () => {
      await insertRetainedContent(client, content({ taskId: "doomed" }));
      await insertMeteringEvent(client, meteringEvent({ taskId: "doomed" }));
      await deleteContentForTask(client, { accountId: CONSENTING, taskId: "doomed" });
      const { rows } = await client.query<{ count: string }>(
        "SELECT count(*)::text AS count FROM sonny.metering_event WHERE task_id = 'doomed'",
      );
      expect(rows[0]!.count).toBe("1");
    });
  });

  describe("whose task is it", () => {
    itUnderHangBackstop("tells apart mine, somebody else's, and one nothing is known about", async () => {
      // §4.6 makes these three different answers and only one of them a 404. The middle case is the
      // one worth having a test for: an incognito task is *known* through its usage and holds no
      // content, and answering 404 for it would surface a delete that is already true as an error.
      await insertRetainedContent(client, content({ accountId: CONSENTING, taskId: "mine" }));
      await insertRetainedContent(client, content({ accountId: OTHER, taskId: "theirs" }));
      await insertMeteringEvent(
        client,
        meteringEvent({ accountId: CONSENTING, taskId: "incognito", retention: "none" }),
      );

      expect(await taskOwnership(client, { accountId: CONSENTING, taskId: "mine" })).toBe("mine");
      expect(await taskOwnership(client, { accountId: CONSENTING, taskId: "theirs" })).toBe("other");
      expect(await taskOwnership(client, { accountId: CONSENTING, taskId: "incognito" })).toBe(
        "mine",
      );
      expect(await taskOwnership(client, { accountId: CONSENTING, taskId: "unheard-of" })).toBe(
        "unknown",
      );
    });
  });

  describe("account deletion reaches everything under the account", () => {
    itUnderHangBackstop("takes content, snapshot membership and the stored idempotency responses", async () => {
      await insertRetainedContent(client, content({ accountId: CONSENTING, taskId: "a" }));
      await insertRetainedContent(client, content({ accountId: CONSENTING, taskId: "b" }));
      await insertRetainedContent(client, content({ accountId: OTHER, taskId: "not-theirs" }));
      const built = await buildTrainingSnapshot(client, { label: "corpus-8" });
      expect(built.memberCount).toBe(3);

      // A stored response for each account, so "the other account is untouched" is asserted on the
      // table this branch is newly reaching into rather than assumed.
      for (const account of [CONSENTING, OTHER]) {
        const key = `key-${account}`;
        const claimed = await claimKey(client, {
          accountScope: account,
          key,
          route: "POST /v1/plan",
          fingerprint: "sha256:aaa",
        });
        if (claimed.kind !== "claimed") throw new Error("the key was not claimable");
        await completeClaim(
          client,
          { accountScope: account, key, token: claimed.token },
          {
            status: 200,
            body: Buffer.from('{"output_text":"something the user said"}'),
            contentType: "application/json",
            requestId: "r",
          },
        );
      }

      const storedResponses = await deleteStoredResponsesForAccount(client, CONSENTING);
      const outcome = await deleteContentForAccount(client, CONSENTING, storedResponses, "account");
      expect(outcome.contentRows).toBe(2);
      expect(outcome.snapshotRows).toBe(2);
      expect(outcome.storedResponses).toBe(1);
      expect(outcome.snapshotsTouched).toEqual([built.snapshotId]);

      const remaining = await contentRows();
      expect(remaining.map((row) => row["account_id"])).toEqual([OTHER]);
      const { rows: bodies } = await client.query<{ account_scope: string }>(
        "SELECT account_scope::text AS account_scope FROM sonny.idempotency_key WHERE response_body IS NOT NULL",
      );
      expect(bodies.map((row) => row.account_scope)).toEqual([OTHER]);
    });

    itUnderHangBackstop("keeps the idempotency rows and their metering claims, which are billing and not content", async () => {
      const key = "claim-survives";
      const claimed = await claimKey(client, {
        accountScope: CONSENTING,
        key,
        route: "POST /v1/plan",
        fingerprint: "sha256:aaa",
      });
      if (claimed.kind !== "claimed") throw new Error("the key was not claimable");
      await completeClaim(
        client,
        { accountScope: CONSENTING, key, token: claimed.token },
        { status: 200, body: Buffer.from("{}"), contentType: "application/json", requestId: "r" },
      );
      await client.query(
        "UPDATE sonny.idempotency_key SET metering_claimed_at = now() WHERE idempotency_key = $1",
        [key],
      );

      await deleteStoredResponsesForAccount(client, CONSENTING);
      const { rows } = await client.query<{ has_body: boolean; claimed: boolean }>(
        `SELECT response_body IS NOT NULL AS has_body, metering_claimed_at IS NOT NULL AS claimed
           FROM sonny.idempotency_key WHERE idempotency_key = $1`,
        [key],
      );
      // The payload went; the row and its claim did not, because deleting the claim would hand the
      // same key a second metering event on day two.
      expect(rows[0]).toEqual({ has_body: false, claimed: true });
    });

    itUnderHangBackstop("keeps the usage history, which requirement 8 separates from content", async () => {
      await insertMeteringEvent(client, meteringEvent({ accountId: CONSENTING }));
      await insertRetainedContent(client, content({ accountId: CONSENTING }));
      await deleteContentForAccount(client, CONSENTING, 0, "account");
      const { rows } = await client.query<{ count: string }>(
        "SELECT count(*)::text AS count FROM sonny.metering_event WHERE account_id = $1",
        [CONSENTING],
      );
      expect(rows[0]!.count).toBe("1");
    });
  });

  describe("the sweep finishes an account deletion that could not finish itself", () => {
    itUnderHangBackstop("takes the content of a closed account, including one closed before this existed", async () => {
      // The recovery path `routes/auth.ts` depends on: its wipe runs after a committed close and
      // cannot answer a failure with a 500, because the caller is no longer attributable. This is
      // what makes that safe, and it is also the only thing that reaches accounts closed while
      // SONNY-127's comment said their content was "retained and unreachable".
      await insertRetainedContent(client, content({ accountId: CONSENTING, taskId: "orphan" }));
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [CONSENTING]);

      const swept = await sweepClosedAccountContent(client, deleteStoredResponsesForAccount);
      expect(swept?.contentRows).toBe(1);
      expect(await contentRows()).toHaveLength(0);
      const deletions = await recentContentDeletions(client, { limit: 10 });
      expect(deletions[0]!.reason).toBe("account");
      expect(deletions[0]!.accountId).toBe(CONSENTING);
    });

    itUnderHangBackstop("takes an account whose only residue is a stored response body", async () => {
      // **PR #148's F4.** The selection asked only about `retained_content`, so an account closed
      // with all-incognito usage, or whose content had already expired, was never picked up by any
      // pass — and the recovery this exists to be held exactly when retained content happened to
      // exist. There is deliberately no content row in this test.
      const key = "residue-only";
      const claimed = await claimKey(client, {
        accountScope: CONSENTING,
        key,
        route: "POST /v1/plan",
        fingerprint: "sha256:aaa",
      });
      if (claimed.kind !== "claimed") throw new Error("the key was not claimable");
      await completeClaim(
        client,
        { accountScope: CONSENTING, key, token: claimed.token },
        {
          status: 200,
          body: Buffer.from('{"output_text":"the reply nobody swept"}'),
          contentType: "application/json",
          requestId: "r",
        },
      );
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [CONSENTING]);
      expect(await contentRows()).toHaveLength(0);

      const swept = await sweepClosedAccountContent(client, deleteStoredResponsesForAccount);
      expect(swept?.storedResponses).toBe(1);
      const { rows } = await client.query<{ has_body: boolean }>(
        "SELECT response_body IS NOT NULL AS has_body FROM sonny.idempotency_key WHERE idempotency_key = $1",
        [key],
      );
      expect(rows[0]!.has_body).toBe(false);
    });

    itUnderHangBackstop("does nothing for an open account, however much content it holds", async () => {
      await insertRetainedContent(client, content({ accountId: CONSENTING }));
      expect(await sweepClosedAccountContent(client, deleteStoredResponsesForAccount)).toBeUndefined();
      expect(await contentRows()).toHaveLength(1);
    });

    itUnderHangBackstop("is part of the ordinary sweep, not a separate thing to remember to run", async () => {
      await insertRetainedContent(client, content({ accountId: CONSENTING }));
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [CONSENTING]);
      const result = await sweepExpiredContent(client);
      expect(result.closedAccountRows).toBe(1);
      expect(await contentRows()).toHaveLength(0);
    });
  });

  describe("DELETE /v1/tasks/{task_id}, through the real app and the real tables", () => {
    /**
     * The whole app over this connection, with a real identity so the gate attributes the caller
     * the way it does in production.
     *
     * **Driven end to end rather than through `deleteContentForTask` alone**, because §4.6's three
     * answers are the route's and not the store's: which status a task with nothing stored gets,
     * which one another account's task gets, and that the two are told apart at all. A test of the
     * store could not have caught the case that matters — a 404 where a 200 was owed.
     */
    const app = () =>
      buildApp(testConfig({ databaseUrl: url }), {
        provider: new UnusedAuthProvider(),
        withConnection: async (work) => work(client),
      });

    const SUPABASE_USER = "9f6c2c4e-8f2a-4a0f-9a11-2b6f5f2a7799";
    const OTHER_SUPABASE_USER = "8f6c2c4e-8f2a-4a0f-9a11-2b6f5f2a7788";

    beforeEachUnderHangBackstop(async () => {
      await client.query(
        `INSERT INTO sonny.identity (account_id, provider, subject, link_method, supabase_user_id)
         VALUES ($1, 'email', $2, 'primary', $3), ($4, 'email', $5, 'primary', $6)`,
        [
          CONSENTING,
          "mine@example.test",
          SUPABASE_USER,
          OTHER,
          "theirs@example.test",
          OTHER_SUPABASE_USER,
        ],
      );
    });

    const deleteTask = async (taskId: string, user = SUPABASE_USER) =>
      app().inject({
        method: "DELETE",
        url: `/v1/tasks/${taskId}`,
        headers: { authorization: `Bearer ${accessTokenFor(user)}` },
      });

    itUnderHangBackstop("deletes this account's task and reports how many requests went", async () => {
      await insertRetainedContent(client, content({ taskId: "mine", accountId: CONSENTING }));
      await insertRetainedContent(client, content({ taskId: "mine", accountId: CONSENTING }));
      const response = await deleteTask("mine");
      expect(response.statusCode).toBe(200);
      const body = JSON.parse(response.body) as { task_id: string; requests_deleted: number };
      expect(body.task_id).toBe("mine");
      expect(body.requests_deleted).toBe(2);
      expect(await contentRows()).toHaveLength(0);
    });

    itUnderHangBackstop("answers 200 with nothing deleted for a task that stored nothing", async () => {
      // §4.6: "A task with nothing stored returns success, not 404 … a delete that is already true
      // must not surface as an error the user has to interpret." This is the incognito case and the
      // ran-before-sign-in case, and both are ordinary successes.
      const response = await deleteTask("never-stored-anything");
      expect(response.statusCode).toBe(200);
      expect(JSON.parse(response.body).requests_deleted).toBe(0);
    });

    itUnderHangBackstop("answers 200 for an incognito task, which is metered and holds no content", async () => {
      await insertMeteringEvent(
        client,
        meteringEvent({ accountId: CONSENTING, taskId: "incognito", retention: "none" }),
      );
      const response = await deleteTask("incognito");
      expect(response.statusCode).toBe(200);
      expect(JSON.parse(response.body).requests_deleted).toBe(0);
      // And the usage is still there afterwards: deleting a task never rewrites what it cost.
      const { rows } = await client.query<{ count: string }>(
        "SELECT count(*)::text AS count FROM sonny.metering_event WHERE task_id = 'incognito'",
      );
      expect(rows[0]!.count).toBe("1");
    });

    itUnderHangBackstop("answers 404 only for a task belonging to another account, and touches nothing", async () => {
      await insertRetainedContent(client, content({ taskId: "theirs", accountId: OTHER }));
      const response = await deleteTask("theirs");
      expect(response.statusCode).toBe(404);
      expect(JSON.parse(response.body).error.code).toBe("resource.not_found");
      expect(await contentRows()).toHaveLength(1);
    });

    /**
     * `DELETE /v1/tasks` and `DELETE /v1/tasks/{task_id}/screenshots` (SONNY-404), driven end to end
     * for the reason the block above gives: what distinguishes these two from the route above them
     * is which rows survive, and that is the route's promise rather than the store's.
     */
    describe("SONNY-404's two narrower deletes, through the real app and the real tables", () => {
      const deleteTasks = async (taskIds: unknown, user = SUPABASE_USER) =>
        app().inject({
          method: "DELETE",
          url: "/v1/tasks",
          headers: { authorization: `Bearer ${accessTokenFor(user)}` },
          payload: { task_ids: taskIds },
        });

      const deleteScreenshots = async (taskId: string, user = SUPABASE_USER) =>
        app().inject({
          method: "DELETE",
          url: `/v1/tasks/${taskId}/screenshots`,
          headers: { authorization: `Bearer ${accessTokenFor(user)}` },
        });

      itUnderHangBackstop("deletes several of this account's tasks in one call", async () => {
        await insertRetainedContent(client, content({ taskId: "a", accountId: CONSENTING }));
        await insertRetainedContent(client, content({ taskId: "a", accountId: CONSENTING }));
        await insertRetainedContent(client, content({ taskId: "b", accountId: CONSENTING }));
        await insertRetainedContent(client, content({ taskId: "keep", accountId: CONSENTING }));

        const response = await deleteTasks(["a", "b"]);
        expect(response.statusCode).toBe(200);
        const body = JSON.parse(response.body) as {
          tasks_deleted: number;
          tasks_not_found: number;
          requests_deleted: number;
        };
        expect(body).toMatchObject({ tasks_deleted: 2, tasks_not_found: 0, requests_deleted: 3 });

        const rows = await contentRows();
        expect(rows.map((row) => row["task_id"])).toEqual(["keep"]);
      });

      itUnderHangBackstop("records one deletion per task, exactly as the same deletes performed one at a time would", async () => {
        // The property the bulk route promises beyond speed: the record of a wipe reads the same as
        // the record of the same deletions performed slowly. A summary row would make the two paths
        // look like different acts to anybody reading `sonny.content_deletion` a year later.
        await insertRetainedContent(client, content({ taskId: "a", accountId: CONSENTING }));
        await deleteTasks(["a", "stored-nothing"]);

        const deletions = await recentContentDeletions(client, { limit: 10 });
        expect(deletions).toHaveLength(2);
        expect(deletions.every((deletion) => deletion.reason === "task")).toBe(true);
        const byTask = new Map(deletions.map((deletion) => [deletion.taskId, deletion.contentRows]));
        expect(byTask.get("a")).toBe(1);
        // Recorded even though it took nothing — §4.6 makes "there was nothing to delete" a success,
        // and a record that only fired on a hit could not tell that apart from a delete that never
        // ran.
        expect(byTask.get("stored-nothing")).toBe(0);
      });

      itUnderHangBackstop("takes only the caller's own tasks and says how many were somebody else's", async () => {
        // **§4.6's 404, at batch granularity.** The other account's content must survive, and the
        // count is what the Mac reads to keep the obligation queued rather than settling it — the
        // same "not deliverable by this session, never not deliverable" reading the single route's
        // 404 already has.
        await insertRetainedContent(client, content({ taskId: "mine", accountId: CONSENTING }));
        await insertRetainedContent(client, content({ taskId: "theirs", accountId: OTHER }));

        const response = await deleteTasks(["mine", "theirs"]);
        expect(response.statusCode).toBe(200);
        expect(JSON.parse(response.body)).toMatchObject({
          tasks_deleted: 1,
          tasks_not_found: 1,
          requests_deleted: 1,
        });

        const rows = await contentRows();
        expect(rows.map((row) => row["task_id"])).toEqual(["theirs"]);
        expect(rows.map((row) => row["account_id"])).toEqual([OTHER]);
      });

      itUnderHangBackstop("refuses a batch that is empty or malformed, and deletes nothing", async () => {
        await insertRetainedContent(client, content({ taskId: "a", accountId: CONSENTING }));
        for (const payload of [[], ["  "], "not-an-array"]) {
          const response = await deleteTasks(payload);
          expect(response.statusCode).toBe(400);
          expect(JSON.parse(response.body).error.code).toBe("request.invalid");
        }
        expect(await contentRows()).toHaveLength(1);
      });

      itUnderHangBackstop("reaches the training snapshots the batch's tasks were copied into", async () => {
        // The half the whole lineage exists for. `expireSnapshots` skips a NULL `expires_at`, which
        // is every snapshot the builder makes, so a member the batch missed would sit there with no
        // clock on it at all.
        await insertRetainedContent(client, content({ taskId: "a", accountId: CONSENTING }));
        await insertRetainedContent(client, content({ taskId: "b", accountId: CONSENTING }));
        const built = await buildTrainingSnapshot(client, { label: "bulk-corpus" });
        expect(built.memberCount).toBe(2);

        await deleteTasks(["a", "b"]);

        const { rows } = await client.query<{ count: string }>(
          "SELECT count(*)::text AS count FROM sonny.training_snapshot_member",
        );
        expect(rows[0]!.count).toBe("0");
        const snapshots = await trainingSnapshots(client);
        expect(snapshots[0]!.memberCount).toBe(0);
        const deletions = await recentContentDeletions(client, { limit: 10 });
        expect(deletions.every((deletion) => deletion.snapshotRows === 1)).toBe(true);
      });

      itUnderHangBackstop("deletes a task's screenshots and leaves everything else that task said", async () => {
        // **The whole reason this route exists.** `DELETE /v1/tasks/{task_id}` would have taken the
        // request text and the served response too, which is more than "Delete what Sonny did on
        // screen" says.
        await insertRetainedContent(client, content({ taskId: "seen", accountId: CONSENTING }));

        const response = await deleteScreenshots("seen");
        expect(response.statusCode).toBe(200);
        expect(JSON.parse(response.body)).toMatchObject({
          task_id: "seen",
          screenshots_deleted: 1,
        });

        const rows = await contentRows();
        expect(rows).toHaveLength(1);
        expect(rows[0]!["screenshot"]).toBeNull();
        // The media type goes with the image: a media type beside a NULL image describes nothing
        // and would be the one surviving trace of what was captured.
        expect(rows[0]!["screenshot_media_type"]).toBeNull();
        expect(rows[0]!["request_text"]).toBe("Decide the next action.");
        expect(rows[0]!["response_body"]).not.toBeNull();
      });

      itUnderHangBackstop("clears the snapshot copies of those screenshots and keeps the members themselves", async () => {
        await insertRetainedContent(client, content({ taskId: "seen", accountId: CONSENTING }));
        const built = await buildTrainingSnapshot(client, { label: "screens-corpus" });
        expect(built.memberCount).toBe(1);

        await deleteScreenshots("seen");

        const { rows } = await client.query<{ screenshot: Buffer | null; media: string | null }>(
          `SELECT screenshot, screenshot_media_type AS media FROM sonny.training_snapshot_member`,
        );
        expect(rows).toHaveLength(1);
        expect(rows[0]!.screenshot).toBeNull();
        expect(rows[0]!.media).toBeNull();
        // No member left the snapshot, so the count it describes has not changed.
        const snapshots = await trainingSnapshots(client);
        expect(snapshots[0]!.memberCount).toBe(1);
      });

      itUnderHangBackstop("records the clear under its own reason, with counts of its own", async () => {
        await insertRetainedContent(client, content({ taskId: "seen", accountId: CONSENTING }));
        await buildTrainingSnapshot(client, { label: "recorded-corpus" });

        await deleteScreenshots("seen");

        const { rows } = await client.query<{
          reason: string;
          task_id: string;
          content_rows: number;
          screenshots_cleared: number;
          snapshot_screenshots_cleared: number;
          snapshots_touched: string[];
        }>(
          `SELECT reason, task_id, content_rows, screenshots_cleared,
                  snapshot_screenshots_cleared, snapshots_touched::text[] AS snapshots_touched
             FROM sonny.content_deletion`,
        );
        expect(rows).toHaveLength(1);
        // Filed under `task` it would have said the whole task was deleted, which is the one thing
        // this route exists not to do; counted in `content_rows` it would have changed what that
        // column means for every reader of this table, including readers that predate this route.
        expect(rows[0]!.reason).toBe("task_screenshots");
        expect(rows[0]!.task_id).toBe("seen");
        expect(rows[0]!.content_rows).toBe(0);
        expect(rows[0]!.screenshots_cleared).toBe(1);
        expect(rows[0]!.snapshot_screenshots_cleared).toBe(1);
        expect(rows[0]!.snapshots_touched).toHaveLength(1);
      });

      itUnderHangBackstop("answers 200 with nothing cleared for a task that stored no screenshots", async () => {
        const response = await deleteScreenshots("never-stored-anything");
        expect(response.statusCode).toBe(200);
        expect(JSON.parse(response.body).screenshots_deleted).toBe(0);
      });

      itUnderHangBackstop("deletes everything this account has stored and leaves the account open", async () => {
        // **Settings' whole wipe, through the real route** (SONNY-404, founder decision 2026-09-04).
        // The rows go; the account does not.
        await insertRetainedContent(client, content({ taskId: "a", accountId: CONSENTING }));
        await insertRetainedContent(client, content({ taskId: "b", accountId: CONSENTING }));
        await insertMeteringEvent(client, meteringEvent({ accountId: CONSENTING, taskId: "a" }));

        const response = await app().inject({
          method: "DELETE",
          url: "/v1/account/content",
          headers: { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` },
        });

        expect(response.statusCode).toBe(200);
        expect(JSON.parse(response.body)).toMatchObject({ requests_deleted: 2 });
        expect(await contentRows()).toHaveLength(0);

        // The account is still open and still usable — this is "delete my data", not "delete my
        // account", and those are two promises with one control between them.
        const { rows } = await client.query<{ deleted_at: Date | null }>(
          "SELECT deleted_at FROM sonny.account WHERE id = $1",
          [CONSENTING],
        );
        expect(rows[0]!.deleted_at).toBeNull();
        // And usage survives on §10.3's long clock: deleting content never rewrites what it cost.
        const usage = await client.query<{ count: string }>(
          "SELECT count(*)::text AS count FROM sonny.metering_event WHERE account_id = $1",
          [CONSENTING],
        );
        expect(usage.rows[0]!.count).toBe("1");
      });

      itUnderHangBackstop("takes only the caller's own account and nothing of anybody else's", async () => {
        await insertRetainedContent(client, content({ taskId: "mine", accountId: CONSENTING }));
        await insertRetainedContent(client, content({ taskId: "theirs", accountId: OTHER }));

        const response = await app().inject({
          method: "DELETE",
          url: "/v1/account/content",
          headers: { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` },
        });

        expect(response.statusCode).toBe(200);
        expect(JSON.parse(response.body).requests_deleted).toBe(1);
        const rows = await contentRows();
        expect(rows.map((row) => row["account_id"])).toEqual([OTHER]);
      });

      itUnderHangBackstop("reaches the training-snapshot copies too, which is the half that never expires", async () => {
        await insertRetainedContent(client, content({ taskId: "a", accountId: CONSENTING }));
        const built = await buildTrainingSnapshot(client, { label: "wipe-corpus" });
        expect(built.memberCount).toBe(1);

        await app().inject({
          method: "DELETE",
          url: "/v1/account/content",
          headers: { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` },
        });

        const { rows } = await client.query<{ count: string }>(
          "SELECT count(*)::text AS count FROM sonny.training_snapshot_member",
        );
        expect(rows[0]!.count).toBe("0");
      });

      itUnderHangBackstop("records the wipe under a reason of its own, not the account close's", async () => {
        // Filed under `account` it would say the account was closed and its content went with it —
        // and `sonny.account.deleted_at` stops telling the two apart the day the user does close it.
        await insertRetainedContent(client, content({ taskId: "a", accountId: CONSENTING }));

        await app().inject({
          method: "DELETE",
          url: "/v1/account/content",
          headers: { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` },
        });

        const deletions = await recentContentDeletions(client, { limit: 10 });
        expect(deletions).toHaveLength(1);
        expect(deletions[0]!.reason).toBe("account_content");
        expect(deletions[0]!.contentRows).toBe(1);
      });

      itUnderHangBackstop("deletes only content at or before ?before, leaving what came after", async () => {
        // **The cutoff, and the data-loss path it closes** (PR #207's F1). The Mac queues this
        // delete when it cannot reach the gateway and may deliver it days later; without a bound the
        // delivery takes content the user made after the press, which the press never promised.
        const old = new Date(Date.now() - 60 * 60 * 1000);
        await insertRetainedContent(client, content({ taskId: "old", accountId: CONSENTING }));
        await client.query("UPDATE sonny.retained_content SET occurred_at = $1 WHERE task_id = 'old'", [old]);
        await insertRetainedContent(client, content({ taskId: "new", accountId: CONSENTING }));

        const cutoff = new Date(Date.now() - 30 * 60 * 1000);
        const response = await app().inject({
          method: "DELETE",
          url: `/v1/account/content?before=${encodeURIComponent(cutoff.toISOString())}`,
          headers: { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` },
        });

        expect(response.statusCode).toBe(200);
        expect(JSON.parse(response.body).requests_deleted).toBe(1);
        const rows = await contentRows();
        expect(rows.map((row) => row["task_id"])).toEqual(["new"]);
      });

      itUnderHangBackstop("bounds the training-snapshot copies by the same cutoff", async () => {
        const old = new Date(Date.now() - 60 * 60 * 1000);
        await insertRetainedContent(client, content({ taskId: "old", accountId: CONSENTING }));
        await client.query("UPDATE sonny.retained_content SET occurred_at = $1 WHERE task_id = 'old'", [old]);
        await insertRetainedContent(client, content({ taskId: "new", accountId: CONSENTING }));
        const built = await buildTrainingSnapshot(client, { label: "cutoff-corpus" });
        expect(built.memberCount).toBe(2);

        const cutoff = new Date(Date.now() - 30 * 60 * 1000);
        await app().inject({
          method: "DELETE",
          url: `/v1/account/content?before=${encodeURIComponent(cutoff.toISOString())}`,
          headers: { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` },
        });

        const { rows } = await client.query<{ task_id: string }>(
          "SELECT task_id FROM sonny.training_snapshot_member",
        );
        expect(rows.map((row) => row.task_id)).toEqual(["new"]);
      });

      itUnderHangBackstop("refuses an unreadable ?before rather than deleting everything", async () => {
        // The direction that matters: an unparseable bound must not fall through to "no bound".
        await insertRetainedContent(client, content({ taskId: "a", accountId: CONSENTING }));
        const response = await app().inject({
          method: "DELETE",
          url: "/v1/account/content?before=not-an-instant",
          headers: { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` },
        });
        expect(response.statusCode).toBe(400);
        expect(JSON.parse(response.body).error.code).toBe("request.invalid");
        expect(await contentRows()).toHaveLength(1);
      });

      itUnderHangBackstop("is safe to repeat, which is what lets the Mac retry it from its queue", async () => {
        await insertRetainedContent(client, content({ taskId: "a", accountId: CONSENTING }));
        const send = async () =>
          app().inject({
            method: "DELETE",
            url: "/v1/account/content",
            headers: { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` },
          });

        expect(JSON.parse((await send()).body).requests_deleted).toBe(1);
        const again = await send();
        expect(again.statusCode).toBe(200);
        expect(JSON.parse(again.body).requests_deleted).toBe(0);
      });

      itUnderHangBackstop("answers 404 for another account's task and leaves that task's screenshot where it is", async () => {
        await insertRetainedContent(client, content({ taskId: "theirs", accountId: OTHER }));

        const response = await deleteScreenshots("theirs");
        expect(response.statusCode).toBe(404);
        expect(JSON.parse(response.body).error.code).toBe("resource.not_found");

        const rows = await contentRows();
        expect(rows).toHaveLength(1);
        expect(rows[0]!["screenshot"]).not.toBeNull();
        // And nothing was recorded either: a refused request is not a deletion that took nothing.
        expect(await recentContentDeletions(client, { limit: 10 })).toHaveLength(0);
      });
    });

    itUnderHangBackstop("closes an account and takes its content, its lineage and its stored responses with it", async () => {
      // **Requirement 8 and SONNY-319 through the real route**, which is the only place their
      // ordering is real: the account is closed first (so nothing can arrive behind the wipe), the
      // revocation drain runs, and the wipe follows. A test of the store alone could not have shown
      // that the handler reaches all three tables, and that is exactly what SONNY-127's version of
      // this route did not do.
      await insertRetainedContent(client, content({ taskId: "a", accountId: CONSENTING }));
      await insertRetainedContent(client, content({ taskId: "b", accountId: CONSENTING }));
      await insertRetainedContent(client, content({ taskId: "c", accountId: OTHER }));
      const built = await buildTrainingSnapshot(client, { label: "corpus-wipe" });
      expect(built.memberCount).toBe(3);

      const claimed = await claimKey(client, {
        accountScope: CONSENTING,
        key: "wipe-key",
        route: "POST /v1/plan",
        fingerprint: "sha256:aaa",
      });
      if (claimed.kind !== "claimed") throw new Error("the key was not claimable");
      await completeClaim(
        client,
        { accountScope: CONSENTING, key: "wipe-key", token: claimed.token },
        {
          status: 200,
          body: Buffer.from('{"output_text":"something the user said"}'),
          contentType: "application/json",
          requestId: "r",
        },
      );

      const response = await app().inject({
        method: "DELETE",
        url: "/v1/account",
        headers: { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` },
      });
      expect(response.statusCode).toBe(204);

      // The account is closed, its content is gone, its snapshot membership is gone, and its stored
      // response body is gone — and the other account is untouched in all four.
      const { rows: closed } = await client.query<{ closed: boolean }>(
        "SELECT deleted_at IS NOT NULL AS closed FROM sonny.account WHERE id = $1",
        [CONSENTING],
      );
      expect(closed[0]!.closed).toBe(true);
      expect((await contentRows()).map((row) => row["account_id"])).toEqual([OTHER]);
      const { rows: members } = await client.query<{ account_id: string }>(
        "SELECT account_id::text AS account_id FROM sonny.training_snapshot_member",
      );
      expect(members.map((row) => row.account_id)).toEqual([OTHER]);
      const { rows: bodies } = await client.query<{ count: string }>(
        `SELECT count(*)::text AS count FROM sonny.idempotency_key
          WHERE account_scope = $1 AND response_body IS NOT NULL`,
        [CONSENTING],
      );
      expect(bodies[0]!.count).toBe("0");

      const deletions = await recentContentDeletions(client, { limit: 5 });
      expect(deletions[0]!.reason).toBe("account");
      expect(deletions[0]!.contentRows).toBe(2);
      expect(deletions[0]!.storedResponses).toBe(1);
      expect(deletions[0]!.snapshotsTouched).toEqual([built.snapshotId]);
    });

    itUnderHangBackstop("reaches the training snapshot the task's content had reached", async () => {
      await insertRetainedContent(client, content({ taskId: "mine", accountId: CONSENTING }));
      const built = await buildTrainingSnapshot(client, { label: "corpus-route" });
      expect(built.memberCount).toBe(1);

      expect((await deleteTask("mine")).statusCode).toBe(200);
      expect(
        await snapshotsHoldingTask(client, { accountId: CONSENTING, taskId: "mine" }),
      ).toEqual([]);
      const deletions = await recentContentDeletions(client, { limit: 1 });
      expect(deletions[0]!.snapshotsTouched).toEqual([built.snapshotId]);
    });
  });

  describe("the support lookup", () => {
    itUnderHangBackstop("shows account state, usage and how much content is held, and no content", async () => {
      await client.query(
        `INSERT INTO sonny.identity (account_id, provider, subject, link_method)
         VALUES ($1, 'email', $2, 'primary')`,
        [CONSENTING, "someone@example.test"],
      );
      await insertMeteringEvent(client, meteringEvent({ accountId: CONSENTING }));
      await insertMeteringEvent(
        client,
        meteringEvent({ accountId: CONSENTING, route: "plan", outcome: "provider_error" }),
      );
      await insertRetainedContent(
        client,
        content({
          accountId: CONSENTING,
          route: "transcription",
          voiceAudio: Buffer.from("a-recording"),
          voiceAudioMediaType: "audio/mp4",
          screenshot: null,
          screenshotMediaType: null,
          requestText: "a secret the founder should not see in this report",
        }),
      );

      const view = await accountSupportView(client, CONSENTING);
      expect(view?.trainingConsent).toBe(true);
      expect(view?.deletedAt).toBeNull();
      expect(view?.identities).toEqual([{ provider: "email", accountClosed: false }]);
      expect(view?.usage.events).toBe(2);
      expect(view?.content.rows).toBe(1);
      expect(view?.content.withVoiceAudio).toBe(1);

      const report = reportAccount(view, CONSENTING);
      expect(report).toContain("training consent granted");
      expect(report).toContain("voice audio    1");
      // **The line requirement 9 draws, asserted on the bytes of the report.** The count is there;
      // the content is not, and neither is the email address behind the identity.
      expect(report).not.toContain("a secret the founder should not see");
      expect(report).not.toContain("someone@example.test");
      // And it says which half of "entitlement state" does not exist yet, rather than printing an
      // empty section that reads like "no entitlements".
      expect(report).toContain("SONNY-135");
    });

    itUnderHangBackstop("records every content lookup, including the ones that find nothing", async () => {
      const requestId = randomUUID();
      await insertRetainedContent(client, content({ requestId, accountId: CONSENTING }));

      const found = await contentForRequest(client, {
        requestId,
        operator: "sauransh",
        reason: "user reported a wrong click",
      });
      expect(found?.requestText).toBe("Decide the next action.");
      // Blobs come back as sizes: a terminal cannot render either, and a megabyte of base64 in a
      // scrollback outlives the lookup.
      expect(found?.screenshotBytes).toBe(Buffer.from("a-redacted-capture").byteLength);

      const missing = await contentForRequest(client, {
        requestId: "no-such-request",
        operator: "bhavya",
        reason: "checking a support ticket",
      });
      expect(missing).toBeUndefined();

      const accesses = await recentContentAccesses(client, 10);
      expect(accesses.map((row) => [row.operator, row.found])).toEqual([
        ["bhavya", false],
        ["sauransh", true],
      ]);
      expect(accesses[1]!.reason).toBe("user reported a wrong click");
      expect(accesses[1]!.accountId).toBe(CONSENTING);
    });

    itUnderHangBackstop("prints a provider error body under the unseal, where §10.3 put it", async () => {
      const requestId = randomUUID();
      await insertRetainedContent(
        client,
        content({
          requestId,
          providerErrorStatus: 400,
          providerErrorBody: '{"error":{"message":"rejected prompt: open the invoice"}}',
        }),
      );
      const view = await contentForRequest(client, {
        requestId,
        operator: "sauransh",
        reason: "a provider refused and the user asked why",
      });
      expect(reportContent(view, requestId)).toContain("rejected prompt: open the invoice");
    });

    itUnderHangBackstop("says plainly that finding nothing is not necessarily a gap", async () => {
      // The report a founder reads after an incognito run, a deleted task, or a call older than
      // thirty days. All three are the system working, and a bare "not found" reads like a bug.
      const report = reportContent(undefined, "req-1");
      expect(report).toContain("thirty days");
      expect(report).toContain("incognito");
      expect(report).toContain("recorded");
    });
  });
  /**
   * §12's deadline, against a real backend (SONNY-428).
   *
   * **`content.test.ts` proves the four routes are wired and this proves the wiring bounds
   * anything**, and neither half is worth much alone. There the store is a fake that honours a
   * `statement_timeout`, so what it establishes is that each route sets one and answers §7.2's
   * envelope when a statement is cancelled; nothing in a fake says Postgres would really cancel.
   * Here the statement is genuinely blocked — by a lock another connection holds, which is the
   * production shape of a deletion that will not finish — and the cancellation is the real server's.
   *
   * **A lock rather than a sleep, deliberately.** `CLAUDE.md`'s wall-clock rule is about a test that
   * races something; this waits on nothing and bets on nothing. The blocking transaction is opened
   * before the delete is attempted and is still open when the assertion runs, so the statement
   * cannot proceed for any reason other than the one under test, and the only thing that ends it is
   * the timeout.
   */
  describe("§12's deadline, enforced by the backend rather than by a race", () => {
    itUnderHangBackstop(
      "cancels a delete that a lock is holding, and hands back the code the mapper answers",
      async () => {
        const accountId = CONSENTING;
        const taskId = `task-${randomUUID()}`;
        await insertRetainedContent(client, content({ accountId, taskId }));

        // A second connection takes a lock the delete must have, and keeps it.
        const blocker = new pg.Client({ connectionString: url });
        await blocker.connect();
        try {
          await blocker.query("BEGIN");
          await blocker.query("LOCK TABLE sonny.retained_content IN ACCESS EXCLUSIVE MODE");

          // 250 ms rather than §12's 15 s: what is under test is that the bound is real and that
          // the backend reports it the way the mapper reads, neither of which is a property of the
          // number. The number itself is pinned in `content.test.ts` against the constant.
          await client.query("SET statement_timeout TO 250");
          let code: string | undefined;
          try {
            await deleteContentForTask(client, { accountId, taskId });
          } catch (error) {
            code = (error as { code?: string }).code;
          } finally {
            await client.query("RESET statement_timeout");
          }

          // **57014 is the whole hinge.** `withDatabaseDeadline` reads this code and nothing else to
          // decide a statement was cancelled, so a backend reporting anything else here would leave
          // every one of the four routes answering 500 for a timeout.
          expect(code).toBe("57014");
        } finally {
          await blocker.query("ROLLBACK").catch(() => {});
          await blocker.end();
        }

        // **And the connection survived it**, which is the property the whole mechanism was chosen
        // for: the store rolled its transaction back, so this client is usable rather than stuck in
        // an aborted transaction — which is what `withConnection` would otherwise hand to the next
        // request.
        const after = await client.query("SELECT 1 AS ok");
        expect(after.rows[0]).toEqual({ ok: 1 });
      },
    );
  });
});
