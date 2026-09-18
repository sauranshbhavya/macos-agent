import { z } from "zod";

/**
 * The slice of cua-driver's payloads this experiment reads, as Zod schemas. Every schema is
 * `passthrough` and asks only for the fields the loop actually consumes: the driver adds fields
 * between releases and a strict schema would turn each addition into a false failure. Field names
 * follow `cua-driver describe <tool>` for 0.28.2; a mismatch fails here, at the boundary, with the
 * tool name in the message, rather than as an undefined three modules later.
 */

export const windowRecordSchema = z
  .object({
    window_id: z.number().int(),
    pid: z.number().int(),
    app_name: z.string().nullish(),
    title: z.string().nullish(),
    bounds: z
      .object({ x: z.number(), y: z.number(), width: z.number(), height: z.number() })
      .passthrough()
      .nullish(),
    z_index: z.number().int().nullish(),
    is_on_screen: z.boolean().nullish(),
  })
  .passthrough();
export type WindowRecord = z.infer<typeof windowRecordSchema>;

export const launchResultSchema = z
  .object({
    pid: z.number().int(),
    bundle_id: z.string().nullish(),
    name: z.string().nullish(),
    windows: z.array(windowRecordSchema).default([]),
  })
  .passthrough();
export type LaunchResult = z.infer<typeof launchResultSchema>;

export const listWindowsSchema = z.object({ windows: z.array(windowRecordSchema) }).passthrough();

export const frameSchema = z.object({ x: z.number(), y: z.number(), w: z.number(), h: z.number() }).passthrough();

export const elementSchema = z
  .object({
    element_index: z.number().int(),
    element_token: z.string().nullish(),
    role: z.string(),
    label: z.string().nullish(),
    value: z.union([z.string(), z.number(), z.boolean()]).nullish(),
    actions: z.array(z.string()).nullish(),
    frame: frameSchema.nullish(),
    parent_index: z.number().int().nullish(),
    depth: z.number().int().nullish(),
    enabled: z.boolean().nullish(),
    focused: z.boolean().nullish(),
    selected: z.boolean().nullish(),
  })
  .passthrough();
export type Element = z.infer<typeof elementSchema>;

export const windowStateSchema = z
  .object({
    snapshot_id: z.string(),
    pid: z.number().int(),
    window_id: z.number().int(),
    elements: z.array(elementSchema).default([]),
    element_count: z.number().int().nullish(),
    total_element_count: z.number().int().nullish(),
    app_name: z.string().nullish(),
    window_title: z.string().nullish(),
    degraded_reason: z.string().nullish(),
    tree_markdown: z.string().nullish(),
    screenshot: z.string().nullish(),
    screenshot_file_path: z.string().nullish(),
    screenshot_width: z.number().int().nullish(),
    screenshot_height: z.number().int().nullish(),
  })
  .passthrough();
export type WindowState = z.infer<typeof windowStateSchema>;

export const effectSchema = z.enum(["confirmed", "partial", "unverifiable", "suspected_noop", "refused"]);
export type Effect = z.infer<typeof effectSchema>;

export const escalationRungSchema = z.enum(["px", "page", "foreground"]);
export type EscalationRung = z.infer<typeof escalationRungSchema>;

/**
 * The driver documents `escalation` as `{ recommended, reason }`; its contracts page also shows
 * it as a bare string. Both are accepted and normalised to the object form.
 */
const escalationSchema = z
  .union([
    z.object({ recommended: z.string().nullish(), reason: z.string().nullish() }).passthrough(),
    z.string(),
    z.null(),
  ])
  .transform((value): { recommended: EscalationRung | null; reason: string | null } => {
    if (value === null) return { recommended: null, reason: null };
    if (typeof value === "string") {
      const rung = escalationRungSchema.safeParse(value);
      return rung.success ? { recommended: rung.data, reason: null } : { recommended: null, reason: value };
    }
    const rung = escalationRungSchema.safeParse(value.recommended);
    return { recommended: rung.success ? rung.data : null, reason: value.reason ?? null };
  });

export const actionResultSchema = z
  .object({
    effect: effectSchema,
    route: z.string().nullish(),
    delivery: z.object({ mode: z.string().nullish() }).passthrough().nullish(),
    evidence: z.union([z.string(), z.record(z.unknown())]).nullish(),
    escalation: escalationSchema.optional().default(null),
  })
  .passthrough();
export type ActionResult = z.infer<typeof actionResultSchema>;

/** The two refusal shapes the contracts page documents, folded into one. */
export const refusalSchema = z
  .union([
    z.object({ status: z.literal("refused"), refusal: z.object({ code: z.string(), message: z.string().nullish() }) }),
    z.object({ code: z.string(), message: z.string().nullish(), effect: z.literal("refused").optional() }),
  ])
  .transform((value) => ("refusal" in value ? value.refusal : { code: value.code, message: value.message }));
export type Refusal = z.infer<typeof refusalSchema>;

export class DriverRefusal extends Error {
  readonly code: string;
  readonly tool: string;

  constructor(tool: string, refusal: Refusal) {
    super(`${tool} refused: ${refusal.code}${refusal.message ? ` — ${refusal.message}` : ""}`);
    this.name = "DriverRefusal";
    this.code = refusal.code;
    this.tool = tool;
  }
}

/** Parse a tool payload, turning a refusal into a `DriverRefusal` and a shape mismatch into a named error. */
export function parseToolPayload<T>(
  tool: string,
  isError: boolean,
  payload: unknown,
  schema: z.ZodType<T, z.ZodTypeDef, unknown>,
): T {
  if (isError) {
    const refusal = refusalSchema.safeParse(payload);
    throw new DriverRefusal(
      tool,
      refusal.success ? refusal.data : { code: "unknown", message: JSON.stringify(payload).slice(0, 300) },
    );
  }
  const parsed = schema.safeParse(payload);
  if (!parsed.success) {
    const refusal = refusalSchema.safeParse(payload);
    if (refusal.success) throw new DriverRefusal(tool, refusal.data);
    const issue = parsed.error.issues[0];
    throw new Error(
      `${tool} answered a shape this experiment does not read (${issue?.path.join(".") ?? "?"}: ${issue?.message ?? "?"}); raw: ${JSON.stringify(payload).slice(0, 300)}`,
    );
  }
  return parsed.data;
}
