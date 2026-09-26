import { randomUUID } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import type { Agent } from "../src/agent/agent.js";
import { memoryModelCallLedger } from "../src/agent/credits.js";
import { CLOSE_CODE } from "../src/agent/session/close.js";
import { memoryTaskStore } from "../src/agent/tasks/store.js";
import { sweepTasksOnce, TASK_ABANDON_AFTER_MS, TASK_RETENTION_MS } from "../src/agent/tasks/retention.js";
import {
  proposeOpen,
  scriptedAgent,
  startHarness,
  TestMac,
  wait,
  type Harness,
} from "./support/agent.js";
import { AGENT_USER } from "./support/agent.js";
import { accessTokenFor } from "./support/tokens.js";

let harnesses: Harness[] = [];
const macs: TestMac[] = [];

async function harness(...args: Parameters<typeof startHarness>): Promise<Harness> {
  const started = await startHarness(...args);
  harnesses.push(started);
  return started;
}

async function mac(url: string, options?: Parameters<typeof TestMac.connect>[1]): Promise<TestMac> {
  const connected = await TestMac.connect(url, options);
  macs.push(connected);
  return connected;
}

afterEach(async () => {
  for (const connected of macs.splice(0)) connected.socket.terminate();
  await Promise.all(harnesses.map((h) => h.close()));
  harnesses = [];
});

const DEVICE = "d0d0d0d0-1111-4222-8333-444455556666";
const noReplies = () => Promise.resolve(0);

describe("a V2 session", () => {
  it("refuses an upgrade with no token", async () => {
    const h = await harness();
    await expect(TestMac.connect(h.url, { token: "" })).rejects.toThrow("401");
  });

  it("welcomes a hello and runs a task through its scripted proposals to the end", async () => {
    const h = await harness({ agentFactory: scriptedAgent([{ messages: [proposeOpen()] }, { messages: [proposeOpen("Mail", true)] }]) });
    const m = await mac(h.url);
    m.hello(DEVICE);
    const welcome = await m.nextOfType("welcome");
    expect(welcome.type === "welcome" && welcome.body.tasks).toEqual([]);

    const task = randomUUID();
    m.startTask(task);
    const first = await m.nextOfType("propose");
    expect(first).toMatchObject({ task, seq: 1, re: 1 });
    m.outcomeFor(first);
    const second = await m.nextOfType("propose");
    expect(second).toMatchObject({ task, seq: 2, re: 2 });
    m.outcomeFor(second);
    const finish = await m.nextOfType("finish");
    expect(finish).toMatchObject({ task, seq: 3, body: { status: "completed" } });

    const record = await h.store.task(task);
    expect(record?.status).toBe("completed");
    expect(h.store.devices.get(DEVICE)).toBeDefined();
  });

  it("resumes after a disconnect without sending any proposal twice", async () => {
    const h = await harness({ agentFactory: scriptedAgent([{ messages: [proposeOpen()] }, { messages: [proposeOpen("Mail")] }]) });
    const first = await mac(h.url);
    first.hello(DEVICE);
    await first.nextOfType("welcome");
    const task = randomUUID();
    first.startTask(task);
    const propose = await first.nextOfType("propose");

    // The Mac answers, then drops before it hears the next proposal.
    first.outcomeFor(propose);
    first.socket.terminate();
    await h.app.agentRunner!.idle();

    const second = await mac(h.url);
    second.setSeq(task, 2);
    second.hello(DEVICE, [{ task, last_seq_in: 1, last_seq_out: 2 }]);
    const welcome = await second.nextOfType("welcome");
    expect(welcome.type === "welcome" && welcome.body.tasks).toEqual([{ task, state: "live", last_seq_in: 2 }]);
    const missed = await second.nextOfType("propose");
    expect(missed).toMatchObject({ task, seq: 2 });
    await wait(100);
    expect(second.received.filter((message) => message.type === "propose")).toEqual([]);
  });

  it("runs a turn again after a restart when the gateway never stored its answer", async () => {
    const store = memoryTaskStore();
    const stuck: Agent = { turn: (context) => new Promise((_resolve, reject) => context.signal.addEventListener("abort", () => reject(new Error("aborted")))) };
    const before = await harness({ store, agentFactory: () => stuck });
    const m = await mac(before.url);
    m.hello(DEVICE);
    await m.nextOfType("welcome");
    const task = randomUUID();
    m.startTask(task);
    await wait(50);
    await before.close();
    harnesses = harnesses.filter((h) => h !== before);

    const after = await harness({ store, agentFactory: scriptedAgent([{ messages: [proposeOpen()] }]) });
    const again = await mac(after.url);
    again.hello(DEVICE, [{ task, last_seq_in: 0, last_seq_out: 1 }]);
    await again.nextOfType("welcome");
    expect(await again.nextOfType("propose")).toMatchObject({ task, seq: 1 });
  });

  it("ignores a repeated message id", async () => {
    const seen: unknown[] = [];
    const h = await harness({ agentFactory: scriptedAgent([{ messages: [proposeOpen()] }, { messages: [proposeOpen()] }], seen as never) });
    const m = await mac(h.url);
    m.hello(DEVICE);
    await m.nextOfType("welcome");
    const task = randomUUID();
    m.startTask(task);
    const propose = await m.nextOfType("propose");
    const outcome = m.outcomeFor(propose);
    m.send(outcome);
    await m.nextOfType("propose");
    await h.app.agentRunner!.idle();
    await wait(50);
    expect(seen).toHaveLength(2);
    const transcript = await h.store.transcript(task);
    expect(transcript.filter((message) => message.type === "outcome")).toHaveLength(1);
  });

  it("says a message skipped a seq and stores nothing for it", async () => {
    const h = await harness({ agentFactory: scriptedAgent([{ messages: [proposeOpen()] }]) });
    const m = await mac(h.url);
    m.hello(DEVICE);
    await m.nextOfType("welcome");
    const task = randomUUID();
    m.startTask(task);
    const propose = await m.nextOfType("propose");
    m.nextSeq(task);
    m.outcomeFor(propose);
    const error = await m.nextOfType("error");
    expect(error).toMatchObject({ body: { code: "sequence_gap" } });
    expect((await h.store.task(task))?.lastSeqIn).toBe(1);
  });

  it("asks for a fresh token before it expires, keeps the session on reauth, and closes 4401 without one", async () => {
    const h = await harness({ agentTiming: { heartbeatMs: 60_000, helloTimeoutMs: 2_000, reauthLeadMs: 1_500 } });
    const renewing = await mac(h.url, { token: accessTokenFor(AGENT_USER, { lifetimeSeconds: 2 }) });
    const ignoring = await mac(h.url, { token: accessTokenFor(AGENT_USER, { lifetimeSeconds: 2 }) });
    renewing.hello(DEVICE);
    ignoring.hello("e0e0e0e0-1111-4222-8333-444455556666");

    const asked = await renewing.nextOfType("reauth.required");
    expect(asked.type === "reauth.required" && asked.body.expires_at_ms).toBeGreaterThan(Date.now());
    renewing.send({ v: 1, type: "reauth", id: randomUUID(), body: { access_token: accessTokenFor(AGENT_USER) } });

    const closed = await ignoring.closed;
    expect(closed.code).toBe(CLOSE_CODE.auth_expired);
    await wait(300);
    expect(renewing.socket.readyState).toBe(renewing.socket.OPEN);
  }, 8_000);

  it("closes 4401 when a reauth token is refused", async () => {
    const h = await harness();
    const m = await mac(h.url);
    m.hello(DEVICE);
    await m.nextOfType("welcome");
    m.send({ v: 1, type: "reauth", id: randomUUID(), body: { access_token: "not.a.token" } });
    expect((await m.closed).code).toBe(CLOSE_CODE.auth_expired);
  });

  it("closes the socket when its sign-in session signs out", async () => {
    const h = await harness();
    const token = accessTokenFor(AGENT_USER);
    const m = await mac(h.url, { token });
    m.hello(DEVICE);
    await m.nextOfType("welcome");
    const response = await h.app.inject({
      method: "POST",
      url: "/v1/auth/signout",
      headers: { authorization: `Bearer ${token}`, "sonny-client-version": "2.0.0" },
    });
    expect(response.statusCode).toBe(204);
    const goodbye = await m.nextOfType("goodbye");
    expect(goodbye).toMatchObject({ body: { reason: "signed_out" } });
    expect((await m.closed).code).toBe(CLOSE_CODE.signed_out);
  });

  it("says goodbye with a reconnect pause when the gateway drains", async () => {
    const h = await harness();
    const m = await mac(h.url);
    m.hello(DEVICE);
    await m.nextOfType("welcome");
    const closing = h.app.close();
    const goodbye = await m.nextOfType("goodbye");
    expect(goodbye).toMatchObject({ body: { reason: "draining", reconnect_after_ms: 1000 } });
    expect((await m.closed).code).toBe(CLOSE_CODE.draining);
    await closing;
    harnesses = harnesses.filter((x) => x !== h);
  });

  it("retires the older session when the same device connects again", async () => {
    const h = await harness();
    const older = await mac(h.url);
    older.hello(DEVICE);
    await older.nextOfType("welcome");
    const newer = await mac(h.url);
    newer.hello(DEVICE);
    await newer.nextOfType("welcome");
    expect(await older.nextOfType("goodbye")).toMatchObject({ body: { reason: "replaced" } });
    expect((await older.closed).code).toBe(CLOSE_CODE.replaced);
  });

  it("closes a session that never says hello, and one that starts a task before hello", async () => {
    const h = await harness({ agentTiming: { heartbeatMs: 60_000, helloTimeoutMs: 200, reauthLeadMs: 1_000 } });
    const silent = await mac(h.url);
    expect((await silent.closed).code).toBe(CLOSE_CODE.protocol);
    const eager = await mac(h.url);
    eager.startTask(randomUUID());
    expect((await eager.closed).code).toBe(CLOSE_CODE.protocol);
  });

  it("answers a malformed message with an error and keeps the session", async () => {
    const h = await harness();
    const m = await mac(h.url);
    m.hello(DEVICE);
    await m.nextOfType("welcome");
    m.send({ v: 1, type: "hello", id: randomUUID(), body: {}, extra: true });
    expect(await m.nextOfType("error")).toMatchObject({ body: { code: "malformed" } });
    m.send({ v: 2, type: "reauth", id: randomUUID(), body: { access_token: "x" } });
    expect(await m.nextOfType("error")).toMatchObject({ body: { code: "unsupported_version" } });
    expect(m.socket.readyState).toBe(m.socket.OPEN);
  });

  it("closes 4429 when an account sends faster than its rate", async () => {
    const h = await harness({ agentMessageRate: { burst: 3, perSecond: 0.001 } });
    const m = await mac(h.url);
    m.hello(DEVICE);
    // Malformed frames: each is answered with an error and never closes the session by itself, so
    // the only close can be the rate limit's.
    for (let index = 0; index < 5; index += 1) {
      m.send({ v: 1, type: "nonsense", id: randomUUID(), body: {} });
    }
    expect((await m.closed).code).toBe(CLOSE_CODE.rate_limited);
  });

  it("stops a task on cancel, including a turn that is still thinking", async () => {
    const thinking: Agent = { turn: (context) => new Promise((_resolve, reject) => context.signal.addEventListener("abort", () => reject(new Error("aborted")))) };
    const h = await harness({ agentFactory: () => thinking });
    const m = await mac(h.url);
    m.hello(DEVICE);
    await m.nextOfType("welcome");
    const task = randomUUID();
    m.startTask(task);
    await wait(50);
    m.send({ v: 1, type: "task.cancel", id: randomUUID(), task, seq: m.nextSeq(task), body: { reason: "user" } });
    expect(await m.nextOfType("finish")).toMatchObject({ task, body: { status: "cancelled", reason: "cancelled" } });
    expect((await h.store.task(task))?.status).toBe("cancelled");
  });

  it("refuses a task id another account already holds", async () => {
    const store = memoryTaskStore();
    const task = randomUUID();
    await store.createTask(
      {
        id: task,
        accountId: "someone-else",
        deviceId: DEVICE,
        isPrivate: false,
        unattended: false,
        goal: "theirs",
        origin: "composer",
        mode: "normal",
        priorTask: null,
        start: { msgId: randomUUID(), body: {} },
      },
      new Date(),
    );
    const h = await harness({ store });
    const m = await mac(h.url);
    m.hello(DEVICE);
    await m.nextOfType("welcome");
    m.startTask(task);
    expect(await m.nextOfType("error")).toMatchObject({ body: { code: "task_conflict" } });
  });

  it("ends a task with internal_error when its agent breaks the protocol", async () => {
    const h = await harness({ agentFactory: () => ({ turn: () => Promise.resolve({ messages: [{ type: "progress", body: { message: "thinking" } }] }) }) });
    const m = await mac(h.url);
    m.hello(DEVICE);
    await m.nextOfType("welcome");
    const task = randomUUID();
    m.startTask(task);
    expect(await m.nextOfType("finish")).toMatchObject({ body: { status: "failed", reason: "internal_error" } });
  });
});

describe("token credits inside a task", () => {
  it("charges each model call by the tokens it used, at its tier's rate", async () => {
    const ledger = memoryModelCallLedger(1000);
    const h = await harness({
      ledger,
      agentFactory: scriptedAgent([{ modelCall: { inputTokens: 3000, outputTokens: 500 }, messages: [proposeOpen()] }]),
    });
    const m = await mac(h.url);
    m.hello(DEVICE);
    await m.nextOfType("welcome");
    const task = randomUUID();
    m.startTask(task);
    await m.nextOfType("propose");

    const calls = [...ledger.calls.values()];
    expect(calls).toHaveLength(1);
    expect(calls[0]!.hold).toMatchObject({ taskId: task, tier: "fast", agent: "planner", credits: 12 });
    expect(calls[0]!.settle).toMatchObject({ credits: 3.5, inputTokens: 3000, outputTokens: 500, outcome: "ok" });
    expect(ledger.remaining()).toBe(996.5);
    expect((await h.store.task(task))?.modelCalls).toBe(1);
  });

  it("stops a task before its next model call when the balance can't cover it", async () => {
    const ledger = memoryModelCallLedger(20);
    const h = await harness({
      ledger,
      agentFactory: scriptedAgent([
        { modelCall: { inputTokens: 10_000, outputTokens: 2_000 }, messages: [proposeOpen()] },
        { modelCall: { inputTokens: 10_000, outputTokens: 2_000 }, messages: [proposeOpen()] },
      ]),
    });
    const m = await mac(h.url);
    m.hello(DEVICE);
    await m.nextOfType("welcome");
    const task = randomUUID();
    m.startTask(task);
    const propose = await m.nextOfType("propose");
    m.outcomeFor(propose);
    expect(await m.nextOfType("finish")).toMatchObject({
      task,
      body: { status: "failed", reason: "credits_exhausted" },
    });
    expect(ledger.calls.size).toBe(1);
    expect((await h.store.task(task))?.status).toBe("failed");
  });

  it("charges nothing for a call whose provider failed", async () => {
    const ledger = memoryModelCallLedger(1000);
    const failing: Agent = {
      async turn(context) {
        await context.modelCall(
          { agent: "screen", tier: "standard", maxInputTokens: 1000, maxOutputTokens: 1000 },
          () => Promise.reject(new Error("provider down")),
        );
        return { messages: [] };
      },
    };
    const h = await harness({ ledger, agentFactory: () => failing });
    const m = await mac(h.url);
    m.hello(DEVICE);
    await m.nextOfType("welcome");
    m.startTask(randomUUID());
    expect(await m.nextOfType("finish")).toMatchObject({ body: { reason: "internal_error" } });
    const [call] = [...ledger.calls.values()];
    expect(call!.settle).toMatchObject({ credits: 0, outcome: "provider_error" });
    expect(ledger.remaining()).toBe(1000);
  });
});

describe("task retention", () => {
  it("deletes a private task's transcript when it ends", async () => {
    const h = await harness({ agentFactory: scriptedAgent([]) });
    const m = await mac(h.url);
    m.hello(DEVICE);
    await m.nextOfType("welcome");
    const task = randomUUID();
    m.startTask(task, { private: true });
    expect(await m.nextOfType("finish")).toMatchObject({ task, body: { status: "completed" } });
    expect(await h.store.task(task)).toBeUndefined();
    expect(await h.store.transcript(task)).toEqual([]);
  });

  it("tells a Mac that comes back after a day that its abandoned task has ended", async () => {
    const h = await harness({ agentFactory: scriptedAgent([{ messages: [proposeOpen()] }]) });
    const first = await mac(h.url);
    first.hello(DEVICE);
    await first.nextOfType("welcome");
    const task = randomUUID();
    first.startTask(task);
    await first.nextOfType("propose");
    // The Mac goes away without answering, and stays away past the abandonment window.
    first.socket.terminate();
    await h.app.agentRunner!.idle();
    const touched = (await h.store.task(task))!.updatedAt;
    const later = new Date(touched.getTime() + TASK_ABANDON_AFTER_MS);
    expect(await sweepTasksOnce({ store: h.store, ledger: h.ledger, pruneReplies: noReplies, now: () => later })).toMatchObject({ abandoned: 1 });

    const back = await mac(h.url);
    back.setSeq(task, 1);
    back.hello(DEVICE, [{ task, last_seq_in: 1, last_seq_out: 1 }]);
    const welcome = await back.nextOfType("welcome");
    expect(welcome.type === "welcome" && welcome.body.tasks).toEqual([{ task, state: "finished", last_seq_in: 1 }]);
    expect(await back.nextOfType("finish")).toMatchObject({ task, seq: 2, body: { status: "failed" } });
  });

  it("keeps an ordinary task for 30 days after it ends, then deletes it", async () => {
    const h = await harness({ agentFactory: scriptedAgent([]) });
    const m = await mac(h.url);
    m.hello(DEVICE);
    await m.nextOfType("welcome");
    const task = randomUUID();
    m.startTask(task);
    await m.nextOfType("finish");
    const ended = (await h.store.task(task))!.endedAt!;

    const almost = new Date(ended.getTime() + TASK_RETENTION_MS - 1000);
    await sweepTasksOnce({ store: h.store, ledger: h.ledger, pruneReplies: noReplies, now: () => almost });
    expect(await h.store.task(task)).toBeDefined();

    const after = new Date(ended.getTime() + TASK_RETENTION_MS);
    expect(await sweepTasksOnce({ store: h.store, ledger: h.ledger, pruneReplies: noReplies, now: () => after })).toMatchObject({ deleted: 1 });
    expect(await h.store.task(task)).toBeUndefined();
  });
});
