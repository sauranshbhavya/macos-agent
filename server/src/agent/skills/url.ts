/**
 * A pack URL read the way the Mac read it, through Foundation's `URLComponents(string:)`.
 *
 * Node's WHATWG `URL` is not a substitute. It adds a trailing slash to a bare origin, lowercases
 * hosts and resolves `..`, and a pack's guidance carries each URL as `absoluteString` and compares
 * start URLs by that exact text. So this parser follows RFC 3986, as Foundation does, and copies
 * the leniency Foundation was measured showing: characters a component does not allow are
 * percent-encoded rather than refused (a space becomes `%20`, a second `#` in a fragment becomes
 * `%23`, a stray `%` becomes `%25`), a non-ASCII host is written in its IDNA form, and the parse
 * fails only on a bad scheme, host or port.
 */
import { domainToASCII } from "node:url";

export interface PackURL {
  /** `URL.absoluteString`: the text with every invalid character percent-encoded. */
  readonly text: string;
  readonly scheme: string | undefined;
  /** Whether a user name or password was written, even an empty one (`https://@host`). */
  readonly hasUserInfo: boolean;
  /** The host as written, after encoding: `undefined` when the URL has no authority. */
  readonly encodedHost: string | undefined;
  /** Percent-encoded, as in `text`. */
  readonly encodedPath: string;
  /** `URL.query`: percent-encoded; `""` for a bare `?`, `undefined` for none. */
  readonly query: string | undefined;
  /** `URL.fragment`: percent-encoded; `""` for a bare `#`, `undefined` for none. */
  readonly fragment: string | undefined;
}

const RFC3986 = /^(?:([^:/?#]+):)?(?:\/\/([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#([\s\S]*))?$/;
const SCHEME = /^[A-Za-z][A-Za-z0-9+.-]*$/;
/** A registered name: unreserved characters, sub-delimiters and percent-encodings, or non-ASCII for IDNA. */
const HOST_CHARACTERS = /^(?:[A-Za-z0-9\-._~!$&'()*+,;=]|%[0-9A-Fa-f]{2}|[^\x00-\x7f])*$/u;
const IP_LITERAL = /^\[[0-9A-Za-z:.%\-_~]*\]$/;
const PORT = /^[0-9]*$/;

/** The characters each component keeps as they are; everything else is percent-encoded. */
const UNRESERVED_AND_SUB_DELIMS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=";
const ALLOWED = {
  userinfo: new Set(`${UNRESERVED_AND_SUB_DELIMS}:`),
  path: new Set(`${UNRESERVED_AND_SUB_DELIMS}:@/`),
  queryOrFragment: new Set(`${UNRESERVED_AND_SUB_DELIMS}:@/?`),
};

/** `URLComponents(string:)` followed by `.url`, or `undefined` where Foundation returns `nil`. */
export function parsePackURL(input: string): PackURL | undefined {
  const match = RFC3986.exec(input);
  if (!match) return undefined;
  const [, scheme, authority, path = "", query, fragment] = match;
  if (scheme !== undefined && !SCHEME.test(scheme)) return undefined;

  let hasUserInfo = false;
  let userinfo: string | undefined;
  let encodedHost: string | undefined;
  let port: string | undefined;
  if (authority !== undefined) {
    let hostAndPort = authority;
    const at = authority.lastIndexOf("@");
    if (at >= 0) {
      hasUserInfo = true;
      userinfo = encode(authority.slice(0, at), ALLOWED.userinfo);
      hostAndPort = authority.slice(at + 1);
    }
    const split = splitHostAndPort(hostAndPort);
    if (!split) return undefined;
    encodedHost = split.host;
    port = split.port;
  }

  const encodedPath = encode(path, ALLOWED.path);
  const encodedQuery = query === undefined ? undefined : encode(query, ALLOWED.queryOrFragment);
  const encodedFragment = fragment === undefined ? undefined : encode(fragment, ALLOWED.queryOrFragment);
  const text =
    (scheme === undefined ? "" : `${scheme}:`) +
    (encodedHost === undefined ? "" : `//${userinfo === undefined ? "" : `${userinfo}@`}${encodedHost}${port === undefined ? "" : `:${port}`}`) +
    encodedPath +
    (encodedQuery === undefined ? "" : `?${encodedQuery}`) +
    (encodedFragment === undefined ? "" : `#${encodedFragment}`);
  return { text, scheme, hasUserInfo, encodedHost, encodedPath, query: encodedQuery, fragment: encodedFragment };
}

function splitHostAndPort(hostAndPort: string): { host: string; port: string | undefined } | undefined {
  let host: string;
  let rest: string;
  if (hostAndPort.startsWith("[")) {
    const close = hostAndPort.indexOf("]");
    if (close < 0) return undefined;
    host = hostAndPort.slice(0, close + 1);
    rest = hostAndPort.slice(close + 1);
    if (!IP_LITERAL.test(host) || (rest !== "" && !rest.startsWith(":"))) return undefined;
  } else {
    const colon = hostAndPort.indexOf(":");
    host = colon < 0 ? hostAndPort : hostAndPort.slice(0, colon);
    rest = colon < 0 ? "" : hostAndPort.slice(colon);
    if (!HOST_CHARACTERS.test(host)) return undefined;
    if (/[^\x00-\x7f]/.test(host)) {
      const ascii = domainToASCII(host);
      if (ascii === "") return undefined;
      host = ascii;
    }
  }
  const port = rest === "" ? undefined : rest.slice(1);
  if (port !== undefined && !PORT.test(port)) return undefined;
  return { host, port };
}

function encode(component: string, allowed: ReadonlySet<string>): string {
  let out = "";
  let index = 0;
  while (index < component.length) {
    const character = component[index] ?? "";
    if (character === "%" && /^[0-9A-Fa-f]{2}$/.test(component.slice(index + 1, index + 3))) {
      out += component.slice(index, index + 3);
      index += 3;
      continue;
    }
    if (allowed.has(character)) {
      out += character;
      index += 1;
      continue;
    }
    const codePoint = component.codePointAt(index) ?? 0;
    const encoded = String.fromCodePoint(codePoint);
    for (const byte of Buffer.from(encoded, "utf8")) {
      out += `%${byte.toString(16).toUpperCase().padStart(2, "0")}`;
    }
    index += encoded.length;
  }
  return out;
}

/**
 * Percent-decoding as Foundation's component getters do it: `undefined` when the bytes are not
 * UTF-8, which is where `URLComponents.query` and `.fragment` answer `nil` and `.path` answers `""`.
 */
export function percentDecoded(text: string): string | undefined {
  if (!text.includes("%")) return text;
  const bytes: number[] = [];
  for (let index = 0; index < text.length; ) {
    if (text[index] === "%" && /^[0-9A-Fa-f]{2}$/.test(text.slice(index + 1, index + 3))) {
      bytes.push(Number.parseInt(text.slice(index + 1, index + 3), 16));
      index += 3;
    } else {
      const codePoint = text.codePointAt(index) ?? 0;
      const character = String.fromCodePoint(codePoint);
      bytes.push(...Buffer.from(character, "utf8"));
      index += character.length;
    }
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(Uint8Array.from(bytes));
  } catch {
    return undefined;
  }
}

/** `URL.host`: decoded, with an IP literal's brackets removed; `undefined` when empty. */
export function hostOf(url: PackURL): string | undefined {
  const host = url.encodedHost;
  if (host === undefined || host === "") return undefined;
  if (host.startsWith("[")) return host.slice(1, -1);
  return percentDecoded(host);
}

/**
 * `URLComponents.host`: decoded, with an IP literal keeping its brackets and an empty host staying
 * `""`. A non-ASCII host comes back in its IDNA form where Foundation answered the Unicode spelling.
 * The callers only ask whether it is empty and whether an ASCII label is an account-creation word,
 * and the two spellings answer both alike.
 */
export function componentsHostOf(url: PackURL): string | undefined {
  const host = url.encodedHost;
  if (host === undefined || host === "" || host.startsWith("[")) return host;
  return percentDecoded(host);
}

/** `URLComponents.path`, decoded. */
export function decodedPath(url: PackURL): string {
  return percentDecoded(url.encodedPath) ?? "";
}

/** `URLComponents.query`, decoded. */
export function decodedQuery(url: PackURL): string | undefined {
  return url.query === undefined ? undefined : percentDecoded(url.query);
}

/** `URLComponents.fragment`, decoded. */
export function decodedFragment(url: PackURL): string | undefined {
  return url.fragment === undefined ? undefined : percentDecoded(url.fragment);
}

/** `URLComponents.queryItems`' names: the query split on `&`, each name before its first `=`, decoded. */
export function queryItemNames(url: PackURL): string[] {
  if (url.query === undefined || url.query === "") return [];
  return url.query.split("&").map((item) => {
    const equals = item.indexOf("=");
    return percentDecoded(equals < 0 ? item : item.slice(0, equals)) ?? "";
  });
}
