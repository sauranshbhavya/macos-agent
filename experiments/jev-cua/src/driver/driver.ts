import type { ActionResult, LaunchResult, WindowRecord, WindowState } from "./types.ts";

/**
 * The seam between the loop and cua-driver. `McpDriver` is the real one; tests hand the executor a
 * scripted implementation. The shape mirrors the driver's own tools one-to-one, so nothing here has
 * to be re-learned when reading `cua-driver describe <tool>`.
 */

export type DeliveryMode = "background" | "foreground";

/** How an action names its target — the three rungs the policy page draws. */
export type ActionTarget =
  | { kind: "element"; pid: number; windowId: number; snapshotId: string; elementIndex: number; elementToken?: string }
  | { kind: "pixel"; pid: number; windowId: number; x: number; y: number }
  | { kind: "focused"; pid: number; windowId: number };

export type ScrollDirection = "up" | "down" | "left" | "right";

export interface Driver {
  launchApp(bundleId: string, urls?: readonly string[]): Promise<LaunchResult>;
  listWindows(pid: number): Promise<WindowRecord[]>;
  /** Activate the app and leave it in front — the one deliberate focus change, taken once at launch. */
  bringToFront(pid: number, windowId?: number): Promise<void>;
  windowState(pid: number, windowId: number, options?: { screenshot?: boolean; maxElements?: number }): Promise<WindowState>;
  click(target: ActionTarget, delivery: DeliveryMode): Promise<ActionResult>;
  typeText(target: ActionTarget, text: string, delivery: DeliveryMode): Promise<ActionResult>;
  pressKey(target: ActionTarget, key: string, delivery: DeliveryMode): Promise<ActionResult>;
  hotkey(target: ActionTarget, keys: readonly string[], delivery: DeliveryMode): Promise<ActionResult>;
  scroll(target: ActionTarget, direction: ScrollDirection, amount: number, delivery: DeliveryMode): Promise<ActionResult>;
  close(): Promise<void>;
}
