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
 * **Every string form Postgres's scanner accepts, enumerated — because the guard is the enumeration
 * and not whichever form somebody happened to name** (SONNY-364 review, F1). The list is §4.1.2 of
 * the Postgres manual, and each entry says what this lexer does with it:
 *
 *   - `'…'` — standard string constant. A doubled `''` is an escaped quote; a backslash is an
 *     ordinary character. Handled by the plain-quote branch.
 *   - `E'…'` / `e'…'` — **escape** string constant. **The doubled-quote handling in this branch is
 *     the only one of the two that is observable**, and that is measured rather than assumed
 *     (cycle 2): a fuzz over 400k inputs found 462 divergences between the two readings of `''`,
 *     100% of them containing an `E'`, while the plain-string twin diverges on **zero** of
 *     12,093,234 exhaustive strings. The reason is provable — both readings consume quotes in pairs
 *     from the same index onto contiguous slices, and every byte is copied verbatim, so the plain
 *     branch's two readings emit identical text. The plain branch's `''` handling is therefore
 *     correct and **unobservable**: it is kept because it is right, and no test can pin it. See
 *     `migration-content-hash.test.ts` for which test holds what.
 *     Backslash escapes are live, so `\'` does NOT end
 *     the literal, and `''` still does. This form had its own branch added after the review: without
 *     it, `\'` ended the string early, everything after it was lexed as code, and a `--` in there was
 *     stripped — so two `INSERT`s storing different rows normalised to the same text. That is exactly
 *     the failure the paragraph above names as the reason this is a lexer and not a regex, arriving
 *     through a form the lexer did not know. The `E` counts only at the start of a token: Postgres's
 *     scanner is flex, longest-match wins, and `some_ident_e'x'` lexes as an identifier followed by
 *     an ordinary string rather than as an escape string.
 *   - `U&'…'` and `U&"…"` — unicode escape string and identifier. **No special handling, and that is
 *     correct rather than an omission**: the backslash in these introduces a *unicode* escape
 *     (`\0441`, `\+000441`), it does not escape a quote, and quotes are still doubled. `UESCAPE 'x'`
 *     changes which character introduces the unicode escape and likewise cannot escape a quote. So
 *     `U&` lexes as ordinary code and the `'` or `"` after it opens a plain literal, which is what
 *     the scanner does too.
 *   - `B'…'` and `X'…'` — bit-string and hex-string constants. The prefix letter lexes as code and
 *     the literal after it needs no branch. **They are not quite "plain quote rules", and the
 *     correction is worth keeping** (cycle 2): a doubled quote does **not** double inside them —
 *     `SELECT B'01''01'` and `SELECT X'1F''F'` are both `syntax error at or near "'01'"` on 17.11,
 *     where the plain `'01''01'` is a five-character string. So this lexer is more permissive there
 *     than Postgres is, reading `''` as a doubled quote where Postgres rejects the statement
 *     outright. That divergence is only reachable on text Postgres will not accept, so it cannot put
 *     two *valid* migrations on one hash; it is recorded rather than fixed because narrowing it
 *     would add a rule whose only effect is on files that can never be applied.
 *   - `$tag$…$tag$` — dollar-quoted. Its own branch; nothing inside is interpreted at all, which is
 *     what keeps a function body's comments in the hash.
 *   - `"…"` — quoted identifier, `""` doubles. Plain-quote branch.
 *   - **Quote continuation** — `'a'` newline `'b'` is **one** constant, not two: Postgres joins two
 *     string constants separated by whitespace containing at least one newline, so that expression
 *     is `ab` with `length` 2, and a comment can carry the newline (`'a' -- c` newline `'b'` is `ab`
 *     as well). All three measured on 17.11. This lexer does not model it: it emits two literals with
 *     the whitespace between them collapsed to a single space, and `SELECT 'a' 'b'` on one line is a
 *     `syntax error at or near "'b'"`. **That is safe for hashing and the reason is worth stating**,
 *     because it is not obvious: the normalised form is never executed, only hashed, and two texts
 *     can differ only in that newline's presence when one of them is invalid SQL — so no two valid
 *     migrations are put on one hash by it. Two valid texts that differ only by a comment carrying
 *     the newline normalise the same and mean the same, which is the intended behaviour anyway.
 *     (The header said these were "two literals to the scanner", which was simply wrong.)
 *
 * **`standard_conforming_strings = on` is a precondition this runner DETECTS, not an assumption it
 * records** (cycle 2). With it off, a backslash escapes inside a plain `'…'` as well, so `\'` would
 * not end the literal where this lexer ends it — F1 returning through the branch the lexer treats as
 * safe, with two `INSERT`s storing different rows collapsing onto one hash. It was a written note
 * until it was pointed out that `DATABASE_URL` alone falsifies it, with no file this repository
 * controls changed: `?options=-c%20standard_conforming_strings%3Doff`. A default since 9.1 that
 * nothing here changes is a likelihood argument, and this design refuses those everywhere else it
 * matters. `applied()` in `migrate.ts` now runs one `SHOW` and refuses the connection outright; see
 * `UnsafeStringLexingError`.
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
const TAG_START = /[A-Za-z_]/;
const TAG_REST = /[A-Za-z0-9_]/;

function dollarTagAt(text: string, at: number): string | undefined {
  if (text[at] !== "$") return undefined;
  let end = at + 1;
  if (end < text.length && TAG_START.test(text[end]!)) {
    end += 1;
    while (end < text.length && TAG_REST.test(text[end]!)) end += 1;
  }
  return text[end] === "$" ? text.slice(at, end + 1) : undefined;
}

/**
 * Whether `ch` can appear inside an unquoted identifier, which is what decides whether an `E` before
 * a quote is an escape-string prefix or just the last letter of a name.
 */
function isIdentifierChar(ch: string | undefined): boolean {
  return ch !== undefined && /[A-Za-z0-9_$]/.test(ch);
}

/**
 * The index just past the closing quote of an escape string that opens at `quoteAt`.
 *
 * Both escapes are live here and they compose the way Postgres composes them: `\\` is a literal
 * backslash and does not escape the quote after it, while `\'` and `''` each keep the literal open.
 * An unterminated literal returns the end of the text, for the reason given on `executableSql`.
 */
function endOfEscapeString(text: string, quoteAt: number): number {
  let j = quoteAt + 1;
  while (j < text.length) {
    if (text[j] === "\\") {
      j += 2;
      continue;
    }
    if (text[j] === "'") {
      if (text[j + 1] === "'") {
        j += 2;
        continue;
      }
      return j + 1;
    }
    j += 1;
  }
  return text.length;
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

    // `E'…'` before the plain-quote branch, because the plain branch would stop at the first `\'`.
    // The identifier check is Postgres's own longest-match behaviour, not caution: `code_e'x'` is an
    // identifier and an ordinary string, and reading its `e` as a prefix would run the literal on
    // past the quote that really closes it.
    if ((ch === "E" || ch === "e") && text[i + 1] === "'" && !isIdentifierChar(text[i - 1])) {
      const j = endOfEscapeString(text, i + 1);
      emit(text.slice(i, j));
      i = j;
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
