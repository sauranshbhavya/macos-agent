import { randomUUID } from "node:crypto";
import pg from "pg";
import { describe, expect } from "vitest";
import { postgresModelCallLedger } from "../src/agent/credits.js";
import { postgresTaskStore } from "../src/agent/tasks/postgres-store.js";
import { sweepTasksOnce, TASK_ABANDON_AFTER_MS, TASK_RETENTION_MS } from "../src/agent/tasks/retention.js";
import type { NewTask } from "../src/agent/tasks/store.js";
import { creditBalance } from "../src/credit/balance.js";
import { parseCreditCatalogue } from "../src/credit/catalogue.js";
import { postgresCreditStore } from "../src/credit/store.js";
import type { WithConnection } from "../src/db/connection.js";
import { TEST_CREDIT_PLANS_WITH_RATES } from "./support/agent.js";
import {
  afterAllUnderHangBackstop,
  beforeAllUnderHangBackstop,
  beforeEachUnderHangBackstop,
  itUnderHangBackstop,
} from "./support/backstop.js";
import { rebuildSchema } from "./support/schema.js";

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

describeDb("V2 tasks in Postgres", () => {
  let client: pg.Client;
  let account: string;
  const withConnection: WithConnection = (work) => work(client);
  const store = postgresTaskStore(withConnection);
  const at = new Date("2026-09-10T12:00:00Z");
  const DEVICE = "d0d0d0d0-1111-4222-8333-444455556666";

  const newTask = (overrides: Partial<NewTask> = {}): NewTask => ({
    id: randomUUID(),
    accountId: account,
    deviceId: DEVICE,
    isPrivate: false,
    unattended: false,
    goal: "Open Notes",
    origin: "composer",
    mode: "normal",
    priorTask: null,
    start: { msgId: randomUUID(), body: { goal: "Open Notes" } },
    ...overrides,
  });

  const count = async (table: string, taskId: string, column = "task_id"): Promise<number> => {
    const { rows } = await client.query<{ n: string }>(
      `SELECT count(*)::text AS n FROM sonny.${table} WHERE ${column} = $1`,
      [taskId],
    );
    return Number(rows[0]!.n);
  };

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await rebuildSchema(client);
  });
  afterAllUnderHangBackstop(async () => {
    await client.end();
  });
  beforeEachUnderHangBackstop(async () => {
    await client.query("TRUNCATE sonny.agent_task CASCADE");
    await client.query("TRUNCATE sonny.agent_model_call");
    const { rows } = await client.query<{ id: string }>("INSERT INTO sonny.account DEFAULT VALUES RETURNING id");
    account = rows[0]!.id;
  });

  itUnderHangBackstop("stores a task, its transcript in order, and resends what came after a seq", async () => {
    const task = newTask();
    expect(await store.createTask(task, at)).toBe("created");
    expect(await store.createTask(task, at)).toBe("duplicate");

    const turn = await store.appendTurn(
      task.id,
      [
        { direction: "note", re: null, msgId: randomUUID(), type: "plan", body: { step: 1 } },
        { direction: "out", re: 1, msgId: randomUUID(), type: "progress", body: { message: "Looking" } },
        { direction: "out", re: 1, msgId: randomUUID(), type: "propose", body: { final: false } },
      ],
      at,
    );
    expect(turn?.map((m) => [m.type, m.seq, m.re])).toEqual([["progress", 1, 1], ["propose", 2, 1]]);

    const reply = { seq: 2, re: 2, msgId: randomUUID(), type: "outcome", body: { results: [] } };
    expect(await store.appendInbound(task.id, reply, at)).toBe("appended");
    expect(await store.appendInbound(task.id, reply, at)).toBe("duplicate");
    expect(await store.appendInbound(task.id, { ...reply, seq: 4, msgId: randomUUID() }, at)).toBe("gap");

    const transcript = await store.transcript(task.id);
    expect(transcript.map((m) => `${m.direction}:${m.type}:${m.seq}`)).toEqual([
      "in:task.start:1",
      "note:plan:1",
      "out:progress:1",
      "out:propose:2",
      "in:outcome:2",
    ]);
    expect((await store.outboundAfter(task.id, 1)).map((m) => m.type)).toEqual(["propose"]);
    const record = await store.task(task.id);
    expect(record).toMatchObject({ lastSeqIn: 2, lastSeqOut: 2, turns: 1, status: "live" });
  });

  itUnderHangBackstop("refuses a task id another account holds", async () => {
    const task = newTask();
    await store.createTask(task, at);
    const { rows } = await client.query<{ id: string }>("INSERT INTO sonny.account DEFAULT VALUES RETURNING id");
    expect(await store.createTask({ ...task, accountId: rows[0]!.id, start: { msgId: randomUUID(), body: {} } }, at)).toBe("conflict");
  });

  itUnderHangBackstop("deletes a private task's rows in the transaction that ends it", async () => {
    const task = newTask({ isPrivate: true });
    await store.createTask(task, at);
    await store.appendTurn(
      task.id,
      [{ direction: "out", re: 1, msgId: randomUUID(), type: "finish", body: { status: "completed" } }],
      at,
      "completed",
    );
    expect(await store.task(task.id)).toBeUndefined();
    expect(await count("agent_message", task.id)).toBe(0);
  });

  itUnderHangBackstop("keeps an ended task 30 days, and fails a task left untouched for a day", async () => {
    const ended = newTask();
    await store.createTask(ended, at);
    await store.end(ended.id, "completed", at);
    const idle = newTask();
    await store.createTask(idle, at);
    const ledger = postgresModelCallLedger({
      withConnection,
      catalogue: parseCreditCatalogue(TEST_CREDIT_PLANS_WITH_RATES),
      defaultCapUnits: 1000,
    });

    const nextDay = new Date(at.getTime() + TASK_ABANDON_AFTER_MS);
    expect(await sweepTasksOnce({ store, ledger, now: () => nextDay })).toMatchObject({ deleted: 0, abandoned: 1 });
    expect((await store.task(idle.id))?.status).toBe("failed");
    expect(await store.task(ended.id)).toBeDefined();

    const monthLater = new Date(at.getTime() + TASK_RETENTION_MS);
    expect(await sweepTasksOnce({ store, ledger, now: () => monthLater })).toMatchObject({ deleted: 1 });
    expect(await store.task(ended.id)).toBeUndefined();
    expect(await count("agent_message", ended.id)).toBe(0);
  });

  itUnderHangBackstop("holds credits, settles them by tokens, and refuses a hold the balance can't cover", async () => {
    const catalogue = parseCreditCatalogue(TEST_CREDIT_PLANS_WITH_RATES);
    const ledger = postgresModelCallLedger({ withConnection, catalogue, defaultCapUnits: 1000 });
    const task = randomUUID();
    const call = (credits: number) => ({
      stepId: randomUUID(),
      accountId: account,
      taskId: task,
      agent: "planner" as const,
      tier: "standard" as const,
      credits,
      now: at,
    });

    const first = call(600);
    expect(await ledger.hold(first)).toEqual({ kind: "held" });
    // The open hold counts against the balance, so a second one that would overdraw is refused.
    expect(await ledger.hold(call(500))).toMatchObject({ kind: "insufficient", remaining: 400 });

    await ledger.settle({
      stepId: first.stepId,
      credits: 7.5,
      provider: "openai",
      model: "gpt-test",
      inputTokens: 1500,
      outputTokens: 1125,
      outcome: "ok",
      now: at,
    });
    expect(await ledger.hold(call(500))).toEqual({ kind: "held" });

    const { rows } = await client.query(
      "SELECT status, credits_charged::float AS charged, tier, input_tokens, output_tokens FROM sonny.agent_model_call WHERE step_id = $1",
      [first.stepId],
    );
    expect(rows[0]).toEqual({ status: "settled", charged: 7.5, tier: "standard", input_tokens: 1500, output_tokens: 1125 });

    // The account's balance route reads the same spend.
    const facts = await postgresCreditStore(withConnection).factsFor(account, at);
    const balance = creditBalance({ catalogue, planKey: facts.planKey, draw: facts.draw, agentCredits: facts.agentCredits!, toppedUpCredits: facts.toppedUpCredits, now: at });
    expect(balance.credits.drawn).toBe(507.5);
  });

  itUnderHangBackstop("releases a hold its process died holding, charging nothing", async () => {
    const ledger = postgresModelCallLedger({
      withConnection,
      catalogue: parseCreditCatalogue(TEST_CREDIT_PLANS_WITH_RATES),
      defaultCapUnits: 1000,
    });
    const stepId = randomUUID();
    await ledger.hold({ stepId, accountId: account, taskId: randomUUID(), agent: "screen", tier: "fast", credits: 900, now: at });
    expect(await ledger.expireHolds(new Date(at.getTime() + 1), at)).toBe(1);
    expect(await ledger.hold({ stepId: randomUUID(), accountId: account, taskId: randomUUID(), agent: "screen", tier: "fast", credits: 900, now: at })).toEqual({ kind: "held" });
  });

  itUnderHangBackstop("stops at the spend cap even with credits left", async () => {
    const ledger = postgresModelCallLedger({
      withConnection,
      catalogue: parseCreditCatalogue(TEST_CREDIT_PLANS_WITH_RATES),
      defaultCapUnits: 1,
    });
    const hold = () => ledger.hold({ stepId: randomUUID(), accountId: account, taskId: randomUUID(), agent: "planner", tier: "fast", credits: 1, now: at });
    expect(await hold()).toEqual({ kind: "held" });
    expect(await hold()).toEqual({ kind: "over_cap" });
  });
});
