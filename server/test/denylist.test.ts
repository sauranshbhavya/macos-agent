import Fastify from "fastify";
import { describe, expect, it } from "vitest";
import { EXPIRY_SKEW_TOLERANCE_SECONDS } from "../src/auth/clock.js";
import {
  denylistedUntil, isProviderSessionRevoked, revokeProviderSession,
} from "../src/auth/denylist.js";
import { DENYLIST_EXEMPT_ROUTES, PUBLIC_ROUTES, registerAuthGate } from "../src/auth/gate.js";
import type { WithConnection } from "../src/db/connection.js";
import { registerErrorHandlers } from "../src/errors.js";
import { signedInConnectionTo } from "./support/connection.js";
import { TEST_JWT_POLICY, accessTokenFor, providerSessionFor, tokenWithClaims } from "./support/tokens.js";

/**
 * The denylist as the gate sees it, with no database in reach (SONNY-237).
 *
 * `denylist.db.test.ts` drives the real table through a real sign-out. This file is the other half:
 * what the gate *asks*, in what order, and what it answers — the things a fake can observe and a
 * real Postgres cannot be made to report. Every test below records the statements the hook issued,
 * so a consult that stopped happening fails here rather than passing quietly against a table that
 * happened to be empty.
 */

const USER = "11111111-1111-1111-1111-111111111111";
const ACCOUNT = "22222222-2222-2222-2222-222222222222";
const OTHER_SESSION = "9a9a9a9a-9a9a-4a9a-8a9a-9a9a9a9a9a9a";

interface Recorded {
  readonly text: string;
  readonly values: readonly unknown[];
}

/**
 * A connection that answers the gate's two reads and records both.
 *
 * Deliberately local rather than `support/connection.ts`'s: that one exists so eleven suites which
 * are not about the gate do not each carry a copy, and it answers without saying what it was asked.
 * What this file asserts is precisely what it was asked, so the recording is the fixture.
 */
function recordingConnection(
  revoked: ReadonlySet<string>,
  asked: Recorded[],
): WithConnection {
  return async (work) => {
    const client = {
      query: async (text: string, values: readonly unknown[] = []) => {
        asked.push({ text, values });
        if (text.includes("FROM sonny.revoked_provider_session")) {
          return { rows: revoked.has(values[0] as string) ? [{ "?column?": 1 }] : [] };
        }
        if (text.includes("FROM sonny.identity")) return { rows: [{ account_id: ACCOUNT }] };
        throw new Error(`unexpected query from the gate: ${text}`);
      },
    };
    return work(client as unknown as never);
  };
}

/** A single protected route that reports whether the gate let the request through, and as whom. */
function appWith(revoked: ReadonlySet<string>, asked: Recorded[]) {
  const app = Fastify();
  registerErrorHandlers(app);
  registerAuthGate(app, {
    policy: TEST_JWT_POLICY,
    withConnection: recordingConnection(revoked, asked),
  });
  app.post("/v1/plan", async (request) => ({
    accountId: request.auth?.accountId,
    providerSessionId: request.auth?.providerSessionId,
    expiresAt: request.auth?.accessTokenExpiresAt?.toISOString(),
  }));
  return app;
}

const consults = (asked: readonly Recorded[]) =>
  asked.filter((q) => q.text.includes("FROM sonny.revoked_provider_session"));
const attributions = (asked: readonly Recorded[]) =>
  asked.filter((q) => q.text.includes("FROM sonny.identity"));

describe("a signed-out session, at the gate", () => {
  it("refuses a token whose session is denylisted, with the code that opens sign-in", async () => {
    const asked: Recorded[] = [];
    const app = appWith(new Set([providerSessionFor(USER)]), asked);

    const refused = await app.inject({
      method: "POST", url: "/v1/plan",
      headers: { authorization: `Bearer ${accessTokenFor(USER)}` },
    });

    expect(refused.statusCode).toBe(401);
    expect(refused.json().error.code).toBe("auth.token_revoked");
    // Not `auth.token_expired`: §7.2 makes that the one retryable 401, and refreshing a session that
    // has been signed out is a loop rather than a recovery.
    expect(refused.json().error.retryable).toBe(false);
    // **The refusal costs one read and stops.** Attribution is not reached, which is the ordering
    // `gate.ts` argues for — a signed-out session is refused whether or not its account resolves.
    expect(consults(asked).map((q) => q.values[0])).toEqual([providerSessionFor(USER)]);
    expect(attributions(asked)).toHaveLength(0);
    await app.close();
  });

  it("lets a token through when a DIFFERENT session is the denylisted one", async () => {
    const asked: Recorded[] = [];
    const app = appWith(new Set([OTHER_SESSION]), asked);

    const served = await app.inject({
      method: "POST", url: "/v1/plan",
      headers: { authorization: `Bearer ${accessTokenFor(USER)}` },
    });

    expect(served.statusCode).toBe(200);
    expect(served.json().accountId).toBe(ACCOUNT);
    // The consult ran and answered no; attribution then ran. Both, in that order, on one connection.
    expect(consults(asked)).toHaveLength(1);
    expect(attributions(asked)).toHaveLength(1);
    expect(asked.map((q) => q.text.includes("FROM sonny.revoked_provider_session"))).toEqual([true, false]);
    await app.close();
  });

  it("carries the verified session and expiry onto the caller, for the route that records them", async () => {
    const asked: Recorded[] = [];
    const app = appWith(new Set(), asked);
    // Minted against the real clock rather than a fixed instant: the gate judges `exp` against
    // `new Date()`, so a literal date is a token that expires the day the literal goes stale — and
    // the assertion below is exact anyway, because `claimsFor` floors `iat` to the second.
    const issued = new Date();
    const expectedExpiry = new Date((Math.floor(issued.getTime() / 1000) + 3600) * 1000);

    const served = await app.inject({
      method: "POST", url: "/v1/plan",
      headers: {
        authorization: `Bearer ${accessTokenFor(USER, { now: issued, lifetimeSeconds: 3600 })}`,
      },
    });

    expect(served.statusCode).toBe(200);
    expect(served.json().providerSessionId).toBe(providerSessionFor(USER));
    expect(served.json().expiresAt).toBe(expectedExpiry.toISOString());
    await app.close();
  });

  it("asks nothing of the denylist for a token that carries no session claim, and serves it", async () => {
    // The residual, pinned in the direction that matters: this token is not denylistable, and the
    // gate must not invent a lookup for it. GoTrue omits the claim (`omitempty`) and handles the
    // absence itself, so this is a shape the provider mints rather than a malformed token.
    const asked: Recorded[] = [];
    const app = appWith(new Set([providerSessionFor(USER)]), asked);

    const served = await app.inject({
      method: "POST", url: "/v1/plan",
      headers: {
        authorization: `Bearer ${tokenWithClaims(USER, { session_id: undefined })}`,
      },
    });

    expect(served.statusCode).toBe(200);
    expect(served.json().providerSessionId).toBeUndefined();
    expect(consults(asked)).toHaveLength(0);
    expect(attributions(asked)).toHaveLength(1);
    await app.close();
  });

  it("refuses a token whose session claim is present and not a uuid, before any read", async () => {
    // A malformed claim must not read as an absent one: that would make the token silently
    // undenylistable, which is the one property this whole mechanism provides. `auth.unauthenticated`
    // rather than `auth.token_revoked` — nothing was revoked, the token is wrong.
    const asked: Recorded[] = [];
    const app = appWith(new Set(), asked);

    const refused = await app.inject({
      method: "POST", url: "/v1/plan",
      headers: { authorization: `Bearer ${tokenWithClaims(USER, { session_id: "not-a-uuid" })}` },
    });

    expect(refused.statusCode).toBe(401);
    expect(refused.json().error.code).toBe("auth.unauthenticated");
    expect(asked).toHaveLength(0);
    await app.close();
  });
});

/**
 * The exemption set, held **by value** and with no database in reach (PR #215's F1).
 *
 * **This is the one door through which a token the gateway has been told to stop honouring is still
 * served**, and until this suite nothing said which routes it lets through. The reviewer measured
 * the gap rather than arguing it: a mutant adding `DELETE /v1/account/content` and `DELETE /v1/tasks`
 * to the set — which would let a signed-out token delete every task the account has ever stored —
 * survived all 1283 tests, while the same widening applied to `PUBLIC_ROUTES`, the sibling set, was
 * killed by nine. The asymmetry was the finding: one set is pinned by value and the other was
 * described only in prose.
 *
 * **A value table rather than a membership check**, for the reason `theWipesOwnSentenceNamesEveryStoreItDeletes`
 * is one in the Swift half: a check that the set *contains* the sign-out route sees a missing entry
 * and never an extra one, and an extra one is the whole risk here.
 *
 * **And in this file rather than a `.db.test.ts`, deliberately.** Every test that held the
 * exemption's behaviour before this one was database-gated, so the documented `npm test` — 445
 * skipped — said nothing about it at all. This assertion runs on every invocation of that command.
 */
describe("which routes a signed-out session may still reach", () => {
  it("is exactly the sign-out route, and nothing else", () => {
    expect([...DENYLIST_EXEMPT_ROUTES]).toEqual(["POST /v1/auth/signout"]);
  });

  it("names a route that is NOT public, so the exemption is the narrower of the two", () => {
    // The distinction the docstring in `gate.ts` draws: an exempt route still has its token
    // verified, its caller attributed and a closed account refused. Only the denylist consult is
    // skipped. A route that had drifted onto both lists would be a route the gate never challenges.
    for (const route of DENYLIST_EXEMPT_ROUTES) {
      expect(PUBLIC_ROUTES.has(route)).toBe(false);
    }
    // The control, so the loop above cannot pass by iterating nothing.
    expect(DENYLIST_EXEMPT_ROUTES.size).toBeGreaterThan(0);
  });
});

/**
 * The shared fake's dispatch, driven by the real statements rather than by transcriptions of them
 * (PR #215's F3).
 *
 * Eleven suites that are not about the gate reach the database through `signedInConnectionTo`, and
 * its whole promise is that a statement it has never heard of throws instead of answering an empty
 * result set. That promise broke silently the moment the sign-out gained a write: the write opens
 * with the prune's `DELETE FROM sonny.revoked_provider_session`, so a dispatch keyed on the table
 * name answered it as if it were the consult. Nothing any suite asserted was wrong — the loudness
 * was gone, which is the kind of thing only a test of the fake itself notices.
 *
 * **The statements come from `denylist.ts` by calling it**, so a rewritten statement arrives here
 * rather than passing against a transcription that has stopped matching.
 *
 * **What this cannot see, said rather than implied: the branch order.** Both branches answer
 * `{rows: []}`, so a fake that matched the write on the consult's condition — F3's actual state —
 * satisfies every assertion below. What the separate branch buys is that the write is *declared*:
 * a later change to what either branch answers can no longer silently apply to the other, and the
 * next statement added to this path meets the `throw` rather than an empty result set. The ordering
 * itself is held by the comment where it is written.
 */
describe("the shared fake connection, against the statements it has to recognise", () => {
  const fake = signedInConnectionTo({ account: ACCOUNT, where: "in the fake's own test" });

  it("recognises the sign-out's WRITE, so a suite driving that route is not refused", async () => {
    await expect(
      fake((client) => revokeProviderSession(
        client, providerSessionFor(USER), new Date(), new Date(),
      )),
    ).resolves.toBeUndefined();
  });

  it("recognises the gate's consult and answers it not-revoked", async () => {
    await expect(
      fake((client) => isProviderSessionRevoked(client, providerSessionFor(USER))),
    ).resolves.toBe(false);
  });

  it("THROWS on a statement it has never heard of, naming the suite", async () => {
    // The control, and the assertion the two above are worthless without: a fake that answered
    // everything would satisfy them exactly, which is the state F3 found and which reads identically
    // from outside.
    await expect(
      fake((client) => client.query("SELECT 1 FROM sonny.metering_event")),
    ).rejects.toThrow(/unexpected query in the fake's own test/);
  });
});

describe("how long a denylist row has to be kept", () => {
  it("is the token's own expiry plus the tolerance the gate grants past it", () => {
    const expiresAt = new Date("2026-09-06T13:00:00.000Z");
    expect(denylistedUntil(expiresAt).toISOString()).toBe("2026-09-06T13:00:30.000Z");
    expect(denylistedUntil(expiresAt).getTime() - expiresAt.getTime())
      .toBe(EXPIRY_SKEW_TOLERANCE_SECONDS * 1000);
  });

  it("is strictly later than exp, so the tolerance window is never uncovered", () => {
    // The assertion above would pass on a `denylistedUntil` hard-coded to a right-looking literal.
    // This one is the property: whatever the tolerance is set to, the row outlives the token.
    const expiresAt = new Date("2026-09-06T13:00:00.000Z");
    expect(denylistedUntil(expiresAt).getTime()).toBeGreaterThan(expiresAt.getTime());
    expect(EXPIRY_SKEW_TOLERANCE_SECONDS).toBeGreaterThan(0);
  });
});
