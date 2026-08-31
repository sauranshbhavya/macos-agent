import { generateKeyPairSync } from "node:crypto";
import { providers, type Config } from "../../src/config.js";
import { DEFAULT_ROUTE_CHAINS, UNVERIFIED_DATA_POLICY } from "../../src/model/provider-router.js";
import { TEST_CREDIT_PLANS } from "./credit.js";
import { TEST_SUPABASE_CONFIG } from "./tokens.js";

/**
 * One Ed25519 key per test process, in the encoded form `Config` carries.
 *
 * **Bound to a name that does not spell the variable it fills**, exactly as `authdeps.test.ts` and
 * `config.test.ts` do and for their stated reason: a line spelling a known-secret variable followed
 * by a long literal is the shape `npm run check:secrets` refuses, correctly, wherever it appears —
 * and it refuses a *generated* value the same way it would refuse a real one, because the scanner
 * reads the source and not the runtime. The first spelling of this line was a finding.
 */
const TEST_SIGNING_KEY = generateKeyPairSync("ed25519")
  .privateKey.export({ type: "pkcs8", format: "der" })
  .toString("base64");

/**
 * One `Config` for every test that builds an app, replacing five hand-written copies (SONNY-130).
 *
 * The copies were identical apart from `databaseUrl` and a `buildId`, and they were five places to
 * edit every time `Config` grew a field — which is exactly what happened when this ticket added the
 * model routes' endpoint and model settings: five files failed to typecheck for a reason none of
 * them was about. A test fixture that has to be edited by every unrelated ticket is a fixture that
 * eventually gets edited wrong.
 *
 * `Partial<Config>` overrides rather than named parameters, because what a test needs to vary is
 * unpredictable and the alternative is a parameter list that grows the same way the copies did.
 *
 * **The next unrelated ticket arrived while this file was still the newest thing in the tree, and it
 * proved the point twice over** (SONNY-307, rebasing onto SONNY-130). That ticket added two more
 * `Config` fields and renamed the constant spread below — `TEST_JWT_CONFIG` became
 * `TEST_SUPABASE_CONFIG`, because it had stopped being only about JWTs. Before this file existed
 * that rename cost five edits; with it, one. **And the two branches merged clean and did not
 * compile**: this file and `tokens.ts` never conflicted, because each side touched a different one,
 * so nothing in the rebase's conflict list pointed at the import that had stopped resolving. What
 * caught it was `npm run typecheck` — **`npm run build` exits 0 on that tree**, since `tsconfig.json`
 * includes only sources under `src` and nothing under `test`. (Written without the glob: the glob
 * ends in a star-slash, which closes this comment and deletes the rest of the file from the
 * compiler's view — `CLAUDE.md` records the same trap on the Swift side.) That is the server
 * half's version of the trap
 * `CLAUDE.md` records from PR #111, and it is why a rebase runs the typecheck and the suite rather
 * than reading the conflict list.
 */
export function testConfig(overrides: Partial<Config> = {}): Config {
  return {
    environment: "local",
    port: 0,
    host: "127.0.0.1",
    buildId: "test-build-1",
    databaseUrl: undefined,
    logLevel: "fatal",
    trustProxy: false,
    rateLimitSalt: "test-salt",
    // The shipped defaults, so a test that says nothing about retention gets the retention a
    // deployment that says nothing about it gets. A test that cares about the clock overrides them.
    contentRetentionDays: 30,
    contentExpirySweepSeconds: 3600,
    // SONNY-211. Billing is off in the default test config, which is the shape of a deployment that
    // takes no payments: naming no provider mounts no webhook route. `billing.test.ts` overrides
    // these to mount it, so a test that says nothing about billing gets a server without one.
    billingProvider: undefined,
    billingWebhookSecret: undefined,
    billingCheckoutUrl: undefined,
    billingProviderAccessToken: undefined,
    billingApiBaseUrl: undefined,
    billingPlans: "",
    billingGraceDays: 14,
    // SONNY-135. A key per process rather than a literal — `support/entitlement.ts` says why a
    // signing key is the one fixture this suite generates instead of writing down. The `Config`
    // carries the encoded form; `requireEntitlementSigningKey` is what turns it into a key object,
    // so a test that builds an app exercises that parse rather than stepping around it.
    entitlementSigningKey: TEST_SIGNING_KEY,
    entitlementSigningKeyId: "test-key-1",
    // A cap high enough that no test meets it by accident; the tests that are *about* the cap set
    // their own. A number here is a test fixture and not an allowance — `config.ts` carries the
    // distinction, and SONNY-212 owns the real ones.
    spendCapUnits: 1_000_000,
    // SONNY-212. Fixture numbers, not allowances -- `support/credit.ts` says why, and it is the same
    // distinction the cap above carries. A test that is *about* the catalogue builds its own.
    creditPlans: TEST_CREDIT_PLANS,
    ...TEST_SUPABASE_CONFIG,
    openAIBaseUrl: "https://openai.invalid/v1",
    openAITextModel: "test-text-model",
    openAITranscriptionModel: "test-transcription-model",
    searchBaseUrl: "https://search.invalid",
    visionBaseUrl: "https://vision.invalid/v1",
    visionModel: "test-vision-model",
    anthropicBaseUrl: "https://anthropic.invalid/v1",
    anthropicTextModel: "test-anthropic-model",
    anthropicMaxOutputTokens: 4096,
    cerebrasBaseUrl: "https://cerebras.invalid/v1",
    cerebrasTextModel: "test-cerebras-model",
    // The shipped defaults, so a test that says nothing about routing gets the routing a
    // deployment that says nothing about routing gets. A test that cares overrides `routeChains`.
    routeChains: DEFAULT_ROUTE_CHAINS,
    dataPolicies: Object.fromEntries(
      providers.map((provider) => [provider, UNVERIFIED_DATA_POLICY]),
    ) as Config["dataPolicies"],
    credentials: [],
    ...overrides,
  };
}
