import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { callerOf } from "../auth/gate.js";
import {
  clearScreenshotsForTask,
  deleteContentForAccount,
  deleteContentForTask,
  deleteContentForTasks,
  taskOwnership,
} from "../content/store.js";
import { deleteStoredResponsesForAccount } from "../idempotency/store.js";
import type { WithConnection } from "../db/connection.js";
import { errorBody } from "../errors.js";

/**
 * `DELETE /v1/tasks/{task_id}` — the user's own delete, reaching the server's copy (SONNY-134).
 * Contract §4.6.
 *
 * **Founder decision, 2026-08-16 via SONNY-14: delete means deleted everywhere.** Local-only
 * deletion was declined. So the Mac deleting its task row is half of the act, and this is the other
 * half; §4.6 fixes that it is "reachable from the app rather than being an internal admin
 * operation", which is what makes it an ordinary authenticated route on the same gate as every
 * other rather than something a founder runs from a terminal.
 *
 * **It reaches training snapshots, which is the whole reason the lineage exists.** `store.ts`'s
 * `deleteContentForTask` removes the live content and every snapshot member copied from it in one
 * transaction, and records which snapshots lost rows. Without that record a deletion could be
 * performed and not described, which is the failure row 12's plan calls impossible to retrofit once
 * anything has been trained on.
 *
 * ## The three answers, and why one of them is not a 404
 *
 * §4.6 is unusually specific here, and each rule is a real failure it is avoiding:
 *
 * - **A task with nothing stored is a 200 with `requests_deleted: 0`, never a 404.** An incognito
 *   run, or a task that ran before the user signed in, has no server-side content — and a delete
 *   that is already true must not surface as an error the user has to interpret. This is the case
 *   most likely to be got wrong, because "no rows deleted" and "no such task" are the same query
 *   result and opposite answers.
 * - **`404 resource.not_found` is reserved for a `task_id` that belongs to a different user**, and
 *   never means "nothing was stored". `taskOwnership` reads both the metering table and the content
 *   table to tell the three cases apart, because a task can be known to this gateway through its
 *   usage while holding no content at all — which is exactly what an incognito run is.
 * - **The delete is scoped by account regardless of the ownership check.** The check answers the
 *   status code; the scope is what makes the statement safe if the check is ever wrong.
 *
 * **What this deliberately does not delete: the metering event.** §10.3 runs two clocks, and usage
 * is the long one. Deleting a task removes what the task *said*; it does not rewrite what the
 * account spent, and `requests_deleted` counts content rows for the same reason. A user asking for
 * their content to go is not asking for the record of their own billing to go with it.
 *
 * **What this cannot reach, stated rather than left to be discovered: the idempotency store's
 * stored responses.** `sonny.idempotency_key` holds one response body per key for twenty-four
 * hours, and it is keyed on `(account_scope, idempotency_key)` with no `task_id` — so a per-task
 * delete has no way to name the rows belonging to one task. The account-wide wipe does clear them
 * (`routes/auth.ts`, SONNY-319), because that path is scoped the way that table is, and adding a
 * `task_id` column to another lane's table was not this branch's to do.
 *
 * **The residual is bounded by twenty-four hours, and until PR #148's review that sentence was
 * false** (F2). It named a bound that nothing enforced: `pruneExpiredResponses` had no production
 * call site, so a body sat past its window indefinitely and the residual was unbounded. The prune
 * now runs on the content-expiry sweep (`content/expiry.ts`), so the bound is real — one sweep
 * interval past the window rather than exactly twenty-four hours, which is the honest figure. Two
 * things narrow it further and neither is the bound: the payload is a response the user's own Mac
 * already has, and an incognito run stores no body here at all (F1).
 */

const params = z.object({ task_id: z.string().trim().min(1).max(200) });

/**
 * The bulk delete's body (SONNY-404, contract §4.6.1).
 *
 * **`MAXIMUM_TASK_IDS` is the Mac's own history cap and not a number chosen here.**
 * `TaskHistoryStore.defaultMaxItems` is 10,000, so that is the largest set the *Task history ›
 * Delete* this route serves can ever name — a limit below it would silently turn one press into a
 * partial deletion, and a limit above it would be headroom for a caller that cannot exist. At
 * roughly forty bytes an id that is about 400 KB, inside §6.1's 1 MiB default for every route that
 * does not name its own.
 */
const MAXIMUM_TASK_IDS = 10_000;

const bulkBody = z.object({
  task_ids: z.array(z.string().trim().min(1).max(200)).min(1).max(MAXIMUM_TASK_IDS),
});

/**
 * `DELETE /v1/account/content`'s one optional parameter (SONNY-404, PR #207's F1). Contract §4.6.3.
 *
 * **Optional, and its absence means "everything"** — which is what §8.1 allows a minor version to
 * add and is why this is a query parameter rather than a new required field. A shipped client that
 * sends none behaves exactly as it did.
 *
 * **It exists because the Mac may deliver this delete days after the press.** The wipe queues an
 * obligation when it cannot reach the gateway; without a bound, the delivery would take content the
 * user created *after* the press, which the press never promised.
 */
const accountContentQuery = z.object({
  before: z.coerce.date().optional(),
});

export interface TaskRoutesDeps {
  readonly withConnection: WithConnection;
}

/**
 * **The four content-deletion routes, grouped by what they delete rather than by path prefix**
 * (SONNY-404). Three are task-scoped and one is account-scoped, and they are registered together
 * because they share `taskOwnership`, the `deleteContentFor*` primitives and — more to the point —
 * §4.6's three answers, which a reader checking one of them wants to check against the others.
 * `DELETE /v1/account/content` is the odd path in that set and is here for that reason rather than
 * beside `DELETE /v1/account` in `routes/auth.ts`: it deletes content and closes nothing, so filing
 * it with the account's own lifecycle is where a later reader would confuse the two promises.
 */
export function registerContentDeletionRoutes(app: FastifyInstance, deps?: TaskRoutesDeps): void {
  /**
   * Mounted unconditionally, including on a deployment with no database.
   *
   * The route table does not change shape with the environment, which is `app.ts`'s own argument
   * about the four model routes: a `404 resource.not_found` standing in for a missing deployment
   * dependency is a code the client reads as "no such route". It is unreachable without a database
   * anyway — this route is absent from `PUBLIC_ROUTES`, so the gate refuses every caller with a 401
   * on a deployment that has no `auth`, and a deployment with `auth` has a pool.
   */
  app.delete("/v1/tasks/:task_id", async (request, reply) => {
    const parsed = params.safeParse(request.params);
    if (!parsed.success) {
      return reply
        .status(400)
        .send(errorBody("request.invalid", "A task identifier is required.", request.id));
    }
    if (deps === undefined) {
      // Unreachable: see the mounting note above. Thrown rather than answered, so the root error
      // handler logs it with a stack and the caller gets §7.2's 500 — the loud answer for a
      // deployment shape that should not exist, rather than a quiet success that deleted nothing.
      throw new Error("DELETE /v1/tasks/:task_id served with no database configured");
    }
    const accountId = callerOf(request).accountId;
    const taskId = parsed.data.task_id;

    return deps.withConnection(async (client) => {
      const ownership = await taskOwnership(client, { accountId, taskId });
      if (ownership === "other") {
        return reply
          .status(404)
          .send(errorBody("resource.not_found", "No such task for this account.", request.id));
      }

      const outcome = await deleteContentForTask(client, { accountId, taskId });
      // Logged with the snapshots so that "which training sets did this deletion reach" is
      // answerable from the operational record as well as from `sonny.content_deletion`. The task
      // id is an opaque client-minted key and is not content; nothing here logs anything that was
      // stored.
      request.log.info(
        {
          taskId,
          contentRows: outcome.contentRows,
          snapshotRows: outcome.snapshotRows,
          snapshots: outcome.snapshotsTouched,
        },
        "task content deleted",
      );
      return reply.status(200).send({
        task_id: taskId,
        deleted_at: new Date().toISOString(),
        // §4.6's field. Content rows, one per request the task made that was kept — so an incognito
        // task and a task that ran before sign-in both answer 0, successfully.
        requests_deleted: outcome.contentRows,
      });
    });
  });

  /**
   * `DELETE /v1/tasks` — several tasks in one call (SONNY-404). Contract §4.6.1.
   *
   * **One call rather than one per row is the founder's decision of 2026-09-05.** The Mac's *Command
   * Center › Memory › Task history › Delete* removes every history row at once, and a queue holding
   * one obligation per row would be up to ten thousand requests behind one press — and, on the Mac's
   * side, ten thousand entries against a queue that holds two hundred, which is nine thousand eight
   * hundred deletions dropped in silence. The obligation is one entry naming many ids for exactly
   * that reason.
   *
   * **It promises no more and no less than the same ids deleted one at a time.** `store.ts`'s
   * `deleteContentForTasks` writes one `sonny.content_deletion` row per task, with that task's own
   * counts and snapshots, so the record of a wipe reads the same as the record of the same deletions
   * performed slowly. A summary row would have made the two paths look like different acts.
   *
   * **A body on a `DELETE`, and it is a decision rather than an accident.** The alternative was
   * `POST /v1/tasks/delete`, which §9.1 would then oblige to carry an `Idempotency-Key` for an
   * operation §9.3 already calls naturally idempotent — a key whose only job would be to stand in
   * for a lost response that costs nothing to repeat. The cost of this direction is stated in §4.6.1
   * and belongs to the host decision rather than to this file: an intermediary that strips a
   * `DELETE` body turns every bulk delete into a `400`, so it is one more thing SONNY-125 has to
   * prove of a candidate host.
   *
   * **Ids belonging to another account are skipped and counted, never a `404` for the batch.** §4.6
   * reserves that code for one foreign id, and the batch equivalent — refusing the whole call —
   * would let one stale id on a Mac two people have signed into strand every other deletion in the
   * queue for good. `tasks_not_found` is what the client reads to keep the obligation instead.
   */
  app.delete("/v1/tasks", async (request, reply) => {
    const parsed = bulkBody.safeParse(request.body);
    if (!parsed.success) {
      return reply
        .status(400)
        .send(
          errorBody(
            "request.invalid",
            `A task_ids array of 1 to ${MAXIMUM_TASK_IDS} identifiers is required.`,
            request.id,
          ),
        );
    }
    if (deps === undefined) {
      // Unreachable for the reason the route above gives, and loud for the same one.
      throw new Error("DELETE /v1/tasks served with no database configured");
    }
    const accountId = callerOf(request).accountId;
    const taskIds = parsed.data.task_ids;

    return deps.withConnection(async (client) => {
      const outcome = await deleteContentForTasks(client, { accountId, taskIds });
      request.log.info(
        {
          submitted: taskIds.length,
          tasksDeleted: outcome.tasksDeleted,
          tasksNotFound: outcome.notMine,
          contentRows: outcome.contentRows,
          snapshotRows: outcome.snapshotRows,
          snapshots: outcome.snapshotsTouched,
        },
        "task content deleted in bulk",
      );
      return reply.status(200).send({
        deleted_at: new Date().toISOString(),
        // Submitted ids this account owns or that this gateway has never heard of — §4.6's rule that
        // a task with nothing stored is a success, applied per id.
        tasks_deleted: outcome.tasksDeleted,
        // Submitted ids this gateway knows under a *different* account. The batch's `404`.
        tasks_not_found: outcome.notMine,
        // §4.6's field, summed: content rows removed across every task in the batch.
        requests_deleted: outcome.contentRows,
      });
    });
  });

  /**
   * `DELETE /v1/tasks/{task_id}/screenshots` — one task's screenshots and nothing else (SONNY-404).
   * Contract §4.6.2.
   *
   * **Why it is not `DELETE /v1/tasks/{task_id}`, which is the whole reason this route exists.** The
   * Mac's *Delete what Sonny did on screen* removes one task's vision-session record and leaves the
   * task, its command and its result standing. §4.6's route takes a task's entire retained content,
   * so pressing it here would delete the request text and the served responses too — more than the
   * button says. The founder decided on 2026-09-05 for the narrower route rather than for a button
   * whose words stop claiming server reach, on the ground that screenshots are the most sensitive
   * content this gateway holds and that snapshot copies of them carry no expiry today.
   *
   * **The three answers are §4.6's, unchanged**, because they are about ownership rather than about
   * what is removed: another account's task is a `404`, a task this gateway never stored is a `200`
   * with a count of zero, and the clear is scoped by account whatever the ownership read said.
   */
  app.delete("/v1/tasks/:task_id/screenshots", async (request, reply) => {
    const parsed = params.safeParse(request.params);
    if (!parsed.success) {
      return reply
        .status(400)
        .send(errorBody("request.invalid", "A task identifier is required.", request.id));
    }
    if (deps === undefined) {
      // Unreachable for the reason the first route gives, and loud for the same one.
      throw new Error("DELETE /v1/tasks/:task_id/screenshots served with no database configured");
    }
    const accountId = callerOf(request).accountId;
    const taskId = parsed.data.task_id;

    return deps.withConnection(async (client) => {
      const ownership = await taskOwnership(client, { accountId, taskId });
      if (ownership === "other") {
        return reply
          .status(404)
          .send(errorBody("resource.not_found", "No such task for this account.", request.id));
      }

      const outcome = await clearScreenshotsForTask(client, { accountId, taskId });
      request.log.info(
        {
          taskId,
          screenshotsCleared: outcome.screenshotsCleared,
          snapshotScreenshotsCleared: outcome.snapshotScreenshotsCleared,
          snapshots: outcome.snapshotsTouched,
        },
        "task screenshots deleted",
      );
      return reply.status(200).send({
        task_id: taskId,
        deleted_at: new Date().toISOString(),
        // Live rows whose screenshot went. The snapshot copies that went with them are in the
        // gateway's own record rather than here: the client has nothing to do with the difference,
        // and a second number on the wire would be a field no caller reads.
        screenshots_deleted: outcome.screenshotsCleared,
      });
    });
  });

  /**
   * `DELETE /v1/account/content` — everything this account has stored, and the account stays open
   * (SONNY-404). Contract §4.6.3.
   *
   * **This is the Mac's "Delete Sonny local data", which is a promise about the account.** Founder
   * decision 2026-09-04, restated 2026-09-05: that press deletes what the servers retain as well as
   * what this Mac holds. The alternative — the wipe promises this Mac only, and its words say so —
   * was built for one round after a coordinator re-asked the settled question, and was declined
   * again by both founders.
   *
   * **It closes nothing, and that is the line between this route and `DELETE /v1/account`.** Closing
   * an account is a different promise with no control in the app today; this deletes the content and
   * leaves the account, its identities, its entitlement and its usage exactly where they were. The
   * user can keep using Sonny straight afterwards, which is what "delete my data" means and what
   * "delete my account" does not.
   *
   * **It reaches what the account-close path reaches, through the same function**, so the two cannot
   * drift: live content, every training-snapshot copy, and `sonny.idempotency_key`'s stored response
   * bodies — the one place the gateway holds response content outside the route that produced it.
   * Usage survives, deliberately, on §10.3's long clock: `sonny.metering_event` holds no content and
   * is the record of what the account was billed for.
   *
   * **Scoped to the caller's own account and to nothing else.** There is no id on this path to get
   * wrong: the account is `callerOf(request).accountId`, which the gate established before the body
   * was read, and every statement beneath is keyed on it.
   *
   * **It is safe to repeat**, which is what makes the Mac's queue able to retry it: a second call
   * finds nothing and answers `200` with zeroes.
   */
  app.delete("/v1/account/content", async (request, reply) => {
    const bounds = accountContentQuery.safeParse(request.query);
    if (!bounds.success) {
      return reply
        .status(400)
        .send(
          errorBody("request.invalid", "before must be an RFC 3339 instant.", request.id),
        );
    }
    if (deps === undefined) {
      // Unreachable for the reason the first route gives, and loud for the same one.
      throw new Error("DELETE /v1/account/content served with no database configured");
    }
    const accountId = callerOf(request).accountId;
    const before = bounds.data.before;

    return deps.withConnection(async (client) => {
      const storedResponses = await deleteStoredResponsesForAccount(client, accountId, before);
      const outcome = await deleteContentForAccount(
        client,
        accountId,
        storedResponses,
        // Not `account`: that value means the account was closed and its content went with it, and
        // nothing in the row would tell the two apart once the user does close it for real.
        "account_content",
        before,
      );
      request.log.info(
        {
          before: before?.toISOString(),
          contentRows: outcome.contentRows,
          snapshotRows: outcome.snapshotRows,
          snapshots: outcome.snapshotsTouched,
          storedResponses: outcome.storedResponses,
        },
        "account content deleted, account left open",
      );
      return reply.status(200).send({
        deleted_at: new Date().toISOString(),
        // §4.6's field, over the whole account: content rows removed, one per kept request.
        requests_deleted: outcome.contentRows,
        // The stored response bodies that went with them. Counted apart because it is a different
        // table with a different clock, which is `sonny.content_deletion`'s own reason for keeping
        // them in a column of their own.
        stored_responses_deleted: outcome.storedResponses,
      });
    });
  });
}
