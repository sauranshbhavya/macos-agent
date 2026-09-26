import { randomUUID } from "node:crypto";
import { describe, expect, it } from "vitest";
import type { Agent } from "../src/agent/agent.js";
import { memoryModelCallLedger } from "../src/agent/credits.js";
import type { ServerTaskMessage } from "../src/agent/protocol.js";
import { TaskRunner } from "../src/agent/tasks/runner.js";
import { memoryTaskStore } from "../src/agent/tasks/store.js";
import { flakyStore, TEST_TOKEN_RATES } from "./support/agent.js";

const ACCOUNT = "0b9c3a52-7c55-4f1e-8d3c-0000000000b2";
const DEVICE = "d0d0d0d0-1111-4222-8333-444455556667";

function runnerOver(agent: Agent, store: ReturnType<typeof memoryTaskStore>, turnRetryDelaysMs: readonly number[]) {
  const delivered: ServerTaskMessage[] = [];
  const runner = new TaskRunner({
    store,
    ledger: memoryModelCallLedger(1000),
    rates: TEST_TOKEN_RATES,
    agentFor: () => agent,
    deliver: (_task, messages) => delivered.push(...messages),
    now: () => new Date(),
    log: { info: () => {}, error: () => {} },
    turnRetryDelaysMs,
  });
  return { runner, delivered };
}

async function start(runner: TaskRunner, task = randomUUID()): Promise<string> {
  await runner.start(ACCOUNT, DEVICE, {
    v: 1,
    type: "task.start",
    id: randomUUID(),
    task,
    seq: 1,
    body: { goal: "Look", origin: "composer", private: false, unattended: false, mode: "normal", context: {} },
  });
  return task;
}

const observeOnce: Agent = {
  turn: () => Promise.resolve({ messages: [{ type: "observe", body: { app: "com.apple.Notes", ax: false, screenshot: true } }] }),
};

function cancelOf(task: string, seq: number) {
  return { v: 1 as const, type: "task.cancel" as const, id: randomUUID(), task, seq, body: { reason: "user" as const } };
}

async function eventually(check: () => boolean): Promise<void> {
  for (let waited = 0; !check(); waited += 5) {
    if (waited > 2000) throw new Error("the condition never became true");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

describe("TaskRunner, when the store fails under a turn", () => {
  it("tries the turn again, rather than leaving the task with nothing scheduled", async () => {
    const { runner, delivered } = runnerOver(observeOnce, flakyStore("transcript"), [5]);
    await start(runner);
    await eventually(() => delivered.length > 0);
    expect(delivered.map((message) => message.type)).toEqual(["observe"]);
  });

  it("stores the answer it already paid for, rather than running the turn again", async () => {
    let turns = 0;
    const counting: Agent = { turn: (context) => ((turns += 1), observeOnce.turn(context)) };
    const { runner, delivered } = runnerOver(counting, flakyStore("appendTurn"), [5]);
    await start(runner);
    await eventually(() => delivered.length > 0);
    expect(delivered.map((message) => message.type)).toEqual(["observe"]);
    expect(turns).toBe(1);
  });

  it("gives up after its last try, and a later schedule still runs the task", async () => {
    const { runner, delivered } = runnerOver(observeOnce, flakyStore("transcript", 3), [5, 5]);
    const task = await start(runner);
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(delivered).toEqual([]);

    const { replay } = await runner.resume(ACCOUNT, [{ task, lastSeqIn: 0 }]);
    await replay();
    await eventually(() => delivered.length > 0);
    expect(delivered.map((message) => message.type)).toEqual(["observe"]);
  });

  it("stops waiting to try again once the runner stops", async () => {
    let turns = 0;
    const counting: Agent = { turn: (context) => ((turns += 1), observeOnce.turn(context)) };
    const { runner, delivered } = runnerOver(counting, flakyStore("transcript"), [50]);
    await start(runner);
    await runner.idle();
    await runner.stop();
    await new Promise((resolve) => setTimeout(resolve, 120));
    expect(turns).toBe(0);
    expect(delivered).toEqual([]);
  });

  it("delivers an answer the store took when only its reply was lost, without running the turn again", async () => {
    const store = memoryTaskStore();
    const appendTurn = store.appendTurn.bind(store);
    let lost = 1;
    store.appendTurn = async (...args) => {
      const stored = await appendTurn(...args);
      if (lost-- > 0) throw new Error("Connection terminated unexpectedly");
      return stored;
    };
    let turns = 0;
    const counting: Agent = { turn: (context) => ((turns += 1), observeOnce.turn(context)) };
    const { runner, delivered } = runnerOver(counting, store, [5]);
    await start(runner);
    await eventually(() => delivered.length > 0);
    expect(delivered.map((message) => message.type)).toEqual(["observe"]);
    expect(turns).toBe(1);
  });

  it("delivers a finish the store took when only its reply was lost", async () => {
    const store = memoryTaskStore();
    const appendTurn = store.appendTurn.bind(store);
    let lost = 1;
    store.appendTurn = async (...args) => {
      const stored = await appendTurn(...args);
      if (lost-- > 0) throw new Error("Connection terminated unexpectedly");
      return stored;
    };
    const finishing: Agent = { turn: () => Promise.resolve({ messages: [{ type: "finish", body: { status: "completed", summary: "Done." } }] }) };
    const { runner, delivered } = runnerOver(finishing, store, [5]);
    await start(runner);
    await eventually(() => delivered.length > 0);
    expect(delivered.map((message) => message.type)).toEqual(["finish"]);
  });

  it("ends a task whose stop is stored but whose end never was, and runs no turn for it", async () => {
    const store = memoryTaskStore();
    const waiting: Agent = { turn: () => Promise.resolve({ messages: [{ type: "ask", body: { question: "Which one?" } }] }) };
    const before = runnerOver(waiting, store, [5]);
    const task = await start(before.runner);
    await eventually(() => before.delivered.length > 0);
    // The stop reached the store; the gateway restarted before it stored the end.
    await store.appendInbound(task, { seq: 2, re: null, msgId: randomUUID(), type: "task.cancel", body: { reason: "user" } }, new Date());

    let turns = 0;
    const counting: Agent = { turn: (context) => ((turns += 1), observeOnce.turn(context)) };
    const after = runnerOver(counting, store, [5]);
    const { replay } = await after.runner.resume(ACCOUNT, [{ task, lastSeqIn: 1 }]);
    await replay();
    await eventually(() => after.delivered.length > 0);
    expect(after.delivered.map((message) => message.type)).toEqual(["finish"]);
    expect(after.delivered[0]).toMatchObject({ body: { status: "cancelled" } });
    expect(turns).toBe(0);
  });

  it("stops a turn that is still reading its transcript when the stop arrives, before any model call", async () => {
    const store = memoryTaskStore();
    const transcript = store.transcript.bind(store);
    let release: () => void = () => {};
    const released = new Promise<void>((resolve) => (release = resolve));
    let held = 1;
    // A slow read: its snapshot is from before the stop, and it answers after the stop is handled.
    store.transcript = async (...args) => {
      const snapshot = await transcript(...args);
      if (held-- > 0) await released;
      return snapshot;
    };
    let turns = 0;
    const counting: Agent = { turn: (context) => ((turns += 1), observeOnce.turn(context)) };
    const { runner, delivered } = runnerOver(counting, store, [5]);
    const task = await start(runner);
    await new Promise((resolve) => setTimeout(resolve, 10));
    await runner.receive(ACCOUNT, cancelOf(task, 2));
    release();
    await runner.idle();
    expect(delivered.map((message) => message.type)).toEqual(["finish"]);
    expect(turns).toBe(0);
  });
});
