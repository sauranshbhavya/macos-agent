import { describe, expect, it } from "vitest";
import { executableSql, migrationContentHash } from "../src/db/migration-hash.js";
import { driftedMigrations, loadMigrations, migrationStates } from "../src/db/migrate.js";

/**
 * What the migration content hash does and does not move for. Needs no database, so it runs on every
 * `npm test` — the decision this pins is a design decision about which edits are legal, and one that
 * only runs when somebody remembers to start a container is not a decision anybody is held to.
 *
 * The end-to-end half — apply, edit the file, watch the runner refuse — is
 * `migration-content-hash.db.test.ts`, which needs a real Postgres.
 */

const hashOf = (up: string, down = "DROP TABLE t;"): string => migrationContentHash(up, down);

describe("executableSql", () => {
  it("drops a line comment", () => {
    expect(executableSql("-- why this exists\nSELECT 1;")).toBe("SELECT 1;");
  });

  it("drops a trailing line comment without joining the tokens around it", () => {
    // `a--x\nb` must not become `ab`: Postgres reads a comment as whitespace, so the separator has
    // to survive the comment's removal.
    expect(executableSql("SELECT 1 -- trailing\nFROM t;")).toBe("SELECT 1 FROM t;");
  });

  it("drops a block comment, and block comments nest as Postgres nests them", () => {
    // C does not nest these; Postgres does. A depth-blind stripper stops at the FIRST `*/`, so the
    // text after it — `DROP TABLE t;` here — would survive into the hash as executable SQL.
    expect(executableSql("SELECT 1; /* outer /* inner */ DROP TABLE t; */ SELECT 2;")).toBe(
      "SELECT 1; SELECT 2;",
    );
  });

  it("collapses layout, so re-indenting a migration is not a change", () => {
    expect(executableSql("SELECT\n\n   1,\n\t2\nFROM   t;")).toBe("SELECT 1, 2 FROM t;");
  });

  it("keeps a double dash inside a string literal, which is content and not a comment", () => {
    // A lexer that treated this as a comment would not merely mis-hash the file; it would silently
    // truncate the literal it was hashing, so two genuinely different INSERTs would agree.
    expect(executableSql("INSERT INTO t VALUES ('a -- not a comment');")).toBe(
      "INSERT INTO t VALUES ('a -- not a comment');",
    );
  });

  it("keeps a doubled quote inside a string literal rather than ending the literal there", () => {
    expect(executableSql("SELECT 'it''s -- fine';")).toBe("SELECT 'it''s -- fine';");
  });

  it("keeps a block-comment opener inside a string literal", () => {
    expect(executableSql("SELECT '/* not a comment';")).toBe("SELECT '/* not a comment';");
  });

  it("keeps a double dash inside a quoted identifier", () => {
    expect(executableSql('SELECT "odd -- name" FROM t;')).toBe('SELECT "odd -- name" FROM t;');
  });

  it("keeps a comment inside a dollar-quoted function body, because Postgres stores it", () => {
    // Eight shipped migrations define plpgsql functions this way and several of those bodies carry
    // `--` lines. Those bytes land in `pg_proc.prosrc`, which `migrate.db.test.ts`'s own schema
    // fingerprint hashes — so a function body's text IS schema, and editing one is a real change.
    const body = "CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$\nBEGIN\n  -- why\n  RETURN 1;\nEND $$;";
    expect(executableSql(body)).toContain("-- why");
  });

  it("preserves whitespace inside a dollar-quoted body, which is stored verbatim too", () => {
    const body = "AS $$\nBEGIN\n  RETURN 1;\nEND $$;";
    expect(executableSql(body)).toBe(body);
  });

  it("reads a tagged dollar quote to its matching tag, not to the first bare $$ inside it", () => {
    const body = "AS $fn$ SELECT '$$'; $fn$;";
    expect(executableSql(body)).toBe(body);
  });

  it("does not mistake a bind parameter for a dollar quote", () => {
    // `$1` is not a dollar-quote opener — a tag cannot begin with a digit — and reading it as one
    // would swallow the rest of the file into a literal that never closes.
    expect(executableSql("UPDATE t SET a = $1 -- c\nWHERE id = $2;")).toBe(
      "UPDATE t SET a = $1 WHERE id = $2;",
    );
  });

  it("does not fold case, because a quoted identifier's case is part of its name", () => {
    expect(executableSql('SELECT "Id" FROM t;')).not.toBe(executableSql('SELECT "id" FROM t;'));
  });

  // ---- Escape strings and the rest of Postgres's literal forms (SONNY-364 review, F1) ----
  //
  // The review's point was not that E'…' was missing, it was that the argument for skipping it
  // rested on a test that did not exist: the changelog grepped the migrations, proved E' absent, and
  // wrote down that the absence was exactly why the tests carry the case. So these are the forms
  // §4.1.2 of the Postgres manual lists, each with a `--` inside it that must survive.

  it("does not let a backslash-escaped quote end an escape string early", () => {
    // The defect this closes. With E'…' lexed as an ordinary string, `\'` ended the literal, `b --
    // two')` was lexed as CODE, and the `--` there was stripped as a comment — so two INSERTs
    // storing different rows normalised to the same text.
    expect(executableSql("INSERT INTO t VALUES (E'a\\' -- one');")).toBe(
      "INSERT INTO t VALUES (E'a\\' -- one');",
    );
  });

  it("hashes two escape strings differing only inside the literal differently", () => {
    // The property underneath the lexing, stated as the collision it prevents.
    expect(hashOf("INSERT INTO t VALUES (E'a\\' -- one');")).not.toBe(
      hashOf("INSERT INTO t VALUES (E'a\\' -- two');"),
    );
  });

  it("accepts a lower-case e as the escape prefix, which Postgres does too", () => {
    expect(executableSql("SELECT e'a\\' -- x';")).toBe("SELECT e'a\\' -- x';");
  });

  it("treats a doubled backslash as a literal one, so the quote after it still closes", () => {
    // `E'a\\'` is a complete literal holding `a\`. If the second backslash were read as escaping the
    // quote, the literal would run on and swallow the statement after it.
    expect(executableSql("SELECT E'a\\\\', 1 -- note\n;")).toBe("SELECT E'a\\\\', 1 ;");
  });

  it("still honours a doubled quote inside an escape string", () => {
    expect(executableSql("SELECT E'it''s -- fine';")).toBe("SELECT E'it''s -- fine';");
  });

  it("keeps an escape string holding BOTH quote forms in one piece", () => {
    // **The simple case above cannot fail, and a battery is what said so** (SONNY-364 round 2, L3).
    // Dropping the doubled-quote branch survived it: every byte is copied verbatim either way, so
    // reading `''` as "close, then reopen" re-partitions `E'it''s -- fine'` into two literals whose
    // bytes concatenate to exactly the same text. Nothing outside a literal moves, so nothing is
    // stripped differently, so the assertion passes on the mutant.
    //
    // It takes both escape forms in one literal for the partitions to diverge: read correctly, this
    // is ONE literal `E'a''b\'c'` (Postgres 17.11 returns `a'b'c`, length 5); read without the
    // doubled-quote branch it becomes `E'a'` + `'b\'` + a bare `c` + a literal that opens at the
    // last quote and never closes — which swallows the real comment below into it instead of
    // stripping it. That is the difference this asserts.
    expect(executableSql("SELECT E'a''b\\'c' , 1 -- x\nFROM t;")).toBe(
      "SELECT E'a''b\\'c' , 1 FROM t;",
    );
  });

  it("hashes two such literals differently when only their content differs", () => {
    expect(hashOf("SELECT E'a''b\\'c' -- x\n;")).not.toBe(hashOf("SELECT E'a''b\\'d' -- x\n;"));
  });

  it("does not read a trailing e of an identifier as an escape prefix", () => {
    // Postgres's scanner is flex and longest-match wins, so `code_e'…'` is an identifier followed by
    // an ORDINARY string — in which `\'` closes the literal. Reading the `e` as a prefix would run
    // the literal past the quote that really closes it and swallow the comment below into it.
    expect(executableSql("SELECT code_e'a\\', 1 -- note\n;")).toBe("SELECT code_e'a\\', 1 ;");
  });

  it("needs no special handling for a unicode escape string, and keeps a comment inside one", () => {
    // U&'…' is deliberately NOT given a branch: its backslash introduces a unicode escape rather
    // than escaping a quote, and quotes are still doubled — so the `U&` lexes as code and the quote
    // opens a plain literal, which is what the scanner does as well.
    expect(executableSql("SELECT U&'\\0441 -- inside';")).toBe("SELECT U&'\\0441 -- inside';");
  });

  it("needs no special handling for a unicode quoted identifier", () => {
    expect(executableSql('SELECT U&"od -- d" FROM t;')).toBe('SELECT U&"od -- d" FROM t;');
  });

  it("needs no special handling for bit-string and hex-string constants", () => {
    expect(executableSql("SELECT B'0101', X'1FF' -- note\n;")).toBe("SELECT B'0101', X'1FF' ;");
  });

  // ---- The dollar-quote tag rule, whose character classes a mutant walked through ----

  it("reads a tag containing digits, which a tag after its first character may hold", () => {
    // Pins TAG_REST. Narrowed to [A-Za-z_], `$fn1$` stops being recognised as a tag at all, the body
    // is lexed as ordinary code, and every comment in that function body is stripped from the hash —
    // silently loosening the guard over exactly the migrations that define functions.
    const body = "AS $fn1$ BEGIN -- why\n RETURN 1; END $fn1$;";
    expect(executableSql(body)).toBe(body);
  });

  it("reads a tag containing an underscore", () => {
    const body = "AS $my_fn$ BEGIN -- why\n RETURN 1; END $my_fn$;";
    expect(executableSql(body)).toBe(body);
  });

  it("does not let a tag BEGIN with a digit, which Postgres does not either", () => {
    // Pins TAG_START. Widened to [A-Za-z0-9_], `$1$` reads as a dollar-quote opener whose closing
    // tag never appears, so the rest of the file is copied verbatim as literal content — comments
    // included. The bind-parameter test above does not catch that: `$1 ` is followed by a space, so
    // the widened class still fails to find the closing `$`, and it takes a `$` right after the
    // digits to tell the two apart.
    expect(executableSql("SELECT $1$ -- note\n;")).toBe("SELECT $1$ ;");
  });

  it("copies an unterminated literal to the end rather than throwing", () => {
    // The file is malformed and Postgres will say so in terms of the real problem. A normalizer that
    // threw first would replace that message with one about hashing.
    expect(executableSql("SELECT 'unclosed")).toBe("SELECT 'unclosed");
  });
});

describe("migrationContentHash", () => {
  it("does not move when only a comment changes — the decision this whole guard rests on", () => {
    // PR #167's edit to 0014 was comment-only, deliberate and correct. A whole-file hash would have
    // made it a hard failure on every environment that had already applied 0014.
    const before = "-- 0014 — a note.\nALTER TABLE t ADD COLUMN c text;";
    const after =
      "-- 0014 — a note, now recording that 0015 changed what this column may imply.\n" +
      "-- A second paragraph, because this repository annotates its migrations on purpose.\n" +
      "ALTER TABLE t ADD COLUMN c text;";
    expect(hashOf(after)).toBe(hashOf(before));
  });

  it("does not move when only layout changes", () => {
    expect(hashOf("ALTER TABLE t\n  ADD COLUMN c text;")).toBe(hashOf("ALTER TABLE t ADD COLUMN c text;"));
  });

  it("moves when a column type changes", () => {
    expect(hashOf("ALTER TABLE t ADD COLUMN c text;")).not.toBe(
      hashOf("ALTER TABLE t ADD COLUMN c uuid;"),
    );
  });

  it("moves when a statement is added", () => {
    expect(hashOf("CREATE TABLE t (id int);")).not.toBe(
      hashOf("CREATE TABLE t (id int);\nCREATE INDEX t_id ON t (id);"),
    );
  });

  it("moves when a constant inside a string literal changes", () => {
    expect(hashOf("INSERT INTO t VALUES ('a');")).not.toBe(hashOf("INSERT INTO t VALUES ('b');"));
  });

  it("moves when only a comment inside a function body changes", () => {
    const fn = (note: string) =>
      `CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$\nBEGIN\n  -- ${note}\n  RETURN 1;\nEND $$;`;
    expect(hashOf(fn("first"))).not.toBe(hashOf(fn("second")));
  });

  it("moves when only the ROLLBACK half changes", () => {
    // Both halves are hashed. README's rehearsal — apply on staging, roll back, apply again, then
    // production — is only a rehearsal if production's rollback is the one staging walked.
    expect(hashOf("CREATE TABLE t (id int);", "DROP TABLE t;")).not.toBe(
      hashOf("CREATE TABLE t (id int);", "DROP TABLE IF EXISTS t;"),
    );
  });

  it("does not confuse a shift of text between the two halves for a match", () => {
    // The halves are length-prefixed rather than joined by a separator, because normalized text may
    // contain any byte inside a string literal and no separator would be safe.
    expect(hashOf("SELECT 1;SELECT 2;", "")).not.toBe(hashOf("SELECT 1;", "SELECT 2;"));
  });

  it("is a sha256 hex digest, which is what the ledger column holds", () => {
    expect(hashOf("SELECT 1;")).toMatch(/^[0-9a-f]{64}$/);
  });

  it("gives every shipped migration a distinct hash", async () => {
    // Not a formality: two migrations hashing alike would mean the normalizer had erased what
    // separates them, and the ledger's whole job is telling one text from another.
    const shipped = await loadMigrations();
    expect(shipped.length).toBeGreaterThan(1);
    expect(new Set(shipped.map((m) => m.contentHash)).size).toBe(shipped.length);
    for (const migration of shipped) expect(migration.contentHash).toMatch(/^[0-9a-f]{64}$/);
  });

  it("leaves executable SQL in every shipped migration, and drops the prose around it", async () => {
    // The stripper runs over files whose headers are fifty lines of prose. If it ever ate the SQL
    // too, every hash would still be a valid digest and every comparison would still pass — a guard
    // over nothing, reporting success. So both directions: something is left, and something went.
    //
    // Note what is NOT asserted: that no `-- ` survives anywhere. It does, inside the plpgsql bodies
    // of eight of these files, and that is the design — those bytes are stored in `pg_proc.prosrc`.
    // This assertion was written the other way first, and 0003 failed it.
    const shipped = await loadMigrations();
    for (const migration of shipped) {
      const up = executableSql(migration.up);
      expect(up.length).toBeGreaterThan(0);
      expect(executableSql(migration.down).length).toBeGreaterThan(0);
      expect(up.startsWith("--")).toBe(false);
      expect(up.length).toBeLessThan(migration.up.length);
    }
  });

  it("does not move when a comment is added to the real 0014, which is the edit PR #167 made", async () => {
    // Against the actual file rather than a fixture, because a fixture is the thing a design
    // decision is easiest to be accidentally right about. 0014's header is the fifty lines of prose
    // this guard has to keep legal.
    const shipped = await loadMigrations();
    const real = shipped.find((m) => m.id === "0014_a_provider_side_user_is_remembered_and_revocable");
    expect(real).toBeDefined();
    const annotated =
      "-- **A later note.** 0015 changed what the column below may imply.\n--\n" + real!.up;
    expect(migrationContentHash(annotated, real!.down)).toBe(real!.contentHash);
  });

  it("moves when one identifier of the real 0014's executable SQL changes", async () => {
    // The other direction against the same file, so "does not move" above is not simply a hash that
    // never moves at all.
    const shipped = await loadMigrations();
    const real = shipped.find((m) => m.id === "0014_a_provider_side_user_is_remembered_and_revocable");
    const tampered = real!.up.replace("sonny.identity_provider_user", "sonny.identity_provider_users");
    expect(tampered).not.toBe(real!.up);
    expect(migrationContentHash(tampered, real!.down)).not.toBe(real!.contentHash);
  });
});

describe("what status reports", () => {
  // `status` never refuses — it is the diagnostic reached for once `up` or `down` has — so what it
  // is worth pinning is the classification, and above all that a changed migration is COUNTED. A
  // status that printed the state and exited 0 anyway is the clean zero this repository keeps
  // recording: a reassuring answer indistinguishable from a real one.
  const migration = (id: string, up: string) => ({
    id,
    up,
    down: "DROP TABLE t;",
    contentHash: migrationContentHash(up, "DROP TABLE t;"),
  });

  const applied = migration("0001_a", "CREATE TABLE t (id int);");
  const changed = migration("0002_b", "CREATE TABLE u (id int);");
  const pending = migration("0003_c", "CREATE TABLE v (id int);");
  const unverified = migration("0004_d", "CREATE TABLE w (id int);");
  const all = [applied, changed, pending, unverified];

  const ledger = new Map<string, string | null>([
    [applied.id, applied.contentHash],
    [changed.id, "a hash from the text this environment actually applied"],
    [unverified.id, null],
  ]);

  it("names each of the four states, and never the wrong one", () => {
    expect(migrationStates(ledger, all)).toEqual([
      { id: "0001_a", state: "applied" },
      { id: "0002_b", state: "CHANGED" },
      { id: "0003_c", state: "pending" },
      { id: "0004_d", state: "unverified" },
    ]);
  });

  it("counts a changed migration, which is what sets the exit code", () => {
    expect(migrationStates(ledger, all).filter((s) => s.state === "CHANGED")).toHaveLength(1);
  });

  it("reports nothing changed when every applied file still matches", () => {
    const clean = new Map<string, string | null>([[applied.id, applied.contentHash]]);
    expect(migrationStates(clean, all).filter((s) => s.state === "CHANGED")).toHaveLength(0);
  });

  it("reports the migrations in file order, so the list reads as a sequence", () => {
    expect(migrationStates(ledger, all).map((s) => s.id)).toEqual(all.map((m) => m.id));
  });
});

describe("driftedMigrations", () => {
  const of = (id: string, up: string) => ({
    id,
    up,
    down: "",
    contentHash: migrationContentHash(up, ""),
  });

  it("reports both hashes, so the refusal can say what moved", () => {
    const m = of("0001_a", "SELECT 1;");
    const drift = driftedMigrations(new Map([["0001_a", "recorded-hash"]]), [m]);
    expect(drift).toEqual([{ id: "0001_a", recorded: "recorded-hash", found: m.contentHash }]);
  });

  it("says nothing about a migration with no ledger row, because pending is not drift", () => {
    expect(driftedMigrations(new Map(), [of("0001_a", "SELECT 1;")])).toEqual([]);
  });

  it("says nothing about an applied migration whose hash was never recorded", () => {
    const m = of("0001_a", "SELECT 1;");
    expect(driftedMigrations(new Map([["0001_a", null]]), [m])).toEqual([]);
  });

  it("says nothing about a ledger row whose file is not in the directory being run", () => {
    // `up(client, someOtherDir)` is how three existing tests apply throwaway migrations against a
    // database that also holds the real ones.
    expect(driftedMigrations(new Map([["0099_gone", "hash"]]), [])).toEqual([]);
  });

  it("reports every drifted migration rather than stopping at the first", () => {
    const a = of("0001_a", "SELECT 1;");
    const b = of("0002_b", "SELECT 2;");
    const stale = new Map([["0001_a", "x"], ["0002_b", "y"]]);
    expect(driftedMigrations(stale, [a, b]).map((d) => d.id)).toEqual(["0001_a", "0002_b"]);
  });
});
