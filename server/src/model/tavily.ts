import {
  providerErrorDetail,
  readJSONBodyOrUnparsed,
  upstreamStatusError,
  upstreamTransportError,
  type SearchRequest,
  type SearchResult,
  type SearchResultItem,
} from "./upstream.js";

/**
 * The web-search adapter, used by the V2 agents' `web_search` tool.
 *
 * **It does not judge result URLs**: the agents' `read_page` tool checks an address before it fetches
 * one (`agent/tools/read-page.ts`). What is dropped here is response garbage only — an entry whose URL
 * does not parse, or parses without an `http`/`https` scheme.
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

    if (!response.ok) {
      // The body travels on the error's `detail`, never in its message: an echoed request here is
      // the user's search query.
      throw upstreamStatusError(response.status, "search", await providerErrorDetail(response));
    }

    const parsed: unknown = await readJSONBodyOrUnparsed(response, "search");
    const results =
      typeof parsed === "object" && parsed !== null
        ? (parsed as { results?: unknown }).results
        : undefined;
    // A body that parsed but carries no `results` array is an empty result list rather than a
    // failure: a search that finds nothing is an ordinary outcome the agent already handles, and
    // turning it into an error would fail a whole task over malformed telemetry. A body that never
    // finished arriving is different — `readJSONBodyOrUnparsed` throws it as the transport failure
    // it is, so a stalled provider is not reported as "nothing found" (PR #143, F2).
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
    return { items };
  };
}
