/**
 * Every pack in `server/skill-packs/`, read once at boot (V2 plan section 5).
 *
 * **A refused pack is absent, never half-loaded.** Each file is read on its own, so one malformed
 * pack costs that site its skill and nothing else; the failures are kept so a test or a boot log can
 * name them rather than a missing site going unexplained.
 */
import { readdirSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";
import { fileURLToPath } from "node:url";
import { decodeSkillPack, SKILL_PACK_FILE_SUFFIX } from "./pack.js";
import type { SkillPack, SkillPackLoadError } from "./pack.js";

/**
 * The shipped packs. Resolved from this module, so the same relative step works from `src/` under
 * the tests and from `dist/` in the image: both sit two levels below the server root.
 */
export const SKILL_PACKS_DIRECTORY = fileURLToPath(new URL("../../../skill-packs/", import.meta.url));

export interface SkillPackLoadFailure {
  readonly fileName: string;
  readonly error: SkillPackLoadError;
}

export interface SkillPackCatalog {
  /** In name order, then id. */
  readonly packs: readonly SkillPack[];
  readonly failures: readonly SkillPackLoadFailure[];
}

/** Every file under `directory`, at any depth, whose name ends in `.skillpack.json`, in file-name order. */
export function skillPackFilePaths(directory: string): string[] {
  return readdirSync(directory, { recursive: true, encoding: "utf8" })
    .filter((relative) => basename(relative).endsWith(SKILL_PACK_FILE_SUFFIX))
    .map((relative) => join(directory, relative))
    .sort((a, b) => compareText(basename(a), basename(b)) || compareText(a, b));
}

/**
 * Loads every pack file under `directory`. Throws when the directory cannot be read: a gateway that
 * booted with no packs because the image left the folder out would otherwise plan every task without
 * them and nothing would say so.
 */
export function loadSkillPackCatalog(directory: string = SKILL_PACKS_DIRECTORY): SkillPackCatalog {
  return loadSkillPackFiles(
    skillPackFilePaths(directory).map((path) => ({ fileName: basename(path), data: readOrEmpty(path) })),
  );
}

function readOrEmpty(path: string): Uint8Array {
  try {
    return readFileSync(path);
  } catch {
    return new Uint8Array();
  }
}

/**
 * Decodes and validates each file, then refuses **every** file sharing an id with another: nothing
 * says which of two packs claiming one site is the right one, and keeping whichever sorted first
 * would make that an accident of file naming.
 */
export function loadSkillPackFiles(files: ReadonlyArray<{ fileName: string; data: Uint8Array | string }>): SkillPackCatalog {
  const decoded: Array<{ fileName: string; pack: SkillPack }> = [];
  const failures: SkillPackLoadFailure[] = [];
  for (const file of files) {
    const result = decodeSkillPack(file.data);
    if (result.ok) decoded.push({ fileName: file.fileName, pack: result.pack });
    else failures.push({ fileName: file.fileName, error: result.error });
  }

  const idCounts = new Map<string, number>();
  for (const entry of decoded) idCounts.set(entry.pack.id, (idCounts.get(entry.pack.id) ?? 0) + 1);
  const packs: SkillPack[] = [];
  for (const entry of decoded) {
    if ((idCounts.get(entry.pack.id) ?? 0) > 1) {
      failures.push({ fileName: entry.fileName, error: { kind: "duplicateID", id: entry.pack.id } });
    } else {
      packs.push(entry.pack);
    }
  }
  packs.sort((a, b) => nameOrder.compare(a.name, b.name) || compareText(a.id, b.id));
  return { packs, failures };
}

/**
 * The Mac sorted by `localizedCaseInsensitiveCompare`: a locale-aware comparison that ignores case
 * and not accents, which is a collator at accent sensitivity.
 */
const nameOrder = new Intl.Collator("en", { sensitivity: "accent" });

function compareText(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
