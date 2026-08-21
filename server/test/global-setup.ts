/**
 * Vitest globalSetup. Exists for one reason: to make the database skip **loud**.
 *
 * `test/migrate.db.test.ts` skips when `DATABASE_URL` is unset, and three documents claimed that
 * skip announced itself. It did not. A `console.warn` at module scope in an all-skipped file is
 * swallowed by the default reporter, so the only trace was `6 skipped` in the summary — which is
 * a count, not a warning, and reads identically to a suite that skipped something trivial.
 *
 * globalSetup writes before the reporter takes over the terminal, so this line always appears.
 */
export default function setup(): void {
  if (!process.env["DATABASE_URL"]) {
    process.stderr.write(
      "\n" +
        "  ┌─────────────────────────────────────────────────────────────────────────────┐\n" +
        "  │  DATABASE TESTS SKIPPED — DATABASE_URL is not set.                           │\n" +
        "  │                                                                             │\n" +
        "  │  The migration runner's behaviour against a real Postgres is NOT covered     │\n" +
        "  │  by this run. To include it:                                                │\n" +
        "  │                                                                             │\n" +
        "  │    docker run -d --name sonny-gw-db -e POSTGRES_PASSWORD=postgres \\          │\n" +
        "  │      -p 55433:5432 postgres:17                                              │\n" +
        "  │    npm run test:db                                                          │\n" +
        "  └─────────────────────────────────────────────────────────────────────────────┘\n\n",
    );
  }
}
