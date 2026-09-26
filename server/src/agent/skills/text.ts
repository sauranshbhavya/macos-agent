/**
 * How skill-pack text is folded, trimmed and cut into words: the TypeScript port of the Mac's
 * `SearchText`, `SkillWords`, `SkillPhraseList` and `SkillPhraseMatch`.
 *
 * Foundation does the folding on the Mac, so each helper here reproduces what Foundation was
 * measured doing rather than what a JavaScript built-in happens to do. Where the two differ the
 * comment says which Foundation behaviour is being copied.
 */

const ASCII_ONLY = /^[\x00-\x7f]*$/;

/**
 * The diacritics Foundation's `.diacriticInsensitive` folding removes: the combining-mark blocks
 * used by Latin, Greek and Cyrillic, plus the combining marks for symbols. It keeps the marks other
 * scripts need to spell a word (Hebrew points, Arabic harakat, kana voicing marks, Devanagari signs),
 * so stripping every `\p{M}` would fold more than the Mac does.
 */
const FOLDED_DIACRITICS = /[̀-ͯ᪰-᫿᷀-᷿⃐-⃿︠-︯]/gu;

/**
 * `SearchText.normalized`: case and diacritics folded, then lowercased.
 *
 * Foundation applies full Unicode case folding, so "ß" becomes "ss", "ﬁ" becomes "fi" and a final
 * sigma becomes an ordinary one. Lowercasing, uppercasing and lowercasing again one code point at a
 * time gives the same result. Dotless "ı" is the one exception: case folding leaves it alone, and the
 * round trip would turn it into "i".
 */
export function normalized(text: string): string {
  if (ASCII_ONLY.test(text)) return text.toLowerCase();
  const stripped = text.normalize("NFD").replace(FOLDED_DIACRITICS, "");
  let folded = "";
  for (const character of stripped) {
    folded += character === "ı" ? character : character.toLowerCase().toUpperCase().toLowerCase();
  }
  return folded.normalize("NFC");
}

/**
 * Foundation's `.whitespacesAndNewlines`, which is what every pack field is trimmed by. It differs
 * from `String.prototype.trim`: it includes U+0085 and U+200B and leaves U+FEFF alone.
 */
const TRIMMED = "[\\t\\n\\v\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200b\\u2028\\u2029\\u202f\\u205f\\u3000]";
const LEADING = new RegExp(`^${TRIMMED}+`, "u");
const TRAILING = new RegExp(`${TRIMMED}+$`, "u");

export function trimmed(text: string): string {
  return text.replace(LEADING, "").replace(TRAILING, "");
}

const LETTER_OR_NUMBER = /^[\p{Alphabetic}\p{N}]/u;

/** Swift's `Character.isLetter || Character.isNumber`, read off the character's first code point. */
export function isWordCharacter(character: string): boolean {
  return LETTER_OR_NUMBER.test(character);
}

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/**
 * The text as Swift `Character`s (grapheme clusters). ASCII text is split per code unit, which is
 * the same except for "\r\n", and "\r\n" is never a letter or a digit either way.
 */
export function characters(text: string): string[] {
  if (ASCII_ONLY.test(text)) return text.split("");
  return Array.from(graphemes.segment(text), (segment) => segment.segment);
}

/** `SkillWords.cut`: the runs of letters and digits in `text`. */
export function cut(text: string): string[] {
  return cutRecordingGaps(text).words;
}

/**
 * `SkillWords.cutRecordingGaps`: the words, and for each whether only spaces or tabs separate it
 * from the word before it (always `false` for the first).
 */
export function cutRecordingGaps(text: string): { words: string[]; joinedToPrevious: boolean[] } {
  const words: string[] = [];
  const joinedToPrevious: boolean[] = [];
  let current = "";
  let gapIsSpaceOnly = true;
  for (const character of characters(text)) {
    if (isWordCharacter(character)) {
      if (current === "") joinedToPrevious.push(words.length === 0 ? false : gapIsSpaceOnly);
      current += character;
    } else {
      if (current !== "") {
        words.push(current);
        current = "";
        gapIsSpaceOnly = true;
      }
      if (character !== " " && character !== "\t") gapIsSpaceOnly = false;
    }
  }
  if (current !== "") words.push(current);
  return { words, joinedToPrevious };
}

/**
 * `SkillWords.singularCandidates`: the word and every singular it might be (`-ies` → `-y`, `-es`
 * dropped, `-s` dropped but not `-ss`). A wrong candidate can only add a match, never lose one.
 */
export function singularCandidates(word: string): string[] {
  const length = Array.from(word).length;
  const candidates = [word];
  if (word.endsWith("ies") && length > 4) candidates.push(`${word.slice(0, -3)}y`);
  if (word.endsWith("es") && length > 3) candidates.push(word.slice(0, -2));
  if (word.endsWith("s") && !word.endsWith("ss") && length > 2) candidates.push(word.slice(0, -1));
  return candidates;
}

/** `SkillWords`: one piece of pack text as the content rules read it. */
export class SkillWords {
  readonly words: string[];
  readonly joinedToPrevious: boolean[];
  /** The text's own spelling, cut the same way, for the one rule that needs case (`PIN`). */
  readonly casedWords: string[];
  /** The folded text, for the currency-amount pattern, which needs symbols the word cut drops. */
  readonly folded: string;
  readonly singularForms: string[][];
  /** Every word and every singular form, so a phrase whose first word is absent is ruled out at once. */
  private readonly vocabulary: ReadonlySet<string>;

  constructor(text: string) {
    this.folded = normalized(text);
    const gaps = cutRecordingGaps(this.folded);
    this.words = gaps.words;
    this.joinedToPrevious = gaps.joinedToPrevious;
    this.casedWords = cut(text);
    this.singularForms = this.words.map(singularCandidates);
    this.vocabulary = new Set(this.singularForms.flat());
  }

  /** Whether `phrase` appears here as a run of whole words, optionally reading this side's plurals. */
  contains(phrase: readonly string[], readingPlurals = false): boolean {
    if (phrase.length === 0 || phrase.length > this.words.length || !this.vocabulary.has(phrase[0] ?? "")) return false;
    for (let start = 0; start <= this.words.length - phrase.length; start += 1) {
      const matched = phrase.every((word, offset) =>
        readingPlurals ? (this.singularForms[start + offset] ?? []).includes(word) : this.words[start + offset] === word,
      );
      if (matched) return true;
    }
    return false;
  }
}

/** `SkillPhraseList`: phrases cut into words once. `first` answers the first phrase, in list order. */
export class SkillPhraseList {
  private readonly phrases: ReadonlyArray<{ spelling: string; words: string[] }>;

  constructor(spellings: readonly string[]) {
    this.phrases = spellings.map((spelling) => ({ spelling, words: cut(normalized(spelling)) }));
  }

  first(texts: readonly SkillWords[], readingPlurals = false): string | undefined {
    return this.phrases.find((phrase) => texts.some((text) => text.contains(phrase.words, readingPlurals)))?.spelling;
  }
}

/**
 * `SkillPhraseMatch.firstIndex`: where `needle` first occurs in `haystack` as a whole phrase, with
 * no letter or digit immediately before or after it. Both are already folded. The index is a
 * UTF-16 offset; only its order matters.
 */
export function firstWholePhraseIndex(needle: string, haystack: string): number | undefined {
  if (needle === "") return undefined;
  let searchStart = 0;
  for (;;) {
    const index = haystack.indexOf(needle, searchStart);
    if (index < 0) return undefined;
    const end = index + needle.length;
    const before = index === 0 ? undefined : codePointBefore(haystack, index);
    const after = end === haystack.length ? undefined : String.fromCodePoint(haystack.codePointAt(end) ?? 0);
    if ((before === undefined || !isWordCharacter(before)) && (after === undefined || !isWordCharacter(after))) {
      return index;
    }
    searchStart = index + 1;
  }
}

function codePointBefore(text: string, index: number): string {
  const low = text.charCodeAt(index - 1);
  if (low >= 0xdc00 && low <= 0xdfff && index >= 2) {
    const high = text.charCodeAt(index - 2);
    if (high >= 0xd800 && high <= 0xdbff) return text.slice(index - 2, index);
  }
  return text.slice(index - 1, index);
}

/**
 * Swift's `split(separator:maxSplits:)` with its default `omittingEmptySubsequences: true`. An
 * omitted empty piece does not count toward `maxSplits`, which is why "=a=b" split once on "=" is
 * ["a", "b"] and not ["", "a=b"]. The URL rules read query pairs through this.
 */
export function swiftSplit(text: string, isSeparator: (character: string) => boolean, maxSplits = Infinity): string[] {
  const units = characters(text);
  const result: string[] = [];
  if (maxSplits === 0 || units.length === 0) {
    return text === "" ? [] : [text];
  }
  let start = 0;
  let index = 0;
  while (index < units.length) {
    if (isSeparator(units[index] ?? "")) {
      const appended = index > start;
      if (appended) result.push(units.slice(start, index).join(""));
      index += 1;
      start = index;
      if (appended && result.length === maxSplits) break;
      continue;
    }
    index += 1;
  }
  if (start < units.length) result.push(units.slice(start).join(""));
  return result;
}
