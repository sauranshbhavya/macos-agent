import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { callerOf } from "../auth/gate.js";
import { deleteContentForTask, taskOwnership } from "../content/store.js";
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
 * delete has no way to name the rows belonging to one task. The residual is bounded by that
 * twenty-four hours and by the fact that the payload is a response the user already has; the
 * account-wide wipe does clear them (`routes/auth.ts`, SONNY-319), because that path is scoped the
 * way that table is. Adding a `task_id` column to another lane's table was not this branch's to do.
 */

const params = z.object({ task_id: z.string().trim().min(1).max(200) });

export interface TaskRoutesDeps {
  readonly withConnection: WithConnection;
}

export function registerTaskRoutes(app: FastifyInstance, deps?: TaskRoutesDeps): void {
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
}
