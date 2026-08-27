import type { Config } from "../../src/config.js";
import { TEST_JWT_CONFIG } from "./tokens.js";

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
    ...TEST_JWT_CONFIG,
    openAIBaseUrl: "https://openai.invalid/v1",
    openAITextModel: "test-text-model",
    openAITranscriptionModel: "test-transcription-model",
    searchBaseUrl: "https://search.invalid",
    credentials: [],
    ...overrides,
  };
}
