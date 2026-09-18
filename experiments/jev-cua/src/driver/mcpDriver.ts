import { McpDriverConnection } from "./mcpClient.ts";
import type { ActionTarget, DeliveryMode, Driver, ScrollDirection } from "./driver.ts";
import {
  actionResultSchema,
  launchResultSchema,
  listWindowsSchema,
  parseToolPayload,
  windowStateSchema,
  type ActionResult,
  type LaunchResult,
  type WindowRecord,
  type WindowState,
} from "./types.ts";

/** The real driver: every method is one `cua-driver` tool call, validated on the way back. */
export class McpDriver implements Driver {
  #connection: McpDriverConnection;

  private constructor(connection: McpDriverConnection) {
    this.#connection = connection;
  }

  static async open(binary?: string): Promise<McpDriver> {
    return new McpDriver(await McpDriverConnection.open(binary));
  }

  async launchApp(bundleId: string, urls?: readonly string[]): Promise<LaunchResult> {
    const result = await this.#connection.call("launch_app", {
      bundle_id: bundleId,
      ...(urls === undefined ? {} : { urls: [...urls] }),
    });
    return parseToolPayload("launch_app", result.isError, result.payload, launchResultSchema);
  }

  async listWindows(pid: number): Promise<WindowRecord[]> {
    const result = await this.#connection.call("list_windows", { pid, on_screen_only: false });
    return parseToolPayload("list_windows", result.isError, result.payload, listWindowsSchema).windows;
  }

  async bringToFront(pid: number, windowId?: number): Promise<void> {
    // Without a window_id the driver refuses an app with several windows (`ambiguous_window_target`).
    const result = await this.#connection.call("bring_to_front", { pid, ...(windowId === undefined ? {} : { window_id: windowId }) });
    if (result.isError) parseToolPayload("bring_to_front", true, result.payload, actionResultSchema);
  }

  async windowState(
    pid: number,
    windowId: number,
    options: { screenshot?: boolean; maxElements?: number } = {},
  ): Promise<WindowState> {
    const result = await this.#connection.call("get_window_state", {
      pid,
      window_id: windowId,
      include_screenshot: options.screenshot ?? false,
      ...(options.maxElements === undefined ? {} : { max_elements: options.maxElements }),
    });
    const state = parseToolPayload("get_window_state", result.isError, result.payload, windowStateSchema);
    // 0.28.2 sends no window_title; the AXWindow element's label is the title (SONNY-517 probe).
    if (!state.window_title) {
      const windowElement = state.elements.find((e) => e.role === "AXWindow" && e.label);
      if (windowElement?.label) return { ...state, window_title: windowElement.label };
    }
    return state;
  }

  async click(target: ActionTarget, delivery: DeliveryMode): Promise<ActionResult> {
    return this.#action("click", { ...addressing(target), delivery_mode: delivery });
  }

  async typeText(target: ActionTarget, text: string, delivery: DeliveryMode): Promise<ActionResult> {
    return this.#action("type_text", { ...addressing(target), text, delivery_mode: delivery });
  }

  async pressKey(target: ActionTarget, key: string, delivery: DeliveryMode): Promise<ActionResult> {
    return this.#action("press_key", { ...addressing(target), key, delivery_mode: delivery });
  }

  async hotkey(target: ActionTarget, keys: readonly string[], delivery: DeliveryMode): Promise<ActionResult> {
    return this.#action("hotkey", { ...addressing(target), keys: [...keys], delivery_mode: delivery });
  }

  async scroll(
    target: ActionTarget,
    direction: ScrollDirection,
    amount: number,
    delivery: DeliveryMode,
  ): Promise<ActionResult> {
    return this.#action("scroll", { ...addressing(target), direction, amount, delivery_mode: delivery });
  }

  async close(): Promise<void> {
    await this.#connection.close();
  }

  async #action(tool: string, args: Record<string, unknown>): Promise<ActionResult> {
    const result = await this.#connection.call(tool, args);
    return parseToolPayload(tool, result.isError, result.payload, actionResultSchema);
  }
}

/**
 * The driver's addressing modes: an element (accessibility rung, carrying the snapshot it came
 * from so a stale index fails closed), a pixel (window-local screenshot coordinates), or nothing
 * beyond the window (the pid's focused element, which is what a bare Return key wants).
 */
export function addressing(target: ActionTarget): Record<string, unknown> {
  switch (target.kind) {
    case "element":
      return {
        pid: target.pid,
        window_id: target.windowId,
        snapshot_id: target.snapshotId,
        element_index: target.elementIndex,
        ...(target.elementToken === undefined ? {} : { element_token: target.elementToken }),
      };
    case "pixel":
      return { pid: target.pid, window_id: target.windowId, x: target.x, y: target.y };
    case "focused":
      return { pid: target.pid, window_id: target.windowId };
  }
}
