import { createHash } from "node:crypto";

/**
 * What a migration's content hash is taken over, and — the whole of SONNY-364's design decision —
 * what it deliberately ignores.
 *
 * **The hazard.** `sonny_meta.schema_migration` recorded an applied migration by id alone, so a
 * migration's file could be edited after it had been applied somewhere and no environment would
 * ever say so. Two deployments both reporting `0014` as applied can hold different schemas, and
 * `npm run migrate status` answered with ids, so it called them identical. Development, beta and v1
 * receive the same image at different times (`docs/sonny-row-12-host-decision.md` §12.2), so an
 * edit landing between two of their deploys puts them permanently out of step on the one thing that
 * defines the database.
 *
 * **Comments are stripped, and that is the decision rather than an optimisation.** A whole-file hash
 * would have made PR #167's comment-only edit to `0014` a hard failure on every environment that had
 * already run it — an edit that was deliberate and correct, recording that `0015` changed what
 * `0014`'s column may imply. This repository writes long explanatory comments into its migrations on
 * purpose: `0014`'s header alone is about fifty lines of prose arguing why the migration is shaped
 * the way it is, and `0009`'s explains a defect it exists to fix. A guard that turned annotating an
 * applied migration into an outage is a guard that would be deleted the first week it fired, and the
 * practice it ended is one this repo's reviews actually depend on. So the hash is over the
 * **executable** SQL: what Postgres would run, with comments and layout removed. A behavioural
 * change still moves it; a paragraph of prose does not.
 *
 * **A comment inside a string literal is not a comment, and is kept.** This is where the line is
 * drawn and it is drawn on what reaches the database rather than on what looks like prose. Eight of
 * the shipped migrations define plpgsql functions inside `$$ … $$`, and several of those bodies
 * carry `--` lines of their own — `0003`'s trigger function explains at lines 30-31 why it fires
 * only on the transition into closed. Those bytes are not discarded by Postgres; they are stored
 * verbatim in `pg_proc.prosrc`, which is why `migrate.db.test.ts`'s own schema fingerprint hashes
 * `md5(p.prosrc)` and treats a function body's text as schema. Editing one changes the database, so
 * it changes the hash. The same holds for `--` or a slash-star inside `'…'` or `"…"`: they are
 * literal content, and a lexer that treated them as comments would not merely mis-hash the file, it
 * would corrupt the text it was hashing.
 *
 * **What this cannot do**, stated rather than implied: it compares a file against what an
 * environment recorded when it applied that file. It says nothing about whether the schema in the
 * database still matches the migration — a hand-run `ALTER TABLE` against production is invisible
 * here, and always was. It also says nothing about an applied migration whose file has been
 * *deleted*: nothing is left to hash, so nothing is compared, and `status` reports it as before.
 * That is the same family of hazard and it is deliberately not this ticket's; it is recorded on
 * SONNY-364's closing comment rather than half-built here.
 */

const WHITESPACE = new Set([" ", "\t", "\n", "\r", "\f", "\v"]);

/**
 * A dollar-quote tag starting at `at`, or undefined. The tag body follows the rules for an unquoted
 * identifier, so `$1` — a bind parameter, which several migrations use — is not one: `1` cannot open
 * an identifier, so the optional body matches empty and the required closing `$` is not there.
 */
function dollarTagAt(text: string, at: number): string | undefined {
  if (text[at] !== "$") return undefined;
  let end = at + 1;
  if (end < text.length && /[A-Za-z_]/.test(text[end]!)) {
    end += 1;
    while (end < text.length && /[A-Za-z0-9_]/.test(text[end]!)) end += 1;
  }
  return text[end] === "$" ? text.slice(at, end + 1) : undefined;
}

/**
 * The migration text as Postgres would see it, with comments removed and layout collapsed, and with
 * every string literal, quoted identifier and dollar-quoted body copied through untouched.
 *
 * An unterminated literal is copied to the end of the file rather than throwing. The file is
 * malformed and Postgres will refuse it with a message about the actual problem; a normalizer that
 * threw first would replace that message with one about hashing.
 */
export function executableSql(text: string): string {
  const out: string[] = [];
  let pendingSpace = false;
  let i = 0;

  // A comment and a run of whitespace both become one separator, and only once something has been
  // emitted — so leading and trailing space fall away, and `a/*x*/b` becomes `a b` rather than `ab`.
  const emit = (chunk: string): void => {
    if (pendingSpace && out.length > 0) out.push(" ");
    pendingSpace = false;
    out.push(chunk);
  };

  while (i < text.length) {
    const ch = text[i]!;

    if (ch === "-" && text[i + 1] === "-") {
      i += 2;
      while (i < text.length && text[i] !== "\n") i += 1;
      pendingSpace = true;
      continue;
    }

    // Postgres block comments nest, unlike C's, so a depth counter rather than an `indexOf`.
    if (ch === "/" && text[i + 1] === "*") {
      let depth = 1;
      i += 2;
      while (i < text.length && depth > 0) {
        if (text[i] === "/" && text[i + 1] === "*") {
          depth += 1;
          i += 2;
        } else if (text[i] === "*" && text[i + 1] === "/") {
          depth -= 1;
          i += 2;
        } else {
          i += 1;
        }
      }
      pendingSpace = true;
      continue;
    }

    if (WHITESPACE.has(ch)) {
      i += 1;
      pendingSpace = true;
      continue;
    }

    const tag = dollarTagAt(text, i);
    if (tag !== undefined) {
      const close = text.indexOf(tag, i + tag.length);
      const stop = close === -1 ? text.length : close + tag.length;
      emit(text.slice(i, stop));
      i = stop;
      continue;
    }

    if (ch === "'" || ch === '"') {
      let j = i + 1;
      while (j < text.length) {
        if (text[j] === ch) {
          // A doubled quote is an escaped one and the literal continues.
          if (text[j + 1] === ch) j += 2;
          else {
            j += 1;
            break;
          }
        } else {
          j += 1;
        }
      }
      emit(text.slice(i, j));
      i = j;
      continue;
    }

    emit(ch);
    i += 1;
  }

  return out.join("");
}

/**
 * The hash recorded beside a migration's id when it is applied, over both halves of the file.
 *
 * **Both halves, not just the one that ran.** The `up` half is what built the schema, so on the
 * narrowest reading the ledger's job is to pin that alone. The `down` half is pinned too because
 * `server/README.md`'s rehearsal — apply on staging, roll back, apply again, then production — is
 * only a rehearsal if production's rollback is the one staging walked. A `down` edited after an
 * `up` was applied means the way out of that migration is untested text, which is exactly the
 * silent divergence this hash exists to end.
 *
 * The two halves are length-prefixed rather than joined by a separator: normalized text may contain
 * any byte inside a string literal, so no separator is safe, and `4:abcd2:ef` cannot be read as any
 * other pair.
 */
export function migrationContentHash(up: string, down: string): string {
  const u = executableSql(up);
  const d = executableSql(down);
  return createHash("sha256").update(`${u.length}:${u}${d.length}:${d}`, "utf8").digest("hex");
}
