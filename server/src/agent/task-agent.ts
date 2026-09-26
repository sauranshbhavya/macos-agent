/**
 * One task, two agents (V2 plan decision 7): the planner owns the task and hands work inside an app
 * to the screen agent. Both run inside the same turn loop, budget and cancellation.
 *
 * Which agent is active is read off the transcript: a `screen.start` note with no `screen.result`
 * after it means the screen agent has the task. Its result goes back to the planner in the same
 * turn, and so do the server tools' results (search, reading a page, a research note), so the
 * planner decides what happens next without another round trip to the Mac.
 */
import { randomUUID } from "node:crypto";
import type { SearchRequest, SearchResult, Routed } from "../model/upstream.js";
import { AgentTurnFailed, type Agent, type AgentFactory, type AgentNote, type TurnContext, type TurnResult } from "./agent.js";
import { estimateRequestTokens } from "./model/adapter.js";
import type { ModelRouter } from "./model/router.js";
import { Planner, toolNotes, type PlannerDecision, type ToolNote } from "./planner/planner.js";
import type { ActionResult } from "./protocol.js";
import { ScreenAgent, type ScreenResult, type ScreenTaskSpec } from "./screen/screen-agent.js";
import type { StoredMessage } from "./tasks/store.js";
import { PageRefused, readPublicPage, type ReadPage } from "./tools/read-page.js";
import { noteMarkdown, RESEARCH_SCHEMA, RESEARCH_SCHEMA_NAME, researchPrompt } from "./tools/research.js";

/** How many agent hand-offs and server tools one turn may use before it must answer the Mac. */
const MAX_HOPS = 12;
const SEARCH_RESULTS = 6;
const RESEARCH_MAX_OUTPUT_TOKENS = 3000;

export interface ServerTools {
  /** Web search, when the gateway has a search provider. */
  readonly search: ((request: SearchRequest) => Promise<Routed<SearchResult>>) | undefined;
  readonly readPage: (url: string, signal: AbortSignal) => Promise<ReadPage>;
}

export interface TaskAgentDeps {
  readonly router: ModelRouter;
  readonly tools: ServerTools;
  /** Skill-pack guidance for this goal, when a pack matches (`skills/`). */
  readonly skillGuidance?: (goal: string, context: { frontmostBundleID: string | undefined }) => string | undefined;
}

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

/**
 * When the last thing the Mac said answers a batch the planner marked final, and every action in it
 * is done, the task is finished with the summary the planner wrote for that case.
 */
function finishedFinalBatch(transcript: readonly StoredMessage[]): string | undefined {
  const exchanged = transcript.filter((m) => m.direction !== "note");
  const last = exchanged.at(-1);
  if (last?.direction !== "in" || last.type !== "outcome" || last.re === null) return undefined;
  const propose = exchanged.find((m) => m.direction === "out" && m.type === "propose" && m.seq === last.re);
  const body = propose?.body as { agent?: string; final?: boolean } | undefined;
  if (body?.agent !== "planner" || body.final !== true) return undefined;
  if (!(last.body as { results: ActionResult[] }).results.every((result) => result.status === "done")) return undefined;
  const decision = [...transcript]
    .reverse()
    .find((m) => m.direction === "note" && m.type === "planner.decision" && (m.body as PlannerDecision).kind === "operations");
  return (decision?.body as { summary?: string | null } | undefined)?.summary ?? "Done.";
}

export class TaskAgent implements Agent {
  private readonly planner: Planner;
  private readonly screen: ScreenAgent;

  constructor(private readonly deps: TaskAgentDeps) {
    this.planner = new Planner(deps.router);
    this.screen = new ScreenAgent(deps.router);
  }

  async turn(context: TurnContext): Promise<TurnResult> {
    const notes: AgentNote[] = [];
    try {
      return await this.hops(context, notes);
    } catch (error) {
      // Keep what earlier hops of this turn already decided (and paid for) in the transcript.
      if (notes.length > 0) throw new AgentTurnFailed(error, notes);
      throw error;
    }
  }

  private async hops(context: TurnContext, notes: AgentNote[]): Promise<TurnResult> {
    const view = (): StoredMessage[] => [...context.transcript, ...notes.map(asNote)];
    const start = context.transcript.find((m) => m.type === "task.start")?.body as
      | { context?: { frontmost_app?: { bundle_id: string } } }
      | undefined;
    const plannerContext = {
      manifest: context.manifest(),
      priorTask: await context.priorTask(),
      skillGuidance: this.deps.skillGuidance?.(context.task.goal, { frontmostBundleID: start?.context?.frontmost_app?.bundle_id }),
    };

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

      const finished = finishedFinalBatch(view());
      if (finished !== undefined) {
        return { notes, messages: [{ type: "finish", body: { status: "completed", summary: finished } }] };
      }

      const decision = await this.planner.decide(context, view(), plannerContext);
      notes.push({ type: "planner.decision", body: decision });
      switch (decision.kind) {
        case "operations":
          return {
            notes,
            messages: [{ type: "propose", body: { agent: "planner", actions: decision.actions, final: decision.final } }],
          };
        case "screen_task":
          notes.push({
            type: "screen.start",
            body: {
              app: decision.app,
              objective: decision.objective,
              doneWhen: decision.doneWhen,
              request: context.task.goal,
            } satisfies ScreenTaskSpec,
          });
          continue;
        case "web_search":
        case "read_page":
        case "research_note":
          notes.push({ type: "tool.result", body: await this.serverTool(context, decision, toolNotes(view())) });
          continue;
        case "ask":
          // A task on a schedule has nobody to answer: it stops and says what it needed, rather than
          // holding the Mac while the question waits.
          if (context.task.unattended) {
            return {
              notes,
              messages: [
                {
                  type: "finish",
                  body: { status: "failed", summary: `This needed your answer, so Sonny stopped: ${decision.question}`, reason: "refused" },
                },
              ],
            };
          }
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

  /** Runs one server tool and records what it found as a note the planner can read and cite. */
  private async serverTool(
    context: TurnContext,
    decision: Extract<PlannerDecision, { kind: "web_search" | "read_page" | "research_note" }>,
    earlier: readonly ToolNote[],
  ): Promise<ToolNote> {
    const index = earlier.length + 1;
    switch (decision.kind) {
      case "web_search": {
        const search = this.deps.tools.search;
        if (!search) {
          return { tool: "web_search", index, label: `web search "${decision.query}"`, content: "Web search isn't available on this server." };
        }
        const found = await search({ query: decision.query, maxResults: SEARCH_RESULTS, signal: context.signal });
        const content = found.items.length === 0
          ? "No results."
          : found.items.map((item) => `${item.title} — ${item.url}${item.snippet ? `\n${item.snippet.slice(0, 400)}` : ""}`).join("\n\n");
        return { tool: "web_search", index, label: `web search "${decision.query}"`, content };
      }
      case "read_page": {
        try {
          const page = await this.deps.tools.readPage(decision.url, context.signal);
          return {
            tool: "read_page",
            index,
            url: decision.url,
            label: `page ${page.url}${page.title ? ` "${page.title}"` : ""}`,
            content: page.text + (page.truncated ? "\n[the page goes on]" : ""),
          };
        } catch (error) {
          const reason = error instanceof PageRefused ? error.message : "it couldn't be read";
          return { tool: "read_page", index, url: decision.url, label: `page ${decision.url}`, content: `Not read: ${reason}.` };
        }
      }
      case "research_note": {
        const pages = earlier
          .filter((note) => note.tool === "read_page" && note.url !== undefined && !note.content.startsWith("Not read:"))
          .filter((note) => decision.sources.includes(note.url!))
          .map((note) => ({ url: note.url!, title: null, text: note.content }));
        if (pages.length === 0) {
          return { tool: "research_note", index, label: "research note (not written)", content: "None of those pages has been read yet; read them first." };
        }
        const prompt = researchPrompt(decision.instruction, pages);
        const request = { ...prompt, images: [] };
        const text = await context.modelCall(
          { agent: "planner", tier: "standard", maxInputTokens: estimateRequestTokens(request) + 200, maxOutputTokens: RESEARCH_MAX_OUTPUT_TOKENS },
          (signal) =>
            this.deps.router.run("standard", {
              ...request,
              schemaName: RESEARCH_SCHEMA_NAME,
              schema: RESEARCH_SCHEMA,
              maxOutputTokens: RESEARCH_MAX_OUTPUT_TOKENS,
              signal,
            }),
        );
        const markdown = noteMarkdown(text, pages);
        if (markdown === null) {
          return { tool: "research_note", index, label: "research note (not written)", content: "The note couldn't be written from those pages." };
        }
        const title = markdown.split("\n")[0]?.replace(/^# /, "") ?? "Research note";
        return { tool: "research_note", index, label: `research note "${title}", ${markdown.length} characters`, content: markdown };
      }
    }
  }
}

export function taskAgentFactory(deps: TaskAgentDeps): AgentFactory {
  const agent = new TaskAgent(deps);
  return () => agent;
}

/** The server tools with the gateway's real search provider and page reader. */
export function serverTools(search: ServerTools["search"]): ServerTools {
  return { search, readPage: (url, signal) => readPublicPage(url, { signal }) };
}
