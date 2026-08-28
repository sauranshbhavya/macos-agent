import type { FastifyInstance } from "fastify";
import { expect } from "vitest";

/**
 * Every route a built server actually serves, one entry per method, **read off the app rather than
 * listed here**.
 *
 * **Extracted from `gate.test.ts` by SONNY-133, unchanged in behaviour**, because a second
 * population scan needed it and a copied route parser is the shape `model/routing.ts` already
 * carries a warning about ("do not edit one of them and assume the other followed"). Two files ask
 * the router now — `gate.test.ts` for "is every route either public or challenged", and
 * `metering.test.ts` for "is every `POST` either metered or declared unmetered" — and both questions
 * are worthless if the parse silently returns nothing.
 *
 * The history is worth keeping with the code, since it is the reason this is a scan at all. It
 * **enumerated two hard-coded registrars and called itself the population** (PR #104's adversarial
 * review, F5): it built a throwaway instance, called `registerHealth` and `registerAuth`, and its
 * comment promised that "a route added by a later ticket appears here automatically" — which was
 * true only of routes added by those two functions. A third registrar's routes were invisible, and
 * the assertion that the protected set is exactly two kept passing while saying nothing about them.
 *
 * `printRoutes` asks the router, so the answer covers every route registered by anything — a route
 * added directly, one inside a plugin, one nested two plugins deep, one in a second plugin beside a
 * first, and one behind a prefix.
 *
 * **The tree is walked rather than read line by line, and that is a correction rather than a
 * refinement** (SONNY-135). The previous version took the path off each line with one regex and
 * called it the route's url, on the belief that `commonPrefix: false` prints every route in full. It
 * does not: a route whose path is a strict *prefix* of another's still becomes a parent node, and
 * the child prints only its own segment. Measured against Fastify 5.12.1 the moment
 * `GET /v1/account/entitlements` landed beside the `DELETE /v1/account` that has been there since
 * SONNY-203:
 *
 * ```text
 * └── /v1/account (DELETE)
 *     └── /entitlements (GET, HEAD)
 * ```
 *
 * — so the scan answered `GET /entitlements`, a path no route serves. **Both callers judge a route by
 * its path**, so the consequence is not cosmetic in either of them: `isPublicRoute` and
 * `meteredRouteFor` both look the string up in a map, a truncated string matches nothing, and a
 * nested route therefore reads as neither-public-nor-listed in one scan and unmetered in the other.
 * That is the exact failure both scans exist to prevent, arriving through the scan itself.
 *
 * Indentation is what says where a segment belongs: each level is four characters of `│`/space
 * padding before the `├──` or `└──` branch, so the depth is that padding's length over four and the
 * url is every ancestor's segment concatenated with this one's.
 * `theScanReadsANestedRoutesWholePath` pins the shape with a hand-built pair, so the fix does not
 * depend on this application still happening to have one.
 */
export async function registeredRoutes(
  app: FastifyInstance,
): Promise<{ method: string; url: string }[]> {
  await app.ready();
  return parsePrintedRoutes(app.printRoutes({ commonPrefix: false }));
}

/** The parse, separated from the app so a test can drive it with a tree it wrote itself. */
export function parsePrintedRoutes(printed: string): { method: string; url: string }[] {
  const collected: { method: string; url: string }[] = [];
  const segments: string[] = [];
  for (const line of printed.split("\n")) {
    const match = /^([\s│]*)(?:├──|└──) (\S*)(?: \(([A-Z, ]+)\))?\s*$/.exec(line);
    if (!match) continue;
    const depth = match[1]!.length / 4;
    segments.length = depth;
    segments[depth] = match[2]!;
    if (match[3] === undefined) continue;
    const url = segments.join("");
    for (const method of match[3].split(",").map((m) => m.trim())) {
      collected.push({ method, url });
    }
  }
  return collected;
}

/** The parse really parsed something: a format change must fail loudly, not quietly return []. */
export function expectPopulationIsReal(routes: { method: string; url: string }[]): void {
  expect(routes.length).toBeGreaterThanOrEqual(7);
  const pairs = routes.map((route) => `${route.method} ${route.url}`);
  expect(pairs).toContain("DELETE /v1/account");
  expect(pairs).toContain("GET /v1/health");
  expect(pairs).toContain("HEAD /v1/health");
  expect(pairs).toContain("POST /v1/auth/email/verify");
}
