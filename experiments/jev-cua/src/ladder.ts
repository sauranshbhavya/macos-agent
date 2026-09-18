import { createHash } from "node:crypto";
import type { ActionTarget, DeliveryMode } from "./driver/driver.ts";
import type { ActionResult, Element, WindowRecord, WindowState } from "./driver/types.ts";

/**
 * cua's action-selection policy as code. The agent starts on the accessibility rung in the
 * background and climbs only when the driver's own signals say to: `effect: "confirmed"` ends the
 * ladder, a fresh snapshot that changed ends it, an explicit `escalation.recommended` names the
 * next rung, and an unverifiable or no-op result with no recommendation climbs one rung.
 *
 * The page rung (browser-tab DOM through the `page` tool) is not built in this MVP: a "page"
 * recommendation climbs to foreground instead and the report says so, because the policy page
 * ranks it below foreground and the browser tasks first need to show where the AX rungs fall down.
 */

export const RUNGS = ["ax", "px", "foreground"] as const;
export type Rung = (typeof RUNGS)[number];

export type LadderVerdict =
  | { kind: "settled"; reason: "confirmed" | "window_changed" | "value_matches" }
  | { kind: "climb"; to: Rung; reason: string }
  | { kind: "exhausted"; reason: string };

export function nextRung(current: Rung, result: ActionResult, evidence: { windowChanged: boolean; valueMatches: boolean }): LadderVerdict {
  if (result.effect === "confirmed") return { kind: "settled", reason: "confirmed" };
  if (evidence.valueMatches) return { kind: "settled", reason: "value_matches" };
  if (evidence.windowChanged) return { kind: "settled", reason: "window_changed" };

  const recommended = result.escalation.recommended;
  const climbTo = (to: Rung, reason: string): LadderVerdict =>
    RUNGS.indexOf(to) > RUNGS.indexOf(current) ? { kind: "climb", to, reason } : { kind: "exhausted", reason };

  if (recommended === "px") return climbTo("px", `driver recommended px: ${result.escalation.reason ?? "no reason given"}`);
  if (recommended === "foreground") {
    return climbTo("foreground", `driver recommended foreground: ${result.escalation.reason ?? "no reason given"}`);
  }
  if (recommended === "page") {
    return climbTo("foreground", `driver recommended page (not built); climbing to foreground: ${result.escalation.reason ?? ""}`);
  }
  const index = RUNGS.indexOf(current);
  const next = RUNGS[index + 1];
  if (next === undefined) return { kind: "exhausted", reason: `${result.effect} on the last rung with no window change` };
  return { kind: "climb", to: next, reason: `${result.effect} with no window change and no recommendation` };
}

export function deliveryFor(rung: Rung): DeliveryMode {
  return rung === "foreground" ? "foreground" : "background";
}

/**
 * The px rung addresses the element's centre in window-local screenshot pixels. Element frames are
 * screen-absolute (documented under Known limits), so the window's bounds are subtracted and the
 * screenshot scale applied. `null` when the geometry to do that is missing — the rung is then
 * skipped rather than aimed at a guess.
 */
export function pixelTarget(
  element: Element,
  state: WindowState,
  window: WindowRecord | null,
): { x: number; y: number } | null {
  const frame = element.frame;
  const bounds = window?.bounds;
  if (!frame || !bounds) return null;
  const scale = screenshotScale(state, bounds);
  return {
    x: Math.round((frame.x + frame.w / 2 - bounds.x) * scale),
    y: Math.round((frame.y + frame.h / 2 - bounds.y) * scale),
  };
}

function screenshotScale(state: WindowState, bounds: { width: number }): number {
  const explicit = (state as Record<string, unknown>)["screenshot_scale"];
  if (typeof explicit === "number" && explicit > 0) return explicit;
  if (typeof state.screenshot_width === "number" && bounds.width > 0) return state.screenshot_width / bounds.width;
  return 1;
}

export function targetFor(
  rung: Rung,
  element: Element | null,
  state: WindowState,
  window: WindowRecord | null,
): ActionTarget | null {
  const base = { pid: state.pid, windowId: state.window_id };
  // A key press has no element: the px rung would repeat the ax call, so it is skipped for foreground.
  if (element === null) return rung === "px" ? null : { kind: "focused", ...base };
  if (rung === "px") {
    const point = pixelTarget(element, state, window);
    return point === null ? null : { kind: "pixel", ...base, ...point };
  }
  return {
    kind: "element",
    ...base,
    snapshotId: state.snapshot_id,
    elementIndex: element.element_index,
    ...(element.element_token ? { elementToken: element.element_token } : {}),
  };
}

/** What "the window changed" compares: title plus every element's index, role, label and value. */
export function fingerprint(state: WindowState): string {
  const hash = createHash("sha1");
  hash.update(state.window_title ?? "");
  for (const e of state.elements) {
    hash.update(`\n${e.element_index}|${e.role}|${e.label ?? ""}|${e.value ?? ""}|${e.selected ?? ""}|${e.focused ?? ""}`);
  }
  return hash.digest("hex");
}
