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
 * **The command below must stay in step with four other places**, and a reader who follows whichever
 * one they happened to open has to end up in the same place: `CLAUDE.md`'s server half,
 * `server/README.md`, `docs/sonny-manual-test-checklist.md`, and `WORKFLOW.md` step 5 — which states
 * the constraint in prose rather than as a copy of the command, and is therefore the one a grep for
 * the command does not find. Five in total, counting this file.
 *
 * It used to name one fixed container and one fixed host port, both machine-wide, which two lanes
 * following it would ask for at once (SONNY-355). It now derives the name from the worktree and lets
 * Docker choose the port, and waits for the database to be ready — `docker run -d` returns long
 * before Postgres accepts a connection, and a suite started in that window fails with `Connection
 * terminated unexpectedly`, which is the same signature those five documents attribute to another
 * lane's container.
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
        "  │    : \"${PORT:?no host port — did the docker run above fail?}\"               │\n" +
        "  │    until docker exec \"sonny-gw-db-$LANE\" pg_isready -q -U postgres; \\       │\n" +
        "  │      do sleep 1; done                                                       │\n" +
        "  │    DATABASE_URL=\"postgres://postgres:postgres@localhost:$PORT/postgres\" \\   │\n" +
        "  │      npm run test:db                                                        │\n" +
        "  │                                                                             │\n" +
        "  │  The pg_isready line is a readiness wait, not ceremony: docker run -d       │\n" +
        "  │  returns before Postgres accepts anything, and a suite started inside       │\n" +
        "  │  that window fails with 'Connection terminated unexpectedly' and no         │\n" +
        "  │  other explanation. 11 to 38 seconds of it, measured twice 2026-08-29.      │\n" +
        "  │                                                                             │\n" +
        "  │  Without DATABASE_URL, test:db falls back to localhost:55433 — right for    │\n" +
        "  │  a lone session, and the collision itself the moment a second lane runs.    │\n" +
        "  └─────────────────────────────────────────────────────────────────────────────┘\n\n",
    );
  }
}
