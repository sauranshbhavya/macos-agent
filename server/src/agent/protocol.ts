/**
 * The V2 session protocol: every JSON text frame on `/v2/session`.
 *
 * `contracts/v2/protocol.schema.json` is the shared definition. This file mirrors it in Zod, the
 * Swift `Wire` types mirror it on the Mac, and `test/contracts.test.ts` decodes every fixture under
 * `contracts/v2/fixtures/` through both this file and the JSON Schema, so the three cannot drift
 * apart silently.
 *
 * Every object is strict: an unknown field or message type is a decoding failure, never ignored.
 */
import { z } from "zod/v4";

export const PROTOCOL_VERSION = 1;

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export const idSchema = z.string().regex(UUID_PATTERN);
const seqSchema = z.number().int().min(1).max(1_000_000);
const seqOrZeroSchema = z.number().int().min(0).max(1_000_000);
const bundleIdSchema = z.string().min(1).max(255);
const operationNameSchema = z.string().regex(/^[a-z][a-z0-9_]{0,63}$/);
const operationVersionSchema = z.number().int().min(1).max(1000);

const rectSchema = z.strictObject({
  x: z.number(),
  y: z.number(),
  w: z.number().min(0),
  h: z.number().min(0),
});

const appRefSchema = z.strictObject({
  bundle_id: bundleIdSchema,
  name: z.string().min(1).max(255),
});

/** What an action does to the world, in rising order of consequence (plan section 7.1). */
export const EFFECTS = [
  "observe",
  "navigate",
  "edit_local",
  "create",
  "destructive",
  "external",
  "financial",
  "credential",
  "unknown",
] as const;
export const effectSchema = z.enum(EFFECTS);
export type Effect = z.infer<typeof effectSchema>;

export const modeSchema = z.enum(["safe", "normal", "power"]);
export type Mode = z.infer<typeof modeSchema>;

const permissionStateSchema = z.enum(["granted", "denied", "not_determined"]);

export const SCREEN_TOOL_NAMES = [
  "observe_ax",
  "screenshot",
  "press",
  "set_value",
  "type_text",
  "key",
  "scroll",
  "menu",
  "click_point",
] as const;
export const screenToolNameSchema = z.enum(SCREEN_TOOL_NAMES);

export const ledgerStateSchema = z.enum([
  "received",
  "prepared",
  "approved",
  "dispatched",
  "done",
  "failed",
  "refused",
  "declined",
  "stale",
  "skipped",
  "outcome_unknown",
]);

export const manifestSchema = z.strictObject({
  operations: z
    .array(z.strictObject({ name: operationNameSchema, version: operationVersionSchema }))
    .max(128),
  screen: z.strictObject({
    tools: z
      .array(screenToolNameSchema)
      .max(16)
      .refine((tools) => new Set(tools).size === tools.length, "screen tools must be unique"),
  }),
  permissions: z.strictObject({
    accessibility: permissionStateSchema,
    screen_recording: permissionStateSchema,
    automation: z
      .array(z.strictObject({ bundle_id: bundleIdSchema, state: permissionStateSchema }))
      .max(64),
  }),
});
export type Manifest = z.infer<typeof manifestSchema>;

const elementRefPattern = /^e[0-9]{1,5}$/;

export const elementRefSchema = z.strictObject({
  ref: z.string().regex(elementRefPattern),
  generation: seqSchema,
});

export const axNodeSchema = z.strictObject({
  ref: z.string().regex(elementRefPattern),
  depth: z.number().int().min(0).max(64),
  role: z.string().min(1).max(64),
  label: z.string().max(500).optional(),
  value: z.string().max(2000).optional(),
  enabled: z.boolean().optional(),
  focused: z.boolean().optional(),
  selected: z.boolean().optional(),
  secure: z.boolean().optional(),
  frame: rectSchema.optional(),
  actions: z.array(z.string().min(1).max(64)).max(8).optional(),
});
export type AXNode = z.infer<typeof axNodeSchema>;

export const screenActionSchema = z.discriminatedUnion("tool", [
  z.strictObject({ tool: z.literal("press"), app: bundleIdSchema, element: elementRefSchema }),
  z.strictObject({
    tool: z.literal("set_value"),
    app: bundleIdSchema,
    element: elementRefSchema,
    value: z.string().max(10_000),
  }),
  z.strictObject({
    tool: z.literal("type_text"),
    app: bundleIdSchema,
    text: z.string().min(1).max(10_000),
    element: elementRefSchema.optional(),
  }),
  z.strictObject({
    tool: z.literal("key"),
    app: bundleIdSchema,
    keys: z
      .array(z.string().regex(/^[a-z0-9]{1,16}$/))
      .min(1)
      .max(5),
  }),
  z.strictObject({
    tool: z.literal("scroll"),
    app: bundleIdSchema,
    direction: z.enum(["up", "down", "left", "right"]),
    amount: z.number().int().min(1).max(20),
    element: elementRefSchema.optional(),
  }),
  z.strictObject({
    tool: z.literal("menu"),
    app: bundleIdSchema,
    path: z.array(z.string().min(1).max(200)).min(1).max(6),
  }),
  z.strictObject({
    tool: z.literal("click_point"),
    app: bundleIdSchema,
    x: z.number().min(0),
    y: z.number().min(0),
    generation: seqSchema,
    count: z.number().int().min(1).max(2).optional(),
  }),
]);
export type ScreenAction = z.infer<typeof screenActionSchema>;

export const operationCallSchema = z.strictObject({
  name: operationNameSchema,
  version: operationVersionSchema,
  args: z.record(z.string(), z.unknown()),
});
export type OperationCall = z.infer<typeof operationCallSchema>;

const actionFields = {
  action_id: idSchema,
  effect: effectSchema,
  expect: z.string().max(500).optional(),
};

/** Exactly one of `operation` or `screen`: each branch is strict, so carrying both fails both. */
export const actionSchema = z.union([
  z.strictObject({ ...actionFields, operation: operationCallSchema }),
  z.strictObject({ ...actionFields, screen: screenActionSchema }),
]);
export type Action = z.infer<typeof actionSchema>;

export const outcomeStatusSchema = z.enum([
  "done",
  "failed",
  "refused",
  "declined",
  "stale",
  "skipped",
  "outcome_unknown",
]);
export type OutcomeStatus = z.infer<typeof outcomeStatusSchema>;

export const outcomeErrorCodeSchema = z.enum([
  "permission_denied",
  "app_not_running",
  "target_not_found",
  "target_refused",
  "stale_reference",
  "invalid_arguments",
  "unsupported_operation",
  "secure_field",
  "mode_refused",
  "unattended_refused",
  "foreground_unavailable",
  "timeout",
  "execution_error",
  "cancelled",
]);

export const actionResultSchema = z.strictObject({
  action_id: idSchema,
  status: outcomeStatusSchema,
  effect: effectSchema,
  evidence: z.string().max(2000).optional(),
  error: z
    .strictObject({ code: outcomeErrorCodeSchema, message: z.string().max(1000).optional() })
    .optional(),
});
export type ActionResult = z.infer<typeof actionResultSchema>;

// Envelopes. Connection messages carry no task, seq or re; strict objects enforce that.

function connectionMessage<T extends string, B extends z.ZodType>(type: T, body: B) {
  return z.strictObject({ v: z.literal(PROTOCOL_VERSION), type: z.literal(type), id: idSchema, body });
}

function taskMessage<T extends string, B extends z.ZodType>(type: T, body: B) {
  return z.strictObject({
    v: z.literal(PROTOCOL_VERSION),
    type: z.literal(type),
    id: idSchema,
    task: idSchema,
    seq: seqSchema,
    re: seqSchema.optional(),
    body,
  });
}

/** A task message that answers one of the other side's messages, so `re` is required. */
function replyMessage<T extends string, B extends z.ZodType>(type: T, body: B) {
  return z.strictObject({
    v: z.literal(PROTOCOL_VERSION),
    type: z.literal(type),
    id: idSchema,
    task: idSchema,
    seq: seqSchema,
    re: seqSchema,
    body,
  });
}

// Mac to gateway.

export const helloSchema = connectionMessage(
  "hello",
  z.strictObject({
    device_id: idSchema,
    app_version: z.string().min(1).max(32),
    os_version: z.string().min(1).max(32),
    manifest: manifestSchema,
    resume: z
      .array(
        z.strictObject({
          task: idSchema,
          last_seq_in: seqOrZeroSchema,
          last_seq_out: seqOrZeroSchema,
          ledger: z
            .array(z.strictObject({ action_id: idSchema, state: ledgerStateSchema }))
            .max(64),
        }),
      )
      .max(16),
  }),
);

export const reauthSchema = connectionMessage(
  "reauth",
  z.strictObject({ access_token: z.string().min(1).max(8192) }),
);

export const taskOriginSchema = z.enum([
  "composer",
  "voice",
  "routine",
  "schedule",
  "follow_up",
  "watcher",
]);

export const taskStartSchema = taskMessage(
  "task.start",
  z.strictObject({
    goal: z.string().min(1).max(4000),
    origin: taskOriginSchema,
    private: z.boolean(),
    unattended: z.boolean(),
    mode: modeSchema,
    prior_task: idSchema.optional(),
    context: z.strictObject({
      frontmost_app: appRefSchema.optional(),
      finder_selection: z.array(z.string().min(1).max(1024)).max(50).optional(),
    }),
  }),
);

export const observationBodySchema = z.strictObject({
  generation: seqSchema,
  app: z
    .strictObject({
      bundle_id: bundleIdSchema,
      name: z.string().min(1).max(255),
      pid: z.number().int().min(1),
    })
    .optional(),
  window: z
    .strictObject({
      id: z.number().int().min(0),
      title: z.string().max(500).optional(),
      frame: rectSchema,
    })
    .optional(),
  ax: z.strictObject({ nodes: z.array(axNodeSchema).max(2000), truncated: z.boolean() }).optional(),
  screenshot: z
    .strictObject({
      media_type: z.enum(["image/jpeg", "image/png"]),
      data: z.string().min(1).max(4_000_000),
      width: z.number().int().min(1).max(20_000),
      height: z.number().int().min(1).max(20_000),
    })
    .optional(),
  error: z
    .strictObject({
      code: z.enum([
        "permission_denied",
        "app_not_running",
        "no_window",
        "unreadable",
        "foreground_unavailable",
        "app_refused",
      ]),
      message: z.string().max(1000).optional(),
    })
    .optional(),
});
export type ObservationBody = z.infer<typeof observationBodySchema>;

export const observationSchema = replyMessage("observation", observationBodySchema);

export const outcomeSchema = replyMessage(
  "outcome",
  z.strictObject({ results: z.array(actionResultSchema).min(1).max(8) }),
);

export const answerSchema = replyMessage(
  "answer",
  z.strictObject({ text: z.string().min(1).max(4000) }),
);

export const taskCancelSchema = taskMessage(
  "task.cancel",
  z.strictObject({ reason: z.enum(["user", "shutdown", "outcome_unknown"]) }),
);

export const clientMessageSchema = z.discriminatedUnion("type", [
  helloSchema,
  reauthSchema,
  taskStartSchema,
  observationSchema,
  outcomeSchema,
  answerSchema,
  taskCancelSchema,
]);
export type ClientMessage = z.infer<typeof clientMessageSchema>;

// Gateway to Mac.

export const welcomeSchema = connectionMessage(
  "welcome",
  z.strictObject({
    session_id: idSchema,
    server_time_ms: z.number().int().min(0),
    max_payload_bytes: z.number().int().min(1024),
    heartbeat_seconds: z.number().int().min(1).max(300),
    tasks: z
      .array(
        z.strictObject({
          task: idSchema,
          state: z.enum(["live", "finished", "unknown"]),
          last_seq_in: seqOrZeroSchema,
        }),
      )
      .max(16),
  }),
);

export const reauthRequiredSchema = connectionMessage(
  "reauth.required",
  z.strictObject({ expires_at_ms: z.number().int().min(0) }),
);

export const goodbyeReasonSchema = z.enum(["draining", "replaced", "signed_out", "auth_expired"]);

export const goodbyeSchema = connectionMessage(
  "goodbye",
  z.strictObject({
    reason: goodbyeReasonSchema,
    reconnect_after_ms: z.number().int().min(0).max(600_000).optional(),
  }),
);

export const errorCodeSchema = z.enum([
  "malformed",
  "unsupported_version",
  "rate_limited",
  "payload_too_large",
  "unknown_task",
  "task_conflict",
  "sequence_gap",
  "internal",
]);
export type ErrorCode = z.infer<typeof errorCodeSchema>;

export const errorSchema = connectionMessage(
  "error",
  z.strictObject({
    code: errorCodeSchema,
    message: z.string().max(1000),
    ref: idSchema.optional(),
  }),
);

export const observeBodySchema = z
  .strictObject({
    app: bundleIdSchema,
    ax: z.boolean(),
    screenshot: z.boolean(),
    max_nodes: z.number().int().min(1).max(2000).optional(),
  })
  .refine((body) => body.ax || body.screenshot, "observe asks for the tree, a screenshot or both");
export type ObserveBody = z.infer<typeof observeBodySchema>;

export const observeSchema = taskMessage("observe", observeBodySchema);

export const proposeBodySchema = z.strictObject({
  agent: z.enum(["planner", "screen"]),
  actions: z.array(actionSchema).min(1).max(8),
  final: z.boolean(),
});
export type ProposeBody = z.infer<typeof proposeBodySchema>;

export const proposeSchema = taskMessage("propose", proposeBodySchema);

export const askSchema = taskMessage(
  "ask",
  z.strictObject({
    question: z.string().min(1).max(2000),
    choices: z.array(z.string().min(1).max(200)).max(6).optional(),
  }),
);

export const progressSchema = taskMessage(
  "progress",
  z.strictObject({ message: z.string().min(1).max(300) }),
);

export const finishReasonSchema = z.enum([
  "credits_exhausted",
  "budget_exhausted",
  "model_unavailable",
  "invalid_output",
  "no_progress",
  "unsupported",
  "refused",
  "cancelled",
  "internal_error",
]);
export type FinishReason = z.infer<typeof finishReasonSchema>;

export const finishBodySchema = z.strictObject({
  status: z.enum(["completed", "failed", "cancelled"]),
  summary: z.string().max(4000),
  reason: finishReasonSchema.optional(),
});
export type FinishBody = z.infer<typeof finishBodySchema>;

export const finishSchema = taskMessage("finish", finishBodySchema);

export const serverMessageSchema = z.discriminatedUnion("type", [
  welcomeSchema,
  reauthRequiredSchema,
  goodbyeSchema,
  errorSchema,
  observeSchema,
  proposeSchema,
  askSchema,
  progressSchema,
  finishSchema,
]);
export type ServerMessage = z.infer<typeof serverMessageSchema>;

/** The task-level messages the gateway sends, which are the ones stored in a task's transcript. */
export type ServerTaskMessage = Extract<ServerMessage, { task: string }>;
export type ClientTaskMessage = Extract<ClientMessage, { task: string }>;
