import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { describe, expect, it } from "vitest";
import {
  isInternalAddress,
  PageRefused,
  pinnedFetch,
  readableText,
  readPublicPage,
  robotsChecker,
  type PinnedFetcher,
  type RobotsCheck,
} from "../src/agent/tools/read-page.js";
import { parseRobots, patternMatches, robotsAllow } from "../src/agent/tools/robots.js";

const publicResolver = () => Promise.resolve(["93.184.216.34"]);
/** For tests about something other than robots.txt. */
const everywhere: RobotsCheck = () => Promise.resolve(true);

function page(body: string, init: ResponseInit = {}): Response {
  return new Response(body, { status: 200, headers: { "content-type": "text/html; charset=utf-8" }, ...init });
}

describe("reading a public page", () => {
  it("knows which addresses no public page lives on", () => {
    for (const internal of ["127.0.0.1", "10.2.3.4", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "::1", "fd00::1", "fe80::1", "::ffff:10.0.0.1"]) {
      expect(isInternalAddress(internal), internal).toBe(true);
    }
    for (const outside of ["93.184.216.34", "8.8.8.8", "2606:4700::6810:84e5"]) {
      expect(isInternalAddress(outside), outside).toBe(false);
    }
  });

  it("refuses a host that resolves inside, and never fetches it", async () => {
    let fetched = false;
    const fetcher: PinnedFetcher = () => {
      fetched = true;
      return Promise.resolve(page("x"));
    };
    await expect(
      readPublicPage("https://intranet.example/", { signal: new AbortController().signal, resolve: () => Promise.resolve(["10.0.0.5"]), fetcher }),
    ).rejects.toBeInstanceOf(PageRefused);
    await expect(readPublicPage("http://localhost:8080/", { signal: new AbortController().signal, resolve: publicResolver, fetcher })).rejects.toBeInstanceOf(PageRefused);
    await expect(readPublicPage("file:///etc/passwd", { signal: new AbortController().signal, resolve: publicResolver, fetcher })).rejects.toBeInstanceOf(PageRefused);
    await expect(readPublicPage("https://user:pass@example.com/", { signal: new AbortController().signal, resolve: publicResolver, fetcher })).rejects.toBeInstanceOf(PageRefused);
    expect(fetched).toBe(false);
  });

  it("checks every redirect the same way", async () => {
    const fetcher = ((url: URL) =>
      Promise.resolve(
        url.hostname === "example.com"
          ? new Response(null, { status: 302, headers: { location: "http://169.254.169.254/latest/meta-data" } })
          : page("secret"),
      )) as PinnedFetcher;
    await expect(
      readPublicPage("https://example.com/go", { signal: new AbortController().signal, resolve: publicResolver, fetcher, robots: everywhere }),
    ).rejects.toThrow("not a public host");
  });

  it("keeps a page's readable text and title, without scripts or styles", async () => {
    const html = `<html><head><title>Solar &amp; you</title><style>p{}</style></head><body><script>steal()</script><p>Pays back in <b>8</b> years.</p><p>Tip&#x21;</p></body></html>`;
    const fetcher = (() => Promise.resolve(page(html))) as PinnedFetcher;
    const read = await readPublicPage("https://example.com/solar", { signal: new AbortController().signal, resolve: publicResolver, fetcher });
    expect(read.title).toBe("Solar & you");
    expect(read.text).toContain("Pays back in 8 years.");
    expect(read.text).toContain("Tip!");
    expect(read.text).not.toContain("steal");
    expect(readableText("<p>a</p><p>b</p>").text).toBe("a\n b");
  });

  it("refuses what isn't a text page", async () => {
    const fetcher = (() => Promise.resolve(new Response("PDF", { headers: { "content-type": "application/pdf" } }))) as PinnedFetcher;
    await expect(readPublicPage("https://example.com/a.pdf", { signal: new AbortController().signal, resolve: publicResolver, fetcher })).rejects.toThrow("not a text page");
  });

  it("connects to the address it checked, so a second lookup can't point it inside", async () => {
    const answers = [["93.184.216.34"], ["10.0.0.5"]];
    let lookups = 0;
    const dialled: (readonly string[])[] = [];
    const fetcher: PinnedFetcher = (_url, addresses) => {
      dialled.push(addresses);
      return Promise.resolve(page("<p>public</p>"));
    };
    const read = await readPublicPage("https://rebind.example/", {
      signal: new AbortController().signal,
      resolve: () => Promise.resolve(answers[lookups++]!),
      fetcher,
      robots: everywhere,
    });
    expect(read.text).toBe("public");
    expect(lookups).toBe(1);
    expect(dialled).toEqual([["93.184.216.34"]]);
  });

  it("dials only the pinned address, whatever the host name would resolve to", async () => {
    const server = createServer((_request, response) => {
      response.writeHead(200, { "content-type": "text/plain" });
      response.end("pinned");
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    try {
      const { port } = server.address() as AddressInfo;
      // .invalid never resolves, so reaching the server proves no lookup of the name took place.
      const response = await pinnedFetch(new URL(`http://sonny-pinned.invalid:${port}/`), ["127.0.0.1"], {
        signal: new AbortController().signal,
        headers: {},
      });
      expect(response.status).toBe(200);
      expect(await response.text()).toBe("pinned");
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }
  });
});

describe("robots.txt", () => {
  const allows = (text: string, path: string) => robotsAllow(parseRobots(text), new URL(`https://example.com${path}`));

  it("obeys a group that names Sonny instead of the * group, not as well as it (RFC 9309 §2.2.1, SONNY-468)", () => {
    const text = "User-agent: *\nAllow: /private/public\n\nUser-agent: Sonny\nDisallow: /private\n";
    expect(allows(text, "/private/public/x")).toBe(false);
    expect(allows(text, "/elsewhere")).toBe(true);
    // With no group naming Sonny, the * group applies.
    expect(allows("User-agent: *\nDisallow: /private\n", "/private/x")).toBe(false);
    // A group naming Sonny with no rules allows everything the * group forbade.
    expect(allows("User-agent: *\nDisallow: /\n\nUser-agent: SonnyResearch\nDisallow:\n", "/anything")).toBe(true);
  });

  it("takes the longest matching rule, and Allow on a tie", () => {
    const text = "User-agent: *\nDisallow: /docs\nAllow: /docs/public\nDisallow: /same\nAllow: /same\n";
    expect(allows(text, "/docs/secret")).toBe(false);
    expect(allows(text, "/docs/public/a")).toBe(true);
    expect(allows(text, "/same")).toBe(true);
  });

  it("reads * and a closing $ as wildcards", () => {
    const text = "User-agent: *\nDisallow: /*.pdf$\nDisallow: /search*q=\n";
    expect(allows(text, "/files/report.pdf")).toBe(false);
    expect(allows(text, "/files/report.pdf.html")).toBe(true);
    expect(allows(text, "/search?lang=en&q=solar")).toBe(false);
  });

  it("shares a group between consecutive user-agent lines, and starts a new one after a rule", () => {
    const text = "User-agent: OtherBot\nUser-agent: Sonny\nDisallow: /a\nUser-agent: OtherBot\nDisallow: /b\n";
    expect(allows(text, "/a")).toBe(false);
    expect(allows(text, "/b")).toBe(true);
  });

  it("matches a hostile pattern in bounded time", () => {
    const started = Date.now();
    expect(patternMatches(`/${"*a".repeat(1000)}$`, `/${"a".repeat(1999)}b`)).toBe(false);
    expect(Date.now() - started).toBeLessThan(1000);
  });

  it("answers disallowed, quickly, when a hostile file and a long address would take too long", () => {
    const hostile = `User-agent: *\n${Array.from({ length: 2_000 }, () => `Allow: /${"*a".repeat(900)}$`).join("\n")}\n`;
    const started = Date.now();
    expect(robotsAllow(parseRobots(hostile), new URL(`https://example.com/${"a".repeat(8_000)}b`))).toBe(false);
    expect(Date.now() - started).toBeLessThan(2_000);
  });

  /** A site whose robots.txt is a fresh answer from `robots` each time it is asked. */
  function site(robots: () => Response | Error, pages: string[] = []): PinnedFetcher {
    return (url) => {
      if (url.pathname === "/robots.txt") {
        const answer = robots();
        return answer instanceof Error ? Promise.reject(answer) : Promise.resolve(answer);
      }
      pages.push(url.pathname);
      return Promise.resolve(page("<p>the page</p>"));
    };
  }
  const read = (path: string, fetcher: PinnedFetcher, robots?: RobotsCheck) =>
    readPublicPage(`https://example.com${path}`, {
      signal: new AbortController().signal,
      resolve: publicResolver,
      fetcher,
      ...(robots === undefined ? {} : { robots }),
    });

  it("refuses a page the site disallows, before fetching it, and reads one it allows", async () => {
    const pages: string[] = [];
    const fetcher = site(() => new Response("User-agent: *\nDisallow: /private\n"), pages);
    await expect(read("/private/notes", fetcher)).rejects.toThrow("robots.txt");
    expect(pages).toEqual([]);
    expect((await read("/public", fetcher)).text).toBe("the page");
    expect(pages).toEqual(["/public"]);
  });

  it("reads nothing when robots.txt redirects more than five times", async () => {
    let hops = 0;
    const fetcher: PinnedFetcher = (url) => {
      if (url.pathname.startsWith("/robots")) {
        hops += 1;
        return Promise.resolve(new Response(null, { status: 301, headers: { location: `/robots-${hops}.txt` } }));
      }
      return Promise.resolve(page("<p>the page</p>"));
    };
    await expect(read("/x", fetcher)).rejects.toThrow("robots.txt");
  });

  it("reads everything when there is no robots.txt, and nothing when it can't be reached", async () => {
    expect((await read("/x", site(() => new Response("gone", { status: 404 })))).text).toBe("the page");
    await expect(read("/x", site(() => new Response("busy", { status: 503 })))).rejects.toThrow("robots.txt");
    await expect(read("/x", site(() => new Error("connection reset")))).rejects.toThrow("robots.txt");
  });

  it("checks robots.txt again for a redirect's target", async () => {
    const fetcher: PinnedFetcher = (url) => {
      if (url.hostname === "example.com" && url.pathname === "/robots.txt") return Promise.resolve(new Response("", { status: 404 }));
      if (url.hostname === "other.example" && url.pathname === "/robots.txt") return Promise.resolve(new Response("User-agent: *\nDisallow: /\n"));
      if (url.hostname === "example.com") return Promise.resolve(new Response(null, { status: 302, headers: { location: "https://other.example/page" } }));
      return Promise.resolve(page("<p>should not be read</p>"));
    };
    await expect(read("/go", fetcher)).rejects.toThrow("robots.txt");
  });

  it("asks each site once an hour, and a site it couldn't reach again after five minutes", async () => {
    let clock = 0;
    let asked = 0;
    let answer = () => new Response("busy", { status: 503 });
    const fetcher: PinnedFetcher = (url) => {
      if (url.pathname === "/robots.txt") {
        asked += 1;
        return Promise.resolve(answer());
      }
      return Promise.resolve(page("<p>the page</p>"));
    };
    const robots = robotsChecker({ resolve: publicResolver, fetcher, now: () => clock });
    await expect(read("/a", fetcher, robots)).rejects.toThrow("robots.txt");
    answer = () => new Response("User-agent: *\nAllow: /\n");
    clock += 60_000;
    await expect(read("/a", fetcher, robots)).rejects.toThrow("robots.txt");
    expect(asked).toBe(1);
    clock += 5 * 60_000;
    expect((await read("/a", fetcher, robots)).text).toBe("the page");
    expect((await read("/b", fetcher, robots)).text).toBe("the page");
    expect(asked).toBe(2);
    clock += 60 * 60_000;
    await read("/c", fetcher, robots);
    expect(asked).toBe(3);
  });
});
