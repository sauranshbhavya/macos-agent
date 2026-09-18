import { describe, expect, it } from "vitest";
import { fingerprint, nextRung, pixelTarget, targetFor } from "./ladder.ts";
import { actionResult, element, windowRecord, windowState } from "./testSupport/fakes.ts";

const still = { windowChanged: false, valueMatches: false };

describe("nextRung", () => {
  it("settles on a confirmed effect whatever the rung", () => {
    expect(nextRung("ax", actionResult("confirmed"), still)).toEqual({ kind: "settled", reason: "confirmed" });
    expect(nextRung("foreground", actionResult("confirmed"), still)).toEqual({ kind: "settled", reason: "confirmed" });
  });

  it("settles on evidence from the fresh snapshot even when the driver could not verify", () => {
    expect(nextRung("ax", actionResult("unverifiable"), { windowChanged: true, valueMatches: false })).toEqual({ kind: "settled", reason: "window_changed" });
    expect(nextRung("ax", actionResult("unverifiable"), { windowChanged: false, valueMatches: true })).toEqual({ kind: "settled", reason: "value_matches" });
  });

  it("climbs one rung at a time when nothing moved and the driver recommends nothing", () => {
    expect(nextRung("ax", actionResult("unverifiable"), still)).toMatchObject({ kind: "climb", to: "px" });
    expect(nextRung("px", actionResult("suspected_noop"), still)).toMatchObject({ kind: "climb", to: "foreground" });
    expect(nextRung("foreground", actionResult("suspected_noop"), still)).toMatchObject({ kind: "exhausted" });
  });

  it("follows the driver's recommendation, including page → foreground since page is not built", () => {
    expect(nextRung("ax", actionResult("unverifiable", { recommended: "px", reason: "electron" }), still)).toMatchObject({ kind: "climb", to: "px", reason: expect.stringContaining("electron") });
    expect(nextRung("ax", actionResult("unverifiable", { recommended: "foreground", reason: null }), still)).toMatchObject({ kind: "climb", to: "foreground" });
    expect(nextRung("ax", actionResult("unverifiable", { recommended: "page", reason: null }), still)).toMatchObject({ kind: "climb", to: "foreground", reason: expect.stringContaining("not built") });
  });

  it("never climbs down: a recommendation at or below the current rung exhausts the ladder", () => {
    expect(nextRung("px", actionResult("unverifiable", { recommended: "px", reason: null }), still)).toMatchObject({ kind: "exhausted" });
    expect(nextRung("foreground", actionResult("refused", { recommended: "px", reason: null }), still)).toMatchObject({ kind: "exhausted" });
  });
});

describe("pixelTarget", () => {
  it("maps a screen-absolute frame centre into window-local screenshot pixels at the screenshot scale", () => {
    const el = element({ element_index: 1, frame: { x: 150, y: 260, w: 100, h: 40 } });
    const state = windowState([el], { screenshot_width: 1600 });
    const window = windowRecord({ bounds: { x: 100, y: 200, width: 800, height: 600 } });
    expect(pixelTarget(el, state, window)).toEqual({ x: 200, y: 160 });
  });

  it("prefers an explicit screenshot_scale and defaults to 1", () => {
    const el = element({ element_index: 1, frame: { x: 150, y: 260, w: 100, h: 40 } });
    const window = windowRecord({ bounds: { x: 100, y: 200, width: 800, height: 600 } });
    expect(pixelTarget(el, { ...windowState([el]), screenshot_scale: 3 } as never, window)).toEqual({ x: 300, y: 240 });
    expect(pixelTarget(el, windowState([el]), window)).toEqual({ x: 100, y: 80 });
  });

  it("refuses to aim without geometry", () => {
    const el = element({ element_index: 1, frame: null });
    expect(pixelTarget(el, windowState([el]), windowRecord())).toBeNull();
    expect(pixelTarget(element({ element_index: 2 }), windowState([]), null)).toBeNull();
    expect(pixelTarget(element({ element_index: 3 }), windowState([]), windowRecord({ bounds: null }))).toBeNull();
  });
});

describe("targetFor", () => {
  const el = element({ element_index: 5, element_token: "tok" });
  const state = windowState([el]);

  it("addresses the ax and foreground rungs by element with the snapshot it came from", () => {
    expect(targetFor("ax", el, state, null)).toEqual({ kind: "element", pid: 42, windowId: 7, snapshotId: "s00000001", elementIndex: 5, elementToken: "tok" });
    expect(targetFor("foreground", el, state, null)).toMatchObject({ kind: "element", elementIndex: 5 });
  });

  it("addresses the px rung by pixel, or not at all without bounds", () => {
    expect(targetFor("px", el, state, windowRecord())).toMatchObject({ kind: "pixel", x: 140, y: 112 });
    expect(targetFor("px", el, state, null)).toBeNull();
  });

  it("addresses a key press with no element at the focused element, and has no px rung for it", () => {
    expect(targetFor("ax", null, state, null)).toEqual({ kind: "focused", pid: 42, windowId: 7 });
    expect(targetFor("px", null, state, windowRecord())).toBeNull();
    expect(targetFor("foreground", null, state, null)).toEqual({ kind: "focused", pid: 42, windowId: 7 });
  });
});

describe("fingerprint", () => {
  it("changes when a value, a label, the title or the set of elements changes, and not otherwise", () => {
    const base = windowState([element({ element_index: 1, value: "a" })]);
    expect(fingerprint(base)).toBe(fingerprint(windowState([element({ element_index: 1, value: "a" })])));
    expect(fingerprint(base)).not.toBe(fingerprint(windowState([element({ element_index: 1, value: "b" })])));
    expect(fingerprint(base)).not.toBe(fingerprint(windowState([element({ element_index: 1, value: "a", label: "Other" })])));
    expect(fingerprint(base)).not.toBe(fingerprint(windowState([element({ element_index: 1, value: "a" })], { window_title: "Changed" })));
    expect(fingerprint(base)).not.toBe(fingerprint(windowState([element({ element_index: 1, value: "a" }), element({ element_index: 2 })])));
  });

  it("ignores frames, so a window that merely moved does not read as changed", () => {
    const a = windowState([element({ element_index: 1, frame: { x: 0, y: 0, w: 10, h: 10 } })]);
    const b = windowState([element({ element_index: 1, frame: { x: 50, y: 50, w: 10, h: 10 } })]);
    expect(fingerprint(a)).toBe(fingerprint(b));
  });
});
