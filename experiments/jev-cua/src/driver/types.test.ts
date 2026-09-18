import { describe, expect, it } from "vitest";
import { actionResultSchema, DriverRefusal, parseToolPayload, windowStateSchema } from "./types.ts";

describe("parseToolPayload", () => {
  it("turns both documented refusal shapes into a DriverRefusal carrying the code", () => {
    expect(() => parseToolPayload("click", true, { status: "refused", refusal: { code: "stale_element_token", message: "re-snapshot" } }, actionResultSchema))
      .toThrow(expect.objectContaining({ name: "DriverRefusal", code: "stale_element_token", tool: "click" }));
    expect(() => parseToolPayload("click", true, { code: "window_target_not_found", effect: "refused", candidates: [], pid: 4711 }, actionResultSchema))
      .toThrow(expect.objectContaining({ code: "window_target_not_found" }));
  });

  it("recognises a refusal even when the transport did not flag it as an error", () => {
    expect(() => parseToolPayload("click", false, { status: "refused", refusal: { code: "permissions_pending" } }, actionResultSchema))
      .toThrow(DriverRefusal);
  });

  it("names the tool and the first mismatched field when the shape is not one it reads", () => {
    expect(() => parseToolPayload("get_window_state", false, { pid: 1 }, windowStateSchema)).toThrow(/get_window_state answered a shape .*snapshot_id/);
  });

  it("wraps an unreadable error payload rather than losing it", () => {
    expect(() => parseToolPayload("click", true, { weird: true }, actionResultSchema)).toThrow(/unknown — .*weird/);
  });
});

describe("actionResultSchema", () => {
  it("normalises the escalation field from object, string, absent and null", () => {
    expect(actionResultSchema.parse({ effect: "unverifiable", escalation: { recommended: "px", reason: "electron" } }).escalation).toEqual({ recommended: "px", reason: "electron" });
    expect(actionResultSchema.parse({ effect: "unverifiable", escalation: "foreground" }).escalation).toEqual({ recommended: "foreground", reason: null });
    expect(actionResultSchema.parse({ effect: "unverifiable", escalation: "try harder" }).escalation).toEqual({ recommended: null, reason: "try harder" });
    expect(actionResultSchema.parse({ effect: "confirmed" }).escalation).toEqual({ recommended: null, reason: null });
    expect(actionResultSchema.parse({ effect: "confirmed", escalation: null }).escalation).toEqual({ recommended: null, reason: null });
    expect(actionResultSchema.parse({ effect: "unverifiable", escalation: { recommended: "unknown_rung" } }).escalation.recommended).toBeNull();
  });

  it("keeps fields it does not know about", () => {
    const parsed = actionResultSchema.parse({ effect: "confirmed", route: "accessibility", evidence: "AXValue read-back", new_field: 1 });
    expect(parsed).toMatchObject({ route: "accessibility", new_field: 1 });
  });

  it("refuses an effect outside the documented set", () => {
    expect(actionResultSchema.safeParse({ effect: "maybe" }).success).toBe(false);
  });
});

describe("windowStateSchema", () => {
  it("defaults elements to empty and accepts a degraded tree", () => {
    const parsed = windowStateSchema.parse({ snapshot_id: "s0000abcd", pid: 1, window_id: 2, degraded_reason: "ax_window_unresolved" });
    expect(parsed.elements).toEqual([]);
    expect(parsed.degraded_reason).toBe("ax_window_unresolved");
  });

  it("accepts numeric and boolean values on elements", () => {
    const parsed = windowStateSchema.parse({ snapshot_id: "s0", pid: 1, window_id: 2, elements: [{ element_index: 1, role: "AXSlider", value: 0.5 }, { element_index: 2, role: "AXCheckBox", value: true }] });
    expect(parsed.elements.map((e) => e.value)).toEqual([0.5, true]);
  });
});
