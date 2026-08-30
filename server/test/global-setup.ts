/**
 * Vitest globalSetup. Exists for one reason: to make the database skip **loud**.
 *
 * `test/migrate.db.test.ts` skips when `DATABASE_URL` is unset, and three documents claimed that
 * skip announced itself. It did not. A `console.warn` at module scope in an all-skipped file is
 * swallowed by the default reporter, so the only trace was `6 skipped` in the summary — which is
 * a count, not a warning, and reads identically to a suite that skipped something trivial.
 *
 * globalSetup writes before the reporter takes over the terminal, so this line always appears.
 *
 * **The command below must stay in step with `CLAUDE.md`'s server half, `server/README.md` and
 * `docs/sonny-manual-test-checklist.md`** — four places state this setup, and a reader who follows
 * whichever one they happened to open has to end up in the same place. It used to name one fixed
 * container and one fixed host port, both machine-wide, which two lanes following it would ask for
 * at once (SONNY-355); it now derives the name from the worktree and lets Docker choose the port.
 */
export default function setup(): void {
  if (!process.env["DATABASE_URL"]) {
    process.stderr.write(
      "\n" +
        "  ┌─────────────────────────────────────────────────────────────────────────────┐\n" +
        "  │  DATABASE TESTS SKIPPED — DATABASE_URL is not set.                          │\n" +
        "  │                                                                             │\n" +
        "  │  The migration runner's behaviour against a real Postgres is NOT covered    │\n" +
        "  │  by this run. To include it, start a database of YOUR OWN — a container     │\n" +
        "  │  name and a host port are machine-wide, and lanes here run in parallel:     │\n" +
        "  │                                                                             │\n" +
        "  │    LANE=\"$(basename \"$(git rev-parse --show-toplevel)\")\"                    │\n" +
        "  │    docker run -d --name \"sonny-gw-db-$LANE\" \\                               │\n" +
        "  │      -e POSTGRES_PASSWORD=postgres -p 0:5432 postgres:17                    │\n" +
        "  │    PORT=\"$(docker port \"sonny-gw-db-$LANE\" 5432 | head -1 | sed 's/.*://')\" │\n" +
        "  │    DATABASE_URL=\"postgres://postgres:postgres@localhost:$PORT/postgres\" \\   │\n" +
        "  │      npm run test:db                                                        │\n" +
        "  │                                                                             │\n" +
        "  │  Without DATABASE_URL, test:db falls back to localhost:55433 — right for a  │\n" +
        "  │  lone session, and the collision itself the moment a second lane runs.      │\n" +
        "  └─────────────────────────────────────────────────────────────────────────────┘\n\n",
    );
  }
}
