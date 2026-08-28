import type pg from "pg";
import type { WithConnection } from "../db/connection.js";
import { claimMeteringEvent, meteringEventClaimed } from "../idempotency/store.js";
import type { MeteringEvent } from "./event.js";

/**
 * Writing a metering event, and the one guarantee that makes a retry free (SONNY-133).
 *
 * **The at-most-once mechanism is SONNY-300's and is consumed here, never rebuilt.** Contract §9.2:
 * "A metering event is written at most once per idempotency key, ever." That sentence has two
 * halves, and SONNY-300's hand-over on this ticket names which is whose — it keeps the key half
 * (one row per `(account_scope, idempotency_key)`, carrying a `metering_claimed_at` set exactly
 * once), and this file keeps the event half: **ask for the claim, and write the event only if you
 * got it.** Nothing here counts, compares timestamps or checks for a duplicate row; the claim is
 * the whole of it, and a second mechanism beside it is how "at most once" ends up enforced by
 * neither.
 *
 * **The claim and the insert are one transaction, and that is not a preference.** SONNY-300's
 * `claimMeteringEvent` takes the caller's own `pg.Client` for exactly this reason: claiming outside
 * the transaction leaves a window where the claim is taken and the event is not, and a crash there
 * loses the event permanently — the same money, in the other direction.
 *
 * **A `false` from `claimMeteringEvent` is not always "already metered", and the difference decides
 * whether a call is billed.** SONNY-300 states the trap: a `POST` carrying no `Idempotency-Key`
 * writes no row at all, so the claim answers `false` for it — the same value as "someone else took
 * it". Reading that `false` as "already metered" would make every keyless request free. So the key's
 * *presence* is checked before the claim is ever attempted: `write` takes `key: string | null`, and
 * a `null` key goes down a branch that never calls `claimMeteringEvent`.
 */

/** What a write attempt turned out to be. Returned so a caller can log the reason it wrote nothing. */
export type MeteringWriteOutcome =
  /** The event is in the table, and this key's one claim is now taken. */
  | "written"
  /**
   * This key's one event was already taken. Contract §9.2 working: a client retry, or a re-attempt
   * that a released retryable failure allowed, whose usage goes deliberately unbilled.
   */
  | "already_claimed"
  /**
   * The event is in the table and no claim protects it, because the key named no row.
   *
   * **This is SONNY-300's trap answered rather than inherited.** `claimMeteringEvent` returns
   * `false` both for "someone already took it" and for "there is no row for this key at all", and
   * reading the second as the first loses the event silently — a call served for free with nothing
   * anywhere saying so. The two are told apart with `meteringEventClaimed`, whose three-valued
   * answer exists for exactly this, and the money is recorded either way.
   *
   * **It should be unreachable from the gateway**, and it is returned rather than assumed away so
   * that if it ever happens somebody can see it: the metering hook passes a key only when the
   * idempotency hook granted a claim, which means the row was inserted; nothing in this codebase
   * deletes one (`pruneExpiredResponses` clears payloads and keeps rows). A caller reaching this has
   * a broken invariant somewhere above it, not a free call.
   */
  | "written_without_claim";

export interface MeteringStore {
  /**
   * Write one event, gated on the key's claim when there is a key.
   *
   * `key` is `null` for a `POST` that carried no `Idempotency-Key` — served by founder decision of
   * 2026-08-28 — and such a request is metered unconditionally. It has no at-most-once guarantee
   * available to it, because there is no key for one to be about, and the alternative is worse: a
   * dropped event is a free call, which is the exact failure §10.1 records for incognito and the
   * one this ticket exists to close.
   */
  write: (event: MeteringEvent, key: string | null) => Promise<MeteringWriteOutcome>;
}

/** The columns, in the order the insert binds them. One list, so a drift is a compile error. */
const COLUMNS = [
  "request_id",
  "idempotency_key",
  "account_id",
  "route",
  "provider",
  "failed_over",
  "model",
  "input_tokens",
  "output_tokens",
  "total_tokens",
  "token_source",
  "image_bytes",
  "image_pixel_width",
  "image_pixel_height",
  "image_media_type",
  "audio_duration_seconds",
  "request_bytes",
  "response_bytes",
  "duration_ms",
  "upstream_duration_ms",
  "outcome",
  "task_id",
  "session_id",
  "session_iteration",
  "retention",
  "client_version",
] as const;

function values(event: MeteringEvent): unknown[] {
  return [
    event.requestId,
    event.idempotencyKey,
    event.accountId,
    event.route,
    event.provider,
    // `pg` maps a JS array onto a Postgres array, so this is `text[]` without a literal to build.
    event.failedOver,
    event.model,
    event.inputTokens,
    event.outputTokens,
    event.totalTokens,
    event.tokenSource,
    event.imageBytes,
    event.imagePixelWidth,
    event.imagePixelHeight,
    event.imageMediaType,
    event.audioDurationSeconds,
    event.requestBytes,
    event.responseBytes,
    event.durationMs,
    event.upstreamDurationMs,
    event.outcome,
    event.taskId,
    event.sessionId,
    event.sessionIteration,
    event.retention,
    event.clientVersion,
  ];
}

const INSERT = `INSERT INTO sonny.metering_event (${COLUMNS.join(", ")})
       VALUES (${COLUMNS.map((_column, index) => `$${index + 1}`).join(", ")})`;

/** The insert alone, on a connection the caller owns. `occurred_at` is the column's own default. */
export async function insertMeteringEvent(
  client: pg.Client,
  event: MeteringEvent,
): Promise<void> {
  await client.query(INSERT, values(event));
}

/**
 * Claim, then insert, in one transaction — or claim nothing and insert nothing.
 *
 * The rollback on a lost claim matters as much as the commit: the `BEGIN` has already happened by
 * the time the claim comes back, and leaving that transaction open would hold the connection for the
 * life of the pool lease.
 */
export async function writeMeteringEvent(
  client: pg.Client,
  event: MeteringEvent,
  key: string | null,
): Promise<MeteringWriteOutcome> {
  await client.query("BEGIN");
  try {
    let outcome: MeteringWriteOutcome = "written";
    if (key !== null) {
      const claimed = await claimMeteringEvent(client, {
        accountScope: event.accountId,
        key,
      });
      if (!claimed) {
        // **`false` alone does not say why**, and the two reasons have opposite answers. A row whose
        // claim is taken means an earlier attempt owns this key's one event and this one writes
        // nothing; no row at all means there is no guarantee available to be about, and dropping the
        // event would make the call free. `meteringEventClaimed` is read-only and three-valued for
        // this question, and it runs inside the same transaction so it sees the same row the claim
        // just failed against.
        const state = await meteringEventClaimed(client, {
          accountScope: event.accountId,
          key,
        });
        if (state !== null) {
          await client.query("ROLLBACK");
          return "already_claimed";
        }
        outcome = "written_without_claim";
      }
    }
    await insertMeteringEvent(client, event);
    await client.query("COMMIT");
    return outcome;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}

/**
 * The `MeteringStore` over a real connection source.
 *
 * **The account scope the claim uses is `event.accountId`, and it has to be the value the hook used**
 * — SONNY-300's hand-over is explicit that a different scope looks at a different row. The metering
 * hook only writes for an authenticated caller, so `request.auth.accountId` is that value on both
 * sides; a request with no account writes nothing at all, so `UNAUTHENTICATED_SCOPE` never reaches
 * here.
 */
export function postgresMeteringStore(withConnection: WithConnection): MeteringStore {
  return {
    write: (event, key) => withConnection((client) => writeMeteringEvent(client, event, key)),
  };
}
