import pg from "pg";
import { describe, expect } from "vitest";
import { rebuildSchema } from "./support/schema.js";
import { afterAllUnderHangBackstop, beforeAllUnderHangBackstop, beforeEachUnderHangBackstop, itUnderHangBackstop } from "./support/backstop.js";
import {
  claimKey,
  completeClaim,
  deleteStoredResponsesForAccount,
  meteringEventClaimed,
  pruneExpiredResponses,
} from "../src/idempotency/store.js";
import type { MeteringEvent } from "../src/metering/event.js";
import { meteringSpan, routeTotals } from "../src/metering/query.js";
import {
  insertMeteringEvent,
  postgresMeteringStore,
  writeMeteringEvent,
} from "../src/metering/store.js";
import { reportRoutes, reportSpan } from "../src/usage.js";

/**
 * Contract §11's table, against a real Postgres (SONNY-133).
 *
 * `metering.test.ts` proves the *decisions* — which requests produce an event, what each field is
 * set to, which outcome an exchange was — against a store the test controls. This file proves the
 * store: the columns, the claim that is only "at most once" if an `UPDATE … WHERE … IS NULL` is
 * atomic, the transaction that makes claiming and writing one act, the aggregation SQL, and the two
 * clocks. None of that is TypeScript behaviour, and a fake would prove nothing about it.
 *
 * **Every age here is produced by back-dating a row, never by waiting.** The same rule
 * `idempotency.db.test.ts` states: a test that slept past a window would be betting on a wall clock
 * it shares with the rest of the suite, which is the shape `CLAUDE.md` records as manufacturing
 * false results, and one that compared two timestamps written in the same instant could not fail at
 * all.
 */

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const ACCOUNT = "8a1d0c8e-1c5a-4a9f-9f6b-2b6f5f2a77ab";
const OTHER_ACCOUNT = "9b9b9b9b-4c4c-4d4d-8e8e-5f5f5f5f5f5f";
const KEY = "6f1b8a2c-0000-4000-8000-abcdefabcdef";

/**
 * §11's row, complete, with every field carrying a value a test can recognise.
 *
 * Written out in full rather than built from partial defaults, so a column added to the table
 * without being added here fails to compile — `MeteringEvent` is the shared shape and the insert
 * binds every one of its fields.
 */
function event(overrides: Partial<MeteringEvent> = {}): MeteringEvent {
  return {
    requestId: "11111111-2222-4333-8444-555555555555",
    idempotencyKey: KEY,
    accountId: ACCOUNT,
    route: "transcription",
    provider: "openai",
    failedOver: [],
    model: "a-transcription-model",
    inputTokens: 1900,
    outputTokens: 40,
    totalTokens: 1940,
    tokenSource: "reported",
    imageBytes: 1_226_249,
    imagePixelWidth: 2406,
    imagePixelHeight: 1354,
    imageMediaType: "image/jpeg",
    audioDurationSeconds: null,
    requestBytes: 1_635_000,
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

describeDb("the metering event table", () => {
  let client: pg.Client;

  /**
   * Take the idempotency key the way a real request does, so the row a claim needs exists.
   *
   * **Without it every write comes back `already_claimed`, and that is the mechanism working rather
   * than a test artifact**: `claimMeteringEvent` is an `UPDATE … WHERE metering_claimed_at IS NULL`,
   * which matches nothing when there is no row — SONNY-300's trap, from the other side. In the
   * gateway the row is always there, because the metering hook passes a key only when the
   * idempotency hook granted a claim, and granting one inserts the row. `writeMeteringEvent`'s
   * `written_without_claim` is what the tree does when it is not, and it has a test of its own.
   */
  const takeKey = async (key = KEY, accountScope = ACCOUNT): Promise<void> => {
    const outcome = await claimKey(client, {
      accountScope,
      key,
      route: "POST /v1/transcriptions",
      fingerprint: "sha256:aaa",
    });
    expect(outcome.kind).toBe("claimed");
  };

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await rebuildSchema(client);
  });
  afterAllUnderHangBackstop(async () => {
    await client.end();
  });
  beforeEachUnderHangBackstop(async () => {
    await client.query("TRUNCATE sonny.metering_event");
    await client.query("TRUNCATE sonny.idempotency_key");
  });

  const rows = async (): Promise<Record<string, unknown>[]> => {
    const { rows: found } = await client.query<Record<string, unknown>>(
      // Named columns rather than `SELECT *`, which this server has none of anywhere
      // (§10.2's own check depends on that staying true).
      `SELECT request_id, idempotency_key, account_id::text AS account_id, occurred_at, route,
              provider, failed_over, model, input_tokens, output_tokens, total_tokens, token_source,
              image_bytes, image_pixel_width, image_pixel_height, image_media_type,
              audio_duration_seconds, request_bytes, response_bytes, duration_ms,
              upstream_duration_ms, outcome, task_id, session_id, session_iteration, retention,
              client_version
         FROM sonny.metering_event ORDER BY session_iteration NULLS FIRST, request_id`,
    );
    return found;
  };

  describe("the shape §11 asks for", () => {
    itUnderHangBackstop("holds no content column, and the whole column set is the assertion", async () => {
      // **§10.3's two clocks rest entirely on this.** Usage lives indefinitely and raw content lives
      // 30 days; a single content column here would put this table on the short clock by accident and
      // nothing would say so. The assertion is the *population* rather than a search for likely
      // names, so a column called anything at all fails it until somebody decides it is not content.
      const { rows: columns } = await client.query<{ column_name: string }>(
        `SELECT column_name FROM information_schema.columns
          WHERE table_schema = 'sonny' AND table_name = 'metering_event'
          ORDER BY column_name`,
      );
      expect(columns.map((column) => column.column_name)).toEqual([
        "account_id",
        "audio_duration_seconds",
        "client_version",
        "duration_ms",
        "event_id",
        "failed_over",
        "idempotency_key",
        "image_bytes",
        "image_media_type",
        "image_pixel_height",
        "image_pixel_width",
        "input_tokens",
        "model",
        "occurred_at",
        "outcome",
        "output_tokens",
        "provider",
        "request_bytes",
        "request_id",
        "response_bytes",
        "retention",
        "route",
        "session_id",
        "session_iteration",
        "task_id",
        "token_source",
        "total_tokens",
        "upstream_duration_ms",
      ]);
    });

    itUnderHangBackstop("round-trips every field of an event", async () => {
      await insertMeteringEvent(client, event({ failedOver: ["openai", "cerebras"] }));
      const [row] = await rows();
      expect(row).toMatchObject({
        request_id: "11111111-2222-4333-8444-555555555555",
        idempotency_key: KEY,
        account_id: ACCOUNT,
        route: "transcription",
        provider: "openai",
        failed_over: ["openai", "cerebras"],
        model: "a-transcription-model",
        input_tokens: 1900,
        output_tokens: 40,
        total_tokens: 1940,
        token_source: "reported",
        image_bytes: 1_226_249,
        image_pixel_width: 2406,
        image_pixel_height: 1354,
        image_media_type: "image/jpeg",
        request_bytes: 1_635_000,
        response_bytes: 412,
        duration_ms: 4218,
        upstream_duration_ms: 4100,
        outcome: "ok",
        task_id: "task-1",
        session_id: "session-1",
        session_iteration: 1,
        retention: "standard",
        client_version: "1.0.0+412",
      });
      expect(row!["audio_duration_seconds"]).toBeNull();
      expect(row!["occurred_at"]).toBeInstanceOf(Date);
    });

    itUnderHangBackstop("keeps a null token count as null rather than as zero", async () => {
      // A refused or failed call carries no usage, and a reader must be able to tell that from a
      // measured zero.
      await insertMeteringEvent(
        client,
        event({ inputTokens: null, outputTokens: null, totalTokens: null, tokenSource: null }),
      );
      const [row] = await rows();
      expect(row!["total_tokens"]).toBeNull();
      expect(row!["token_source"]).toBeNull();
    });

    itUnderHangBackstop("refuses a route, an outcome, a token source or a retention the contract does not name", async () => {
      // The CHECK constraints, which are what stop a typo from becoming a category nothing queries.
      const refusals: [keyof MeteringEvent, unknown][] = [
        ["route", "screen.analyse"],
        ["outcome", "served"],
        ["tokenSource", "guessed"],
        ["retention", "standard "],
      ];
      for (const [field, value] of refusals) {
        await expect(
          insertMeteringEvent(client, event({ [field]: value } as Partial<MeteringEvent>)),
        ).rejects.toThrow(/violates check constraint/);
      }
    });
  });

  describe("at most once per idempotency key, ever", () => {
    itUnderHangBackstop("writes one event and refuses the second attempt under the same key", async () => {
      await takeKey();
      expect(await writeMeteringEvent(client, event(), KEY)).toBe("written");
      expect(await writeMeteringEvent(client, event({ requestId: "second" }), KEY)).toBe(
        "already_claimed",
      );
      expect(await rows()).toHaveLength(1);
      expect((await rows())[0]!["request_id"]).toBe("11111111-2222-4333-8444-555555555555");
    });

    itUnderHangBackstop("holds under concurrency, which is the only thing that makes it a guarantee", async () => {
      // **The claim is an `UPDATE … WHERE metering_claimed_at IS NULL`, and this is the property
      // that sentence rests on.** Ten connections race for one key; Postgres serialises the update
      // and nine of them match zero rows. A test on one connection cannot fail here, which is why
      // this one opens its own.
      await takeKey();
      // **Connected one at a time, and only the writes race.** Ten simultaneous connection
      // handshakes against a container already carrying the rest of the suite is not what this test
      // is about, and it made the test flake once in four full runs — a five-second timeout with no
      // failing assertion, which is the shape that gets re-run and dismissed. Setup is sequential;
      // the concurrency being asserted is `writeMeteringEvent`'s, and it is unchanged.
      const racers: pg.Client[] = [];
      for (let index = 0; index < 10; index += 1) {
        const racer = new pg.Client({ connectionString: url });
        await racer.connect();
        racers.push(racer);
      }
      try {
        const outcomes = await Promise.all(
          racers.map((racer, index) =>
            writeMeteringEvent(racer, event({ requestId: `racer-${index}` }), KEY),
          ),
        );
        expect(outcomes.filter((outcome) => outcome === "written")).toHaveLength(1);
        expect(outcomes.filter((outcome) => outcome === "already_claimed")).toHaveLength(9);
        expect(await rows()).toHaveLength(1);
      } finally {
        await Promise.all(racers.map((racer) => racer.end()));
      }
    });

    itUnderHangBackstop("scopes the claim to the account, so two accounts may use one key", async () => {
      // §9.2's keys are scoped so one account's cannot collide with — or replay — another's. A
      // global key space would let one account's request silence another's bill.
      await takeKey();
      await takeKey(KEY, OTHER_ACCOUNT);
      expect(await writeMeteringEvent(client, event(), KEY)).toBe("written");
      expect(await writeMeteringEvent(client, event({ accountId: OTHER_ACCOUNT }), KEY)).toBe(
        "written",
      );
      expect(await rows()).toHaveLength(2);
    });

    itUnderHangBackstop("meters every keyless write, because none of them has a guarantee to share", async () => {
      // SONNY-300's trap avoided at the level below the hook: with no key there is no row and no
      // claim, and treating that as "already metered" would make every keyless call free.
      expect(await writeMeteringEvent(client, event({ idempotencyKey: null }), null)).toBe("written");
      expect(
        await writeMeteringEvent(client, event({ idempotencyKey: null, requestId: "second" }), null),
      ).toBe("written");
      expect(await rows()).toHaveLength(2);
      expect(await meteringEventClaimed(client, { accountScope: ACCOUNT, key: KEY })).toBeNull();
    });

    itUnderHangBackstop("gives the claim back when the insert fails, so the event is not lost with it", async () => {
      // **The reason SONNY-300's read API takes the caller's own client.** Claim and insert are one
      // transaction: a failed insert must not leave a taken claim behind, because that key would
      // then be permanently unbillable while nothing had been recorded. Driven with a row the CHECK
      // constraint refuses, which is the cheapest real failure available.
      await takeKey();
      await expect(
        writeMeteringEvent(client, event({ outcome: "served" as MeteringEvent["outcome"] }), KEY),
      ).rejects.toThrow(/violates check constraint/);
      expect(await rows()).toHaveLength(0);
      // The claim is untaken, so a retry can still record what this attempt could not.
      expect(await meteringEventClaimed(client, { accountScope: ACCOUNT, key: KEY })).toBe(false);
      expect(await writeMeteringEvent(client, event(), KEY)).toBe("written");
      expect(await rows()).toHaveLength(1);
    });

    itUnderHangBackstop("survives the key store releasing and re-claiming the key, which is what a retry does", async () => {
      // §9.2's founder decision of 2026-08-28: a retryable failure releases the key so the retry
      // genuinely re-runs — and `releaseClaim` deliberately does not clear `metering_claimed_at`, so
      // the second run's usage goes unbilled. This is that sentence as two calls.
      await takeKey();
      expect(await writeMeteringEvent(client, event(), KEY)).toBe("written");
      // The key comes back and a second attempt really runs.
      await client.query(
        "UPDATE sonny.idempotency_key SET state = 'released' WHERE account_scope = $1",
        [ACCOUNT],
      );
      const second = await claimKey(client, {
        accountScope: ACCOUNT,
        key: KEY,
        route: "POST /v1/transcriptions",
        fingerprint: "sha256:aaa",
      });
      expect(second.kind).toBe("claimed");
      expect(await writeMeteringEvent(client, event({ requestId: "second" }), KEY)).toBe(
        "already_claimed",
      );
      expect(await rows()).toHaveLength(1);
    });

    itUnderHangBackstop("records an event whose key names no row, rather than losing it to an ambiguous false", async () => {
      // **SONNY-300's trap, driven rather than described.** `claimMeteringEvent` answers `false`
      // both for "already taken" and for "there is no row", and reading the second as the first
      // would serve a call for free with nothing anywhere saying so. Unreachable from the gateway —
      // a granted claim means a row exists and nothing deletes one — so the outcome is what says the
      // invariant broke, while the money is still recorded.
      expect(await writeMeteringEvent(client, event(), KEY)).toBe("written_without_claim");
      expect(await rows()).toHaveLength(1);
      // And it stays unprotected, honestly: a repeat under the same key writes a second event,
      // because there was never a claim for one to be about.
      expect(await writeMeteringEvent(client, event({ requestId: "second" }), KEY)).toBe(
        "written_without_claim",
      );
      expect(await rows()).toHaveLength(2);
    });

    itUnderHangBackstop("is the same guarantee through postgresMeteringStore", async () => {
      // The store the running gateway actually uses, over a connection it leases per call — so the
      // claim and the insert are one transaction on one connection rather than two on two.
      await takeKey();
      const store = postgresMeteringStore(async (work) => work(client));
      expect(await store.write(event(), KEY)).toBe("written");
      expect(await store.write(event({ requestId: "second" }), KEY)).toBe("already_claimed");
      expect(await rows()).toHaveLength(1);
    });
  });

  describe("the usage clock is not the content clock", () => {
    itUnderHangBackstop("keeps an event far older than the content retention window", async () => {
      // §10.3: content on the short clock (a task is deleted 30 days after it ends), usage kept
      // indefinitely. Back-dated four hundred days, past every content window this project names.
      await insertMeteringEvent(client, event());
      await client.query("UPDATE sonny.metering_event SET occurred_at = now() - interval '400 days'");

      const span = await meteringSpan(client);
      expect(span.events).toBe(1);
      const ageDays = (Date.now() - span.oldest!.getTime()) / (24 * 60 * 60 * 1000);
      expect(ageDays).toBeGreaterThan(365);
      // And it is still readable through the founder query path, not merely present in the table.
      const totals = await routeTotals(client);
      expect(totals.find((total) => total.route === "transcription")?.calls).toBe(1);
    });

    itUnderHangBackstop("is untouched by every sweep this gateway has", async () => {
      // **Enumerated rather than asserted in general**, because "nothing deletes it" is a negative
      // and the evidence for one lives everywhere you did not look. The two operations that clear
      // data sharing a key with this event are in `idempotency/store.ts`, and both are run here.
      // (The task sweep and the account close delete `agent_task` rows, which this table never
      // references.)
      const claimed = await claimKey(client, {
        accountScope: ACCOUNT,
        key: KEY,
        route: "POST /v1/transcriptions",
        fingerprint: "sha256:aaa",
      });
      if (claimed.kind !== "claimed") throw new Error("the key was not claimable");
      await completeClaim(
        client,
        { accountScope: ACCOUNT, key: KEY, token: claimed.token },
        {
          status: 200,
          body: Buffer.from("{}"),
          contentType: "application/json",
          requestId: "r",
        },
      );
      await writeMeteringEvent(client, event(), KEY);
      expect(await rows()).toHaveLength(1);

      // The response's twenty-four hours elapse.
      await client.query(
        "UPDATE sonny.idempotency_key SET response_expires_at = now() - interval '1 hour'",
      );
      expect(await pruneExpiredResponses(client)).toBe(1);
      expect(await deleteStoredResponsesForAccount(client, ACCOUNT)).toBe(0);

      // The stored content is gone; the usage is not, and neither is the claim that keeps the key
      // from being billed twice on day two.
      expect(await rows()).toHaveLength(1);
      expect(await meteringEventClaimed(client, { accountScope: ACCOUNT, key: KEY })).toBe(true);
    });
  });

  describe("what every route cost", () => {
    itUnderHangBackstop("totals the metered route, and leaves out rows under a route no longer metered", async () => {
      await insertMeteringEvent(client, event({ tokenSource: "estimated", audioDurationSeconds: 4.8 }));
      await insertMeteringEvent(
        client,
        event({ requestId: "second", idempotencyKey: "second-key", inputTokens: null, outputTokens: null, totalTokens: null, tokenSource: null }),
      );
      // A row V1 wrote under a route V2 no longer meters. The table's CHECK still admits it.
      await insertMeteringEvent(
        client,
        event({ requestId: "v1-row", idempotencyKey: "v1-key", route: "plan" as MeteringEvent["route"] }),
      );
      const totals = await routeTotals(client);
      expect(totals.map((total) => total.route)).toEqual(["transcription"]);
      const [transcription] = totals;
      expect(transcription!.calls).toBe(2);
      expect(transcription!.estimatedTotalTokens).toBe(1940);
      expect(transcription!.reportedTotalTokens).toBe(0);
      expect(transcription!.callsWithoutTokens).toBe(1);
      expect(transcription!.audioSeconds).toBeCloseTo(4.8);
    });
  });

  describe("the founder command", () => {
    itUnderHangBackstop("prints no price on either report, which is the never-touch list asserted", async () => {
      // **Every report, not just one** (PR #147's review, F8 — this covered one and the PR body
      // generalised it). The ticket's never-touch list is one line: no price, no plan, no tier, no
      // credit weight, and no number that implies one.
      //
      // Driven over a real corpus, so a report that is empty cannot pass this by having nothing to
      // say. **Nothing in the corpus may contain a forbidden word itself**, which is not a
      // hypothetical: the first draft named a fixture `session-price`, and the assertion failed on
      // its own fixture rather than on anything the renderer wrote.
      for (const index of [1, 2]) {
        await insertMeteringEvent(
          client,
          event({
            idempotencyKey: `forbidden-words-key-${index}`,
            requestId: `forbidden-words-request-${index}`,
            audioDurationSeconds: 4.8,
          }),
        );
      }

      const reports = {
        routes: await reportRoutes(client, {}),
        span: await reportSpan(client, {}),
      };
      for (const [name, report] of Object.entries(reports)) {
        // Named in the assertion rather than looped silently, so a failure says which report.
        expect(`${name}: ${report.length > 0}`).toBe(`${name}: true`);
        expect(`${name}: ${/[$£€¥₹]/.test(report)}`).toBe(`${name}: false`);
        for (const forbidden of ["price", "pricing", "credit", "cost per", "per token", "tier", "plan tier"]) {
          expect(`${name} contains ${forbidden}: ${report.toLowerCase().includes(forbidden)}`).toBe(
            `${name} contains ${forbidden}: false`,
          );
        }
      }
      // The corpus really did reach both, or the loop above asserted over nothing.
      expect(reports.routes).toContain("transcription");
      expect(reports.span).toContain("2 metering event(s)");
    });

    itUnderHangBackstop("reports how far back usage goes, which is the two clocks made visible", async () => {
      await insertMeteringEvent(client, event());
      await client.query("UPDATE sonny.metering_event SET occurred_at = now() - interval '400 days'");
      const report = await reportSpan(client, {});
      expect(report).toContain("1 metering event(s)");
      expect(report).toMatch(/40\d\.\d days ago/);
      expect(report).toContain("long clock");
    });
  });
});
