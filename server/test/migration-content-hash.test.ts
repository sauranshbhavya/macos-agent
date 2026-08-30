import { describe, expect, it } from "vitest";
import { executableSql, migrationContentHash } from "../src/db/migration-hash.js";
import { loadMigrations } from "../src/db/migrate.js";

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
