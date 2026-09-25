/**
 * `GET /v2/session`: the one WebSocket a Mac holds to the gateway.
 *
 * The version gate and the auth gate run on the upgrade request as they do for any route, with the
 * token in the Authorization header. A refused upgrade is an ordinary HTTP error with the contract's
 * error body.
 */
import fastifyWebsocket from "@fastify/websocket";
import type { FastifyInstance } from "fastify";
import { callerOf } from "../../auth/gate.js";
import { errorBody } from "../../errors.js";
import { MAX_PAYLOAD_BYTES, SessionConnection, type SessionDeps } from "./connection.js";

export const SESSION_ROUTE = "/v2/session";

/** How long a draining gateway waits for sessions to close after saying goodbye. */
const DRAIN_GRACE_MS = 2000;

export function registerAgentSession(app: FastifyInstance, deps: SessionDeps): void {
  // An upgrade the version or auth gate refuses is answered with an ordinary HTTP error, and its
  // socket must then close. The websocket plugin's own hook for that never runs, because the gates'
  // hooks were added first and one that replies stops the rest; so this one does it. A successful
  // upgrade is hijacked and never reaches onResponse.
  app.addHook("onResponse", async (request) => {
    if (request.headers.upgrade?.toLowerCase() === "websocket") request.raw.socket?.destroy();
  });

  void app.register(fastifyWebsocket, {
    options: { maxPayload: MAX_PAYLOAD_BYTES },
    // A deploy says goodbye to every session before the server closes, so each Mac reconnects to
    // the new process instead of seeing its socket drop.
    preClose: async function (this: FastifyInstance) {
      deps.registry.drain();
      await deps.runner.stop();
      const deadline = Date.now() + DRAIN_GRACE_MS;
      while (deps.registry.size > 0 && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      for (const client of this.websocketServer.clients) client.terminate();
    },
  });

  void app.register(async (scope) => {
    scope.get(
      SESSION_ROUTE,
      {
        websocket: true,
        preHandler: async (request, reply) => {
          if (!deps.registry.draining) return undefined;
          return reply
            .status(503)
            .header("Retry-After", "1")
            .send(
              errorBody("server.unavailable", "The gateway is restarting.", request.id, {
                retryable: true,
                retryAfterSeconds: 1,
              }),
            );
        },
      },
      (socket, request) => {
        new SessionConnection(socket, callerOf(request), deps);
      },
    );
  });
}
