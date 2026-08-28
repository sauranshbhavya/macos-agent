import type pg from "pg";
import { meteredRoutes, type MeteredRoute } from "../metering/event.js";

/**
 * The documented snapshots training reads from, and the lineage that makes a deletion traceable
 * (SONNY-134). Contract §10.2 and §10.3.
 *
 * **Training never reads the live store, and the reason is the delete path rather than tidiness.**
 * Row 12's plan §4.2, consequence 3: "Training reads from documented snapshots with recorded
 * lineage, never directly from the live store, so a deletion request can be traced to which
 * snapshots it touched. This cannot be retrofitted once data has been trained on." A snapshot that
 * were a saved query would leave nothing to trace once the content behind it expired — no record
 * that a row had ever been selected, and no way to answer which training set a deleted task
 * reached. So a member carries a copy of the content and the `content_id` it came from, and keeps
 * naming that source after the source is gone.
 *
 * ## The two exclusions, and why only one of them is a `WHERE` clause
 *
 * **Consent is a join, plus a trigger under it.** §10.2's field defaults to not-granted and is
 * `NOT NULL`, so a user whose consent was never written is excluded by the same predicate that
 * excludes one who declined — there is no third state. The join below is the mechanism; 0013's
 * `training_snapshot_member_consent` trigger refuses a member the join would have caught anyway,
 * because training on the content of a user who did not consent is not a defect that can be
 * repaired afterwards, and one predicate in one statement is a thin thing to rest that on.
 *
 * **Incognito is not a predicate at all, and that is §10.1's second rule kept rather than
 * described.** "Structurally excluded from training snapshots, not filtered by a query: if an
 * incognito run can reach a snapshot because someone dropped a `WHERE` clause, the guarantee is not
 * one." There is no `retention` filter in the statement below — look for one — because
 * `sonny.retained_content` cannot hold an incognito row: the writer refuses first and the table's
 * CHECK admits exactly one value. Deleting every predicate in this file would widen the snapshot to
 * every consenting account's stored content and would still not reach a single incognito run, which
 * is what `content.db.test.ts` proves by running the unfiltered statement itself.
 *
 * A closed account is excluded too. Its content is on its way out; adding it to a training set on
 * the way would be the opposite of what closing an account means.
 */

/**
 * Stamped on every snapshot, so a training run can say which builder produced its corpus.
 *
 * Bumped when what a member *contains* changes — a new content column copied, a different selection
 * rule — and not for a refactor. A snapshot built by a builder that no longer exists is exactly the
 * thing this field is for.
 */
export const SNAPSHOT_BUILDER_VERSION = "1";

export interface SnapshotRequest {
  /** §10.3's "documented": the name a training run and a deletion report both quote. */
  readonly label: string;
  readonly since?: Date | undefined;
  readonly until?: Date | undefined;
  /** Empty or absent means every route. */
  readonly routes?: readonly MeteredRoute[] | undefined;
  /**
   * The snapshot's own clock, or `undefined` for none set.
   *
   * §10.3 puts snapshots on "their own separately-consented lifecycle" and names no number; no
   * founder has set one. `undefined` writes NULL, which `expireSnapshots` skips — see `store.ts`
   * for why that is the honest value rather than a missing feature.
   */
  readonly expiresAt?: Date | undefined;
}

export interface SnapshotResult {
  readonly snapshotId: string;
  readonly label: string;
  readonly memberCount: number;
}

/** The content columns a member copies, in one list so the two halves of the insert cannot drift. */
const CONTENT_COLUMNS = [
  "request_text",
  "voice_audio",
  "voice_audio_media_type",
  "voice_audio_filename",
  "screenshot",
  "screenshot_media_type",
  "response_status",
  "response_content_type",
  "response_body",
  "provider_error_status",
  "provider_error_body",
] as const;

/**
 * The statement that fills a snapshot, with every predicate it has.
 *
 * Exported because `content.db.test.ts` runs a **deliberately unfiltered** version of it — the same
 * `INSERT … SELECT` with the `WHERE` gone — to prove that removing every filter still cannot reach
 * an incognito run. A test that wrote its own approximation of this statement would prove something
 * about the approximation.
 */
export const SNAPSHOT_MEMBER_SELECT = `
  SELECT $1::uuid, rc.content_id, rc.account_id, rc.task_id, rc.request_id, rc.route,
         rc.occurred_at, ${CONTENT_COLUMNS.map((column) => `rc.${column}`).join(", ")}
    FROM sonny.retained_content rc
    JOIN sonny.account a ON a.id = rc.account_id`;

const MEMBER_TARGET = `sonny.training_snapshot_member
  (snapshot_id, content_id, account_id, task_id, request_id, route, source_occurred_at,
   ${CONTENT_COLUMNS.join(", ")})`;

/**
 * Build one snapshot from the live store and seal it.
 *
 * **One transaction, so a snapshot is never half-built and never sealed empty by accident.** The
 * row, its members and its `member_count` land together or not at all; a partially populated
 * snapshot that a training run then read would be a corpus nobody could describe.
 *
 * `member_count` is written from the insert's own row count rather than recounted, because inside
 * this transaction they are the same number and the insert is the thing that knows it.
 */
export async function buildTrainingSnapshot(
  client: pg.Client,
  request: SnapshotRequest,
): Promise<SnapshotResult> {
  const routes = request.routes ?? [];
  await client.query("BEGIN");
  try {
    const { rows } = await client.query<{ snapshot_id: string }>(
      `INSERT INTO sonny.training_snapshot
         (label, window_start, window_end, routes, builder_version, expires_at)
       VALUES ($1, $2, $3, $4::text[], $5, $6)
       RETURNING snapshot_id::text AS snapshot_id`,
      [
        request.label,
        request.since ?? null,
        request.until ?? null,
        routes,
        SNAPSHOT_BUILDER_VERSION,
        request.expiresAt ?? null,
      ],
    );
    const snapshotId = rows[0]!.snapshot_id;

    const inserted = await client.query(
      `INSERT INTO ${MEMBER_TARGET}
       ${SNAPSHOT_MEMBER_SELECT}
       WHERE a.training_consent
         AND a.deleted_at IS NULL
         AND ($2::timestamptz IS NULL OR rc.occurred_at >= $2)
         AND ($3::timestamptz IS NULL OR rc.occurred_at < $3)
         AND ($4::text[] = '{}' OR rc.route = ANY($4::text[]))`,
      [snapshotId, request.since ?? null, request.until ?? null, routes],
    );
    const memberCount = inserted.rowCount ?? 0;

    await client.query(
      "UPDATE sonny.training_snapshot SET member_count = $2, sealed_at = now() WHERE snapshot_id = $1",
      [snapshotId, memberCount],
    );
    await client.query("COMMIT");
    return { snapshotId, label: request.label, memberCount };
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}

/** Which snapshots hold content from this task, without deleting anything. */
export async function snapshotsHoldingTask(
  client: pg.Client,
  request: { readonly accountId: string; readonly taskId: string },
): Promise<{ readonly snapshotId: string; readonly label: string; readonly rows: number }[]> {
  const { rows } = await client.query<{ snapshot_id: string; label: string; rows: string }>(
    `SELECT s.snapshot_id::text AS snapshot_id, s.label, count(*)::text AS rows
       FROM sonny.training_snapshot_member m
       JOIN sonny.training_snapshot s ON s.snapshot_id = m.snapshot_id
      WHERE m.account_id = $1 AND m.task_id = $2
      GROUP BY s.snapshot_id, s.label
      ORDER BY s.label`,
    [request.accountId, request.taskId],
  );
  return rows.map((row) => ({
    snapshotId: row.snapshot_id,
    label: row.label,
    rows: Number(row.rows),
  }));
}

/** Whether a string is one of §11's five routes, for a CLI argument that has not been validated. */
export function isMeteredRoute(value: string): value is MeteredRoute {
  return (meteredRoutes as readonly string[]).includes(value);
}
