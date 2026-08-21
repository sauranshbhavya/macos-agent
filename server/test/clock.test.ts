import { describe, expect, it } from "vitest";
import { EXPIRY_SKEW_TOLERANCE_SECONDS, expiryFields, isExpiryAcceptable } from "../src/auth/clock.js";

describe("clock-skew tolerance", () => {
  const expiry = new Date("2026-08-21T12:00:00Z");
  const at = (offsetSeconds: number) => new Date(expiry.getTime() + offsetSeconds * 1000);

  it("accepts a token that has not expired", () => {
    expect(isExpiryAcceptable(expiry, at(-1))).toEqual({ valid: true, withinTolerance: false });
  });

  it("accepts a token just inside the tolerance — the slow-clock edge", () => {
    const verdict = isExpiryAcceptable(expiry, at(EXPIRY_SKEW_TOLERANCE_SECONDS - 1));
    expect(verdict).toEqual({ valid: true, withinTolerance: true });
  });

  it("accepts a token exactly at the tolerance boundary", () => {
    expect(isExpiryAcceptable(expiry, at(EXPIRY_SKEW_TOLERANCE_SECONDS)).valid).toBe(true);
  });

  it("REFUSES a token one second past the tolerance — the other edge", () => {
    // Both edges, which the acceptance criterion names. The boundary is closed on the accepting
    // side and open on the refusing side, asserted rather than left to a reader of the arithmetic.
    const verdict = isExpiryAcceptable(expiry, at(EXPIRY_SKEW_TOLERANCE_SECONDS + 1));
    expect(verdict).toEqual({ valid: false, withinTolerance: false });
  });

  it("grants no tolerance to a token from the future", () => {
    // Tolerance is one-directional on purpose. A not-yet-valid token is either the server's own
    // clock being wrong, which tolerance cannot fix, or a forged claim, which it must not help.
    const future = new Date("2026-08-21T13:00:00Z");
    expect(isExpiryAcceptable(future, expiry)).toEqual({ valid: true, withinTolerance: false });
  });

  it("keeps the tolerance small enough to be a drift allowance, not a grace period", () => {
    // A regression guard with a reason: every second here is a second a revoked token still works.
    expect(EXPIRY_SKEW_TOLERANCE_SECONDS).toBeLessThanOrEqual(60);
    expect(EXPIRY_SKEW_TOLERANCE_SECONDS).toBeGreaterThan(0);
  });

  it("derives expires_in and expires_at from ONE instant so they cannot disagree", () => {
    const issued = new Date("2026-08-21T09:41:07Z");
    expect(expiryFields(issued, 3600)).toEqual({
      expires_in: 3600,
      expires_at: "2026-08-21T10:41:07Z",
    });
  });

  it("emits expires_at in the contract's RFC 3339 UTC form", () => {
    // §2.1: "RFC 3339 in UTC with a Z suffix". A client comparing against the Date header parses
    // this, and a fractional-seconds form is a different string than the contract's example.
    expect(expiryFields(new Date("2026-08-21T09:41:07.482Z"), 60).expires_at)
      .toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  });
});
