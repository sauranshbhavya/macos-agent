import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { describe, expect, it } from "vitest";
import { isInternalAddress, PageRefused, pinnedFetch, readableText, readPublicPage, type PinnedFetcher } from "../src/agent/tools/read-page.js";

const publicResolver = () => Promise.resolve(["93.184.216.34"]);

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
    await expect(readPublicPage("https://example.com/go", { signal: new AbortController().signal, resolve: publicResolver, fetcher })).rejects.toThrow("not a public host");
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
