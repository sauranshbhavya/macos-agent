import { buildApp } from "./app.js";
import { ConfigError, loadConfig } from "./config.js";

/**
 * Process entry point. Kept separate from `app.ts` so that building the server and *listening* are
 * different acts: tests build, this file listens.
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

  const app = buildApp(config);

  for (const signal of ["SIGTERM", "SIGINT"] as const) {
    process.on(signal, () => {
      // Containers are stopped by signal on every host on the timeline, so draining rather than
      // dying mid-request is table stakes rather than polish.
      app.log.info({ signal }, "shutting down");
      void app.close().then(() => process.exit(0));
    });
  }

  await app.listen({ port: config.port, host: config.host });
  app.log.info(
    { environment: config.environment, version: config.buildId },
    "gateway listening",
  );
}

await main();
