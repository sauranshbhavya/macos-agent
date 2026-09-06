import type { FastifyError, FastifyInstance, FastifyReply, FastifyRequest } from "fastify";

/**
 * The contract's error envelope (`docs/sonny-backend-api-contract.md` §7.1), applied to every
 * failure the server can produce — including the ones the framework produces on its own.
 *
 * **This exists because Fastify's default envelope is a different document.** It emits
 * `{statusCode, error, message}`, which shares no field with §7.1's `{error: {code, message,
 * retryable, retry_after_seconds, request_id}}`. Left alone, a 404 or a malformed body would hand
 * the client framework internals under a shape it does not parse, and every route added after this
 * ticket would inherit that. So the handlers are installed at the foundation rather than per route.
 *
 * **`message` is never displayed by the client** (§7.1): it maps `code` to its own copy. The
 * messages here are for logs, the support lookup, and a developer reading a response by hand —
 * which is also why they must never carry anything user-specific or secret.
 */

export interface ErrorBody {
  readonly error: {
    readonly code: string;
    readonly message: string;
    readonly retryable: boolean;
    readonly retry_after_seconds: number | null;
    readonly request_id: string;
    /**
     * Where to get a version this gateway still serves. **Present only on `version.unsupported`**
     * (§8.3, SONNY-204), which is the one refusal whose recovery is outside the app.
     *
     * Added to the envelope rather than composed at the call site because §7.1's envelope has one
     * home and a second shape built beside it is how the two drift. Optional rather than nullable
     * everywhere: §2.1 makes the client ignore fields it does not know, so a field that appears on
     * one code and not the others is additive in exactly the way §8.1 permits, while making it
     * `string | null` on every error would put a null on tens of thousands of responses to say
     * nothing.
     */
    readonly upgrade_url?: string;
  };
}

export function errorBody(
  code: string,
  message: string,
  requestId: string,
  options: {
    retryable?: boolean;
    retryAfterSeconds?: number | null;
    upgradeUrl?: string | undefined;
  } = {},
): ErrorBody {
  return {
    error: {
      code,
      message,
      retryable: options.retryable ?? false,
      retry_after_seconds: options.retryAfterSeconds ?? null,
      request_id: requestId,
      // Spread rather than `upgrade_url: options.upgradeUrl`, so the key is absent from the object
      // instead of present and undefined.
      //
      // **Not for the wire**, and the first version of this comment claimed it was: `JSON.stringify`
      // drops an undefined value, and `app.inject`'s `.json()` parses what was stringified, so an
      // HTTP-level assertion cannot tell the two apart. SONNY-204's mutation battery is what said
      // so — the mutant that writes the key unconditionally SURVIVED a suite whose test asserts the
      // exact key set of a 404 body, because at that level there was nothing to see.
      //
      // What it is for is the object this function returns, which is a value before it is a
      // response. `exactOptionalPropertyTypes` is on, so `upgrade_url?: string` does not accept
      // `string | undefined` and the direct assignment is a type error rather than a style
      // preference — which is why the surviving mutant would not have passed `npm run typecheck`.
      // The suite holds it too now, at the level it exists: `errorBody` is asserted directly.
      ...(options.upgradeUrl === undefined ? {} : { upgrade_url: options.upgradeUrl }),
    },
  };
}

/**
 * Maps a framework or thrown error onto §7.2's taxonomy.
 *
 * Only the cases this ticket's server can actually produce are mapped. The rest of §7.2 —
 * `auth.*`, `entitlement.*`, `limit.*`, `provider.*` — belongs to the tickets that add the routes
 * that can raise them; inventing them here would be guessing at their semantics.
 */
export function classify(error: FastifyError): {
  status: number;
  code: string;
  message: string;
  retryable: boolean;
} {
  const status = error.statusCode ?? 500;

  // §7.2 case 4. Fastify raises FST_ERR_CTP_BODY_TOO_LARGE for a body over `bodyLimit`.
  if (status === 413 || error.code === "FST_ERR_CTP_BODY_TOO_LARGE") {
    return {
      status: 413,
      code: "request.too_large",
      message: "Request body exceeds the limit for this route.",
      retryable: false,
    };
  }

  // **§7.2's `request.timeout`, and the reason it is not `request.invalid`** (SONNY-322, PR #208's
  // F1). A request whose body did not finish arriving is a transient *network* condition, and the
  // client's whole behaviour keys off `code`: `request.invalid` is hard-coded on the Mac as not
  // retryable and renders as "Sonny couldn't send this one", which reads as a malformed request
  // nobody can act on. Every clause of that is wrong here — the request was well formed, it is the
  // network rather than Sonny, the user can act on it, and a retry would plausibly succeed.
  //
  // **Retryable, and that flag is not what makes the client retry** — `SonnyBackendError` consults
  // the envelope's flag for `idempotency.conflict` alone and decides every other code from the code
  // itself. The flag is set because §7.2's table sets it for this row and a client keying off it
  // must not be told the opposite of what the code means.
  if (status === 408) {
    return {
      status: 408,
      code: "request.timeout",
      message: "Request was not delivered in time.",
      retryable: true,
    };
  }

  // §7.2's second table: malformed request. Covers a bad JSON body and a failed schema check.
  if (status === 400) {
    return {
      status: 400,
      code: "request.invalid",
      message: "Request could not be parsed or failed validation.",
      retryable: false,
    };
  }

  if (status === 404) {
    return {
      status: 404,
      code: "resource.not_found",
      message: "No such route.",
      retryable: false,
    };
  }

  if (status === 415) {
    return {
      status: 415,
      code: "request.invalid",
      message: "Unsupported content type.",
      retryable: false,
    };
  }

  // 4xx the taxonomy does not name individually still gets a taxonomy code rather than a
  // framework one; anything else is ours and is `server.error`, which §7.2 marks retryable.
  if (status >= 400 && status < 500) {
    return {
      status,
      code: "request.invalid",
      message: "Request was rejected.",
      retryable: false,
    };
  }
  return {
    status: 500,
    code: "server.error",
    message: "Internal error.",
    retryable: true,
  };
}

export function registerErrorHandlers(app: FastifyInstance): void {
  app.setErrorHandler((error: FastifyError, request: FastifyRequest, reply: FastifyReply) => {
    const mapped = classify(error);
    // The original is logged, never returned: a framework message can name internal paths and
    // library versions, and §7.1's `message` is a field the support lookup reads.
    if (mapped.status >= 500) {
      request.log.error({ err: error }, "request failed");
    } else {
      request.log.info({ err: error, code: mapped.code }, "request rejected");
    }
    void reply
      .status(mapped.status)
      .send(errorBody(mapped.code, mapped.message, request.id, { retryable: mapped.retryable }));
  });

  app.setNotFoundHandler((request: FastifyRequest, reply: FastifyReply) => {
    void reply
      .status(404)
      .send(errorBody("resource.not_found", "No such route.", request.id));
  });
}
