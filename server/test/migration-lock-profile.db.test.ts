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
  tablesScannedSince,
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
 * **Every half is measured twice: from empty tables, and with rows seeded** (PR #250 review, F1).
 * The first version measured only from empty tables and said no seeding was needed, and that was
 * wrong: on an empty table the executor skips a join's second table and a per-row subquery, so five
 * shipped declarations were missing a table they read once rows exist. `lock-profile.ts` now builds
 * the scan line from the locks a statement takes when it is planned as well as from the scans that
 * start, and the seeded pass is what holds that: each half must measure the same both ways. What the
 * seed cannot prove is that nothing is left — a row trigger or a branch the seed never takes is still
 * unplanned — and `lock-profile.ts` and the README say so. Neither pass gives a duration; a duration
 * is a property of the data an environment holds, and this file makes no claim about one.
 */
const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const here = dirname(fileURLToPath(import.meta.url));
const shippedDir = join(here, "..", "src", "db", "migrations");

/**
 * PR #171's first 0017, as that branch wrote it before review (`git show fb3fb2f9:server/src/db/
 * migrations/0017_the_latest_sign_in_code_is_the_last_one_issued.sql`, executable lines only — the
 * `COMMENT ON COLUMN` included, since it is one): a
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
COMMENT ON COLUMN sonny.sign_in_code_issue.issue_seq IS
  'Issuance order, and the only thing that decides which code at a mailbox is the latest one '
  '(SONNY-353). issued_at is not unique and two codes sharing an instant have no defined newest, '
  'which makes both "which code does a verify redeem" and "which of the three failures is '
  'disclosed" depend on the query plan. GENERATED ALWAYS: application code may not write it. '
  'Per mailbox this is exactly issuance order, because issueCode holds an advisory lock on the '
  'mailbox across its invalidate-and-insert.';
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

/** A throwaway directory holding every shipped migration whose file name sorts below `before`. */
async function shippedBelow(before: string): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "sonny-lock-"));
  for (const name of await readdir(shippedDir)) {
    if (name.endsWith(".sql") && name < before) await copyFile(join(shippedDir, name), join(dir, name));
  }
  return dir;
}

/**
 * Rows for the tables 0002 creates, written between 0002 and 0003: six accounts, every other one
 * closed, and one identity each carrying a provider-side id. That is the review's seed, and it is
 * enough for every join the five halves F1 named to reach its second table — 0003's and 0004's
 * `USING`/`FROM sonny.account` over identities of closed accounts, 0005's over live ones, and 0014's
 * copy into `sonny.identity_provider_user`, which its rollback joins back.
 */
const SEED = `
  INSERT INTO sonny.account (id, deleted_at)
  SELECT gen_random_uuid(), CASE WHEN g % 2 = 0 THEN now() END FROM generate_series(1, 6) AS g;
  INSERT INTO sonny.identity (account_id, provider, subject, supabase_user_id, link_method)
  SELECT a.id, 'email', 'seed-' || row_number() OVER (), gen_random_uuid(), 'primary'
    FROM sonny.account a`;

/** Every half declared, compared against a measurement; the lines that would be true, when not. */
async function declarationsAgainst(measured: ReadonlyMap<string, LockProfile>): Promise<string> {
  const wrong: string[] = [];
  for (const migration of await loadMigrations()) {
    for (const half of ["up", "down"] as const) {
      const key = `${migration.id} ${half}`;
      const actual = measured.get(key);
      if (actual === undefined) continue; // each pass's own reach test names a half it missed
      const declared = declaredLockProfile(half === "up" ? migration.up : migration.down, key);
      if (declared === undefined || !sameLockProfile(declared, actual)) {
        wrong.push(
          `${key} declares\n${declared === undefined ? "(nothing)" : formatLockProfile(declared)}\n` +
            `but measures\n${formatLockProfile(actual)}`,
        );
      }
    }
  }
  return wrong.join("\n\n");
}

describeDb("every migration's lock profile, measured", () => {
  let client: pg.Client;
  const measured = new Map<string, LockProfile>();
  const seeded = new Map<string, LockProfile>();
  let seedRows = { accounts: 0, identities: 0 };

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: testDatabaseUrl() });
    await client.connect();
    // Every half, from nothing: each `up` over the schema the ones before it built, then each `down`
    // from the top over the schema its own `up` left.
    await dropSchema(client);
    await up(client, undefined, measuring(measured));
    while (await down(client, undefined, measuring(measured))) { /* one migration per pass */ }

    // Every half again, with rows: 0001 and 0002 applied unmeasured, the seed written, then the rest
    // up and everything down, measured. Counted rather than trusted, because a seed that inserted
    // nothing would make this pass the empty one twice.
    await dropSchema(client);
    await up(client, await shippedBelow("0003"));
    await client.query(SEED);
    const { rows } = await client.query<{ accounts: string; identities: string }>(
      "SELECT (SELECT count(*) FROM sonny.account) AS accounts, (SELECT count(*) FROM sonny.identity) AS identities",
    );
    seedRows = { accounts: Number(rows[0]!.accounts), identities: Number(rows[0]!.identities) };
    await up(client, undefined, measuring(seeded));
    while (await down(client, undefined, measuring(seeded))) { /* one migration per pass */ }
  });
  afterAllUnderHangBackstop(async () => { await client.end(); });

  itUnderHangBackstop("reached both halves of every migration that ships", async () => {
    const shipped = await loadMigrations();
    expect(shipped.length).toBeGreaterThan(20);
    const expected = shipped.flatMap((m) => [`${m.id} down`, `${m.id} up`]).sort();
    expect([...measured.keys()].sort()).toEqual(expected);
  });

  itUnderHangBackstop("finds each half's declaration true, or prints the lines that would be", async () => {
    expect(await declarationsAgainst(measured)).toBe("");
  });

  itUnderHangBackstop("seeded rows, and reached every half after the seed", async () => {
    expect(seedRows).toEqual({ accounts: 6, identities: 6 });
    const shipped = await loadMigrations();
    const expected = shipped
      .flatMap((m) => [`${m.id} down`, `${m.id} up`])
      .filter((key) => !/^000[12]_.* up$/.test(key))
      .sort();
    expect(expected.length).toBe(shipped.length * 2 - 2);
    expect([...seeded.keys()].sort()).toEqual(expected);
  });

  itUnderHangBackstop("finds every declaration still true with rows in the tables", async () => {
    // At 4b2ae723 this failed on exactly the review's five: the scan line was the scan counter alone,
    // and with rows each of them read a second table the empty run never started a scan of.
    expect(await declarationsAgainst(seeded)).toBe("");
  });

  itUnderHangBackstop("reads the second table in each of the five halves an empty table used to hide", async () => {
    const scansOf = (key: string) => ({ key, empty: measured.get(key)?.scans, seeded: seeded.get(key)?.scans });
    const both = (key: string, scans: string[]) => ({ key, empty: scans, seeded: scans });
    expect(scansOf("0003_release_identities_on_close up")).toEqual(
      both("0003_release_identities_on_close up", ["sonny.account", "sonny.identity"]));
    expect(scansOf("0004_identities_are_closed_not_deleted up")).toEqual(
      both("0004_identities_are_closed_not_deleted up", ["sonny.account", "sonny.identity"]));
    expect(scansOf("0005_account_closed_follows_the_account up")).toEqual(
      both("0005_account_closed_follows_the_account up", ["sonny.account", "sonny.identity"]));
    expect(scansOf("0004_identities_are_closed_not_deleted down")).toEqual(
      both("0004_identities_are_closed_not_deleted down", ["sonny.account", "sonny.identity"]));
    expect(scansOf("0014_a_provider_side_user_is_remembered_and_revocable down")).toEqual(
      both("0014_a_provider_side_user_is_remembered_and_revocable down", ["sonny.identity", "sonny.identity_provider_user"]));
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

describeDb("the two cases SONNY-370 was filed for, and the edges of the instrument", () => {
  let client: pg.Client;

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: testDatabaseUrl() });
    await client.connect();
  });
  afterAllUnderHangBackstop(async () => {
    await rebuildSchema(client);
    await client.end();
  });

  itUnderHangBackstop("measures PR #171's first 0017 as a scan of the sign-in table under ACCESS EXCLUSIVE, which a lock-and-no-scan declaration of it cannot state", async () => {
    // 0001 to 0016 as they ship, then the first 0017 in its place, applied by the real runner.
    const dir = await shippedBelow("0017");
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
    // **What this test does not show, said so its name cannot be read as more** (PR #250 review, R1):
    // declared the way the suite prints it, this draft passes, and with exactly the profile the
    // shipped 0017 carries. The check does not refuse a backfill under ACCESS EXCLUSIVE; it makes the
    // shape impossible to state as anything else, which is what puts it in front of a reviewer.
    const shipped0017 = (await loadMigrations()).find((m) => m.id.startsWith("0017_"))!;
    expect(declaredLockProfile(shipped0017.up, "0017 up")).toEqual(first);
  });

  itUnderHangBackstop("counts an index scan against its table, and still counts it after the half drops that index", async () => {
    // The scan counter on its own, through the runner (PR #250 review, F3). A statement that scans
    // an index also takes a weak lock on the table, so the full profile would report the table either
    // way — this reads the counter half alone, which is the only thing that sees an index scan run
    // under a strong lock, and is where deleting the index branch used to go unnoticed.
    await dropSchema(client);
    await client.query("DROP SCHEMA IF EXISTS lock_probe CASCADE");
    const dir = await mkdtemp(join(tmpdir(), "sonny-lock-index-"));
    const declared = "-- @locks none\n-- @scans none\n";
    const probe = "SET LOCAL enable_seqscan = off;\nSET LOCAL enable_bitmapscan = off;\n" +
      "SELECT * FROM lock_probe.t WHERE k = 1;\n";
    await writeFile(join(dir, "0001_probe_table.sql"),
      `${declared}CREATE SCHEMA lock_probe;\nCREATE TABLE lock_probe.t (id int PRIMARY KEY, k int);\n` +
        `CREATE INDEX t_k_idx ON lock_probe.t (k);\n-- @rollback\n${declared}DROP SCHEMA lock_probe CASCADE;`);
    await writeFile(join(dir, "0002_index_scan.sql"),
      `-- @locks none\n-- @scans lock_probe.t\n${probe}-- @rollback\n${declared}SELECT 1;`);
    await writeFile(join(dir, "0003_index_scan_then_drop.sql"),
      `-- @locks ACCESS EXCLUSIVE lock_probe.t\n-- @scans lock_probe.t\n${probe}DROP INDEX lock_probe.t_k_idx;\n` +
        `-- @rollback\n${declared}CREATE INDEX t_k_idx ON lock_probe.t (k);`);

    const counted = new Map<string, readonly string[]>();
    const full = new Map<string, LockProfile>();
    try {
      await up(client, dir, async (c, migration, half, run) => {
        const snapshot = await relationSnapshot(c);
        await run();
        counted.set(`${migration.id} ${half}`, await tablesScannedSince(c, snapshot));
        full.set(`${migration.id} ${half}`, await measuredLockProfile(c, snapshot));
      });
      expect({
        scan: counted.get("0002_index_scan up"),
        scanThenDrop: counted.get("0003_index_scan_then_drop up"),
      }).toEqual({ scan: ["lock_probe.t"], scanThenDrop: ["lock_probe.t"] });
      expect(full.get("0003_index_scan_then_drop up")).toEqual({
        locks: [{ relation: "lock_probe.t", mode: "ACCESS EXCLUSIVE" }],
        scans: ["lock_probe.t"],
      });
    } finally {
      await client.query("DROP SCHEMA IF EXISTS lock_probe CASCADE");
      await dropSchema(client);
    }
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
