import { providers, type Config } from "../../src/config.js";
import { DEFAULT_ROUTE_CHAINS, UNVERIFIED_DATA_POLICY } from "../../src/model/provider-router.js";
import { TEST_SUPABASE_CONFIG } from "./tokens.js";

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
