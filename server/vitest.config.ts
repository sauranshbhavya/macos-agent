import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    environment: "node",
    // Announces the database skip before the reporter owns the terminal. A console.warn inside an
    // all-skipped file is swallowed, which is how three documents came to claim a loudness the run
    // did not have (SONNY-126).
    globalSetup: ["test/global-setup.ts"],

    // **One database, so one file at a time.** The `*.db.test.ts` files share a single Postgres and
    // each resets the schema it needs — `migrate.db.test.ts` rolls migrations back by design. Run in
    // parallel, that file drops the schema out from under the others mid-assertion, which surfaced
    // as `relation "sonny.identity" does not exist` in 22 tests at once. Isolating by giving each
    // file its own schema was the alternative and was rejected: it would mean the migration tests no
    // longer exercise the schema names the migrations actually declare, which is most of what they
    // are for. The whole suite runs in well under a second, so serial costs nothing worth having.
    fileParallelism: false,
  },
});
