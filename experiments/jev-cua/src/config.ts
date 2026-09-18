import { z } from "zod";

/**
 * Everything the run reads from the environment, validated once. Keys are read here and handed
 * to the two clients; nothing else in the tree touches `process.env` for a credential.
 */
const schema = z.object({
  TYPESAFE_API_KEY: z.string().min(1, "TYPESAFE_API_KEY is required (https://typesafe.ai)"),
  TYPESAFE_MODEL: z.string().min(1).default("jev-latest"),
  OPENAI_API_KEY: z.string().min(1, "OPENAI_API_KEY is required"),
  OPENAI_BASE_URL: z.string().url().optional(),
  COORDINATOR_MODEL: z.string().min(1).default("gpt-5.6-luna"),
  TEXT_MODEL: z.string().min(1).default("gpt-5.5"),
  /** Hard ceiling on driver actions per run; the coordinator's own budget sits inside it. */
  MAX_ACTIONS: z.coerce.number().int().positive().default(60),
  MAX_COORDINATOR_TURNS: z.coerce.number().int().positive().default(12),
  /** Jev's operation confidence below which the executor asks the coordinator instead of acting. */
  MIN_OPERATION_CONFIDENCE: z.coerce.number().min(0).max(1).default(0.35),
  /** Where run reports land. */
  RUNS_DIR: z.string().min(1).default("runs"),
});

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const lines = parsed.error.issues.map((i) => `  ${i.path.join(".")}: ${i.message}`);
    throw new Error(`Configuration is incomplete. Copy .env.example to .env and fill it in:\n${lines.join("\n")}`);
  }
  return parsed.data;
}
