import type { FastifyInstance } from "fastify";
import type { Config } from "../config.js";

/**
 * `GET /v1/health` — liveness and a build identifier, unauthenticated.
 *
 * The contract lists this route but leaves its shape to this ticket
 * (`docs/sonny-backend-api-contract.md` §3.6: "Its shape is SONNY-126's; it is listed here only so
 * nobody adds a second one"). What it returns:
 *
 * - `status`   — always `"ok"` when the process can answer at all.
 * - `version`  — the build identifier. This is the field the ticket requires, and it is what makes
 *                two deployments distinguishable from a browser.
 * - `environment` — which of local/staging/production this process believes it is.
 *
 * **What it deliberately does not return**, because this route is unauthenticated and reachable by
 * anyone who can find the hostname: no dependency status, no database connectivity check, no
 * configured-provider list, no counts. A liveness probe that reports which providers have
 * credentials tells an unauthenticated caller the shape of the system for free, and a liveness
 * probe that checks the database turns one database blip into a load balancer removing every
 * healthy instance. Readiness — the check that *does* consult dependencies — is a separate concern
 * and belongs to whichever ticket first has a dependency worth gating traffic on.
 *
 * `environment` is disclosed on purpose despite that reasoning: telling staging from production is
 * the founder's own manual-test item for this ticket, and the value is not a secret — the hostname
 * already says it.
 */
export function registerHealth(app: FastifyInstance, config: Config): void {
  app.get("/v1/health", async (_request, reply) => {
    reply.header("Cache-Control", "no-store");
    return {
      status: "ok",
      version: config.buildId,
      environment: config.environment,
    };
  });
}
