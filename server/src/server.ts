import { buildApp } from "./app.js";
import { authWiringFrom } from "./auth/deps.js";
import { ConfigError, loadConfig } from "./config.js";

/**
 * Process entry point. Kept separate from `app.ts` so that building the server and *listening* are
 * different acts: tests build, this file listens.
 *
 * **This file used to call `buildApp(config)` with no second argument, and that one omission was
 * half of why no deployment of this gateway had ever served a sign-in** (SONNY-307). `buildApp`
 * mounts the auth routes only when it is given `AuthDeps`, so every `/v1/auth/*` route answered
 * `404 resource.not_found` in every environment — measured against the container with all five of
 * the then-forwarded credentials present inside it, which is what separated it from a missing-
 * credential problem. The other half was that no concrete `AuthProvider` existed to pass;
 * `auth/supabase.ts` is that adapter and `auth/deps.ts` decides whether this environment gets one.
 */
async function main(): Promise<void> {
  let config;
  try {
    config = loadConfig();
  } catch (error) {
    // Before the logger exists, so this is the one place a plain write is right. Prints the
    // message, which names variables and never values.
    process.stderr.write(
      `${error instanceof ConfigError ? error.message : String(error)}\n`,
    );
    process.exit(78); // EX_CONFIG
  }

  // **Same exit code and same channel as a bad config, because that is what a half-configured
  // sign-in is.** `authWiringFrom` answers `undefined` for a health-only deployment and throws only
  // when the environment asked for sign-in and cannot have it; either way nothing is open yet, so
  // there is nothing to close on this path.
  let wiring;
  try {
    wiring = authWiringFrom(config);
  } catch (error) {
    process.stderr.write(
      `${error instanceof ConfigError ? error.message : String(error)}\n`,
    );
    process.exit(78); // EX_CONFIG
  }

  const app = buildApp(config, wiring?.deps);

  let shuttingDown = false;
  for (const signal of ["SIGTERM", "SIGINT"] as const) {
    process.on(signal, () => {
      // Containers are stopped by signal on every host on the timeline, so draining rather than
      // dying mid-request is table stakes rather than polish. A second signal while the first is
      // still draining is ignored rather than starting a second shutdown over the same resources.
      if (shuttingDown) return;
      shuttingDown = true;
      app.log.info({ signal }, "shutting down");
      void shutdown(app, wiring).then(() => process.exit(0));
    });
  }

  await app.listen({ port: config.port, host: config.host });
  app.log.info(
    {
      environment: config.environment,
      version: config.buildId,
      // Printed because a 404 on a sign-in route is otherwise indistinguishable from a defect, and
      // this line is the first thing anyone reads. Names the shape, never a credential.
      auth: wiring ? "mounted" : "health-only",
    },
    "gateway listening",
  );
}

/**
 * Close the server, then the pool, and let neither failure prevent the other or the exit.
 *
 * **The order is load-bearing and the error handling is what keeps it from becoming a hang.**
 * Fastify's `close` waits for in-flight requests, and those requests are holding connections, so
 * ending the pool first would pull one out from under a handler mid-transaction. But a rejected
 * `close` in a plain promise chain skips everything after it — the pool would stay open, `exit`
 * would never be reached, and the container would sit there until its orchestrator sent SIGKILL,
 * which is the shutdown path failing in the one way nobody watches. Each step is therefore attempted
 * and its failure reported rather than propagated.
 *
 * `wiring` is `undefined` on a health-only deployment, which opened no pool; there is nothing to
 * drain and this is one branch.
 */
async function shutdown(
  app: { close: () => Promise<void>; log: { error: (data: object, message: string) => void } },
  wiring: { close: () => Promise<void> } | undefined,
): Promise<void> {
  try {
    await app.close();
  } catch (error) {
    app.log.error({ err_name: (error as Error)?.name }, "server did not close cleanly");
  }
  try {
    await wiring?.close();
  } catch (error) {
    app.log.error({ err_name: (error as Error)?.name }, "connection pool did not drain cleanly");
  }
}

await main();
