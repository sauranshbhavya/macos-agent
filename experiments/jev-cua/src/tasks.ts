import type { Task } from "./agent.ts";

/**
 * The first benchmark set (SONNY-517 kickoff decision): three native apps and two Safari pages.
 * Safari rather than Chrome for the browser tasks because WebKit exposes page content through the
 * accessibility tree without any setup, which is what the accessibility-first ladder needs; the
 * Chrome/CDP route is a later comparison. The flight task stops at the results list by design.
 */
export const TASKS: readonly Task[] = [
  {
    id: "calculator",
    goal: "Use Calculator to work out 48 times 37 and leave the answer showing on the display.",
    app: { bundleId: "com.apple.calculator" },
    humanCheck: "The Calculator display shows 1776.",
  },
  {
    id: "textedit",
    goal: "In TextEdit, start a new document and type exactly this sentence into it: The quick brown fox jumps over the lazy dog.",
    app: { bundleId: "com.apple.TextEdit" },
    humanCheck: "An untitled TextEdit document contains that one sentence and nothing else.",
  },
  {
    id: "settings",
    goal: "Open the Displays pane of System Settings.",
    app: { bundleId: "com.apple.systempreferences" },
    humanCheck: "System Settings is showing the Displays pane.",
  },
  {
    id: "wikipedia",
    goal: "In Safari, use Wikipedia's search to find the article about the Eiffel Tower and open it.",
    app: { bundleId: "com.apple.Safari", urls: ["https://en.wikipedia.org/wiki/Main_Page"] },
    humanCheck: "Safari is on the English Wikipedia article titled Eiffel Tower.",
  },
  {
    id: "flights",
    goal:
      "In Safari on Google Flights, search for one-way flights from Zurich to London on 20 October 2026 for one adult in economy, " +
      "and stop as soon as the list of flight results is showing. Do not sign in, do not pick a flight, and do not book anything.",
    app: { bundleId: "com.apple.Safari", urls: ["https://www.google.com/travel/flights?hl=en"] },
    humanCheck: "Google Flights shows a one-way ZRH to LHR/London results list for 20 Oct 2026, one adult, economy; nothing selected or booked.",
  },
];

export function findTask(id: string): Task | undefined {
  return TASKS.find((t) => t.id === id);
}
