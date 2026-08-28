import {
  readJSONBodyOrUnparsed,
  upstreamStatusError,
  upstreamTransportError,
  type SearchRequest,
  type SearchResult,
  type SearchResultItem,
} from "./upstream.js";

/**
 * The web-search adapter (`POST /v1/search`).
 *
 * **The server does not filter or validate result URLs**, and `docs/sonny-backend-api-contract.md`
 * §4.3 says why in one sentence: real URL policy — `SafeURL`, the path whitelist, the risk engine —
 * is deliberately downstream in the capability adapter on the Mac, and moving any of it here would
 * put a safety decision on the far side of a network call, which is the thing this row's
 * architecture exists not to do.
 *
 * What *is* dropped is response garbage, and only in the one shape the client already dropped it
 * in: an entry whose URL does not parse, or parses without an `http`/`https` scheme. That is a
 * malformed payload with no meaningful downstream handling, not a policy call — and the client
 * keeps its own copy of the same filter, so this is defence in depth rather than a move.
 */

export interface TavilySettings {
  readonly keys: readonly string[];
  readonly baseUrl: string;
}

function isWebURL(value: unknown): value is string {
  if (typeof value !== "string" || value.length === 0) return false;
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return false;
  }
  return parsed.protocol === "http:" || parsed.protocol === "https:";
}

export function makeTavilySearchAdapter(
  settings: TavilySettings,
): (request: SearchRequest) => Promise<SearchResult> {
  const key = settings.keys[0];
  if (key === undefined) throw new Error("search adapter constructed with no credential");
  const base = settings.baseUrl.endsWith("/") ? settings.baseUrl.slice(0, -1) : settings.baseUrl;

  return async (request) => {
    let response: Response;
    try {
      response = await fetch(`${base}/search`, {
        method: "POST",
        headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
        body: JSON.stringify({ query: request.query, max_results: request.maxResults }),
        signal: request.signal,
      });
    } catch (error) {
      throw upstreamTransportError(error, "search");
    }

    if (!response.ok) throw upstreamStatusError(response.status, "search");

    const parsed: unknown = await readJSONBodyOrUnparsed(response, "search");
    const results =
      typeof parsed === "object" && parsed !== null
        ? (parsed as { results?: unknown }).results
        : undefined;
    // A body that parsed but carries no `results` array is an empty result list rather than a
    // failure, which is what the client did before this route existed: a search that finds nothing
    // is an ordinary outcome the research step already handles, and turning it into an error would
    // fail a whole task over telemetry-grade malformation.
    //
    // **A body that never finished arriving is no longer collapsed into that** (PR #143, F2). It
    // used to be, because `response.json().catch(() => null)` could not tell an aborted read from a
    // malformed one — so a search whose provider stalled after headers reported "nothing found",
    // which is worse here than on the text routes: a wrong *answer* rather than a wrong error, and
    // a research task that silently proceeds with no sources. `readJSONBodyOrUnparsed` throws that
    // case as the transport failure it is, and keeps the malformed-body decision above intact —
    // the two are told apart by whether `json()` rejected with a `SyntaxError`.
    if (!Array.isArray(results)) return { items: [] };

    const items: SearchResultItem[] = [];
    for (const entry of results) {
      if (typeof entry !== "object" || entry === null) continue;
      const record = entry as Record<string, unknown>;
      const url = record["url"];
      if (!isWebURL(url)) continue;
      const title = record["title"];
      const snippet = record["content"];
      items.push({
        title: typeof title === "string" ? title : "",
        url,
        snippet: typeof snippet === "string" ? snippet : null,
      });
    }
    // `{ items }` rather than the bare array it used to be (SONNY-132): the router adds `served` to
    // whatever an adapter returns, and an intersection of an array type with an object is a shape
    // nobody should have to read. `upstream.ts`'s `SearchResult` carries the reasoning.
    return { items };
  };
}
