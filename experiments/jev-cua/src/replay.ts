import { readFileSync } from "node:fs";
import { TypeSafeClient } from "@typesafe-ai/sdk";
import { buildActionSpace } from "./actionSpace.ts";
import { fitToBudget, validateChoice } from "./actionModel/jev.ts";
import { visibleText } from "./executor.ts";
import { loadConfig } from "./config.ts";
import { windowStateSchema } from "./driver/types.ts";

/**
 * Replay one saved snapshot against Jev and print the raw answer: `npm run replay -- <snapshot.json>
 * "<instruction>" ["<goal>"]`. For reading a wrong pick against what was offered, without a driver.
 */
const [file, instruction, goal] = process.argv.slice(2);
if (!file || !instruction) {
  console.error('usage: npm run replay -- <runs/<task>-<time>-snapshots/NNN.json> "<instruction>" ["<goal>"]');
  process.exit(2);
}
const config = loadConfig();
const state = windowStateSchema.parse(JSON.parse(readFileSync(file, "utf8")));
const space = buildActionSpace(state.elements);
const { request, input } = fitToBudget({ instruction, goal: goal ?? instruction, window: { app: state.app_name ?? null, title: state.window_title ?? null }, visibleText: visibleText(state), space, recentActions: [] });
console.log(`elements ${state.elements.length} | candidates ${space.candidates.length} | offered CLICK ${Object.keys(input.space.targets.CLICK).length}, TYPE_TEXT ${Object.keys(input.space.targets.TYPE_TEXT).length} | truncated ${JSON.stringify(space.truncated)}`);
console.log(`request chars: state ${JSON.stringify(request.state).length}, questions ${Object.entries(request.questions).map(([k, q]) => `${k} ${JSON.stringify(q).length}`).join(", ")}`);

const client = new TypeSafeClient({ apiKey: config.TYPESAFE_API_KEY, defaultModel: config.TYPESAFE_MODEL, timeout: 20_000 });
const started = performance.now();
const result = await client.systemOne({ state: request.state, questions: request.questions });
console.log(`latency ${Math.round(performance.now() - started)} ms | usage ${JSON.stringify(result.usage)} | model ${result.model}`);

for (const [key, answer] of Object.entries(result.answers as Record<string, { choice: string; confidence: number; probabilities: Record<string, number> }>)) {
  const sum = Object.values(answer.probabilities).reduce((a, b) => a + b, 0);
  const top = Object.entries(answer.probabilities).sort((a, b) => b[1] - a[1]).slice(0, 5);
  let verdict = "valid";
  try {
    validateChoice(answer, Object.keys(answer.probabilities));
  } catch (error) {
    verdict = error instanceof Error ? error.message : String(error);
  }
  console.log(`\n${key}: choice ${answer.choice} | confidence ${answer.confidence.toFixed(3)} | ${Object.keys(answer.probabilities).length} keys | sum ${sum.toFixed(5)} | ${verdict}`);
  for (const [k, p] of top) {
    const label = key === "click_target" ? input.space.targets.CLICK[k]?.label : key === "type_text_target" ? input.space.targets.TYPE_TEXT[k]?.label : null;
    console.log(`   ${p.toFixed(3)}  ${k}${label ? `  ${label}` : ""}`);
  }
}
