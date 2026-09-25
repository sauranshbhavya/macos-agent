/**
 * One task, two agents (V2 plan decision 7): the planner owns the task and hands work inside an app
 * to the screen agent. Both run inside the same turn loop, budget and cancellation.
 *
 * Which agent is active is read off the transcript: a `screen.start` note with no `screen.result`
 * after it means the screen agent has the task. Its result goes back to the planner in the same
 * turn, so the planner decides what happens next without another round trip to the Mac.
 */
import { randomUUID } from "node:crypto";
import type { Agent, AgentFactory, AgentNote, TurnContext, TurnResult } from "./agent.js";
import type { ModelRouter } from "./model/router.js";
import { Planner } from "./planner/planner.js";
import { ScreenAgent, type ScreenResult, type ScreenTaskSpec } from "./screen/screen-agent.js";
import type { StoredMessage } from "./tasks/store.js";

/** How many agent hand-offs one turn may make before it must answer the Mac. */
const MAX_HOPS = 6;

function asNote(note: AgentNote): StoredMessage {
  return { direction: "note", seq: 0, re: null, msgId: randomUUID(), type: note.type, body: note.body, createdAt: new Date(0) };
}

/** The screen session in progress, if any: its spec and every entry after it started. */
function activeScreenSession(transcript: readonly StoredMessage[]): { spec: ScreenTaskSpec; session: StoredMessage[] } | undefined {
  let start = -1;
  for (let index = transcript.length - 1; index >= 0; index -= 1) {
    const message = transcript[index]!;
    if (message.direction !== "note") continue;
    if (message.type === "screen.result") return undefined;
    if (message.type === "screen.start") {
      start = index;
      break;
    }
  }
  if (start === -1) return undefined;
  return { spec: transcript[start]!.body as ScreenTaskSpec, session: transcript.slice(start + 1) };
}

export class TaskAgent implements Agent {
  private readonly planner: Planner;
  private readonly screen: ScreenAgent;

  constructor(router: ModelRouter) {
    this.planner = new Planner(router);
    this.screen = new ScreenAgent(router);
  }

  async turn(context: TurnContext): Promise<TurnResult> {
    const notes: AgentNote[] = [];
    const view = (): StoredMessage[] => [...context.transcript, ...notes.map(asNote)];

    for (let hop = 0; hop < MAX_HOPS; hop += 1) {
      context.signal.throwIfAborted();
      const active = activeScreenSession(view());
      if (active) {
        const step = await this.screen.step(context, active.spec, active.session);
        notes.push(...step.notes);
        if (step.kind === "messages") return { notes, messages: step.messages };
        notes.push({ type: "screen.result", body: step.result satisfies ScreenResult });
        continue;
      }

      const decision = await this.planner.decide(context, view());
      notes.push({ type: "planner.decision", body: decision });
      switch (decision.kind) {
        case "screen_task":
          notes.push({
            type: "screen.start",
            body: { app: decision.app, objective: decision.objective, doneWhen: decision.doneWhen } satisfies ScreenTaskSpec,
          });
          continue;
        case "ask":
          return { notes, messages: [{ type: "ask", body: { question: decision.question } }] };
        case "finish":
          return {
            notes,
            messages: [
              {
                type: "finish",
                body: {
                  status: decision.status,
                  summary: decision.summary,
                  ...(decision.status === "failed" ? { reason: "unsupported" as const } : {}),
                },
              },
            ],
          };
      }
    }
    return {
      notes,
      messages: [{ type: "finish", body: { status: "failed", summary: "Sonny went round in circles, so it stopped.", reason: "no_progress" } }],
    };
  }
}

export function taskAgentFactory(router: ModelRouter): AgentFactory {
  const agent = new TaskAgent(router);
  return () => agent;
}
