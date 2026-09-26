/**
 * What a request declared about keeping its content: `"none"` for a task started with "Don't save
 * this task". The idempotency store honours it, keeping no replayable copy of such a response.
 *
 * The transcription route's body is multipart, so it records the declaration itself once the meta
 * part is validated; every other route declares it in its JSON body.
 */
import type { FastifyRequest } from "fastify";

export type DeclaredRetention = "standard" | "none" | undefined;

declare module "fastify" {
  interface FastifyRequest {
    declaredRetention?: DeclaredRetention;
  }
}

export function noteRetention(request: FastifyRequest, retention: "standard" | "none"): void {
  request.declaredRetention = retention;
}

export function retentionOf(request: FastifyRequest): DeclaredRetention {
  if (request.declaredRetention !== undefined) return request.declaredRetention;
  const body = request.body;
  if (typeof body !== "object" || body === null) return undefined;
  const value = (body as Record<string, unknown>)["retention"];
  return value === "standard" || value === "none" ? value : undefined;
}
