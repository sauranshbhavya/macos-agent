import type { FastifyReply, FastifyRequest } from "fastify";
import { errorBody } from "../errors.js";
import { ProviderRejected, ProviderTimedOut, ProviderUnavailable } from "./upstream.js";

/**
 * The two things every model route does around its provider call: bound it in time, and turn what it
 * threw into one of §7.2's codes (SONNY-131).
 *
 * **This file exists because SONNY-131 needed both and could not import either.** Both functions
 * were written by SONNY-130 as private declarations inside `routes/model.ts`, which is on this
 * ticket's never-touch list — it is "the four text routes". Copying them into the vision route would
 * have given §12's deadline behaviour and §7.2's failure mapping two implementations that can drift,
 * which is the failure this repository already has a rule about. So they are here, the vision route
 * uses them, and **SONNY-316** is the ticket that points the four text routes at them and deletes
 * the private copies.
 *
 * Nothing here is new behaviour. The bodies are SONNY-130's, moved rather than rewritten, so a
 * reader comparing the two sees the same code and `SONNY-316` is a deletion rather than a merge.
 */

/**
 * Run `work` under the route's total deadline (§12), with an `AbortSignal` bounded by its upstream
 * deadline.
 *
 * **Two deadlines and not one, because they fail in different places.** The signal ends a provider
 * call that is still open. The total-deadline race ends a handler that is stuck anywhere else —
 * parsing a pathological body, an adapter that resolved and then hung. Without the second, §12's
 * "server total deadline" column would be a number nothing enforces, and the failure it describes
 * would arrive as whatever the platform in front does when it gives up, which the client cannot tell
 * apart from a dead network.
 */
export async function withDeadlines<T>(
  deadlines: { readonly upstream: number; readonly total: number },
  work: (signal: AbortSignal) => Promise<T>,
): Promise<T> {
  const controller = new AbortController();
  const upstreamTimer = setTimeout(() => controller.abort(), deadlines.upstream);
  let totalTimer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      work(controller.signal),
      new Promise<never>((_resolve, reject) => {
        totalTimer = setTimeout(() => {
          controller.abort();
          reject(new ProviderTimedOut("the route's total deadline elapsed"));
        }, deadlines.total);
      }),
    ]);
  } finally {
    clearTimeout(upstreamTimer);
    if (totalTimer !== undefined) clearTimeout(totalTimer);
  }
}

/**
 * Every upstream failure a model route can produce, as §7.2 names it.
 *
 * **Keyed on the thrown type, never on a status this gateway saw.** §9.3 states the client-side
 * version of the same rule and gives the reason: several statuses carry more than one code with
 * opposite semantics. `provider.rejected` and `provider.unavailable` are both 502 and the client
 * retries exactly one of them.
 *
 * Anything this does not recognise is rethrown, so it reaches the root error handler and is logged
 * at `error` with its stack — §7.2 case 6's retryable 500. Swallowing it into a `502` here would
 * make this gateway's own bugs look like a provider's.
 */
export function sendUpstreamFailure(
  request: FastifyRequest,
  reply: FastifyReply,
  error: unknown,
): FastifyReply {
  if (error instanceof ProviderTimedOut) {
    request.log.info({ err: error }, "upstream timed out");
    return reply.status(504).send(
      errorBody("provider.timeout", "The upstream provider did not answer in time.", request.id, {
        retryable: true,
      }),
    );
  }
  if (error instanceof ProviderUnavailable) {
    request.log.warn({ err: error }, "upstream unavailable");
    return reply.status(502).send(
      errorBody("provider.unavailable", "The upstream provider could not be reached.", request.id, {
        retryable: true,
      }),
    );
  }
  if (error instanceof ProviderRejected) {
    request.log.warn({ err: error }, "upstream rejected the request");
    return reply.status(502).send(
      errorBody("provider.rejected", "The upstream provider refused this request.", request.id, {
        retryable: false,
      }),
    );
  }
  throw error;
}
