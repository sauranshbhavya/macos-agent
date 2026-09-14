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
 * and **the pre-existing tables it reads through**. PR #171's first 0017 had a table on both lines
 * (a backfill under `ACCESS EXCLUSIVE` on the sign-in path), and 0016 is the harmless shape beside
 * it (`ACCESS EXCLUSIVE`, nothing read through). **What the two lines cannot say is the order**: a
 * lock taken before a scan stalls traffic for as long as the scan runs, a lock taken after it only
 * from that statement to COMMIT, and a declaration is two sets with no order in them (PR #250
 * review, F2 — 0014's up half reads `sonny.identity` under `SHARE ROW EXCLUSIVE` and takes
 * `ACCESS EXCLUSIVE` on it only afterwards).
 *
 * **Measured, never read off the SQL.** Keywords are the wrong instrument in both directions: a
 * `DROP INDEX` takes `ACCESS EXCLUSIVE` with no `ALTER TABLE` in sight, and the ledger's own
 * `ALTER … ADD COLUMN IF NOT EXISTS` took it while changing nothing (PR #169). So everything comes
 * from `pg_locks` for this backend and from Postgres's own per-transaction scan counter, read inside
 * the migration's transaction.
 *
 * **What an empty table hides, and how the scan line is built so it does not depend on one**
 * (PR #250 review, F1). The suite measures against the tables a fresh schema has, which are empty,
 * and on an empty table the executor skips work: a hash join whose first side is empty never scans
 * the second, a per-row subquery never runs. So the scan counter alone left tables out — with six
 * rows seeded, 0003 up, 0004 up, 0005 up, 0004 down and 0014 down each read a second table the
 * empty run never saw. **The scan line is therefore the union of two readings:**
 *
 * - **A weak relation lock** — `ACCESS SHARE`, `ROW SHARE` or `ROW EXCLUSIVE` — held on the table or
 *   one of its indexes. Postgres takes those when it *plans* a statement that names the table, before
 *   any row is read, so they are there whether or not the executor ever started the scan. This is
 *   what catches the five by construction. It over-reports a statement that names a table and reads
 *   no rows of it (`INSERT … VALUES`), which is the safe direction.
 * - **The scan counter** (`pg_stat_get_xact_numscans`) on the table or any of its indexes, read as a
 *   delta from the start of the same transaction because a backend does not flush it while one is
 *   open. It catches the DDL that reads rows without taking a weak lock — an index build,
 *   `SET NOT NULL` and `CHECK` validation, a rewrite — each of which starts its scan on an empty table
 *   too (measured on Postgres 17.11: `CREATE INDEX`, `SET NOT NULL` and `ADD CONSTRAINT … CHECK` at
 *   least one, `ALTER COLUMN … TYPE` and a volatile `DEFAULT` three).
 *
 * **What neither reading can see**, stated because the union is not complete: a statement that is
 * never planned on an empty database. A row trigger that never fires, a branch of a `DO` block or a
 * function that is never taken, and a function called once per row of an empty table all plan their
 * statements only when they run — so a table those statements read, **and a lock they take**, is
 * absent from both lines. Row locks are not relation locks at all, and neither line reports them.
 *
 * **Why not a timing, and why not seeded rows.** A duration is a wall-clock bet whose answer depends
 * on the machine and the data, and a suite that asserts one manufactures failures. Seeding every
 * table of every migration's starting schema is a constraint solver, and would still miss a branch
 * the seed happens not to take.
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

function isMarkerLine(line: string, marker: string): boolean {
  return line === marker || line.startsWith(`${marker} `);
}

/**
 * The half's head — its leading blank and `--` lines, up to the first line of anything else — and
 * every trimmed line after it.
 *
 * **A declaration is read only from the head** (PR #250 review, R2). The loader used to accept the
 * two lines anywhere in a half, including inside a `$$` function body or a multi-line string
 * literal, and a line in either of those is not a comment to Postgres: it is stored, so it is
 * hashed, and "adding the lines leaves the hash alone" would be false for exactly the file that put
 * them there. The head is always outside both, because nothing but comments and blank lines precede
 * it.
 */
function splitHead(half: string): { readonly head: string[]; readonly rest: string[] } {
  const lines = half.split("\n").map((line) => line.trim());
  const firstStatement = lines.findIndex((line) => line !== "" && !line.startsWith("--"));
  const end = firstStatement === -1 ? lines.length : firstStatement;
  return { head: lines.slice(0, end), rest: lines.slice(end) };
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
 * or `none` on either, in the half's head: above its first statement, among its leading comments.
 * There they are comments to Postgres too, so they are outside the content hash (`migration-hash.ts`
 * strips comments outside string literals), and a declaration can be added to an applied migration
 * without its ledger row calling it changed. A marker line anywhere below the head is refused rather
 * than read or ignored — below the head it may be inside a function body, where it would be hashed,
 * and silently ignoring it would let a reader believe a declaration is in force that is not.
 */
export function declaredLockProfile(half: string, where: string): LockProfile | undefined {
  const { head, rest } = splitHead(half);
  const below = rest.find((line) => isMarkerLine(line, LOCKS_MARKER) || isMarkerLine(line, SCANS_MARKER));
  if (below !== undefined) {
    throw new LockDeclarationError(
      where,
      `"${below}" sits below the half's first statement, where it may be inside a function body or ` +
        `a string and would be part of the SQL. Declarations go at the head of the half, above any SQL.`,
    );
  }
  const lockLines = head.filter((line) => isMarkerLine(line, LOCKS_MARKER));
  const scanLines = head.filter((line) => isMarkerLine(line, SCANS_MARKER));
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

/** One relation as the snapshot saw it. */
export interface SnapshotRelation {
  readonly name: string;
  /** `pg_class.relkind`: `r` table, `p` partitioned table, `m` materialized view, `i` index, … */
  readonly kind: string;
  /** For an index, the table it belongs to; otherwise null. */
  readonly tableOid: string | null;
  readonly scans: number;
}

/** Every non-system relation as it stood when the snapshot was taken, keyed by oid. */
export interface RelationSnapshot {
  readonly relations: ReadonlyMap<string, SnapshotRelation>;
}

/** The relation kinds whose rows a statement reads: a `@scans` entry is always one of these. */
const ROW_KINDS = new Set(["r", "p", "m"]);

/**
 * Names, kinds, index parents and scan counts of every relation outside the system schemas.
 *
 * Taken **inside** the transaction being measured and before its SQL, which is what makes
 * "pre-existing" mean something: a lock on a relation the migration itself created blocks nobody,
 * because nobody else can see it until COMMIT. Names are captured here because a relation the
 * migration drops has no `pg_class` row by the time the locks are read — and an index it drops
 * keeps its scan count, but no longer appears in `pg_index`, so the snapshot is also where a dropped
 * index is found again (PR #250 review, F3).
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
  const { rows } = await client.query<{ oid: string; name: string; kind: string; table_oid: string | null; scans: string }>(
    `SELECT c.oid::text AS oid,
            format('%I.%I', n.nspname, c.relname) AS name,
            c.relkind::text AS kind,
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
      rows.map((row) => [
        row.oid,
        { name: row.name, kind: row.kind, tableOid: row.table_oid, scans: Number(row.scans) },
      ]),
    ),
  };
}

/** The relation a lock or a scan is reported against: an index's table, or the relation itself. */
function owner(snapshot: RelationSnapshot, oid: string): SnapshotRelation | undefined {
  const relation = snapshot.relations.get(oid);
  if (relation === undefined || relation.tableOid === null) return relation;
  return snapshot.relations.get(relation.tableOid);
}

/** Every relation lock this backend holds, granted, in `pg_locks`' own spelling of the mode. */
async function relationLocksHeld(client: pg.Client): Promise<readonly { oid: string; mode: string }[]> {
  const { rows } = await client.query<{ oid: string; mode: string }>(
    `SELECT relation::text AS oid, mode
       FROM pg_locks
      WHERE pid = pg_backend_pid() AND locktype = 'relation' AND granted`,
  );
  return rows;
}

/**
 * The strongest blocking lock this backend holds on each relation the snapshot knew.
 *
 * A lock on an index is reported against its table: the planner takes `ACCESS SHARE` on every index
 * of a table it plans a query over, so `ACCESS EXCLUSIVE` on an index stalls that table's readers
 * exactly as it would on the table.
 */
export async function blockingLocksHeld(client: pg.Client, snapshot: RelationSnapshot): Promise<readonly HeldLock[]> {
  const strongest = new Map<string, BlockingMode>();
  for (const row of await relationLocksHeld(client)) {
    const mode = PG_LOCKS_MODE[row.mode];
    const relation = owner(snapshot, row.oid)?.name;
    if (mode === undefined || relation === undefined) continue;
    const held = strongest.get(relation);
    if (held === undefined || BLOCKING_MODES.indexOf(mode) > BLOCKING_MODES.indexOf(held)) {
      strongest.set(relation, mode);
    }
  }
  return [...strongest].map(([relation, mode]) => ({ relation, mode }))
    .sort((a, b) => a.relation.localeCompare(b.relation));
}

/** `pg_locks`' spelling of the three modes a statement takes on a table it names when it is planned. */
const PLANNED_READ_MODES = new Set(["AccessShareLock", "RowShareLock", "RowExclusiveLock"]);

/**
 * Every pre-existing table the half holds a weak relation lock on — directly, or through one of its
 * indexes.
 *
 * **This is the half of the scan line that does not depend on rows** (PR #250 review, F1). Postgres
 * takes these modes while it plans a statement naming the table, before the executor decides whether
 * to read anything, so a join's second table, a per-row subquery's table and a `USING` table are all
 * here on an empty database even when their scan never started. What is not here is anything that
 * is never planned on an empty database: a row trigger's statements, an untaken branch.
 */
export async function tablesLockedForReading(client: pg.Client, snapshot: RelationSnapshot): Promise<readonly string[]> {
  const read = new Set<string>();
  for (const row of await relationLocksHeld(client)) {
    if (!PLANNED_READ_MODES.has(row.mode)) continue;
    const table = owner(snapshot, row.oid);
    if (table !== undefined && ROW_KINDS.has(table.kind)) read.add(table.name);
  }
  return [...read].sort();
}

/**
 * Every pre-existing table whose own scan count, or any of its indexes', rose since the snapshot.
 *
 * **Indexes come from both catalogs, and each one covers a case the other cannot** (PR #250 review,
 * F3): the snapshot's indexes include one the half scanned and then dropped, which has left
 * `pg_index` by now but kept its count; the catalog as it stands now includes one the half created
 * and then scanned, which the snapshot never saw. This half of the scan line is what sees the DDL
 * that reads rows without a weak lock — an index build, a validation, a rewrite — and an index scan
 * the half ran under a strong lock only.
 */
export async function tablesScannedSince(client: pg.Client, snapshot: RelationSnapshot): Promise<readonly string[]> {
  const tables: string[] = [];
  const indexes: string[] = [];
  const indexTables: string[] = [];
  for (const [oid, relation] of snapshot.relations) {
    if (relation.tableOid === null) tables.push(oid);
    else { indexes.push(oid); indexTables.push(relation.tableOid); }
  }
  const { rows } = await client.query<{ oid: string; table_oid: string; scans: string }>(
    `SELECT t.oid::text AS oid, t.oid::text AS table_oid, pg_stat_get_xact_numscans(t.oid)::text AS scans
       FROM unnest($1::oid[]) AS t(oid)
     UNION ALL
     SELECT s.oid::text, s.table_oid::text, pg_stat_get_xact_numscans(s.oid)::text
       FROM unnest($2::oid[], $3::oid[]) AS s(oid, table_oid)
     UNION ALL
     SELECT i.indexrelid::text, i.indrelid::text, pg_stat_get_xact_numscans(i.indexrelid)::text
       FROM pg_index i
      WHERE i.indrelid = ANY($1::oid[]) AND NOT (i.indexrelid = ANY($2::oid[]))`,
    [tables, indexes, indexTables],
  );
  const scanned = new Set<string>();
  for (const row of rows) {
    const before = snapshot.relations.get(row.oid)?.scans ?? 0;
    const table = snapshot.relations.get(row.table_oid);
    if (Number(row.scans) > before && table !== undefined && ROW_KINDS.has(table.kind)) scanned.add(table.name);
  }
  return [...scanned].sort();
}

/** Both lines of a profile, read at one point inside the transaction being measured. */
export async function measuredLockProfile(client: pg.Client, snapshot: RelationSnapshot): Promise<LockProfile> {
  const scans = new Set([
    ...(await tablesScannedSince(client, snapshot)),
    ...(await tablesLockedForReading(client, snapshot)),
  ]);
  return { locks: await blockingLocksHeld(client, snapshot), scans: [...scans].sort() };
}
