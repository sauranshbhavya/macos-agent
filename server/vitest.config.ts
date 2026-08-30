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

    // **Both deadlines are chosen here rather than inherited, and the numbers are different because
    // the two populations are** (SONNY-354, and PR #172's F4 for the hook half).
    //
    // `testTimeout` stays at vitest's own 5000 ms — the same number, now written down, so that a
    // reader can see it was decided. It governs only the files that run *in process*: every
    // `.db.test.ts` test is declared through `itUnderHangBackstop`, which sets its own, and
    // `backstop.test.ts` fails the suite if one is not. The non-database files run at under 300 ms
    // for a whole file, so their slowest single test has something like a 500x margin against a
    // worst measured load-induced slowdown of 10x (`test/support/backstop.ts` carries that
    // measurement). Five seconds is not tight for that population and a wider one would only make a
    // genuine mutant-induced hang cost longer to catch — and a bare timeout there is still counted
    // as a kill, deliberately, because in a pure-CPU test it is evidence.
    //
    // `hookTimeout` is raised from vitest's 10 s default because this branch put real work inside a
    // `beforeAll`: SONNY-366 gave every database file a schema rebuild, about 230 ms of drop plus
    // apply, where seven of them previously had a 4 ms no-op `up()`. Ten seconds is still ample and
    // that is exactly the problem — it is ample by accident, chosen by vitest for a suite that is
    // not this one. `VITEST_TIMEOUT_MS` is the number this suite already decided on for a wait
    // whose cost it does not control, so the hooks get it too. `backstop.test.ts` pins both fields
    // against that constant, so the config and the construct cannot drift apart.
    //
    // **Ninety seconds is not derived, and the argument for it is a different one** (PR #172's
    // cycle-2 review, which measured the cost and settled it here). It is a 390x margin on 230 ms
    // of work, where the tests it borrows the number from get 24x on theirs. What it buys is that
    // this suite has ONE deadline to reason about rather than two, and what it costs is bounded
    // and only arrives when the database is already broken: a wedged hook burns 91 s in that file
    // instead of 10, and the worst case — every file's `beforeAll` wedged — is about 20 minutes
    // against about 2. A run in that state is not a measurement of anything either way. If the
    // trade ever stops looking right, the thing to change is this number, not the constant: the
    // constant is the tests' bound, derived from their own load measurements.
    testTimeout: 5_000,
    hookTimeout: 90_000,
  },
});
