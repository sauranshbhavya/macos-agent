import { z } from "zod";

/**
 * Environment → typed configuration, validated once at startup.
 *
 * Two properties this file exists to guarantee, both of which the ticket names:
 *
 * 1. **No credential is ever read from anywhere but the process environment.** There is no
 *    config file, no default value for any secret, and no fallback. A missing credential is a
 *    startup failure with a named variable, not a server that runs and fails on the first real
 *    request.
 * 2. **Every provider supports two live credentials at once**, so one can be retired while the
 *    other serves. See `providerCredentials` below for why that is a list rather than a pair of
 *    named fields.
 */

/** The three places this server runs. Orthogonal to *which host* carries them (see README). */
export const environments = ["local", "staging", "production"] as const;
export type Environment = (typeof environments)[number];

/** The providers whose credentials this gateway holds. From row 12's plan §4.4. */
export const providers = ["openai", "anthropic", "cerebras", "tavily", "vision"] as const;
export type Provider = (typeof providers)[number];

/**
 * Credentials for one provider, newest first.
 *
 * **A list rather than `primary`/`secondary`, and the reason is the rotation itself.** With two
 * named fields, retiring the primary means editing two variables in one step — the new key into
 * `primary` and the old one into `secondary` — and any deploy that catches those half-applied has
 * either a duplicated key or a missing one. With an ordered list the rotation is three independent
 * deploys, each valid on its own: add the new key at position 2, promote it to position 1, drop the
 * old one. At no point is the server without a working credential, which is what "no downtime"
 * actually requires.
 *
 * Index 0 is the credential used for new requests. Later entries stay accepted so in-flight work
 * and any provider-side caching keyed to the old credential keep working through the overlap.
 */
export interface ProviderCredentials {
  readonly provider: Provider;
  readonly keys: readonly string[];
}

const nonEmpty = z.string().trim().min(1);

const schema = z.object({
  SONNY_ENV: z.enum(environments),
  PORT: z.coerce.number().int().min(1).max(65535).default(8080),
  HOST: nonEmpty.default("0.0.0.0"),
  /** Build identifier surfaced by GET /v1/health. Injected at image build time. */
  SONNY_BUILD_ID: nonEmpty.default("dev"),
  /** Postgres connection string. Supabase's, per the 2026-08-21 decision. */
  DATABASE_URL: nonEmpty.optional(),
  LOG_LEVEL: z.enum(["fatal", "error", "warn", "info", "debug", "trace"]).default("info"),
  /**
   * Whether to believe `X-Forwarded-*`. Defaults to false: those headers are caller-supplied, so
   * trusting them with nothing in front of the container lets a client choose its own apparent IP.
   * Set only where a proxy really terminates the connection.
   */
  TRUST_PROXY: z.enum(["true", "false"]).default("false"),
});

export interface Config {
  readonly environment: Environment;
  readonly port: number;
  readonly host: string;
  readonly buildId: string;
  readonly databaseUrl: string | undefined;
  readonly logLevel: z.infer<typeof schema>["LOG_LEVEL"];
  readonly trustProxy: boolean;
  readonly credentials: readonly ProviderCredentials[];
}

/**
 * Reads `<PROVIDER>_API_KEY` and `<PROVIDER>_API_KEY_2`, `_3`, … in order, stopping at the first
 * gap. Stopping at a gap rather than scanning a fixed range is deliberate: a typo'd `_4` with no
 * `_3` present should not silently become the second credential.
 *
 * Absent entirely is allowed and yields no entry for that provider. **This ticket builds no route
 * that calls a provider**, so requiring all five here would make the server unstartable for no
 * reason; the ticket that adds a provider route is where its credential becomes mandatory.
 */
export function providerCredentials(env: NodeJS.ProcessEnv): readonly ProviderCredentials[] {
  return providers
    .map((provider) => {
      const prefix = provider.toUpperCase();
      const keys: string[] = [];
      for (let index = 1; ; index += 1) {
        const name = index === 1 ? `${prefix}_API_KEY` : `${prefix}_API_KEY_${index}`;
        const value = env[name]?.trim();
        if (!value) break;
        keys.push(value);
      }
      return { provider, keys } as const;
    })
    .filter((entry) => entry.keys.length > 0);
}

export class ConfigError extends Error {}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    // **Built from the variable name and the issue CODE, never from `issue.message`.**
    //
    // This is narrower than it first looks, and the first version of this file got it wrong.
    // Zod's message is safe for most issue kinds, but `invalid_enum_value` renders as
    // `Invalid enum value. Expected 'local' | 'staging' | 'production', received 'sk-abc...'` --
    // it quotes the value back. So a credential pasted into an enum-typed variable by mistake
    // would land in whatever collects this server's logs, at startup, in plain text. Since the
    // set of issue kinds Zod can produce grows with Zod, the rule is that no rendered message is
    // used at all rather than that the unsafe ones are filtered.
    const problems = parsed.error.issues
      .map((issue) => `${issue.path.join(".") || "(root)"} (${issue.code})`)
      .join("; ");
    throw new ConfigError(
      `invalid environment configuration -- ${problems}. ` +
        `Values are omitted deliberately; see server/.env.example for the expected shape.`,
    );
  }
  const value = parsed.data;
  return {
    environment: value.SONNY_ENV,
    port: value.PORT,
    host: value.HOST,
    buildId: value.SONNY_BUILD_ID,
    databaseUrl: value.DATABASE_URL,
    logLevel: value.LOG_LEVEL,
    trustProxy: value.TRUST_PROXY === "true",
    credentials: providerCredentials(env),
  };
}

/** The credential new requests use. `undefined` when the provider has none configured. */
export function activeKey(config: Config, provider: Provider): string | undefined {
  return config.credentials.find((entry) => entry.provider === provider)?.keys[0];
}

/** Every credential still honoured for `provider`, newest first. */
export function acceptedKeys(config: Config, provider: Provider): readonly string[] {
  return config.credentials.find((entry) => entry.provider === provider)?.keys ?? [];
}
