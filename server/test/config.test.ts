import { describe, expect, it } from "vitest";
import {
  ConfigError,
  MAX_JWT_SECRET_OVERLAP_DAYS,
  MIN_JWT_SECRET_LENGTH,
  acceptedKeys,
  activeKey,
  loadConfig,
  parseTrustedProxies,
  providerCredentials,
  requireSupabaseJwtPolicy,
} from "../src/config.js";

const base = { SONNY_ENV: "local" } as NodeJS.ProcessEnv;

// Bound to names rather than written inline at each call site, so that no line in this file spells a
// known-secret variable followed by a long literal -- which is the shape `npm run check:secrets`
// refuses, correctly, wherever it appears.
const secret = "a-signing-key-long-enough-to-clear-the-floor";
const overlapSecret = "the-other-signing-key-also-past-the-floor";
const issuer = "https://project-ref.supabase.co/auth/v1";

/** A fixed instant, so every deadline in the overlap tests is a fixed distance from a fixed now. */
const NOW = new Date("2026-09-07T12:00:00.000Z");
const daysFromNow = (days: number): string =>
  new Date(NOW.getTime() + days * 24 * 60 * 60 * 1000).toISOString();

/** The environment of a deployment mid-rotation, before whichever field a test is about is changed. */
const rotating = {
  ...base,
  SUPABASE_JWT_SECRET: secret,
  SUPABASE_JWT_ISSUER: issuer,
  SUPABASE_JWT_SECRET_2: overlapSecret,
  SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: daysFromNow(1),
} as NodeJS.ProcessEnv;

describe("configuration", () => {
  it("refuses to start on an unknown environment rather than guessing one", () => {
    expect(() => loadConfig({ SONNY_ENV: "prod" })).toThrow(ConfigError);
  });

  it("refuses to start with no environment at all", () => {
    expect(() => loadConfig({})).toThrow(ConfigError);
  });

  it("names the offending variable and never echoes a value", () => {
    // An invalid-config error that printed the environment back would put credentials into
    // whatever collects this server's logs.
    try {
      loadConfig({ SONNY_ENV: "local", PORT: "not-a-port", OPENAI_API_KEY: "sk-secret-value" });
      expect.unreachable("should have thrown");
    } catch (error) {
      const message = (error as Error).message;
      expect(message).toContain("PORT");
      expect(message).not.toContain("sk-secret-value");
    }
  });

  it("defaults the port and build id so a bare local run works", () => {
    const config = loadConfig({ ...base });
    expect(config.port).toBe(8080);
    expect(config.buildId).toBe("dev");
    expect(config.environment).toBe("local");
  });
});

describe("provider credentials — two live keys per provider", () => {
  it("reads the primary key alone", () => {
    const found = providerCredentials({ OPENAI_API_KEY: "one" });
    expect(found).toEqual([{ provider: "openai", keys: ["one"] }]);
  });

  it("reads a second live key so one can be retired while the other serves", () => {
    const found = providerCredentials({ OPENAI_API_KEY: "one", OPENAI_API_KEY_2: "two" });
    expect(found[0]?.keys).toEqual(["one", "two"]);
  });

  it("reads beyond two, because the ceiling is the rotation's, not the format's", () => {
    const found = providerCredentials({
      ANTHROPIC_API_KEY: "a",
      ANTHROPIC_API_KEY_2: "b",
      ANTHROPIC_API_KEY_3: "c",
    });
    expect(found[0]?.keys).toEqual(["a", "b", "c"]);
  });

  it("stops at the first gap rather than skipping it", () => {
    // A typo'd _4 with no _3 must not silently become the second credential — that would make a
    // rotation promote a key nobody meant to promote.
    const found = providerCredentials({ TAVILY_API_KEY: "a", TAVILY_API_KEY_4: "typo" });
    expect(found[0]?.keys).toEqual(["a"]);
  });

  it("ignores blank and whitespace-only values", () => {
    const found = providerCredentials({ CEREBRAS_API_KEY: "a", CEREBRAS_API_KEY_2: "   " });
    expect(found[0]?.keys).toEqual(["a"]);
  });

  it("omits a provider entirely when it has no credential", () => {
    expect(providerCredentials({ OPENAI_API_KEY: "a" }).map((c) => c.provider)).toEqual(["openai"]);
  });

  it("survives every step of a zero-downtime rotation with a usable key throughout", () => {
    // The property the ticket actually asks for, walked end to end. Each step is one deploy and
    // each is valid on its own; at no point is there no active key, and the retiring key stays
    // accepted until it is removed.
    const steps: Array<[string, NodeJS.ProcessEnv]> = [
      ["before", { ...base, OPENAI_API_KEY: "old" }],
      ["add new as secondary", { ...base, OPENAI_API_KEY: "old", OPENAI_API_KEY_2: "new" }],
      ["promote new", { ...base, OPENAI_API_KEY: "new", OPENAI_API_KEY_2: "old" }],
      ["retire old", { ...base, OPENAI_API_KEY: "new" }],
    ];
    const active = steps.map(([, env]) => activeKey(loadConfig(env), "openai"));
    expect(active).toEqual(["old", "old", "new", "new"]);
    expect(active.every((key) => key !== undefined)).toBe(true);

    // The old key is still honoured through the overlap, which is what makes the retirement safe.
    expect(acceptedKeys(loadConfig(steps[2]![1]), "openai")).toContain("old");
    expect(acceptedKeys(loadConfig(steps[3]![1]), "openai")).not.toContain("old");
  });

  it("returns undefined rather than throwing for a provider with no credential", () => {
    expect(activeKey(loadConfig({ ...base }), "vision")).toBeUndefined();
    expect(acceptedKeys(loadConfig({ ...base }), "vision")).toEqual([]);
  });

  describe("the Supabase JWT policy", () => {
    // **What replaced `ALLOW_UNAUTHENTICATED_ACCOUNT_DELETE`** (SONNY-203). That flag, its production
    // refusal and the four tests that pinned them are gone with the reason they existed: nothing
    // verified a token, so a destructive route had to be kept off by default. Verification exists
    // now, and these are the variables it needs. The flag's tests are not ported — there is no flag
    // to keep off, which is the outcome that ticket was for.

    it("carries the three values through, defaulting the audience to Supabase's own", () => {
      const config = loadConfig({ ...base, SUPABASE_JWT_SECRET: secret, SUPABASE_JWT_ISSUER: issuer });
      expect(config.supabaseJwtSecret).toBe(secret);
      expect(config.supabaseJwtIssuer).toBe(issuer);
      expect(config.supabaseJwtAudience).toBe("authenticated");
      expect(requireSupabaseJwtPolicy(config)).toEqual({
        secrets: [{ value: secret, acceptedUntil: undefined }],
        issuer,
        audience: "authenticated",
      });
    });

    it("takes a non-default audience when the project uses one", () => {
      const config = loadConfig({
        ...base, SUPABASE_JWT_SECRET: secret, SUPABASE_JWT_ISSUER: issuer,
        SUPABASE_JWT_AUDIENCE: "sonny-users",
      });
      expect(requireSupabaseJwtPolicy(config).audience).toBe("sonny-users");
    });

    it("LOADS without them, because a deployment mounting no authenticated route needs neither", () => {
      // Same split as RATE_LIMIT_SALT: absent is fine at load, and refused at the point of use.
      const config = loadConfig({ ...base });
      expect(config.supabaseJwtSecret).toBeUndefined();
      expect(() => requireSupabaseJwtPolicy(config)).toThrow(ConfigError);
    });

    it("names EVERY missing variable, not the first one", () => {
      // An operator who fixes the named one and restarts to find a second failure has spent a deploy
      // learning something one message could have said.
      try {
        requireSupabaseJwtPolicy(loadConfig({ ...base }));
        expect.unreachable("should have thrown");
      } catch (error) {
        expect((error as Error).message).toContain("SUPABASE_JWT_SECRET");
        expect((error as Error).message).toContain("SUPABASE_JWT_ISSUER");
      }
      expect(() => requireSupabaseJwtPolicy(loadConfig({ ...base, SUPABASE_JWT_ISSUER: issuer })))
        .toThrow(/SUPABASE_JWT_SECRET/);
    });

    it("refuses a secret short enough to guess, and reports the length without the value", () => {
      // Anyone holding this secret can MINT a token for any user, so a guessable one is a forgery
      // key rather than a weak password. Supabase's own is far longer than the floor.
      const short = "0123456789abcdef";
      try {
        requireSupabaseJwtPolicy(
          loadConfig({ ...base, SUPABASE_JWT_SECRET: short, SUPABASE_JWT_ISSUER: issuer }),
        );
        expect.unreachable("should have thrown");
      } catch (error) {
        const message = (error as Error).message;
        expect(message).toContain(String(MIN_JWT_SECRET_LENGTH));
        expect(message).toContain("16 characters");
        expect(message).not.toContain(short);
      }
      // One character under the floor is refused; the floor itself is not.
      const floor = "x".repeat(MIN_JWT_SECRET_LENGTH);
      expect(() => requireSupabaseJwtPolicy(
        loadConfig({ ...base, SUPABASE_JWT_SECRET: floor.slice(1), SUPABASE_JWT_ISSUER: issuer }),
      )).toThrow(ConfigError);
      expect(requireSupabaseJwtPolicy(
        loadConfig({ ...base, SUPABASE_JWT_SECRET: floor, SUPABASE_JWT_ISSUER: issuer }),
      ).secrets[0]!.value).toBe(floor);
    });

    it("refuses an issuer that is not a URL, and says so with the value", () => {
      // The issuer is a public URL naming the project, not a secret — and a mismatch is otherwise
      // invisible, since every token verifies against the secret and is then refused. That reads as
      // "all my users are signed out" rather than as a typo in one variable.
      for (const bad of ["project-ref", "project-ref.supabase.co", "/auth/v1", "ftp://x/auth"]) {
        expect(() => requireSupabaseJwtPolicy(
          loadConfig({ ...base, SUPABASE_JWT_SECRET: secret, SUPABASE_JWT_ISSUER: bad }),
        )).toThrow(ConfigError);
      }
      expect(() => requireSupabaseJwtPolicy(
        loadConfig({ ...base, SUPABASE_JWT_SECRET: secret, SUPABASE_JWT_ISSUER: "project-ref" }),
      )).toThrow(/project-ref/);
    });

    it("accepts the local Supabase's http issuer, so development is not forced onto https", () => {
      const local = "http://127.0.0.1:54321/auth/v1";
      expect(requireSupabaseJwtPolicy(
        loadConfig({ ...base, SUPABASE_JWT_SECRET: secret, SUPABASE_JWT_ISSUER: local }),
      ).issuer).toBe(local);
    });

    it("refuses an empty or whitespace-only value rather than treating it as absent", () => {
      for (const blank of ["", "   "]) {
        expect(() => loadConfig({ ...base, SUPABASE_JWT_SECRET: blank, SUPABASE_JWT_ISSUER: issuer }))
          .toThrow(ConfigError);
        expect(() => loadConfig({ ...base, SUPABASE_JWT_SECRET: secret, SUPABASE_JWT_AUDIENCE: blank }))
          .toThrow(ConfigError);
      }
    });
  });

  describe("rotating the JWT secret with an overlap (SONNY-238)", () => {
    // **What this is for.** A Supabase access token is verified locally against
    // `SUPABASE_JWT_SECRET`, so replacing that value used to invalidate every token signed with the
    // old one at the instant the new one deployed -- every signed-in user signed out, with no
    // overlap. One slot fixes that, and the whole risk of the fix is that the slot is a second key
    // able to mint a token for any user. So the tests below come in two halves: the rotation works,
    // and the slot cannot be a permanent second key.

    it("walks the three deploys of a rotation, with a usable secret at every one", () => {
      // The mirror of the provider-credential walk above, and the direction is opposite: a provider
      // key is one this gateway SENDS, so that list is "what to try", while this is one Supabase
      // signs with and this gateway only verifies, so this list is "what to accept". The overlap
      // therefore has to straddle the moment Supabase's own value changes -- which is why the slot
      // holds the INCOMING secret at step 1 and the RETIRING one at step 2.
      const incoming = overlapSecret;
      const steps: readonly (readonly [string, NodeJS.ProcessEnv])[] = [
        ["1 — accept the incoming secret before Supabase signs with it", {
          ...base, SUPABASE_JWT_ISSUER: issuer,
          SUPABASE_JWT_SECRET: secret,
          SUPABASE_JWT_SECRET_2: incoming,
          SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: daysFromNow(2),
        }],
        ["2 — Supabase has switched; keep accepting the retiring one", {
          ...base, SUPABASE_JWT_ISSUER: issuer,
          SUPABASE_JWT_SECRET: incoming,
          SUPABASE_JWT_SECRET_2: secret,
          SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: daysFromNow(2),
        }],
        ["3 — the overlap is removed", {
          ...base, SUPABASE_JWT_ISSUER: issuer,
          SUPABASE_JWT_SECRET: incoming,
        }],
      ];

      const accepted = steps.map(([, env]) =>
        requireSupabaseJwtPolicy(loadConfig(env), NOW).secrets.map((entry) => entry.value));

      // Step 1 accepts both, so no token minted before the switch is refused.
      expect(accepted[0]).toEqual([secret, incoming]);
      // Step 2 accepts both, so no token minted before the switch is refused HERE either -- which is
      // the deploy the whole overlap exists for.
      expect(accepted[1]).toEqual([incoming, secret]);
      // Step 3 has retired it, and only then.
      expect(accepted[2]).toEqual([incoming]);
      // Every step has a usable secret, which is the property the three-deploy shape buys.
      for (const values of accepted) expect(values.length).toBeGreaterThan(0);
    });

    it("gives the overlap slot an end and the current secret none", () => {
      // The asymmetry is the whole mechanism: an end on the current secret would be a date after
      // which this gateway refuses every token, which is the outage an overlap exists to prevent.
      const policy = requireSupabaseJwtPolicy(loadConfig(rotating), NOW);
      expect(policy.secrets).toHaveLength(2);
      expect(policy.secrets[0]).toEqual({ value: secret, acceptedUntil: undefined });
      expect(policy.secrets[1]!.value).toBe(overlapSecret);
      expect(policy.secrets[1]!.acceptedUntil).toEqual(new Date(daysFromNow(1)));
    });

    it("refuses an overlap secret with no end, because that is a permanent second key", () => {
      // The founders decided on 2026-08-30 that a retired secret gets a stated maximum overlap, on
      // the ground that "left in the environment and forgotten" is indistinguishable from never
      // having rotated. An unbounded slot is exactly that state.
      const { SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: _drop, ...noDeadline } = rotating;
      expect(() => requireSupabaseJwtPolicy(loadConfig(noDeadline), NOW)).toThrow(ConfigError);
      expect(() => requireSupabaseJwtPolicy(loadConfig(noDeadline), NOW))
        .toThrow(/SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL/);
    });

    it("refuses a deadline that names no secret, and says which half is missing", () => {
      // A half-applied rotation deploy is how one of these arrives alone, and which half is missing
      // decides what the operator does next -- so the two messages are different rather than one
      // message saying "one of these is wrong".
      const { SUPABASE_JWT_SECRET_2: _drop, ...noSecret } = rotating;
      expect(() => requireSupabaseJwtPolicy(loadConfig(noSecret), NOW)).toThrow(ConfigError);
      expect(() => requireSupabaseJwtPolicy(loadConfig(noSecret), NOW))
        .toThrow(/SUPABASE_JWT_SECRET_2 is not/);
    });

    it("refuses a deadline further away than the stated maximum, and never echoes the secret", () => {
      const tooFar = {
        ...rotating,
        SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: daysFromNow(MAX_JWT_SECRET_OVERLAP_DAYS + 1),
      };
      try {
        requireSupabaseJwtPolicy(loadConfig(tooFar), NOW);
        expect.unreachable("should have thrown");
      } catch (error) {
        const message = (error as Error).message;
        expect(message).toContain(String(MAX_JWT_SECRET_OVERLAP_DAYS));
        // A date is not a secret and is reported; the secrets are not.
        expect(message).not.toContain(overlapSecret);
        expect(message).not.toContain(secret);
      }
      // The boundary itself is accepted, so the maximum is a maximum rather than an exclusive bound.
      const atTheLimit = {
        ...rotating,
        SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: daysFromNow(MAX_JWT_SECRET_OVERLAP_DAYS),
      };
      expect(requireSupabaseJwtPolicy(loadConfig(atTheLimit), NOW).secrets).toHaveLength(2);
    });

    it("keeps a deadline already past rather than refusing to start on it", () => {
      // **The direction here is deliberate and is the opposite of the one above.** Refusing to boot
      // on leftover bookkeeping would turn it into every user being signed out -- the exact failure
      // this slot exists to avoid -- and it would buy nothing, because a secret past its instant
      // authorises nothing: `verifyAccessToken` skips it. `token.test.ts` is where that is asserted.
      const finished = { ...rotating, SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: daysFromNow(-1) };
      const policy = requireSupabaseJwtPolicy(loadConfig(finished), NOW);
      expect(policy.secrets).toHaveLength(2);
      expect(policy.secrets[1]!.acceptedUntil!.getTime()).toBeLessThan(NOW.getTime());
    });

    it("accepts only an ISO-8601 instant carrying an offset, and refuses the rest with the value", () => {
      // **Three of these were accepted and the refusal message said they were not** (PR #218's F3).
      // `new Date("2026")` is the first instant of that year, so a bare year in the past booted clean
      // with the slot never accepted -- an overlap dead on arrival. `Sep 8 2026` parsed. Worst of the
      // three, a ZONE-LESS spelling is read in the process's local zone, so the same string means a
      // different instant on a host west of UTC than east of it, moving the end of a second signing
      // key's life by the host's offset -- on the one variable whose whole job is to bound that.
      for (const bad of [
        "2026",                     // a bare year: accepted before, as 1 January
        "2026-09-08T00:00:00",      // zone-less: read in whatever zone the container runs in
        "Sep 8 2026",               // not ISO-8601 by any reading, and parsed before
        "2026-09-08",               // a date with no time
        "20260908T000000Z",         // basic format, which the date parser rejects anyway
        "nonsense", "next tuesday", "14/09/2026",
      ]) {
        expect(() => requireSupabaseJwtPolicy(
          loadConfig({ ...rotating, SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: bad }), NOW,
        ), bad).toThrow(/must be an ISO-8601 instant carrying an offset/);
        // The value IS reported, unlike a secret: a deadline is a date, and one nobody can see is
        // one nobody can fix.
        expect(() => requireSupabaseJwtPolicy(
          loadConfig({ ...rotating, SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: bad }), NOW,
        ), bad).toThrow(new RegExp(bad.replace(/[/\\]/g, "\\$&")));
      }

      // **The accepted forms, which are what every example in `.env.example`, the README table and
      // the runbook now spell.** Without these the refusals above would pass just as well from a
      // parser that refused everything.
      const accepted: readonly (readonly [string, string])[] = [
        ["2026-09-08T00:00:00Z", "2026-09-08T00:00:00.000Z"],
        ["2026-09-08T00:00:00-04:00", "2026-09-08T04:00:00.000Z"],
        ["2026-09-08T00:00:00+05:30", "2026-09-07T18:30:00.000Z"],
        ["2026-09-08T00:00:00.500Z", "2026-09-08T00:00:00.500Z"],
      ];
      for (const [written, instant] of accepted) {
        const policy = requireSupabaseJwtPolicy(
          loadConfig({ ...rotating, SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: written }), NOW,
        );
        expect(policy.secrets[1]!.acceptedUntil!.toISOString(), written).toBe(instant);
      }
    });

    it("refuses a spelling that is shaped like an instant and names no moment", () => {
      // **The gap the shape check opened, found by its own battery** (PR #218, round 1's R8). Before
      // the shape check, everything unparseable reached the `NaN` branch and a test driving
      // `"nonsense"` covered it. Afterwards the shape check refuses all of those first, so the `NaN`
      // branch is reachable only by a spelling that is well-formed and still names no moment — a
      // month of 13, an hour of 25 — and nothing drove one. The mutant neutralising that branch
      // survived the whole suite. It is the branch that matters most if it ever goes: an Invalid
      // Date compares false against everything, so an unchecked one reads as "not yet reached"
      // forever, which is an overlap with no end.
      for (const bad of ["2026-13-01T00:00:00Z", "2026-09-08T25:00:00Z", "2026-00-01T00:00:00Z"]) {
        // Shape-valid, so this is the second message and not the first — asserted by wording,
        // because a test that only checks `ConfigError` cannot tell the two refusals apart and a
        // mutant that swaps one for the other would pass.
        expect(() => requireSupabaseJwtPolicy(
          loadConfig({ ...rotating, SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: bad }), NOW,
        ), bad).toThrow(/is shaped like an instant but is not one/);
      }
      // The control: a spelling that is NOT shaped like an instant reaches the first message
      // instead, so the two branches are distinguished rather than merely both throwing.
      expect(() => requireSupabaseJwtPolicy(
        loadConfig({ ...rotating, SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: "nonsense" }), NOW,
      )).toThrow(/must be an ISO-8601 instant carrying an offset/);
    });

    it("refuses a day past the end of its month rather than rolling it forward", () => {
      // ECMAScript's own ISO parser absorbs a day-of-month overflow: `new Date("2026-02-30T00:00:00Z")`
      // is 2 March. The shape check cannot see it -- `30` is two digits -- so the written digits are
      // compared against the parsed fields. Same family as the zone-less case above: the operator
      // wrote one instant and the bound became another, with nothing saying so.
      for (const bad of ["2026-02-30T00:00:00Z", "2026-02-30T00:00:00+05:30", "2026-04-31T00:00:00Z"]) {
        // By wording, not merely by type: these are shape-valid and parseable, so `ConfigError`
        // alone cannot tell this refusal from the two above it.
        expect(() => requireSupabaseJwtPolicy(
          loadConfig({ ...rotating, SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: bad }), NOW,
        ), bad).toThrow(/names a date that does not exist/);
      }
      // The controls: the last real day of each of those months is accepted, so the check is about
      // the overflow and not about February or about a `30`.
      for (const good of ["2026-02-28T00:00:00Z", "2026-04-30T00:00:00Z", "2026-03-30T00:00:00Z"]) {
        expect(() => requireSupabaseJwtPolicy(
          loadConfig({ ...rotating, SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: good }), NOW,
        ), good).not.toThrow();
      }
      // And an offset that carries the instant into the NEXT UTC day is still the written day, so
      // the comparison is against what was typed rather than against the UTC reading of it.
      expect(requireSupabaseJwtPolicy(
        loadConfig({ ...rotating, SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: "2026-09-08T23:00:00-04:00" }),
        NOW,
      ).secrets[1]!.acceptedUntil!.toISOString()).toBe("2026-09-09T03:00:00.000Z");
    });

    it("refuses the same value in both slots, which reads as an overlap and is not one", () => {
      expect(() => requireSupabaseJwtPolicy(
        loadConfig({ ...rotating, SUPABASE_JWT_SECRET_2: secret }), NOW,
      )).toThrow(ConfigError);
    });

    it("holds the overlap secret to the same length floor as the current one", () => {
      // The ticket's own words: a rotation that quietly relaxed a check for the second key would be
      // worse than the sign-out it avoids. The floor is the check a second slot could most easily
      // have skipped, because nothing else in the file would have noticed.
      const short = "0123456789abcdef";
      try {
        requireSupabaseJwtPolicy(loadConfig({ ...rotating, SUPABASE_JWT_SECRET_2: short }), NOW);
        expect.unreachable("should have thrown");
      } catch (error) {
        const message = (error as Error).message;
        expect(message).toContain("SUPABASE_JWT_SECRET_2");
        expect(message).toContain(String(MIN_JWT_SECRET_LENGTH));
        expect(message).not.toContain(short);
      }
    });

    it("refuses a numbered slot nothing reads, rather than ignoring it", () => {
      // **Where this departs from `providerCredentials` above, and why.** That function stops at the
      // first gap in silence, and a skipped provider key costs a credential to try. A skipped
      // VERIFYING secret means every token signed with it is refused -- the sign-out this whole
      // feature exists to prevent, reached through the fix for it, and reached silently.
      // **`_02` and `_002` are in this loop because they were not, and passed** (PR #218's F1). The
      // guard compared `Number(match[1])` to the slot number, and `Number("02") === 2`, so a
      // zero-padded spelling read as "the slot we read" while the Zod schema reads the literal name
      // and nothing else: set, unread, and unreported. Zero-padding an index is an ordinary thing to
      // write in a compose file, and the comparison is textual now.
      for (const name of [
        "SUPABASE_JWT_SECRET_1", "SUPABASE_JWT_SECRET_3", "SUPABASE_JWT_SECRET_4",
        "SUPABASE_JWT_SECRET_02", "SUPABASE_JWT_SECRET_002", "SUPABASE_JWT_SECRET_20",
      ]) {
        expect(() => loadConfig({ ...rotating, [name]: overlapSecret })).toThrow(ConfigError);
        expect(() => loadConfig({ ...rotating, [name]: overlapSecret })).toThrow(new RegExp(name));
      }
      // The two names this gateway DOES read are the control: without them the refusal above would
      // pass just as well from a function that refused everything.
      expect(() => loadConfig(rotating)).not.toThrow();
      // **And the deadline is not a numbered slot, though its name begins with one.** This line was
      // `loadConfig({ ...rotating })` — a shallow copy of the line above it, so it re-ran that check
      // and asserted nothing about the property the comment names (PR #218's R5). The deadline is
      // spelled out here rather than relied on through `rotating`, so removing it from that fixture
      // cannot quietly empty this assertion.
      expect(() => loadConfig({
        ...base,
        SUPABASE_JWT_SECRET: secret,
        SUPABASE_JWT_ISSUER: issuer,
        SUPABASE_JWT_SECRET_2: overlapSecret,
        SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL: daysFromNow(1),
      })).not.toThrow();
    });

    it("is silent about an unread slot that is set to nothing", () => {
      // An empty value is nobody setting the variable -- a compose file with a blank line, an unset
      // shell variable expanded into an env block -- and refusing it would refuse a deployment that
      // has done nothing wrong.
      expect(() => loadConfig({ ...rotating, SUPABASE_JWT_SECRET_3: "" })).not.toThrow();
      expect(() => loadConfig({ ...rotating, SUPABASE_JWT_SECRET_3: "   " })).not.toThrow();
    });

    it("loads and starts with no rotation in flight, which is the ordinary shape", () => {
      const policy = requireSupabaseJwtPolicy(
        loadConfig({ ...base, SUPABASE_JWT_SECRET: secret, SUPABASE_JWT_ISSUER: issuer }), NOW,
      );
      expect(policy.secrets).toEqual([{ value: secret, acceptedUntil: undefined }]);
    });
  });

  describe("TRUSTED_PROXIES", () => {
    // **PR #87 third round, F5.** Nothing validated these entries, so a typo reached
    // `@fastify/proxy-addr`'s `compile()` and threw a raw third-party `TypeError` **inside the
    // `Fastify(...)` constructor** — before `app.ready()`, before this server's logger exists, and
    // naming library internals rather than the variable that is wrong. The gateway would not start
    // and the log did not say why, which is the exact opposite of what this file exists to
    // guarantee: a bad environment is a named `ConfigError` identifying the variable.

    it("accepts addresses, CIDR ranges and Fastify's named sets", () => {
      expect(parseTrustedProxies("10.0.0.0/8, 172.16.0.0/12")).toEqual(["10.0.0.0/8", "172.16.0.0/12"]);
      expect(parseTrustedProxies("192.168.1.1")).toEqual(["192.168.1.1"]);
      expect(parseTrustedProxies("::1")).toEqual(["::1"]);
      expect(parseTrustedProxies("2001:db8::/32")).toEqual(["2001:db8::/32"]);
      // Named sets are `proxy-addr`'s own documented shorthand; refusing them would make this
      // validation narrower than the thing it validates for.
      expect(parseTrustedProxies("loopback,uniquelocal")).toEqual(["loopback", "uniquelocal"]);
    });

    it("still means trust-nothing when empty, as `false` rather than an empty array", () => {
      expect(parseTrustedProxies("")).toBe(false);
      expect(parseTrustedProxies("   ")).toBe(false);
      expect(loadConfig({ ...base }).trustProxy).toBe(false);
    });

    it("refuses a malformed entry with a ConfigError that NAMES it", () => {
      // Naming the entry is the point: there is no fixing a list without knowing which element is
      // bad, and a proxy address — unlike every other value this file refuses to echo — is not a
      // secret.
      expect(() => parseTrustedProxies("10.0.0.0/8,not-an-ip")).toThrow(ConfigError);
      expect(() => parseTrustedProxies("10.0.0.0/8,not-an-ip")).toThrow(/not-an-ip/);
      expect(() => parseTrustedProxies("10.0.0.0/8,not-an-ip")).toThrow(/TRUSTED_PROXIES/);
    });

    it("refuses a /0 prefix, which is how someone writes trust-everything", () => {
      // **PR #87 sixth round.** `@fastify/proxy-addr` refuses a full-range prefix, so `/0` passed
      // this validator and then threw `TypeError: invalid range on address: 0.0.0.0/0` inside the
      // `Fastify(...)` constructor — the exact failure this validator exists to prevent, reached
      // through the validator itself. And it is not an exotic typo: `/0` is what an operator writes
      // when they are looking for the old boolean `true`.
      for (const entry of ["0.0.0.0/0", "10.0.0.0/0", "1.2.3.4/0", "::/0", "::1/0", "fe80::/0", "0.0.0.0/00"]) {
        expect(() => parseTrustedProxies(entry), entry).toThrow(ConfigError);
      }
      // The message has to say why, or the operator retries the same idea in another spelling.
      expect(() => parseTrustedProxies("0.0.0.0/0")).toThrow(/trust every proxy/);
      // Everything adjacent still compiles — this is a refusal of /0, not of small prefixes.
      expect(parseTrustedProxies("0.0.0.0/1")).toEqual(["0.0.0.0/1"]);
      expect(parseTrustedProxies("::/1")).toEqual(["::/1"]);
      expect(parseTrustedProxies("10.0.0.0/008")).toEqual(["10.0.0.0/008"]);
    });

    it("accepts NOTHING that Fastify itself cannot compile", async () => {
      // **The assertion that catches this class without knowing which entry is the problem.** The
      // `/0` test above pins the case we now know about; this one pins the *property* — whatever
      // this validator lets through, `proxy-addr`'s `compile()` must accept, and that runs inside
      // the `Fastify(...)` constructor where a throw is unreachable by any error handler.
      //
      // Written as "for each candidate: if the validator accepts it, the app must build" rather
      // than as a list of known-good values. That is the difference between a test that confirms
      // what we already fixed and one that would have found it: relaxing the validator makes a
      // candidate below start passing, and then the build throws and this fails.
      const { buildApp } = await import("../src/app.js");
      const candidates = [
        "10.0.0.0/8,172.16.0.0/12", "192.168.1.1", "::1", "2001:db8::/32", "loopback,uniquelocal",
        "0.0.0.0/1", "10.0.0.0/008",
        // The shapes a looser validator would start admitting. Each is currently refused; if any
        // stops being refused, it has to be one Fastify can compile.
        "0.0.0.0/0", "10.0.0.0/0", "::/0", "fe80::/0", "0.0.0.0/00",
        "10.0.0.0/64", "10.0.0.0/abc", "not-an-ip", "10.0.0.0/",
      ];
      let accepted = 0;
      for (const raw of candidates) {
        let parsed;
        try {
          parsed = loadConfig({ SONNY_ENV: "local", TRUSTED_PROXIES: raw });
        } catch {
          continue;                       // refused by the validator, which is a fine outcome
        }
        accepted += 1;
        expect(() => buildApp(parsed), raw).not.toThrow();
      }
      // And the loop is not vacuous: some of them really do get through.
      expect(accepted).toBe(7);
    });

    it("refuses a prefix that is not a prefix for that address family", () => {
      // `10.0.0.0/64` is not a v4 network, and `proxy-addr` would say so at a moment nobody is
      // watching. Both families are checked against their own width rather than one shared bound.
      expect(() => parseTrustedProxies("10.0.0.0/64")).toThrow(ConfigError);
      expect(() => parseTrustedProxies("10.0.0.0/abc")).toThrow(ConfigError);
      expect(() => parseTrustedProxies("10.0.0.0/")).toThrow(ConfigError);
      expect(parseTrustedProxies("2001:db8::/64")).toEqual(["2001:db8::/64"]);
    });

    it("fails at loadConfig, so a bad value is a startup refusal rather than a crash later", () => {
      expect(() => loadConfig({ ...base, TRUSTED_PROXIES: "10.0.0.0/8,garbage" })).toThrow(ConfigError);
      // The whole hazard was the failure arriving from somewhere else entirely. This asserts the
      // error is ours, by type and by the variable it names.
      expect(() => loadConfig({ ...base, TRUSTED_PROXIES: "garbage" })).toThrow(/TRUSTED_PROXIES/);
    });
  });
});
