// SONNY-125 host probe. Throwaway measurement code, not the beginning of server/.
//
// One handler, two deployments. Both Supabase Edge Functions (Deno) and Cloudflare Workers
// speak the Web-standard Request/Response, so the arms measure the same code and any
// difference in the numbers is the platform rather than the probe.
//
// Routes, matched on the tail of the path so the same source works under Supabase's
// /functions/v1/<name>/... prefix and under a Worker's bare path:
//
//   POST .../echo        read the whole body, report what arrived. Never echoes the body
//                        back -- that would measure the response limit at the same time and
//                        the two failures would be indistinguishable.
//   GET  .../slow?ms=N   sleep N ms inside the handler, then respond. Measures the
//                        platform's wall-clock ceiling on a request that produces no bytes.
//   GET  .../up?ms=N     fetch UPSTREAM_URL/slow?ms=N and respond once it answers. The
//                        honest arm: a gateway's wait is I/O on a provider, not a sleep.
//   GET  .../drip?ms=N   start the response immediately, then emit one byte per second for
//                        N ms. Answers "can it be made to work" if /slow is cut off.
//   GET  .../health      liveness.

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });

async function inflate(bytes) {
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer()).byteLength;
}

export async function handle(request, upstreamURL) {
  const url = new URL(request.url);
  const route = url.pathname.split("/").filter(Boolean).pop() || "health";
  const ms = Number(url.searchParams.get("ms") || 0);
  const started = Date.now();

  if (route === "health") return json({ ok: true, route: "health" });

  if (route === "slow") {
    await new Promise((r) => setTimeout(r, ms));
    return json({ route: "slow", requested_ms: ms, actual_ms: Date.now() - started });
  }

  if (route === "up") {
    if (!upstreamURL) return json({ error: "UPSTREAM_URL unset" }, 500);
    const target = `${upstreamURL}?ms=${ms}`;
    try {
      const response = await fetch(target);
      const text = await response.text();
      return json({
        route: "up", requested_ms: ms, actual_ms: Date.now() - started,
        upstream_status: response.status, upstream_body: text.slice(0, 200),
      });
    } catch (error) {
      return json({ route: "up", requested_ms: ms, actual_ms: Date.now() - started,
                    upstream_error: String(error) }, 502);
    }
  }

  if (route === "drip") {
    const encoder = new TextEncoder();
    const body = new ReadableStream({
      async start(controller) {
        controller.enqueue(encoder.encode('{"route":"drip","keepalive":"'));
        for (let elapsed = 0; elapsed < ms; elapsed += 1000) {
          await new Promise((r) => setTimeout(r, Math.min(1000, ms - elapsed)));
          controller.enqueue(encoder.encode("."));
        }
        controller.enqueue(encoder.encode(`","actual_ms":${Date.now() - started}}`));
        controller.close();
      },
    });
    return new Response(body, { headers: { "content-type": "application/json" } });
  }

  if (route === "echo") {
    // Read first, measure second. What the handler receives is the only thing that can be
    // reported honestly: whether the platform inflated the body before the handler saw it is
    // exactly the question, so the header and the observed length are both reported and
    // neither is inferred from the other.
    let raw;
    try {
      raw = new Uint8Array(await request.arrayBuffer());
    } catch (error) {
      return json({ route: "echo", read_error: String(error) }, 400);
    }
    const encoding = request.headers.get("content-encoding");
    const looksGzipped = raw.byteLength > 2 && raw[0] === 0x1f && raw[1] === 0x8b;
    let decoded = raw.byteLength, inflateError = null;
    if (looksGzipped) {
      try { decoded = await inflate(raw); } catch (error) { inflateError = String(error); }
    }
    return json({
      route: "echo",
      received_bytes: raw.byteLength,
      decoded_bytes: decoded,
      still_gzipped: looksGzipped,
      header_content_encoding: encoding,
      header_content_length: request.headers.get("content-length"),
      inflate_error: inflateError,
      actual_ms: Date.now() - started,
    });
  }

  return json({ error: "unknown route", route }, 404);
}
