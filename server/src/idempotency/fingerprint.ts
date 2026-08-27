import { createHash } from "node:crypto";
import type { FastifyRequest } from "fastify";

/**
 * What "the same body" means for contract §9.2's third guarantee (SONNY-300).
 *
 * §9.2 makes a repeat of one key with a *different* body a `409 idempotency.conflict`, so something
 * has to decide sameness — before the handler runs, and therefore before any upstream call.
 *
 * ## Why this hashes the parsed body and not the raw bytes
 *
 * The obvious design is a digest of the request's raw bytes, taken by teeing the body stream in a
 * `preParsing` hook: one hook, every content type, nothing per-route. **It was built that way first
 * and it deadlocks**, and the measurement is worth keeping because the failure is silent and arrives
 * only at size.
 *
 * A `Transform` at Node's default 16 KB high-water mark, piped between the request stream and
 * `@fastify/multipart`, serves a 4-byte and a 60,000-byte audio part and then **hangs** on a
 * 2,000,000-byte one — no error, no response, the request simply never completes. The cause is the
 * order the two ends run in: `@fastify/multipart` hands the handler an iterator and does not read a
 * byte until the handler's `for await` begins, which is *after* `preHandler`, while the tee fills its
 * 16 KB buffer long before then and stops. Raising the high-water mark past the body size clears it,
 * which is only another way of saying the whole audio body is buffered in memory — the thing
 * `limits.fileSize` exists to avoid. Measured at fastify 5.6.1 / `@fastify/multipart` 9.2.1:
 * `Transform` at the default mark → timeout at 2 MB; the same at an 8 MiB mark → 200; the same body
 * with no tee at all → 200 in 13 ms. It surfaced as `model.test.ts`'s
 * `lets /v1/transcriptions carry ten times what /v1/search may` timing out.
 *
 * So nothing here touches the request stream. The digest is taken at `preHandler` from
 * `request.body` — what Fastify's own parser produced — which is available for every content type
 * this server parses and costs no interference with the one it streams.
 *
 * **Canonical rather than `JSON.stringify`**: object keys are sorted at every level, so two bodies
 * that differ only in key order hash the same. That is the right answer for JSON (they are the same
 * document) and it also removes the dependence on a serializer's insertion order, which would
 * otherwise make a dependency bump turn live keys into conflicts.
 *
 * ## Where it is weaker, stated plainly
 *
 * **There is one such place, and this section named it as the only one while a second existed** (PR
 * #142's review, F2). The other was a collision *across content types*, closed by hashing each body
 * kind under its own prefix — `digestOfBody` carries what it cost. What follows is the one that
 * remains, and it is remaining by choice rather than by oversight.
 *
 * `/v1/transcriptions` is `multipart/form-data` (§4.4) and its body is consumed inside the handler,
 * so `request.body` is `undefined` at `preHandler` and `LENGTH_PREFIX` below stands in: the declared
 * body length, and nothing about its content. **The consequence:** on that route alone, two
 * genuinely different recordings of exactly the same encoded byte length sent under one key are read
 * as the same body, and the first response is replayed instead of a 409 being raised. That needs a
 * client bug (§9.1 mints one key per logical operation) *and* a byte-length collision, and it fails
 * in the safe direction — a replay never bills twice and never calls a provider twice.
 *
 * A body sent with no `Content-Length` at all (chunked) falls back further, to the route alone.
 * `SonnyBackendClient` sends an in-memory `Data` body, so `URLSession` always sets the header; a
 * client that does not gets conflict detection no finer than "same route".
 */

/** Marks a fingerprint taken from the parsed body. */
const BODY_PREFIX = "sha256:";
/** Marks the multipart fallback: the declared body length, and nothing about its content. */
const LENGTH_PREFIX = "len:";
/** Marks a body whose length was not declared either. */
const UNKNOWN_BODY = "unknown-body";

/**
 * A stable string for any JSON value: object keys sorted at every level, array order preserved
 * because an array's order is part of its meaning.
 *
 * Written out rather than reached for from a dependency because it is eight lines and it is the
 * definition of "the same body" — a thing worth reading in the file that decides it.
 */
function canonicalize(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value) ?? "null";
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(",")}]`;
  const entries = Object.entries(value as Record<string, unknown>).sort(([a], [b]) =>
    a < b ? -1 : a > b ? 1 : 0,
  );
  return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalize(v)}`).join(",")}}`;
}

/**
 * **Each body kind is hashed under its own prefix, and the prefix is the whole point.**
 *
 * Without it a parsed object is hashed canonically while a string is hashed raw, so a `text/plain`
 * body whose bytes happen to *equal* the canonical serialization digests identically to the JSON
 * document — two genuinely different requests, one fingerprint. PR #142's review measured the
 * consequence end to end: the canonical bytes sent as `text/plain` were answered `400
 * request.invalid` and stored (a non-retryable code, so the row stays `completed`), and the client's
 * real `application/json` request under the same key was then **replayed that 400 for twenty-four
 * hours**, with zero upstream calls and a code it will not retry. Unlike the multipart fallback
 * below, that direction fails *unsafe*: it is a wrong answer to a correct request, not a repeat of a
 * right one.
 *
 * The prefixes make the kinds disjoint, so no serialization coincidence can cross them.
 */
function digestOfBody(body: unknown): string | undefined {
  if (body === undefined || body === null) return undefined;
  const hash = createHash("sha256");
  if (Buffer.isBuffer(body)) {
    hash.update("bytes\n", "utf8");
    hash.update(body);
  } else if (typeof body === "string") {
    hash.update("text\n", "utf8");
    hash.update(body, "utf8");
  } else {
    hash.update("json\n", "utf8");
    hash.update(canonicalize(body), "utf8");
  }
  return hash.digest("hex");
}

/**
 * The string two requests are compared on: the route they are addressed to, and the strongest
 * statement about their body available at `preHandler`.
 *
 * The route is in here so that one key presented to two different routes conflicts rather than
 * replaying one route's response to the other. **Both sides of a comparison take the same branch**,
 * because which branch applies is decided by the content type — a parsed body is always available at
 * `preHandler` and a multipart one never is — and not by timing. A key sent once as JSON and once as
 * multipart to one route lands on different branches and conflicts, which is the correct answer to a
 * request that really has changed shape; the same now holds for two *parsed* bodies of different
 * kinds, which it did not until `digestOfBody` gained its prefixes.
 */
export function fingerprintOf(request: FastifyRequest, routeKey: string): string {
  const digest = digestOfBody(request.body);
  if (digest !== undefined) return `${routeKey}\n${BODY_PREFIX}${digest}`;

  const declared = request.headers["content-length"];
  const length = declared === undefined ? Number.NaN : Number(declared);
  if (!Number.isFinite(length)) return `${routeKey}\n${UNKNOWN_BODY}`;
  return `${routeKey}\n${LENGTH_PREFIX}${length}`;
}
