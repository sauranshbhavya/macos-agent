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
 */
export async function registeredRoutes(
  app: FastifyInstance,
): Promise<{ method: string; url: string }[]> {
  await app.ready();
  const collected: { method: string; url: string }[] = [];
  for (const line of app.printRoutes({ commonPrefix: false }).split("\n")) {
    const match = /(\/\S*)\s+\(([A-Z, ]+)\)\s*$/.exec(line);
    if (!match) continue;
    for (const method of match[2]!.split(",").map((m) => m.trim())) {
      collected.push({ method, url: match[1]! });
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
