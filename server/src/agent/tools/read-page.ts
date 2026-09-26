/**
 * Reads one public web page for the planner, on the gateway (V2 plan section 5, "Server tools").
 *
 * Public means public: an address that resolves to a private, loopback, link-local or otherwise
 * internal network is refused before anything is fetched, and every redirect is checked the same
 * way. The connection is made to the addresses that were checked, never to a second lookup, so a
 * host can't pass the check and then point somewhere internal. The body is capped, and only its
 * readable text is kept.
 *
 * A page the site's robots.txt asks automated tools not to read is refused before it is fetched,
 * and so is every redirect's target (`robots.ts`).
 */
import { lookup } from "node:dns/promises";
import { request as httpRequest, type IncomingMessage } from "node:http";
import { request as httpsRequest } from "node:https";
import { isIP, type LookupFunction } from "node:net";
import { Readable } from "node:stream";
import { ALLOW_ALL, DISALLOW_ALL, parseRobots, robotsAllow, type RobotsRules } from "./robots.js";

export const PAGE_BYTE_LIMIT = 2_000_000;
export const PAGE_TEXT_LIMIT = 30_000;
const MAX_REDIRECTS = 4;
const PAGE_DEADLINE_MS = 15_000;
const USER_AGENT = "SonnyResearch/2";
/** RFC 9309 §2.5: at least 500 KiB of a robots.txt is read. */
const ROBOTS_BYTE_LIMIT = 512_000;
/** RFC 9309 §2.4 allows caching up to a day; an hour keeps a changed file from being missed for long. */
const ROBOTS_TTL_MS = 60 * 60 * 1000;
/** A site that couldn't be asked is treated as disallowing everything, but only briefly. */
const ROBOTS_ERROR_TTL_MS = 5 * 60 * 1000;
const ROBOTS_CACHE_SIZE = 1_000;
const ROBOTS_MAX_REDIRECTS = 5;

export interface ReadPage {
  readonly url: string;
  readonly title: string | null;
  readonly text: string;
  readonly truncated: boolean;
}

export class PageRefused extends Error {
  constructor(readonly url: string, reason: string) {
    super(reason);
    this.name = "PageRefused";
  }
}

export type AddressResolver = (host: string) => Promise<readonly string[]>;

const systemResolver: AddressResolver = async (host) =>
  (await lookup(host, { all: true, verbatim: true })).map((entry) => entry.address);

/** True for any address a public web page cannot live on. */
export function isInternalAddress(address: string): boolean {
  const version = isIP(address);
  if (version === 4) {
    const [a, b] = address.split(".").map(Number) as [number, number];
    return (
      a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224
    );
  }
  if (version === 6) {
    const lower = address.toLowerCase();
    if (lower === "::" || lower === "::1") return true;
    if (lower.startsWith("::ffff:")) return isInternalAddress(lower.slice(7));
    return /^(fc|fd|fe8|fe9|fea|feb|ff)/.test(lower);
  }
  return true;
}

interface CheckedURL {
  readonly url: URL;
  /** The public addresses the host resolved to when it was checked; the only ones dialled. */
  readonly addresses: readonly string[];
}

/** Fetches one URL, connecting only to `addresses`. Redirects are returned, not followed. */
export type PinnedFetcher = (url: URL, addresses: readonly string[], init: { signal: AbortSignal; headers: Record<string, string> }) => Promise<Response>;

/** A DNS lookup that answers every question with the addresses already checked. */
export function pinnedLookup(addresses: readonly string[]): LookupFunction {
  const entries = addresses.map((address) => ({ address, family: isIP(address) }));
  return (_hostname, options, callback) => {
    if (options.all) {
      (callback as (error: null, addresses: typeof entries) => void)(null, entries);
    } else {
      callback(null, entries[0]!.address, entries[0]!.family);
    }
  };
}

const NULL_BODY_STATUSES = new Set([204, 205, 304]);

/** The default fetcher: Node's own HTTP client with the lookup pinned, so TLS still checks the host's name. */
export const pinnedFetch: PinnedFetcher = (url, addresses, init) =>
  new Promise((resolve, reject) => {
    const send = url.protocol === "https:" ? httpsRequest : httpRequest;
    const outgoing = send(url, { method: "GET", headers: init.headers, lookup: pinnedLookup(addresses), signal: init.signal }, (incoming: IncomingMessage) => {
      const headers = new Headers();
      for (const [name, value] of Object.entries(incoming.headers)) {
        if (value === undefined) continue;
        for (const item of Array.isArray(value) ? value : [value]) headers.append(name, item);
      }
      const status = incoming.statusCode ?? 502;
      const body = NULL_BODY_STATUSES.has(status) ? null : (Readable.toWeb(incoming) as ReadableStream<Uint8Array>);
      if (body === null) incoming.resume();
      resolve(new Response(body, { status: status < 200 || status > 599 ? 502 : status, headers }));
    });
    outgoing.on("error", reject);
    outgoing.end();
  });

async function checkURL(raw: string, resolve: AddressResolver): Promise<CheckedURL> {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new PageRefused(raw, "that is not a web address");
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") throw new PageRefused(raw, "only http and https pages");
  if (url.username || url.password) throw new PageRefused(raw, "an address with a login in it");
  const host = url.hostname.replace(/^\[|\]$/g, "");
  if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal")) {
    throw new PageRefused(raw, "not a public host");
  }
  const addresses = isIP(host) ? [host] : await resolve(host).catch(() => []);
  if (addresses.length === 0) throw new PageRefused(raw, "the host doesn't resolve");
  if (addresses.some(isInternalAddress)) throw new PageRefused(raw, "not a public host");
  return { url, addresses };
}

const ENTITIES: Readonly<Record<string, string>> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

/** The readable text of an HTML document: no scripts, styles or tags, entities decoded. */
function decodeEntities(text: string): string {
  return text.replace(/&(#x?[0-9a-f]+|\w+);/gi, (whole, entity: string) => {
    if (entity.startsWith("#x") || entity.startsWith("#X")) return String.fromCodePoint(parseInt(entity.slice(2), 16) || 32);
    if (entity.startsWith("#")) return String.fromCodePoint(Number(entity.slice(1)) || 32);
    return ENTITIES[entity.toLowerCase()] ?? whole;
  });
}

export function readableText(html: string): { title: string | null; text: string } {
  const rawTitle = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html)?.[1]?.trim();
  const title = rawTitle ? decodeEntities(rawTitle) : null;
  const stripped = html
    .replace(/<(script|style|noscript|template|svg)[\s\S]*?<\/\1>/gi, " ")
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/<\/(p|div|li|h[1-6]|tr|br|section|article)>/gi, "\n")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<[^>]+>/g, " ");
  const text = decodeEntities(stripped)
    .replace(/[ \t\f\v]+/g, " ")
    .replace(/\n\s*\n+/g, "\n\n")
    .trim();
  return { title, text };
}

/** Whether the site's robots.txt lets Sonny read `url`, whose host resolved to `addresses`. */
export type RobotsCheck = (url: URL, addresses: readonly string[], signal: AbortSignal) => Promise<boolean>;

/**
 * A robots.txt check with its own cache, one entry per origin. Its robots.txt is fetched the way a
 * page is: from the addresses already checked, and every redirect checked again.
 */
export function robotsChecker(options: { resolve?: AddressResolver; fetcher?: PinnedFetcher; now?: () => number } = {}): RobotsCheck {
  const resolve = options.resolve ?? systemResolver;
  const fetcher = options.fetcher ?? pinnedFetch;
  const now = options.now ?? Date.now;
  const cache = new Map<string, { rules: RobotsRules; until: number }>();
  return async (url, addresses, signal) => {
    let entry = cache.get(url.origin);
    if (entry === undefined || entry.until <= now()) {
      const { rules, reachable } = await fetchRobots(url, addresses, signal, resolve, fetcher);
      entry = { rules, until: now() + (reachable ? ROBOTS_TTL_MS : ROBOTS_ERROR_TTL_MS) };
      cache.delete(url.origin);
      cache.set(url.origin, entry);
      if (cache.size > ROBOTS_CACHE_SIZE) cache.delete(cache.keys().next().value!);
    }
    return robotsAllow(entry.rules, url);
  };
}

/**
 * RFC 9309 §2.3.1: a robots.txt that isn't there (4xx) allows everything, and one that can't be
 * reached (5xx, a network error, a redirect to somewhere no page may live, more than five
 * redirects) disallows everything.
 */
async function fetchRobots(
  page: URL,
  addresses: readonly string[],
  signal: AbortSignal,
  resolve: AddressResolver,
  fetcher: PinnedFetcher,
): Promise<{ rules: RobotsRules; reachable: boolean }> {
  let checked: CheckedURL = { url: new URL("/robots.txt", page.origin), addresses };
  for (let hop = 0; hop <= ROBOTS_MAX_REDIRECTS; hop += 1) {
    let response: Response;
    try {
      response = await fetcher(checked.url, checked.addresses, {
        signal,
        headers: { accept: "text/plain", "user-agent": USER_AGENT },
      });
    } catch (error) {
      if (signal.aborted) throw error;
      return { rules: DISALLOW_ALL, reachable: false };
    }
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      await response.body?.cancel().catch(() => {});
      if (!location) return { rules: DISALLOW_ALL, reachable: false };
      try {
        checked = await checkURL(new URL(location, checked.url).href, resolve);
      } catch {
        return { rules: DISALLOW_ALL, reachable: false };
      }
      continue;
    }
    if (response.status >= 400 && response.status < 500) {
      await response.body?.cancel().catch(() => {});
      return { rules: ALLOW_ALL, reachable: true };
    }
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      return { rules: DISALLOW_ALL, reachable: false };
    }
    return { rules: parseRobots(await readCapped(response, ROBOTS_BYTE_LIMIT)), reachable: true };
  }
  // §2.3.1.2 lets a crawler treat this as a missing file. Sonny treats it as one it couldn't reach:
  // the product rule is not to read what a site may have asked it not to.
  return { rules: DISALLOW_ALL, reachable: false };
}

const sharedRobots = robotsChecker();

export async function readPublicPage(
  raw: string,
  options: { signal: AbortSignal; resolve?: AddressResolver; fetcher?: PinnedFetcher; robots?: RobotsCheck } = {
    signal: new AbortController().signal,
  },
): Promise<ReadPage> {
  const resolve = options.resolve ?? systemResolver;
  const fetcher = options.fetcher ?? pinnedFetch;
  // A caller with its own network gets a robots check over that same network.
  const robots =
    options.robots ??
    (options.resolve === undefined && options.fetcher === undefined ? sharedRobots : robotsChecker({ resolve, fetcher }));
  const deadline = AbortSignal.any([options.signal, AbortSignal.timeout(PAGE_DEADLINE_MS)]);
  let checked = await checkURL(raw, resolve);
  for (let hop = 0; ; hop += 1) {
    const { url } = checked;
    if (!(await robots(url, checked.addresses, deadline))) {
      throw new PageRefused(url.href, "the site asks automated tools not to read this page (robots.txt)");
    }
    const response = await fetcher(url, checked.addresses, {
      signal: deadline,
      headers: { accept: "text/html,text/plain;q=0.9,*/*;q=0.1", "user-agent": USER_AGENT },
    });
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      await response.body?.cancel().catch(() => {});
      if (!location || hop >= MAX_REDIRECTS) throw new PageRefused(url.href, "too many redirects");
      checked = await checkURL(new URL(location, url).href, resolve);
      continue;
    }
    if (!response.ok) throw new PageRefused(url.href, `the page answered ${response.status}`);
    const type = response.headers.get("content-type") ?? "";
    if (!/text\/html|text\/plain|application\/xhtml/i.test(type)) throw new PageRefused(url.href, "not a text page");
    const declared = Number(response.headers.get("content-length"));
    if (Number.isFinite(declared) && declared > PAGE_BYTE_LIMIT) throw new PageRefused(url.href, "the page is too large");
    const body = await readCapped(response, PAGE_BYTE_LIMIT);
    const { title, text } = /text\/plain/i.test(type) ? { title: null, text: body.trim() } : readableText(body);
    return {
      url: url.href,
      title,
      text: text.slice(0, PAGE_TEXT_LIMIT),
      truncated: text.length > PAGE_TEXT_LIMIT,
    };
  }
}

async function readCapped(response: Response, limit: number): Promise<string> {
  if (response.body === null) return "";
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > limit) break;
      chunks.push(value);
    }
  } finally {
    await reader.cancel().catch(() => {});
  }
  return Buffer.concat(chunks).toString("utf8");
}
