import pg from "pg";
import { describe, expect } from "vitest";
import { copyFile, mkdtemp, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { down, loadMigrations, runCommand, up, type MigrationObserver } from "../src/db/migrate.js";
import {
  blockingLocksHeld,
  declaredLockProfile,
  formatLockProfile,
  measuredLockProfile,
  relationSnapshot,
  sameLockProfile,
  type LockProfile,
} from "../src/db/lock-profile.js";
import { afterAllUnderHangBackstop, beforeAllUnderHangBackstop, itUnderHangBackstop } from "./support/backstop.js";
import { testDatabaseUrl } from "./support/database.js";
import { dropSchema, rebuildSchema } from "./support/schema.js";

/**
 * Every migration's declared lock profile, measured against a real Postgres through the runner that
 * really applies it (SONNY-370).
 *
 * **The measurement goes through `up` and `down` themselves**, by the observer they take, rather
 * than through a copy of their transaction here. A copy would keep measuring the old shape if the
 * runner ever changed how it applies a migration, and stay green while doing it — a sample entering
 * downstream of the mechanism it claims to hold.
 *
 * **Empty tables, on purpose.** Postgres counts a scan when it starts, so an index build or a
 * backfill registers on a table with no rows (`lock-profile.ts` carries the measurements), and no
 * seeding is needed to see the shape. What an empty table cannot give is a duration; a duration is a
 * property of the data an environment holds, and this file makes no claim about one.
 */
const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const here = dirname(fileURLToPath(import.meta.url));
const shippedDir = join(here, "..", "src", "db", "migrations");

/**
 * PR #171's first 0017, as that branch wrote it before review (`git show fb3fb2f9:server/src/db/
 * migrations/0017_the_latest_sign_in_code_is_the_last_one_issued.sql`, executable lines only): a
 * backfill of every row of `sonny.sign_in_code_issue` under the `ACCESS EXCLUSIVE` its `ADD COLUMN`
 * took, on the table `latestIssuance` reads on the sign-in path. The reviewer measured a concurrent
 * read of that query blocked for 2851 ms at 200,000 rows.
 *
 * **The declaration lines are this file's, not that branch's**: the mechanism did not exist, and the
 * runner now refuses a file without them. The up half declares what the README's old paragraph
 * promised of migrations like it — a lock and nothing scanned, "metadata-only, so microseconds" — which
 * is the claim the measurement has to be able to refute. The down half's lines are there so the file
 * loads; nothing here rolls this fixture back, so they are never measured.
 */
const PR_171_FIRST_0017 = `
-- @locks ACCESS EXCLUSIVE sonny.sign_in_code_issue
-- @scans none
ALTER TABLE sonny.sign_in_code_issue ADD COLUMN issue_seq bigint;
UPDATE sonny.sign_in_code_issue s
   SET issue_seq = ordered.n
  FROM (SELECT id, row_number() OVER (ORDER BY issued_at, id) AS n
          FROM sonny.sign_in_code_issue) ordered
 WHERE s.id = ordered.id;
ALTER TABLE sonny.sign_in_code_issue ALTER COLUMN issue_seq SET NOT NULL;
ALTER TABLE sonny.sign_in_code_issue
  ALTER COLUMN issue_seq ADD GENERATED ALWAYS AS IDENTITY;
SELECT setval(pg_get_serial_sequence('sonny.sign_in_code_issue', 'issue_seq'),
              GREATEST((SELECT max(issue_seq) FROM sonny.sign_in_code_issue), 1),
              (SELECT count(*) FROM sonny.sign_in_code_issue) > 0);
CREATE INDEX sign_in_code_issue_mailbox_seq_idx
    ON sonny.sign_in_code_issue (mailbox_key, issue_seq DESC);
DROP INDEX sonny.sign_in_code_issue_email_idx;
-- @rollback
-- @locks ACCESS EXCLUSIVE sonny.sign_in_code_issue
-- @scans none
CREATE INDEX sign_in_code_issue_email_idx
    ON sonny.sign_in_code_issue (mailbox_key, issued_at DESC);
DROP INDEX sonny.sign_in_code_issue_mailbox_seq_idx;
ALTER TABLE sonny.sign_in_code_issue DROP COLUMN issue_seq;
`;

/**
 * PR #169's ledger SQL before its review (`git show 1cdb56b6:server/src/db/migrate.ts`, `LEDGER`):
 * the `ALTER … ADD COLUMN IF NOT EXISTS` ran on every command, `status` included, and took
 * `ACCESS EXCLUSIVE` to evaluate its own `IF NOT EXISTS` while changing nothing — read-only `status`
 * went from 0.20 s to 9.12 s behind one ledger writer.
 */
const PR_169_UNCONDITIONAL_LEDGER = `
  CREATE SCHEMA IF NOT EXISTS sonny_meta;
  CREATE TABLE IF NOT EXISTS sonny_meta.schema_migration (
    id           text PRIMARY KEY,
    applied_at   timestamptz NOT NULL DEFAULT now(),
    content_hash text
  );
  ALTER TABLE sonny_meta.schema_migration ADD COLUMN IF NOT EXISTS content_hash text`;

/** Records what each half really did, keyed `<id> <half>`. */
function measuring(into: Map<string, LockProfile>): MigrationObserver {
  return async (client, migration, half, run) => {
    const snapshot = await relationSnapshot(client);
    await run();
    into.set(`${migration.id} ${half}`, await measuredLockProfile(client, snapshot));
  };
}

const silent = { out: () => {}, err: () => {} };

describeDb("every migration's lock profile, measured", () => {
  let client: pg.Client;
  const measured = new Map<string, LockProfile>();

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: testDatabaseUrl() });
    await client.connect();
    // Every half, from nothing: each `up` over the schema the ones before it built, then each `down`
    // from the top over the schema its own `up` left.
    await dropSchema(client);
    await up(client, undefined, measuring(measured));
    while (await down(client, undefined, measuring(measured))) { /* one migration per pass */ }
  });
  afterAllUnderHangBackstop(async () => { await client.end(); });

  itUnderHangBackstop("reached both halves of every migration that ships", async () => {
    const shipped = await loadMigrations();
    expect(shipped.length).toBeGreaterThan(20);
    const expected = shipped.flatMap((m) => [`${m.id} down`, `${m.id} up`]).sort();
    expect([...measured.keys()].sort()).toEqual(expected);
  });

  itUnderHangBackstop("finds each half's declaration true, or prints the lines that would be", async () => {
    const shipped = await loadMigrations();
    const wrong: string[] = [];
    for (const migration of shipped) {
      for (const half of ["up", "down"] as const) {
        const key = `${migration.id} ${half}`;
        const declared = declaredLockProfile(half === "up" ? migration.up : migration.down, key);
        const actual = measured.get(key);
        if (actual === undefined) continue; // the test above names a half the walk missed
        if (declared === undefined || !sameLockProfile(declared, actual)) {
          wrong.push(
            `${key} declares\n${declared === undefined ? "(nothing)" : formatLockProfile(declared)}\n` +
              `but measures\n${formatLockProfile(actual)}`,
          );
        }
      }
    }
    expect(wrong.join("\n\n")).toBe("");
  });

  itUnderHangBackstop("measures 0016 as the harmless shape: ACCESS EXCLUSIVE, and nothing scanned", async () => {
    expect(measured.get("0016_a_drain_discharges_the_obligation_it_claimed up")).toEqual({
      locks: [{ relation: "sonny.identity_provider_user", mode: "ACCESS EXCLUSIVE" }],
      scans: [],
    });
  });

  itUnderHangBackstop("measures the shipped 0017 as holding ACCESS EXCLUSIVE across its index build", async () => {
    // PR #171's rewrite removed the backfill and kept the index build, which still runs under the
    // `ACCESS EXCLUSIVE` the `ADD COLUMN` took. Its header says so in prose; this is the measurement.
    expect(measured.get("0017_the_latest_sign_in_code_is_the_last_one_issued up")).toEqual({
      locks: [{ relation: "sonny.sign_in_code_issue", mode: "ACCESS EXCLUSIVE" }],
      scans: ["sonny.sign_in_code_issue"],
    });
  });
});

describeDb("the two cases SONNY-370 was filed for", () => {
  let client: pg.Client;

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: testDatabaseUrl() });
    await client.connect();
  });
  afterAllUnderHangBackstop(async () => {
    await rebuildSchema(client);
    await client.end();
  });

  itUnderHangBackstop("refuses PR #171's first 0017: a scan of the sign-in table under ACCESS EXCLUSIVE", async () => {
    // 0001 to 0016 as they ship, then the first 0017 in its place, applied by the real runner.
    const dir = await mkdtemp(join(tmpdir(), "sonny-lock-"));
    for (const name of await readdir(shippedDir)) {
      if (name.endsWith(".sql") && name < "0017") await copyFile(join(shippedDir, name), join(dir, name));
    }
    await writeFile(join(dir, "0017_pr_171_first_draft.sql"), PR_171_FIRST_0017);
    const measured = new Map<string, LockProfile>();
    await dropSchema(client);
    await up(client, dir, measuring(measured));

    const first = measured.get("0017_pr_171_first_draft up");
    expect(first).toEqual({
      locks: [{ relation: "sonny.sign_in_code_issue", mode: "ACCESS EXCLUSIVE" }],
      scans: ["sonny.sign_in_code_issue"],
    });
    // Its own declaration, read out of the file the runner loaded: a lock and no scan, the shape 0016
    // truthfully has. The measurement disagrees, and on exactly the scan — the one line that turns a
    // lock held for microseconds into a lock held for as long as the sign-in table is big.
    const loaded = (await loadMigrations(dir)).find((m) => m.id === "0017_pr_171_first_draft");
    const asDeclared = declaredLockProfile(loaded!.up, "0017_pr_171_first_draft up")!;
    expect(asDeclared).toEqual({ locks: first!.locks, scans: [] });
    expect(sameLockProfile(asDeclared, first!)).toBe(false);
    expect(sameLockProfile({ ...asDeclared, scans: ["sonny.sign_in_code_issue"] }, first!)).toBe(true);
  });

  itUnderHangBackstop("reads PR #169's unconditional ledger ALTER as ACCESS EXCLUSIVE on the ledger", async () => {
    // The control for the test below: the instrument that finds the shipped read path clean does
    // see the lock that made `status` wait nine seconds.
    await rebuildSchema(client);
    await client.query("BEGIN");
    try {
      const snapshot = await relationSnapshot(client);
      await client.query(PR_169_UNCONDITIONAL_LEDGER);
      expect(await blockingLocksHeld(client, snapshot)).toEqual([
        { relation: "sonny_meta.schema_migration", mode: "ACCESS EXCLUSIVE" },
      ]);
    } finally {
      await client.query("ROLLBACK");
    }
  });

  itUnderHangBackstop("holds no blocking lock on the runner's read path: status, and up with nothing pending", async () => {
    await rebuildSchema(client);
    for (const command of ["status", "up"]) {
      // Inside one transaction, so every lock the command took is still held when it is read.
      await client.query("BEGIN");
      try {
        const snapshot = await relationSnapshot(client);
        expect(snapshot.relations.size).toBeGreaterThan(0);
        expect(await runCommand(command, client, silent)).toBe(0);
        expect({ command, locks: await blockingLocksHeld(client, snapshot) }).toEqual({ command, locks: [] });
      } finally {
        await client.query("ROLLBACK");
      }
    }
  });
});
