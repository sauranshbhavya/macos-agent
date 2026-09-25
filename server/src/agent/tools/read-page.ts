/**
 * Reads one public web page for the planner, on the gateway (V2 plan section 5, "Server tools").
 *
 * Public means public: an address that resolves to a private, loopback, link-local or otherwise
 * internal network is refused before anything is fetched, and every redirect is checked the same
 * way. The body is capped, and only its readable text is kept.
 */
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";

export const PAGE_BYTE_LIMIT = 2_000_000;
export const PAGE_TEXT_LIMIT = 30_000;
const MAX_REDIRECTS = 4;
const PAGE_DEADLINE_MS = 15_000;

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

async function checkURL(raw: string, resolve: AddressResolver): Promise<URL> {
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
  return url;
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

export async function readPublicPage(
  raw: string,
  options: { signal: AbortSignal; resolve?: AddressResolver; fetcher?: typeof fetch } = { signal: new AbortController().signal },
): Promise<ReadPage> {
  const resolve = options.resolve ?? systemResolver;
  const fetcher = options.fetcher ?? fetch;
  const deadline = AbortSignal.any([options.signal, AbortSignal.timeout(PAGE_DEADLINE_MS)]);
  let url = await checkURL(raw, resolve);
  for (let hop = 0; ; hop += 1) {
    const response = await fetcher(url, {
      redirect: "manual",
      signal: deadline,
      headers: { accept: "text/html,text/plain;q=0.9,*/*;q=0.1", "user-agent": "SonnyResearch/2" },
    });
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location || hop >= MAX_REDIRECTS) throw new PageRefused(url.href, "too many redirects");
      url = await checkURL(new URL(location, url).href, resolve);
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
