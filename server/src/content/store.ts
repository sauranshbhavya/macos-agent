import type pg from "pg";
import type { WithConnection } from "../db/connection.js";
import type { RetainedContent } from "./record.js";

/**
 * Writing content, and the three ways it stops being kept (SONNY-134). Contract §10 and §4.6.
 *
 * **Every removal path in this file writes a row to `sonny.content_deletion` in the same
 * transaction as the removal.** That is what turns §10.3's "expiry must actually run and be
 * observable, not be a column nobody enforces" and §4.6's "traceable to which snapshots it touched"
 * into properties of the system rather than of a log nobody kept. A deletion whose record could be
 * lost separately from the deletion would be a record that eventually disagrees with the tables.
 *
 * **Every removal path also reaches training snapshots, and that is the whole reason lineage is
 * carried.** §4.6: delete "must reach training snapshots, not only the live content store". A
 * member holds a copy rather than a pointer (0013's header says why), so deleting the live row
 * alone would leave the content in the training set with nothing left pointing at it — the exact
 * failure row 12's plan §4.2 calls impossible to retrofit "once data has been trained on".
 */

/** The columns of `sonny.retained_content`, in the order the insert binds them. */
const COLUMNS = [
  "request_id",
  "account_id",
  "task_id",
  "session_id",
  "session_iteration",
  "route",
  "expires_at",
  // **Bound explicitly, and that is the whole of F3's fix** (PR #148's review). With the column
  // omitted every insert took the table's default, so the CHECK could only ever refuse a
  // hand-written statement the gateway cannot emit — a backstop for nobody. The value bound is the
  // one the caller declared, so a wrong `isStorable` above writes `'none'` here and the constraint
  // refuses it. The column's `DEFAULT` was dropped in the same change: a default is what let this
  // go unnoticed, and without one a writer that forgets the column fails loudly on NOT NULL.
  "retention",
  "provider",
  "provider_request_id",
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

const INSERT = `INSERT INTO sonny.retained_content (${COLUMNS.join(", ")})
       VALUES (${COLUMNS.map((_column, index) => `$${index + 1}`).join(", ")})
       ON CONFLICT (request_id) DO NOTHING`;

function values(content: RetainedContent): unknown[] {
  return [
    content.requestId,
    content.accountId,
    content.taskId,
    content.sessionId,
    content.sessionIteration,
    content.route,
    content.expiresAt,
    // `undefined` — a request that declared nothing — is normalised to an explicit NULL rather than
    // left for `pg` to infer, and an explicit NULL against a NOT NULL column is a refusal. That is
    // the second half of the backstop: `isStorable` already excludes it, and if it ever did not, the
    // row does not land.
    content.retention ?? null,
    content.provider,
    content.providerRequestId,
    // `pg` serialises this as JSON for a `jsonb` parameter. `null` stays SQL NULL rather than the
    // JSON `null` literal, which are different values in a `jsonb` column and would read as "the
    // client sent null" instead of "there was nothing to keep".
    content.requestText === null ? null : JSON.stringify(content.requestText),
    content.voiceAudio,
    content.voiceAudioMediaType,
    content.voiceAudioFilename,
    content.screenshot,
    content.screenshotMediaType,
    content.responseStatus,
    content.responseContentType,
    content.responseBody,
    content.providerErrorStatus,
    content.providerErrorBody,
  ];
}

/**
 * Store one call's content.
 *
 * **`ON CONFLICT (request_id) DO NOTHING` rather than an error**, because the two writers in
 * `content/hook.ts` are "whichever gets there first" and a lost race is not a failure — the row is
 * already there and it is the same row. The `written` flag makes the second write not happen at
 * all; this is what remains true if that flag is ever wrong.
 *
 * **Nothing here consults `retention`.** By the time this runs the caller has answered `isStorable`
 * and the table's own CHECK admits one value; a third check here would be a third place the same
 * decision could be made differently.
 */
export async function insertRetainedContent(
  client: pg.Client,
  content: RetainedContent,
): Promise<void> {
  await client.query(INSERT, values(content));
}

/** What one removal took. `snapshotsTouched` is §4.6's traceability, and is the point of it. */
export interface DeletionOutcome {
  readonly contentRows: number;
  readonly snapshotRows: number;
  readonly snapshotsTouched: readonly string[];
  readonly storedResponses: number;
}

const NOTHING: DeletionOutcome = {
  contentRows: 0,
  snapshotRows: 0,
  snapshotsTouched: [],
  storedResponses: 0,
};

/**
 * Remove snapshot members and say which snapshots lost rows, then correct those snapshots' counts.
 *
 * `member_count` is corrected rather than decremented: recounting is one statement over an indexed
 * column, and a decrement that ever ran twice would leave a sealed snapshot describing a membership
 * it does not have.
 */
async function removeSnapshotMembers(
  client: pg.Client,
  where: string,
  parameters: readonly unknown[],
): Promise<{ rows: number; snapshots: string[] }> {
  const { rows } = await client.query<{ removed: string; snapshots: string[] }>(
    `WITH removed AS (
       DELETE FROM sonny.training_snapshot_member WHERE ${where} RETURNING snapshot_id
     )
     SELECT count(*)::text AS removed,
            coalesce(array_agg(DISTINCT snapshot_id::text), '{}') AS snapshots
       FROM removed`,
    [...parameters],
  );
  const removed = Number(rows[0]?.removed ?? 0);
  const snapshots = rows[0]?.snapshots ?? [];
  if (snapshots.length > 0) {
    await client.query(
      `UPDATE sonny.training_snapshot s
          SET member_count = (SELECT count(*) FROM sonny.training_snapshot_member m
                               WHERE m.snapshot_id = s.snapshot_id)
        WHERE s.snapshot_id = ANY($1::uuid[])`,
      [snapshots],
    );
  }
  return { rows: removed, snapshots };
}

async function recordDeletion(
  client: pg.Client,
  entry: {
    reason: "task" | "account" | "expiry" | "snapshot_expiry";
    accountId: string | null;
    taskId: string | null;
    outcome: DeletionOutcome;
  },
): Promise<void> {
  await client.query(
    `INSERT INTO sonny.content_deletion
       (reason, account_id, task_id, content_rows, snapshot_rows, snapshots_touched,
        stored_responses)
     VALUES ($1, $2, $3, $4, $5, $6::uuid[], $7)`,
    [
      entry.reason,
      entry.accountId,
      entry.taskId,
      entry.outcome.contentRows,
      entry.outcome.snapshotRows,
      entry.outcome.snapshotsTouched,
      entry.outcome.storedResponses,
    ],
  );
}

/**
 * Whose task is this?
 *
 * §4.6 draws a line this function exists to keep on the right side of: "A task with nothing stored
 * returns success, not 404 … `404 resource.not_found` is reserved for a `task_id` that belongs to a
 * different user. It never means 'nothing was stored.'"
 *
 * So there are three answers, not two. **`unknown` is the incognito case and the signed-out case**,
 * and both must succeed with nothing deleted: a delete that is already true must not surface as an
 * error the user has to interpret. It reads both tables because a task can be known to this gateway
 * through its usage while having no content at all — which is exactly what an incognito run is.
 */
export type TaskOwnership = "mine" | "other" | "unknown";

export async function taskOwnership(
  client: pg.Client,
  request: { readonly accountId: string; readonly taskId: string },
): Promise<TaskOwnership> {
  const { rows } = await client.query<{ mine: boolean | null }>(
    `SELECT bool_or(account_id = $1) AS mine
       FROM (SELECT account_id FROM sonny.metering_event WHERE task_id = $2
             UNION ALL
             SELECT account_id FROM sonny.retained_content WHERE task_id = $2) AS known`,
    [request.accountId, request.taskId],
  );
  const mine = rows[0]?.mine;
  if (mine === null || mine === undefined) return "unknown";
  return mine ? "mine" : "other";
}

/**
 * Delete everything stored for one task: the live content, and the training snapshots that copied
 * it.
 *
 * **Scoped by account as well as by task, always.** `task_id` is client-minted, so a query keyed on
 * it alone would let one account's delete reach another's rows if two ever collided; the route
 * checks ownership first and this scopes the statement anyway, because a destructive primitive that
 * relies on its caller having checked is one refactor from being wrong.
 *
 * **Metering is untouched, and that is §10.3's two clocks rather than an omission.** Usage lives
 * indefinitely and holds no content; deleting it would destroy the record of what the account spent
 * in order to delete a screenshot that is going anyway. §4.6's `requests_deleted` counts content
 * rows for the same reason.
 */
export async function deleteContentForTask(
  client: pg.Client,
  request: { readonly accountId: string; readonly taskId: string },
): Promise<DeletionOutcome> {
  await client.query("BEGIN");
  try {
    const removed = await removeSnapshotMembers(client, "account_id = $1 AND task_id = $2", [
      request.accountId,
      request.taskId,
    ]);
    const content = await client.query(
      "DELETE FROM sonny.retained_content WHERE account_id = $1 AND task_id = $2",
      [request.accountId, request.taskId],
    );
    const outcome: DeletionOutcome = {
      contentRows: content.rowCount ?? 0,
      snapshotRows: removed.rows,
      snapshotsTouched: removed.snapshots,
      storedResponses: 0,
    };
    // **Recorded even when it took nothing**, because §4.6 makes "there was nothing to delete" a
    // success, and a record that only ever fired on a hit could not tell that apart from a delete
    // that never ran.
    await recordDeletion(client, {
      reason: "task",
      accountId: request.accountId,
      taskId: request.taskId,
      outcome,
    });
    await client.query("COMMIT");
    return outcome;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}

/**
 * What one bulk removal took, per task and in total (SONNY-404).
 *
 * `notMine` names the submitted ids that belong to a **different** account. It is a count rather
 * than the ids themselves: the caller sent them, so echoing them back discloses nothing, but the
 * only thing the client does with the answer is decide whether its queued obligation is finished —
 * and a count answers that. Nothing renders it.
 */
export interface BulkDeletionOutcome {
  readonly tasksDeleted: number;
  readonly notMine: number;
  readonly contentRows: number;
  readonly snapshotRows: number;
  readonly snapshotsTouched: readonly string[];
}

/** Which of these task ids belong to somebody else. Everything else is this account's to delete. */
async function foreignTaskIds(
  client: pg.Client,
  request: { readonly accountId: string; readonly taskIds: readonly string[] },
): Promise<Set<string>> {
  const { rows } = await client.query<{ task_id: string }>(
    // `bool_or` per task, exactly as `taskOwnership` does for one: a task is somebody else's only
    // when this gateway knows it and knows it under another account. A task it has never heard of
    // is `unknown`, which §4.6 makes a success with nothing deleted rather than a 404 — so it is
    // deliberately absent from this result.
    `SELECT task_id
       FROM (SELECT task_id, account_id FROM sonny.metering_event WHERE task_id = ANY($2::text[])
             UNION ALL
             SELECT task_id, account_id FROM sonny.retained_content WHERE task_id = ANY($2::text[])
            ) AS known
      GROUP BY task_id
     HAVING bool_or(account_id = $1) IS FALSE`,
    [request.accountId, [...request.taskIds]],
  );
  return new Set(rows.map((row) => row.task_id));
}

/**
 * Delete everything stored for several tasks at once — the Memory page's *Task history › Delete*,
 * which removes every row the Mac holds (SONNY-404, contract §4.6.1).
 *
 * **One call rather than one per row is the founder's decision of 2026-09-05**, and it is a decision
 * about the number of requests and about nothing else. What this writes is byte-for-byte what the
 * same tasks deleted one at a time would have written: one `sonny.content_deletion` row per task,
 * carrying that task's own counts and its own `snapshots_touched`, including a row of zeroes for a
 * task that stored nothing. A bulk path that recorded one summary row instead would make the record
 * of a wipe read differently from the record of the same deletions performed slowly, which is how a
 * later reader concludes the two paths did different things.
 *
 * **Scoped by account in every statement, as `deleteContentForTask` is and for its reason.** The
 * ownership read above decides what is reported; the scope is what makes the statement safe if that
 * read is ever wrong.
 *
 * **A task belonging to another account is skipped, never a failure for the batch.** §4.6 answers
 * one foreign id with a 404, and the batch equivalent of refusing the whole call would make one
 * stale id on a shared Mac able to strand every other deletion in the queue indefinitely. The count
 * goes back so the client can keep the obligation instead — the same "not deliverable by this
 * session, never not deliverable" reading §4.6's 404 already has.
 */
export async function deleteContentForTasks(
  client: pg.Client,
  request: { readonly accountId: string; readonly taskIds: readonly string[] },
): Promise<BulkDeletionOutcome> {
  const submitted = [...new Set(request.taskIds)];
  if (submitted.length === 0) {
    return { tasksDeleted: 0, notMine: 0, contentRows: 0, snapshotRows: 0, snapshotsTouched: [] };
  }

  await client.query("BEGIN");
  try {
    const foreign = await foreignTaskIds(client, { accountId: request.accountId, taskIds: submitted });
    const mine = submitted.filter((taskId) => !foreign.has(taskId));
    if (mine.length === 0) {
      await client.query("COMMIT");
      return {
        tasksDeleted: 0,
        notMine: foreign.size,
        contentRows: 0,
        snapshotRows: 0,
        snapshotsTouched: [],
      };
    }

    const members = await client.query<{ task_id: string; rows: string; snapshots: string[] }>(
      `WITH removed AS (
         DELETE FROM sonny.training_snapshot_member
          WHERE account_id = $1 AND task_id = ANY($2::text[])
        RETURNING task_id, snapshot_id
       )
       SELECT task_id,
              count(*)::text AS rows,
              coalesce(array_agg(DISTINCT snapshot_id::text), '{}') AS snapshots
         FROM removed
        GROUP BY task_id`,
      [request.accountId, mine],
    );
    const touched = [...new Set(members.rows.flatMap((row) => row.snapshots))];
    if (touched.length > 0) {
      // Recounted rather than decremented, for `removeSnapshotMembers`' reason: a decrement that
      // ever ran twice would leave a sealed snapshot describing a membership it does not have.
      await client.query(
        `UPDATE sonny.training_snapshot s
            SET member_count = (SELECT count(*) FROM sonny.training_snapshot_member m
                                 WHERE m.snapshot_id = s.snapshot_id)
          WHERE s.snapshot_id = ANY($1::uuid[])`,
        [touched],
      );
    }

    const content = await client.query<{ task_id: string; rows: string }>(
      `WITH removed AS (
         DELETE FROM sonny.retained_content
          WHERE account_id = $1 AND task_id = ANY($2::text[])
        RETURNING task_id
       )
       SELECT task_id, count(*)::text AS rows FROM removed GROUP BY task_id`,
      [request.accountId, mine],
    );

    const contentByTask = new Map(content.rows.map((row) => [row.task_id, Number(row.rows)]));
    const membersByTask = new Map(
      members.rows.map((row) => [row.task_id, { rows: Number(row.rows), snapshots: row.snapshots }]),
    );
    const records = mine.map((taskId) => ({
      task_id: taskId,
      content_rows: contentByTask.get(taskId) ?? 0,
      snapshot_rows: membersByTask.get(taskId)?.rows ?? 0,
      snapshots: membersByTask.get(taskId)?.snapshots ?? [],
    }));

    // One statement for every record, because the alternative is one round trip per deleted task
    // and this route exists to delete a whole history. `jsonb_to_recordset` is what lets the rows be
    // built client-side and still land as a single INSERT.
    await client.query(
      `INSERT INTO sonny.content_deletion
         (reason, account_id, task_id, content_rows, snapshot_rows, snapshots_touched)
       SELECT 'task', $1, entry.task_id, entry.content_rows, entry.snapshot_rows, entry.snapshots
         FROM jsonb_to_recordset($2::jsonb)
           AS entry(task_id text, content_rows integer, snapshot_rows integer, snapshots uuid[])`,
      [request.accountId, JSON.stringify(records)],
    );

    await client.query("COMMIT");
    return {
      tasksDeleted: mine.length,
      notMine: foreign.size,
      contentRows: records.reduce((total, entry) => total + entry.content_rows, 0),
      snapshotRows: records.reduce((total, entry) => total + entry.snapshot_rows, 0),
      snapshotsTouched: touched,
    };
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}

/** What one screenshot clear took. No row was removed; two columns were set to NULL. */
export interface ScreenshotClearOutcome {
  readonly screenshotsCleared: number;
  readonly snapshotScreenshotsCleared: number;
  readonly snapshotsTouched: readonly string[];
}

/**
 * Take one task's screenshots and leave the rest of that task alone (SONNY-404, contract §4.6.2).
 *
 * **An UPDATE to NULL, not a DELETE, and that is the whole difference from `deleteContentForTask`.**
 * The button this serves is *Delete what Sonny did on screen*: it removes the task's vision-session
 * record on the Mac and leaves the task, its command and its result standing. A row of
 * `sonny.retained_content` holds the screenshot beside the request text and the served response, so
 * deleting the row would take two things the button never mentions. §4.6's route is the one that
 * takes everything; this one is deliberately narrower, which is the founder decision of 2026-09-05.
 *
 * **It reaches training snapshots for the same reason every other removal path here does**, and
 * more sharply: a member holds a copy rather than a pointer, and `expireSnapshots` skips a NULL
 * `expires_at`, which is every snapshot the builder makes — so a screenshot left in a snapshot is
 * left there with no clock on it at all.
 *
 * **`screenshot_media_type` goes with `screenshot`.** A media type beside a NULL image describes
 * nothing and would be the one surviving trace of what was captured.
 *
 * **Scoped by account in both statements**, the same way and for the same reason as everything else
 * in this file: a `task_id` is client-minted, so a statement keyed on it alone is one collision away
 * from reaching another account's rows.
 */
export async function clearScreenshotsForTask(
  client: pg.Client,
  request: { readonly accountId: string; readonly taskId: string },
): Promise<ScreenshotClearOutcome> {
  await client.query("BEGIN");
  try {
    const members = await client.query<{ snapshots: string[]; rows: string }>(
      `WITH cleared AS (
         UPDATE sonny.training_snapshot_member
            SET screenshot = NULL, screenshot_media_type = NULL
          WHERE account_id = $1 AND task_id = $2 AND screenshot IS NOT NULL
        RETURNING snapshot_id
       )
       SELECT count(*)::text AS rows,
              coalesce(array_agg(DISTINCT snapshot_id::text), '{}') AS snapshots
         FROM cleared`,
      [request.accountId, request.taskId],
    );
    const snapshotRows = Number(members.rows[0]?.rows ?? 0);
    const snapshots = members.rows[0]?.snapshots ?? [];

    const live = await client.query(
      `UPDATE sonny.retained_content
          SET screenshot = NULL, screenshot_media_type = NULL
        WHERE account_id = $1 AND task_id = $2 AND screenshot IS NOT NULL`,
      [request.accountId, request.taskId],
    );

    const outcome: ScreenshotClearOutcome = {
      screenshotsCleared: live.rowCount ?? 0,
      snapshotScreenshotsCleared: snapshotRows,
      snapshotsTouched: snapshots,
    };

    // **Recorded even when it took nothing**, for `deleteContentForTask`'s reason: §4.6 makes "there
    // was nothing to delete" a success, and a record that only ever fired on a hit could not tell
    // that apart from a delete that never ran. `member_count` is untouched here, deliberately — no
    // member left the snapshot, so the count it describes has not changed.
    await client.query(
      `INSERT INTO sonny.content_deletion
         (reason, account_id, task_id, snapshots_touched, screenshots_cleared,
          snapshot_screenshots_cleared)
       VALUES ('task_screenshots', $1, $2, $3::uuid[], $4, $5)`,
      [
        request.accountId,
        request.taskId,
        outcome.snapshotsTouched,
        outcome.screenshotsCleared,
        outcome.snapshotScreenshotsCleared,
      ],
    );

    await client.query("COMMIT");
    return outcome;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}

/**
 * Everything one account has: content, snapshot membership, and its stored idempotency responses.
 *
 * **The third of those is SONNY-319, closed here rather than left as a function with no call site.**
 * `sonny.idempotency_key` holds response bodies for twenty-four hours, which makes it the one place
 * in the gateway holding response content outside the route that produced it, and
 * `deleteStoredResponsesForAccount` has done exactly the right thing since SONNY-300 wrote it while
 * nothing called it. The founder question that ticket raised — whether a wipe must take those
 * immediately or may leave them to expire — is answered "immediately": a privacy wipe that left a
 * day of response bodies behind would be a wipe with an asterisk, and the rows and their metering
 * claims survive either way, which is what makes taking the payloads free.
 *
 * **Usage survives, deliberately.** Requirement 8 says account deletion reaches "content, usage
 * history where the law or the promise requires it, and snapshot lineage". Nothing about usage is
 * content: `sonny.metering_event` holds token counts, byte counts and outcomes, it is the record of
 * what an account was billed for, and it is what a later question about that billing is answered
 * from. It stays, on the long clock, exactly as 0012 says.
 *
 * The account row itself is not touched here — `routes/auth.ts` marks `deleted_at`, and this runs
 * after it, for the ordering that route's own comment sets out: the account row is the handle these
 * records are addressable by, so it is closed rather than removed.
 */
export async function deleteContentForAccount(
  client: pg.Client,
  accountId: string,
  storedResponses: number,
): Promise<DeletionOutcome> {
  await client.query("BEGIN");
  try {
    const removed = await removeSnapshotMembers(client, "account_id = $1", [accountId]);
    const content = await client.query(
      "DELETE FROM sonny.retained_content WHERE account_id = $1",
      [accountId],
    );
    const outcome: DeletionOutcome = {
      contentRows: content.rowCount ?? 0,
      snapshotRows: removed.rows,
      snapshotsTouched: removed.snapshots,
      storedResponses,
    };
    await recordDeletion(client, {
      reason: "account",
      accountId,
      taskId: null,
      outcome,
    });
    await client.query("COMMIT");
    return outcome;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}

/**
 * Content still stored for accounts that have been closed, taken account by account.
 *
 * **This is what makes `DELETE /v1/account`'s wipe survive failing.** That handler runs its wipe
 * after the close has committed, and it cannot answer a failure with a 500: the caller is no longer
 * attributable to the account, so their retry meets a 401 and the failure is permanent. It is the
 * same shape PR #87's third round removed from the revocation path, and the same answer — the work
 * is derived from committed state afterwards rather than depending on one request succeeding.
 *
 * **It is also the only thing that reaches accounts closed before this branch existed.** SONNY-127's
 * comment recorded them plainly: "until [the retention ticket] lands a closed account's content is
 * retained and unreachable". This is what reaches them, and it needs no migration and no backfill —
 * they are simply rows this query already matches.
 *
 * One account per pass, oldest closure first, so a single sweep cannot become an unbounded delete
 * across a large backlog; the next pass takes the next one. Each account's wipe is
 * `deleteContentForAccount`, so it writes the same `sonny.content_deletion` record with the same
 * reason, and the account's own stored idempotency responses go with it.
 */
export async function sweepClosedAccountContent(
  client: pg.Client,
  clearStoredResponses: (client: pg.Client, accountId: string) => Promise<number>,
): Promise<DeletionOutcome | undefined> {
  const { rows } = await client.query<{ account_id: string }>(
    // **Either residue selects the account, and the second arm is PR #148's F4.** This asked only
    // about `sonny.retained_content`, which meant an account whose *only* leftover was a stored
    // response body — all-incognito usage, or content that had already expired — was never picked
    // up by any pass, and the recovery this function exists to be was true exactly when retained
    // content happened to exist. Both arms are `EXISTS` rather than a join, so an account with a
    // thousand rows costs the same as one with a single row.
    `SELECT a.id::text AS account_id
       FROM sonny.account a
      WHERE a.deleted_at IS NOT NULL
        AND (EXISTS (SELECT 1 FROM sonny.retained_content rc WHERE rc.account_id = a.id)
             OR EXISTS (SELECT 1 FROM sonny.idempotency_key k
                         WHERE k.account_scope = a.id AND k.response_body IS NOT NULL))
      ORDER BY a.deleted_at
      LIMIT 1`,
  );
  const accountId = rows[0]?.account_id;
  if (accountId === undefined) return undefined;
  const storedResponses = await clearStoredResponses(client, accountId);
  return deleteContentForAccount(client, accountId, storedResponses);
}

/**
 * The content clock coming round: delete everything past its `expires_at`, in one bounded batch.
 *
 * **Bounded, and the caller loops.** An unbounded `DELETE` over a table holding megabyte
 * screenshots is a long transaction holding locks on rows a live request may be inserting beside;
 * a batch that commits is a sweep that can be interrupted and resumed. `sweepExpiredContent` in
 * `expiry.ts` is the loop.
 *
 * **Returns what it took, and writes nothing when it took nothing.** This is the one path where the
 * "record even a zero" rule of `deleteContentForTask` is wrong: a sweep runs on a timer and mostly
 * finds nothing, so recording every pass would bury the passes that did something under thousands
 * that did not. What makes expiry observable is that a sweep which deleted rows always leaves a
 * row saying so — `expiry.ts` also logs each pass, which is where "did the timer fire" is answered.
 */
export async function expireContentBatch(client: pg.Client, limit: number): Promise<number> {
  await client.query("BEGIN");
  try {
    const deleted = await client.query(
      `DELETE FROM sonny.retained_content
        WHERE content_id IN (SELECT content_id FROM sonny.retained_content
                              WHERE expires_at <= now() LIMIT $1)`,
      [limit],
    );
    const rows = deleted.rowCount ?? 0;
    if (rows > 0) {
      await recordDeletion(client, {
        reason: "expiry",
        accountId: null,
        taskId: null,
        outcome: { ...NOTHING, contentRows: rows },
      });
    }
    await client.query("COMMIT");
    return rows;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}

/**
 * A snapshot reaching its own end, which is a different clock and mostly does not exist yet.
 *
 * §10.3 puts snapshots on "their own separately-consented lifecycle" and names no number, so
 * `expires_at` is nullable and is NULL on every snapshot this branch's builder makes unless a
 * caller passes one. **NULL is skipped rather than treated as "never"**: the difference is that
 * nothing here has decided a snapshot lives forever — a founder has not set the number, and the day
 * one is set this sweep already works.
 */
export async function expireSnapshots(client: pg.Client): Promise<number> {
  await client.query("BEGIN");
  try {
    const { rows } = await client.query<{ removed: string; members: string }>(
      `WITH doomed AS (
         SELECT snapshot_id, member_count FROM sonny.training_snapshot
          WHERE expires_at IS NOT NULL AND expires_at <= now()
       ), gone AS (
         DELETE FROM sonny.training_snapshot
          WHERE snapshot_id IN (SELECT snapshot_id FROM doomed)
         RETURNING snapshot_id
       )
       SELECT (SELECT count(*)::text FROM gone) AS removed,
              (SELECT coalesce(sum(member_count), 0)::text FROM doomed) AS members`,
    );
    const removed = Number(rows[0]?.removed ?? 0);
    const members = Number(rows[0]?.members ?? 0);
    if (removed > 0) {
      await recordDeletion(client, {
        reason: "snapshot_expiry",
        accountId: null,
        taskId: null,
        outcome: { ...NOTHING, snapshotRows: members },
      });
    }
    await client.query("COMMIT");
    return removed;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}

/**
 * The one operation the request hooks need, behind an interface.
 *
 * **The seam exists for the reason SONNY-300's and SONNY-133's do**, stated on both in the same
 * words: a database-backed test runs only when `DATABASE_URL` is set, which the flagged `npm test`
 * deliberately does not do — so without it, every behaviour §10.1 names would be verified only in
 * `npm run test:db`, and the run this repository gates on would be silent about the guarantee that
 * an incognito run is never stored.
 */
export interface ContentStore {
  write: (content: RetainedContent) => Promise<void>;
}

export function postgresContentStore(withConnection: WithConnection): ContentStore {
  return {
    write: (content) => withConnection((client) => insertRetainedContent(client, content)),
  };
}
