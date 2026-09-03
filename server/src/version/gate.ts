import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { errorBody } from "../errors.js";
import { bandFor, type ClientVersionPolicy } from "./policy.js";

/**
 * Contract §8.3's `410 version.unsupported` and §8.4's deprecation headers, as one `onRequest` hook
 * (SONNY-204).
 *
 * **Registered on the root instance and before `registerAuthGate`, and both halves are
 * load-bearing.**
 *
 * *Root instance*, for the reason `auth/gate.ts` measured and wrote down: coverage is encapsulation,
 * not registration order. A hook added to a context covers every route in that context and its
 * descendants and covers nothing outside it, so a version gate installed inside a plugin would leave
 * a sibling plugin's routes answering a client this deployment has said it does not serve.
 *
 * *Before the auth gate*, and here order genuinely is the point. Fastify runs `onRequest` hooks in
 * registration order, and an outdated client's token is usually the first thing that has gone stale:
 * it launches, its access token is long expired, and the auth gate answers `401 auth.token_expired`.
 * §7.2 makes that the one `401` a client answers by refreshing and retrying — so a client that is
 * six months old and unable to parse anything the modern gateway sends spends its whole session in a
 * refresh loop and never learns the one fact that would end it. Refusing on version first is what
 * turns that into §8.3's "definite, actionable state". It also means an outdated client learns it is
 * outdated **without holding a valid token at all**, which is the state a user who reinstalled an old
 * build is actually in.
 *
 * **The gate runs for requests that matched no route, deliberately, and this is the one place it
 * differs from the auth gate.** That gate returns early on `routeOptions.url === undefined` so a 404
 * stays a 404, because the 401/404 distinction is what tells a caller a path exists. Nothing here is
 * about disclosure: `410` answers the *caller*, not the path, and it is the more useful answer to an
 * old client that is asking for something this `/v1` no longer routes — which is the shape a stale
 * client's request table takes.
 *
 * **A disarmed policy costs one boolean and does nothing.** `config.ts` defaults both bounds to
 * `0.0.0` so that shipping this gate refuses nobody until a founder decides it should; the branch
 * below is what makes that literally true rather than approximately.
 */
export function registerVersionGate(app: FastifyInstance, policy: ClientVersionPolicy): void {
  if (!policy.armed) return;

  app.addHook("onRequest", async (request: FastifyRequest, reply: FastifyReply) => {
    const band = bandFor(request.headers["sonny-client-version"], policy);

    if (band === "deprecated") {
      // §8.4 — "gets its requests served normally, plus `Sonny-Deprecation: true` and
      // `Sonny-Deprecation-Info: <url>` on every response". Set here rather than in an `onSend`
      // hook so that they reach a response this request never gets a handler for: a `401` from the
      // gate below, a `404`, a `413` refused at the body limit. A header set on the reply in
      // `onRequest` is on whatever that reply eventually sends, and "every response" is what §8.4
      // says. The one class it cannot reach is a request rejected before routing — a malformed URL,
      // which `app.ts`'s `frameworkErrors` answers — where no hook of this instance has run.
      reply.header("Sonny-Deprecation", "true");
      reply.header("Sonny-Deprecation-Info", policy.upgradeUrl);
      return undefined;
    }

    if (band !== "unsupported") return undefined;

    // Logged at `info` with the version that was refused, because the operator question this
    // answers is "who is still on what" — the number that decides whether raising the minimum again
    // is safe. The header is a version string and not a secret; it is already stored on every
    // metered request (§11).
    request.log.info(
      {
        clientVersion: request.headers["sonny-client-version"],
        minimum: policy.minimumText,
        route: `${request.method} ${request.routeOptions.url ?? request.url}`,
      },
      "client below the minimum supported version; refusing",
    );

    return reply.status(410).send(
      errorBody(
        "version.unsupported",
        // §7.1: never displayed. The client maps `code` to its own copy — which is exactly what
        // makes this refusal work for a client that predates every other string on the wire.
        `This client is older than the minimum supported version ${policy.minimumText}.`,
        request.id,
        { retryable: false, upgradeUrl: policy.upgradeUrl },
      ),
    );
  });
}
