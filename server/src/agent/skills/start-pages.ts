/**
 * Where a deep pack's start pages landed for a signed-out visitor, and the loader's reading of those
 * records against the flows (SONNY-510). A port of the Mac's `SkillPackStartPages.swift`, whose doc
 * comments hold the full rule, what it catches and what it cannot.
 *
 * In short: every start URL has exactly one record and every record a flow; a landing carries no
 * query; it lands on the pack's own site or on a listed identity host that signs in for that site;
 * an identity host admits only a sign-in page; and neither URL names account creation.
 */
import { characters, swiftSplit } from "./text.js";
import { componentsHostOf, decodedFragment, decodedPath, decodedQuery, hostOf, type PackURL } from "./url.js";
import type { SkillPackLoadError } from "./pack.js";

/** What a start page offered a visitor who is not signed in: the only two words a record may say. */
export type SkillPackStartPageOffer = "sign-in" | "product";

export interface SkillPackStartPage {
  readonly url: PackURL;
  readonly landedURL: PackURL;
  readonly title: string;
  /** The other titles a page reported on its way to `title`, when it races; empty otherwise. */
  readonly otherTitles: readonly string[];
  readonly heading: string;
  readonly offers: SkillPackStartPageOffer;
  /** `YYYY-MM-DD`, in UTC. */
  readonly read: string;
}

/** The words that name account creation, read as runs of a URL part's words. */
export const ACCOUNT_CREATION_PARTS: ReadonlySet<string> = new Set(["signup", "register", "registration", "createaccount"]);

/** The first day any start page was read under this rule; a record dated earlier is a placeholder. */
export const FIRST_READING_DAY = "2026-09-17";

/**
 * Where a start page may land off its own pack's site: each host a shipped start page was read
 * landing on, with the sites whose packs it signs in for. Kept one pairing at a time, and held equal
 * to the shipped landings by the tests.
 */
export const IDENTITY_HOSTS: ReadonlyMap<string, ReadonlySet<string>> = new Map([
  ["accounts.google.com", new Set(["google.com", "youtube.com"])],
  ["login.microsoftonline.com", new Set(["office.com", "microsoft.com", "microsoft365.com", "azure.com"])],
  ["login.live.com", new Set(["live.com"])],
  ["id.atlassian.com", new Set(["trello.com", "bitbucket.org"])],
  ["app.frontapp.com", new Set(["front.com"])],
  ["app.notion.com", new Set(["notion.so"])],
  ["authenticator.cursor.sh", new Set(["cursor.com"])],
  ["identity.getpostman.com", new Set(["postman.com"])],
  ["accounts.zoho.com", new Set(["zoho.com"])],
  ["carrd.com", new Set(["carrd.co"])],
]);

/** The pack's own site: its domain, or a subdomain of it. `host` is already lowercased. */
export function isOnSite(host: string, domain: string): boolean {
  const siteDomain = domain.toLowerCase();
  return host === siteDomain || host.endsWith(`.${siteDomain}`);
}

/** Whether `text` (already `YYYY-MM-DD`) is a real Gregorian date on or after `FIRST_READING_DAY`. */
export function isAReadingDay(text: string): boolean {
  const parts = text.split("-").map(Number);
  const [year, month, day] = parts;
  if (parts.length !== 3 || year === undefined || month === undefined || day === undefined) return false;
  if (month < 1 || month > 12 || day < 1) return false;
  const leap = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
  const daysInMonth = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1] ?? 0;
  return day <= daysInMonth && text >= FIRST_READING_DAY;
}

function signsIn(host: string, domain: string): boolean {
  const sites = IDENTITY_HOSTS.get(host);
  return sites !== undefined && [...sites].some((site) => isOnSite(domain.toLowerCase(), site));
}

/** The flows' start URLs and titles, which is all this rule reads of a flow. */
interface StartingFlow {
  readonly title: string;
  readonly startURL: PackURL;
}

/** The first thing wrong with a pack's start-page records, or `undefined`. */
export function startPageViolation(
  flows: readonly StartingFlow[],
  startPages: readonly SkillPackStartPage[],
  domain: string,
): SkillPackLoadError | undefined {
  const recorded = new Map<string, number>();
  for (const page of startPages) recorded.set(page.url.text, (recorded.get(page.url.text) ?? 0) + 1);
  for (const page of startPages) {
    if ((recorded.get(page.url.text) ?? 0) > 1) return { kind: "startPageRecordedTwice", url: page.url.text };
  }
  for (const flow of flows) {
    if (!recorded.has(flow.startURL.text)) return { kind: "startPageNotRecorded", flow: flow.title };
  }
  const started = new Set(flows.map((flow) => flow.startURL.text));
  for (const page of startPages) {
    const url = page.url.text;
    if (!started.has(url)) return { kind: "startPageUnused", url };
    // A query inside a single-page app's fragment is as much a session as one in the URL's own query.
    if (page.landedURL.query !== undefined || (page.landedURL.fragment ?? "").includes("?")) {
      return { kind: "landedURLCarriesQuery", url };
    }
    const landedHost = (hostOf(page.landedURL) ?? "").toLowerCase();
    if (!isOnSite(landedHost, domain) && !signsIn(landedHost, domain)) {
      return { kind: "landingHostNotPairedWithSite", url, host: landedHost, site: domain.toLowerCase() };
    }
    // Asked of every landing on a listed host, the pack's own site included: the Google pack's domain
    // is google.com, and accounts.google.com is on it.
    if (IDENTITY_HOSTS.has(landedHost) && page.offers !== "sign-in") {
      return { kind: "identityHostLandingIsNotSignIn", url, host: landedHost };
    }
    for (const named of [page.url, page.landedURL]) {
      if (namesAccountCreation(named)) return { kind: "startPageCreatesAnAccount", url: named.text };
    }
  }
  return undefined;
}

const URL_SEPARATORS = (character: string) => "/#?&=.".includes(character);

/**
 * Whether `url` names account creation: a run of words in a path part, a fragment route part, a
 * query value or a host label left of the last two; or a whole piece of a query key.
 */
export function namesAccountCreation(url: PackURL): boolean {
  const fragment = decodedFragment(url) ?? "";
  const questionMark = fragment.indexOf("?");
  const route = questionMark < 0 ? fragment : fragment.slice(0, questionMark);
  const queries = [decodedQuery(url) ?? "", questionMark < 0 ? "" : fragment.slice(questionMark + 1)];
  const pairs = queries.flatMap((query) =>
    swiftSplit(query, (character) => character === "&").map((pair) => swiftSplit(pair, (character) => character === "=", 1)),
  );
  const keys = pairs.flatMap((pair) => pair.slice(0, 1));
  const values = pairs.flatMap((pair) => pair.slice(1, 2));
  const parts = swiftSplit([decodedPath(url), route, ...values].join("/"), URL_SEPARATORS);
  const hostLabels = swiftSplit(componentsHostOf(url) ?? "", (character) => character === ".").slice(0, -2);
  return (
    [...parts, ...hostLabels].some((part) => accountCreationWords(part).length > 0) ||
    keys.flatMap((key) => swiftSplit(key, URL_SEPARATORS)).some((piece) => ACCOUNT_CREATION_PARTS.has(foldedWhole(piece)))
  );
}

/** One piece of a query key as one word: lowercased, `-` and `_` dropped. */
export function foldedWhole(key: string): string {
  return key.toLowerCase().replaceAll("-", "").replaceAll("_", "");
}

/**
 * The account-creation words one URL part carries, as runs of its words. Words are cut at `-`, at
 * `_` and where a lowercase letter meets an uppercase one, so `sign-up-free` and `SignUpNow` carry
 * `signup`, and `registered-users` carries nothing.
 */
export function accountCreationWords(part: string): string[] {
  const words: string[] = [];
  let word = "";
  let previous: string | undefined;
  for (const character of characters(part)) {
    if (character === "-" || character === "_") {
      words.push(word);
      word = "";
    } else {
      if (previous !== undefined && isLowercase(previous) && isUppercase(character)) {
        words.push(word);
        word = "";
      }
      word += character;
    }
    previous = character;
  }
  words.push(word);
  const folded = words.filter((each) => each !== "").map((each) => each.toLowerCase());
  const found: string[] = [];
  for (let start = 0; start < folded.length; start += 1) {
    let run = "";
    for (const next of folded.slice(start)) {
      run += next;
      if (ACCOUNT_CREATION_PARTS.has(run)) found.push(run);
    }
  }
  return found;
}

function isLowercase(character: string): boolean {
  return /^\p{Lowercase}/u.test(character);
}

function isUppercase(character: string): boolean {
  return /^\p{Uppercase}/u.test(character);
}
