import type pg from "pg";

/**
 * What a migration does to the traffic around it, declared in its file and measured by the suite
 * (SONNY-370).
 *
 * **Two things decide a migration's stall, and a declaration names both.** The lock MODE decides
 * whether a reader or a writer waits at all — `ACCESS EXCLUSIVE` conflicts with the `ACCESS SHARE`
 * every `SELECT` takes, and `SHARE` conflicts with the `ROW EXCLUSIVE` every write takes. The
 * transaction decides how long: this runner gives each migration one, and a lock is held to COMMIT,
 * so the wait lasts as long as the whole migration runs. What makes that long is work that grows
 * with a table's rows — a backfill, an index build, a `SET NOT NULL` or `CHECK` validation, a
 * rewrite. So a migration's profile is **the pre-existing relations it holds a blocking lock on**
 * and **the pre-existing tables it scans**, and the dangerous shape is a lock on one line and a scan
 * on the other. PR #171's first 0017 was exactly that shape (a backfill under `ACCESS EXCLUSIVE` on
 * the sign-in path), and 0016 is the harmless one beside it (`ACCESS EXCLUSIVE`, nothing scanned).
 *
 * **Measured, never read off the SQL.** Keywords are the wrong instrument in both directions: a
 * `DROP INDEX` takes `ACCESS EXCLUSIVE` with no `ALTER TABLE` in sight, and the ledger's own
 * `ALTER … ADD COLUMN IF NOT EXISTS` took it while changing nothing (PR #169). So the locks come from
 * `pg_locks` for this backend, and the scans from Postgres's own per-transaction scan counter, both
 * read inside the migration's transaction.
 *
 * **Why a scan counter and not a timing, and not row counts.** A duration is a wall-clock bet whose
 * answer depends on the machine and the data, and a suite that asserts one manufactures failures.
 * Row counts need rows, and seeding every table of every migration's starting schema is a constraint
 * solver. `pg_stat_get_xact_numscans` counts a scan when it *starts*, so it answers on an empty
 * table: measured on Postgres 17.11, an index build, an `UPDATE … FROM` backfill, `SET NOT NULL`,
 * `ADD CONSTRAINT … CHECK` and a `DELETE … WHERE id = …` each counted at least one, a rewrite
 * (`ALTER COLUMN … TYPE`, a volatile `DEFAULT`) three, and `ADD COLUMN … NOT NULL DEFAULT 1`,
 * `DROP INDEX`, `COMMENT ON` and `INSERT … VALUES` none. The counter is read as a delta from the
 * start of the same transaction, because a backend does not flush it while one is open.
 */

/**
 * The lock modes that conflict with ordinary traffic, weakest first.
 *
 * Ordinary traffic takes `ACCESS SHARE` (a read), `ROW SHARE` (`SELECT … FOR UPDATE`) and
 * `ROW EXCLUSIVE` (a write). `SHARE` and `SHARE ROW EXCLUSIVE` block writes; `EXCLUSIVE` also blocks
 * locking reads; `ACCESS EXCLUSIVE` blocks every read. `SHARE UPDATE EXCLUSIVE` — `COMMENT ON`,
 * `ANALYZE` — conflicts with none of the three and is therefore not a stall, which is why it is not
 * here. The order is what "strongest" means when a relation holds several.
 */
export const BLOCKING_MODES = [
  "SHARE",
  "SHARE ROW EXCLUSIVE",
  "EXCLUSIVE",
  "ACCESS EXCLUSIVE",
] as const;
export type BlockingMode = (typeof BLOCKING_MODES)[number];

/** `pg_locks.mode` spells each mode as one CamelCase word. */
const PG_LOCKS_MODE: Readonly<Record<string, BlockingMode>> = {
  ShareLock: "SHARE",
  ShareRowExclusiveLock: "SHARE ROW EXCLUSIVE",
  ExclusiveLock: "EXCLUSIVE",
  AccessExclusiveLock: "ACCESS EXCLUSIVE",
};

export interface HeldLock {
  /** Schema-qualified, the way `format('%I.%I')` writes it. */
  readonly relation: string;
  /** The strongest blocking mode held on it. */
  readonly mode: BlockingMode;
}

export interface LockProfile {
  /** Sorted by relation, one entry per relation. */
  readonly locks: readonly HeldLock[];
  /** Sorted, schema-qualified tables. */
  readonly scans: readonly string[];
}

export const LOCKS_MARKER = "-- @locks";
export const SCANS_MARKER = "-- @scans";

/** A declaration that is present and cannot be read. Never treated as "undeclared". */
export class LockDeclarationError extends Error {
  constructor(where: string, problem: string) {
    super(`${where}: ${problem}`);
    this.name = "LockDeclarationError";
  }
}

const RELATION = /^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$/;

function markerLines(half: string, marker: string): string[] {
  return half
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line === marker || line.startsWith(`${marker} `));
}

function itemsOf(line: string, marker: string, where: string): string[] | undefined {
  const body = line.slice(marker.length).trim();
  if (body === "") throw new LockDeclarationError(where, `"${marker}" names nothing; write "${marker} none"`);
  if (body === "none") return undefined;
  const items = body.split(",").map((item) => item.trim());
  if (items.some((item) => item === "" || item === "none")) {
    throw new LockDeclarationError(where, `"${line}" has an empty entry or mixes "none" with names`);
  }
  return items;
}

/**
 * Reads one half's declaration: `undefined` when the half declares nothing at all, and a refusal
 * when it declares something unreadable.
 *
 * The format is two comment lines, each exactly once per half:
 *
 *     -- @locks ACCESS EXCLUSIVE sonny.sign_in_code_issue, SHARE sonny.identity
 *     -- @scans sonny.sign_in_code_issue
 *
 * or `none` on either. They are comments, so they are outside the content hash (`migration-hash.ts`
 * strips comments outside string literals), and a declaration can be added to an applied migration
 * without its ledger row calling it changed.
 */
export function declaredLockProfile(half: string, where: string): LockProfile | undefined {
  const lockLines = markerLines(half, LOCKS_MARKER);
  const scanLines = markerLines(half, SCANS_MARKER);
  if (lockLines.length === 0 && scanLines.length === 0) return undefined;
  if (lockLines.length !== 1 || scanLines.length !== 1) {
    throw new LockDeclarationError(
      where,
      `needs exactly one "${LOCKS_MARKER}" line and one "${SCANS_MARKER}" line, ` +
        `found ${lockLines.length} and ${scanLines.length}`,
    );
  }
  const locks: HeldLock[] = [];
  for (const item of itemsOf(lockLines[0]!, LOCKS_MARKER, where) ?? []) {
    // Longest mode first, so "SHARE ROW EXCLUSIVE x" is not read as "SHARE" of "ROW EXCLUSIVE x".
    const mode = [...BLOCKING_MODES]
      .sort((a, b) => b.length - a.length)
      .find((candidate) => item.startsWith(`${candidate} `));
    const relation = mode === undefined ? "" : item.slice(mode.length).trim();
    if (mode === undefined || !RELATION.test(relation)) {
      throw new LockDeclarationError(
        where,
        `"${item}" is not a blocking mode (${BLOCKING_MODES.join(", ")}) followed by schema.table`,
      );
    }
    locks.push({ relation, mode });
  }
  const scans = itemsOf(scanLines[0]!, SCANS_MARKER, where) ?? [];
  for (const relation of scans) {
    if (!RELATION.test(relation)) {
      throw new LockDeclarationError(where, `"${relation}" is not schema.table`);
    }
  }
  if (new Set(locks.map((lock) => lock.relation)).size !== locks.length) {
    throw new LockDeclarationError(where, "names one relation twice in its locks; declare the strongest mode once");
  }
  if (new Set(scans).size !== scans.length) {
    throw new LockDeclarationError(where, "names one table twice in its scans");
  }
  return normalized({ locks, scans });
}

function normalized(profile: LockProfile): LockProfile {
  return {
    locks: [...profile.locks].sort((a, b) => a.relation.localeCompare(b.relation)),
    scans: [...profile.scans].sort(),
  };
}

/** The two lines a migration carries, so a failure prints exactly what to write. */
export function formatLockProfile(profile: LockProfile): string {
  const locks = profile.locks.length === 0
    ? "none"
    : profile.locks.map((lock) => `${lock.mode} ${lock.relation}`).join(", ");
  const scans = profile.scans.length === 0 ? "none" : profile.scans.join(", ");
  return `${LOCKS_MARKER} ${locks}\n${SCANS_MARKER} ${scans}`;
}

export function sameLockProfile(a: LockProfile, b: LockProfile): boolean {
  return formatLockProfile(normalized(a)) === formatLockProfile(normalized(b));
}

/** Every non-system relation as it stood when the snapshot was taken. */
export interface RelationSnapshot {
  readonly relations: ReadonlyMap<string, { readonly name: string; readonly tableOid: string | null; readonly scans: number }>;
}

/**
 * Names, index parents and scan counts of every relation outside the system schemas.
 *
 * Taken **inside** the transaction being measured and before its SQL, which is what makes
 * "pre-existing" mean something: a lock on a relation the migration itself created blocks nobody,
 * because nobody else can see it until COMMIT. Names are captured here because a relation the
 * migration drops has no `pg_class` row by the time the locks are read.
 *
 * **It refuses when `track_counts` is off.** Every scan count would then read zero, and a
 * measurement that can only ever answer "scans nothing" is the reassuring clean zero this
 * repository keeps recording rather than a measurement.
 */
export async function relationSnapshot(client: pg.Client): Promise<RelationSnapshot> {
  const { rows: setting } = await client.query<{ track_counts: string }>("SHOW track_counts");
  if (setting[0]?.track_counts !== "on") {
    throw new Error(
      `track_counts is ${setting[0]?.track_counts ?? "unreadable"} on this connection, so every ` +
        `scan count reads zero and no lock profile measured here could report a scan.`,
    );
  }
  const { rows } = await client.query<{ oid: string; name: string; table_oid: string | null; scans: string }>(
    `SELECT c.oid::text AS oid,
            format('%I.%I', n.nspname, c.relname) AS name,
            (SELECT i.indrelid::text FROM pg_index i WHERE i.indexrelid = c.oid) AS table_oid,
            pg_stat_get_xact_numscans(c.oid)::text AS scans
       FROM pg_class c
       JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND n.nspname NOT LIKE 'pg\\_toast%'
        AND n.nspname NOT LIKE 'pg\\_temp%'`,
  );
  return {
    relations: new Map(
      rows.map((row) => [row.oid, { name: row.name, tableOid: row.table_oid, scans: Number(row.scans) }]),
    ),
  };
}

/** The table an index belongs to, or the relation itself. */
function owningName(snapshot: RelationSnapshot, oid: string): string | undefined {
  const relation = snapshot.relations.get(oid);
  if (relation === undefined) return undefined;
  if (relation.tableOid === null) return relation.name;
  return snapshot.relations.get(relation.tableOid)?.name;
}

/**
 * The strongest blocking lock this backend holds on each relation the snapshot knew.
 *
 * A lock on an index is reported against its table: the planner takes `ACCESS SHARE` on every index
 * of a table it plans a query over, so `ACCESS EXCLUSIVE` on an index stalls that table's readers
 * exactly as it would on the table.
 */
export async function blockingLocksHeld(client: pg.Client, snapshot: RelationSnapshot): Promise<readonly HeldLock[]> {
  const { rows } = await client.query<{ oid: string; mode: string }>(
    `SELECT relation::text AS oid, mode
       FROM pg_locks
      WHERE pid = pg_backend_pid() AND locktype = 'relation' AND granted`,
  );
  const strongest = new Map<string, BlockingMode>();
  for (const row of rows) {
    const mode = PG_LOCKS_MODE[row.mode];
    const relation = owningName(snapshot, row.oid);
    if (mode === undefined || relation === undefined) continue;
    const held = strongest.get(relation);
    if (held === undefined || BLOCKING_MODES.indexOf(mode) > BLOCKING_MODES.indexOf(held)) {
      strongest.set(relation, mode);
    }
  }
  return [...strongest].map(([relation, mode]) => ({ relation, mode }))
    .sort((a, b) => a.relation.localeCompare(b.relation));
}

/**
 * Every pre-existing table whose own scan count, or any of its indexes', rose since the snapshot.
 *
 * Indexes are read from the catalog as it stands **now** as well as from the snapshot, so an index
 * the migration created and then scanned through still counts against its table.
 */
export async function tablesScannedSince(client: pg.Client, snapshot: RelationSnapshot): Promise<readonly string[]> {
  const tables = [...snapshot.relations].filter(([, relation]) => relation.tableOid === null).map(([oid]) => oid);
  const { rows } = await client.query<{ oid: string; table_oid: string; scans: string }>(
    `SELECT t.oid::text AS oid, t.oid::text AS table_oid, pg_stat_get_xact_numscans(t.oid)::text AS scans
       FROM unnest($1::oid[]) AS t(oid)
     UNION ALL
     SELECT i.indexrelid::text, i.indrelid::text, pg_stat_get_xact_numscans(i.indexrelid)::text
       FROM pg_index i
      WHERE i.indrelid = ANY($1::oid[])`,
    [tables],
  );
  const scanned = new Set<string>();
  for (const row of rows) {
    const before = snapshot.relations.get(row.oid)?.scans ?? 0;
    if (Number(row.scans) > before) {
      const name = snapshot.relations.get(row.table_oid)?.name;
      if (name !== undefined) scanned.add(name);
    }
  }
  return [...scanned].sort();
}

/** Both halves of a profile, read at one point inside the transaction being measured. */
export async function measuredLockProfile(client: pg.Client, snapshot: RelationSnapshot): Promise<LockProfile> {
  return { locks: await blockingLocksHeld(client, snapshot), scans: await tablesScannedSince(client, snapshot) };
}
