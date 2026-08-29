import { generateKeyPairSync } from "node:crypto";
import {
  entitlementSigningKeyFrom,
  publicKeyMaterial,
  type EntitlementSigningKey,
} from "../../src/entitlement/claim.js";
import type {
  AdmitInput,
  AdmitOutcome,
  EntitlementRecord,
  EntitlementStore,
  SettleOutcome,
} from "../../src/entitlement/store.js";
import { unprovisioned } from "../../src/entitlement/store.js";

/**
 * A signing key and an in-memory store, so the whole entitlement path can be driven by `npm test`
 * (SONNY-135).
 *
 * **The key is generated per run rather than committed**, which is the opposite call to
 * `support/tokens.ts`' fixed HS256 secret and is right for the opposite reason. That secret is a
 * *verifying* value: a test needs the same one the fixture was signed with, and writing it down
 * costs nothing because it verifies nothing real. This is a *signing* key — the private half of the
 * thing that grants capabilities — and a committed one is a working minting key sitting in the
 * repository for anyone who copies it into a deployment. Generating it costs a millisecond.
 *
 * **The Swift half's golden vector is the one place a claim is written down**, and it is a claim
 * plus a public key: signed, expired, about a synthetic account, and unable to mint anything.
 */
export function testSigningKey(keyId = "test-key-1"): EntitlementSigningKey {
  const { privateKey } = generateKeyPairSync("ed25519");
  const der = privateKey.export({ type: "pkcs8", format: "der" });
  return entitlementSigningKeyFrom(der.toString("base64"), keyId);
}

export function testPublicKey(key: EntitlementSigningKey): string {
  return publicKeyMaterial(key);
}

/** What a fake store was asked to do, in order, so a test can assert on the sequence. */
export interface FakeStoreCalls {
  readonly admitted: AdmitInput[];
  readonly settled: { reservationId: string; charge: boolean }[];
}

export interface FakeEntitlementStore extends EntitlementStore {
  readonly calls: FakeStoreCalls;
  setRecord: (accountId: string, record: Partial<EntitlementRecord>) => void;
  /** What the next admissions answer. Set once; every later request gets the same answer. */
  answerWith: (outcome: AdmitOutcome) => void;
}

/**
 * An in-memory `EntitlementStore`.
 *
 * **It is not a model of the cap and must never become one.** Its `admit` returns whatever a test
 * told it to; it does no arithmetic, holds no counter and knows nothing about periods, because a
 * race against a fake proves nothing and a fake that looks like it enforces a cap is how a suite
 * comes to believe it has tested one. The real mechanism is Postgres's and is proved in
 * `entitlement.db.test.ts` against a real Postgres, under forced interleavings and a concurrent
 * battery. What this exists for is everything *around* the cap: which requests reach it, what each
 * refusal tells a client, and whether a hold is charged or released.
 */
export function fakeEntitlementStore(): FakeEntitlementStore {
  const records = new Map<string, EntitlementRecord>();
  const calls: FakeStoreCalls = { admitted: [], settled: [] };
  let nextOutcome: AdmitOutcome | undefined;
  let nextId = 1;

  return {
    calls,
    setRecord(accountId, record) {
      records.set(accountId, { ...unprovisioned(accountId), ...record, accountId });
    },
    answerWith(outcome) {
      nextOutcome = outcome;
    },
    entitlementFor(accountId) {
      return Promise.resolve(records.get(accountId) ?? unprovisioned(accountId));
    },
    admit(input) {
      calls.admitted.push(input);
      if (nextOutcome !== undefined) return Promise.resolve(nextOutcome);
      // Admitted, with a hold exactly when the real store would take one: on a metered route.
      return Promise.resolve({
        kind: "admitted",
        reservationId: input.metered ? `reservation-${nextId++}` : undefined,
      });
    },
    settle(reservationId, charge) {
      calls.settled.push({ reservationId, charge });
      return Promise.resolve("charged" as SettleOutcome);
    },
  };
}
