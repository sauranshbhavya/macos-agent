import type pg from "pg";
import { describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import {
  ProviderUnavailable,
  type AuthProvider,
  type VerifiedSession,
} from "../src/auth/provider.js";
import type { WithConnection } from "../src/db/connection.js";
import { DEADLINE_MS } from "../src/model/limits.js";
import { testConfig } from "./support/config.js";
import { fakeEntitlementStore } from "./support/entitlement.js";
import { accessTokenFor } from "./support/tokens.js";

/**
 * §12's deadlines on the auth routes (SONNY-425), for the two of them that reach the provider with
 * no database read in front — so this whole file runs under the documented `npm test`, with no
 * Postgres and nothing skipped.
 *
 * **Why that matters here rather than being a convenience.** The three remaining routes' deadline
 * tests are in `auth.db.test.ts`, which skips itself without a `DATABASE_URL`, and a skipped test
 * reads exactly like a passing one. Splitting the file this way means the wiring cannot be silently
 * unobserved on the command a reader is most likely to run: `refresh` proves the wrapper is applied
 * and `signout` proves it on an *authenticated* route, which is the other half of the shape.
 *
 * **Every test drives the real app through `inject`**, for the reason `screen.test.ts` and
 * `model.test.ts` both give: what is worth asserting is what the client receives, and a test calling
 * the route's helpers directly would skip the gate, the wrapper and the error mapping — which is
 * where the requirement lives.
 *
 * **Fake timers, because the numbers are fifteen seconds.** The bound is asserted by advancing to
 * one millisecond before it and checking that nothing has answered, then advancing past it. Without
 * the first half the assertion is about the stub rather than about the deadline: a provider that
 * simply never resolves would produce the same final status under any bound at all, including none.
 */

const SUPABASE_USER = "0f6c2c4e-8f2a-4a0f-9a11-2b6f5f2a77aa";
const ACCOUNT = "8a1d0c8e-1c5a-4a9f-9f6b-2b6f5f2a77ab";

/**
 * A provider whose calls never come back, and which records the signal it was handed.
 *
 * `stalls` is the whole point: it ignores the signal, so what ends a request against it can only be
 * the wrapper's *total* deadline. `abortsOnSignal` is the mirror — it settles when the signal fires,
 * the way `auth/supabase.ts`'s `fetch` does, and it rejects with the auth seam's own
 * `ProviderUnavailable`, which is what that adapter maps an aborted fetch to. The two together are
 * what tell the two deadlines apart.
 */
class StallingProvider implements AuthProvider {
  /** The signal each wrapped call was handed, in call order. `undefined` means it was given none. */
  readonly signals: (AbortSignal | undefined)[] = [];
  constructor(private readonly mode: "stalls" | "abortsOnSignal") {}

  #stall<T>(signal?: AbortSignal): Promise<T> {
    this.signals.push(signal);
    return new Promise<T>((_resolve, reject) => {
      if (this.mode === "stalls") return;
      signal?.addEventListener("abort", () => {
        reject(new ProviderUnavailable("aborted"));
      });
    });
  }

  async sendEmailCode(_email: string, signal?: AbortSignal) {
    return this.#stall<{ providerRequestId: string | undefined }>(signal);
  }
  async verifyEmailCode(
    _email: string,
    _code: string,
    signal?: AbortSignal,
  ): Promise<VerifiedSession> {
    return this.#stall<VerifiedSession>(signal);
  }
  async refresh(_refreshToken: string, signal?: AbortSignal): Promise<VerifiedSession> {
    return this.#stall<VerifiedSession>(signal);
  }
  async signOut(_accessToken: string, signal?: AbortSignal): Promise<void> {
    return this.#stall<void>(signal);
  }
  async userFromAccessToken(): Promise<string> {
    throw new Error("not used here");
  }
  async signOutAllForUser(): Promise<void> {}
  async deleteUser(): Promise<void> {}
}

/**
 * A connection that answers the gate's one attribution query and nothing else.
 *
 * `POST /v1/auth/signout` reads no database of its own — it hands the token back to the provider —
 * so anything past the gate's query reaching this is the route doing something it does not do.
 * Throwing rather than returning empty rows keeps that a red test rather than a silent one.
 */
const signedInConnection: WithConnection = async (work) => {
  const client = {
    query: async (text: string) => {
      if (!text.includes("FROM sonny.identity")) {
        throw new Error(`unexpected query from an auth deadline test: ${text}`);
      }
      return { rows: [{ account_id: ACCOUNT }] };
    },
  };
  return work(client as unknown as pg.Client);
};

const build = (provider: AuthProvider) =>
  buildApp(
    testConfig(),
    { provider, withConnection: signedInConnection },
    { entitlementStore: fakeEntitlementStore() },
  );

const authorization = () => `Bearer ${accessTokenFor(SUPABASE_USER)}`;

describe("§12's total deadline on the auth routes", () => {
  it("answers 504 provider.timeout when POST /v1/auth/refresh outruns the total deadline", async () => {
    // The provider ignores the signal, so the upstream half cannot be what ends this — which is
    // what makes the assertion about `total` specifically.
    vi.useFakeTimers();
    try {
      const provider = new StallingProvider("stalls");
      const app = build(provider);
      const pending = app.inject({
        method: "POST",
        url: "/v1/auth/refresh",
        payload: { refresh_token: "rt-live" },
      });
      let settled = false;
      void pending.then(() => {
        settled = true;
      });

      // Past the upstream deadline and still open: the state the second deadline exists for.
      await vi.advanceTimersByTimeAsync(DEADLINE_MS.auth.total - 1);
      expect(settled).toBe(false);

      await vi.advanceTimersByTimeAsync(2);
      const response = await pending;
      expect(response.statusCode).toBe(504);
      expect(response.json().error.code).toBe("provider.timeout");
      expect(response.json().error.retryable).toBe(true);
      await app.close();
    } finally {
      vi.useRealTimers();
    }
  });

  it("answers 504 provider.timeout when POST /v1/auth/signout outruns the total deadline", async () => {
    // The authenticated half of the same shape. `signout`'s own docstring makes `204` a claim that
    // the family was revoked, so a timeout must not answer it — the family is still live and
    // nothing else records that.
    vi.useFakeTimers();
    try {
      const app = build(new StallingProvider("stalls"));
      const pending = app.inject({
        method: "POST",
        url: "/v1/auth/signout",
        headers: { authorization: authorization() },
      });
      let settled = false;
      void pending.then(() => {
        settled = true;
      });

      await vi.advanceTimersByTimeAsync(DEADLINE_MS.auth.total - 1);
      expect(settled).toBe(false);

      await vi.advanceTimersByTimeAsync(2);
      const response = await pending;
      expect(response.statusCode).toBe(504);
      expect(response.json().error.code).toBe("provider.timeout");
      await app.close();
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("§12's upstream deadline on the auth routes", () => {
  it("hands the provider a signal that aborts at the upstream deadline, not the total one", async () => {
    // **The other half of the wiring, and the half a total-deadline test cannot see.** The wrapper
    // would still answer 504 at 15 s with the signal thrown away, so nothing above proves it
    // reaches the seam. Here the provider settles *on the signal*, the way `auth/supabase.ts`'s
    // `fetch` does — so an answer that arrives at 10 s rather than 15 s is the signal arriving.
    //
    // **502 and not 504, and that is the auth seam's mapping rather than a slip.** `supabase.ts`
    // turns an aborted fetch into this seam's `ProviderUnavailable`; §7.2 case 5's code is what a
    // caller then sees. The `504 provider.timeout` above comes from the wrapper's own race, which is
    // the only thing on these routes that raises `ProviderTimedOut`.
    vi.useFakeTimers();
    try {
      const provider = new StallingProvider("abortsOnSignal");
      const app = build(provider);
      const pending = app.inject({
        method: "POST",
        url: "/v1/auth/refresh",
        payload: { refresh_token: "rt-live" },
      });
      let settled = false;
      void pending.then(() => {
        settled = true;
      });

      await vi.advanceTimersByTimeAsync(DEADLINE_MS.auth.upstream - 1);
      expect(settled).toBe(false);

      await vi.advanceTimersByTimeAsync(2);
      const response = await pending;
      expect(response.statusCode).toBe(502);
      expect(response.json().error.code).toBe("provider.unavailable");
      // The call really was handed one — asserted directly, because "it answered early" is
      // circumstantial and this is the fact the wiring is about.
      expect(provider.signals).toHaveLength(1);
      expect(provider.signals[0]).toBeInstanceOf(AbortSignal);
      expect(provider.signals[0]!.aborted).toBe(true);
      await app.close();
    } finally {
      vi.useRealTimers();
    }
  });
});
