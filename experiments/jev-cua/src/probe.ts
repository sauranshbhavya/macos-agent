import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { McpDriverConnection } from "./driver/mcpClient.ts";

/**
 * A raw look at what cua-driver returns, written to disk so the shapes the Zod schemas assert can
 * be read off real payloads rather than guessed. Usage: `npm run probe -- <outDir> [bundleId]`.
 */
const outDir = resolve(process.argv[2] ?? "runs/probe");
const bundleId = process.argv[3] ?? "com.apple.calculator";
mkdirSync(outDir, { recursive: true });

function dump(name: string, value: unknown): void {
  writeFileSync(resolve(outDir, `${name}.json`), JSON.stringify(value, null, 2));
  const text = JSON.stringify(value);
  console.log(`${name}: ${text.length > 400 ? `${text.slice(0, 400)}…` : text}`);
}

const driver = await McpDriverConnection.open();
try {
  dump("tools", await driver.listTools());
  dump("check_permissions", await driver.call("check_permissions", { prompt: false }));
  const launched = await driver.call("launch_app", { bundle_id: bundleId });
  dump("launch_app", launched);
  const payload = launched.payload as { pid?: number } | null;
  const pid = payload?.pid;
  if (typeof pid !== "number") {
    throw new Error("launch_app returned no pid");
  }
  await new Promise((r) => setTimeout(r, 1500));
  const windows = await driver.call("list_windows", { pid, on_screen_only: false });
  dump("list_windows", windows);
  const list = (windows.payload as { windows?: Array<{ window_id?: number; is_on_screen?: boolean }> } | null)?.windows ?? [];
  // list_windows also returns the per-display menu-bar shims (30px tall, off screen); the real window is on screen.
  const windowId = (list.find((w) => w.is_on_screen === true) ?? list[0])?.window_id;
  if (typeof windowId !== "number") {
    throw new Error("list_windows returned no window for the app");
  }
  const state = await driver.call("get_window_state", {
    pid,
    window_id: windowId,
    include_screenshot: false,
  });
  dump("get_window_state", state);
} finally {
  await driver.close();
}
