import { describe, expect, it } from "vitest";
import { buildActionSpace, MAX_TARGETS_PER_OPERATION, normalizeRole, operationsFor } from "./actionSpace.ts";
import { element } from "./testSupport/fakes.ts";

describe("normalizeRole", () => {
  it("strips the AX prefix, separators and case so both driver spellings meet", () => {
    expect(normalizeRole("AXTextField")).toBe("textfield");
    expect(normalizeRole("text_field")).toBe("textfield");
    expect(normalizeRole("Text Field")).toBe("textfield");
  });
});

describe("operationsFor", () => {
  it("offers CLICK to anything that exposes a press-like action, whatever its role", () => {
    expect(operationsFor(element({ element_index: 1, role: "AXStaticText", actions: ["AXPress"] }))).toEqual(["CLICK"]);
    expect(operationsFor(element({ element_index: 2, role: "AXImage", actions: ["AXPick"] }))).toEqual(["CLICK"]);
  });

  it("offers CLICK to known clickable roles even when the driver omits actions", () => {
    expect(operationsFor(element({ element_index: 1, role: "AXLink", actions: null }))).toEqual(["CLICK"]);
    expect(operationsFor(element({ element_index: 2, role: "AXCheckBox", actions: undefined }))).toEqual(["CLICK"]);
  });

  it("offers TYPE_TEXT only to editable roles, and both to a combo box", () => {
    expect(operationsFor(element({ element_index: 1, role: "AXTextField", actions: null }))).toEqual(["TYPE_TEXT"]);
    expect(operationsFor(element({ element_index: 2, role: "AXTextArea", actions: [] }))).toEqual(["TYPE_TEXT"]);
    expect(operationsFor(element({ element_index: 3, role: "AXComboBox", actions: null }))).toEqual(["CLICK", "TYPE_TEXT"]);
  });

  it("never offers a password field as a typing target", () => {
    expect(operationsFor(element({ element_index: 1, role: "AXSecureTextField", actions: null }))).toEqual([]);
  });

  it("offers nothing to plain text", () => {
    expect(operationsFor(element({ element_index: 1, role: "AXStaticText", actions: null }))).toEqual([]);
  });
});

describe("buildActionSpace", () => {
  it("keys candidates by the driver's element_index so a log line reads against the tree", () => {
    const space = buildActionSpace([element({ element_index: 12, label: "Search" }), element({ element_index: 30, role: "AXTextField", actions: null, label: "Where to?" })]);
    expect(space.candidates.map((c) => c.key)).toEqual(["12", "30"]);
    expect(Object.keys(space.targets.CLICK)).toEqual(["12"]);
    expect(Object.keys(space.targets.TYPE_TEXT)).toEqual(["30"]);
    expect(space.targets.CLICK["12"]?.label).toBe("Search");
  });

  it("drops disabled elements and the 1px frames virtualised rows come back with", () => {
    const space = buildActionSpace([
      element({ element_index: 1, enabled: false }),
      element({ element_index: 2, frame: { x: 0, y: 0, w: 120, h: 1 } }),
      element({ element_index: 3 }),
    ]);
    expect(space.candidates.map((c) => c.key)).toEqual(["3"]);
  });

  it("gives an unlabeled control its role as a label rather than an empty string", () => {
    const space = buildActionSpace([element({ element_index: 1, label: "  " }), element({ element_index: 2, label: null, value: "42" })]);
    expect(space.candidates[0]?.label).toBe("unlabeled button");
    expect(space.candidates[1]?.label).toBe("42");
  });

  it("clips long labels and values and collapses whitespace", () => {
    const space = buildActionSpace([element({ element_index: 1, label: `a  b\n${"x".repeat(200)}`, value: "y".repeat(300) })]);
    expect(space.candidates[0]?.label.length).toBe(120);
    expect(space.candidates[0]?.label.startsWith("a b x")).toBe(true);
    expect(space.candidates[0]?.value?.length).toBe(200);
  });

  it("caps each operation at the Choice limit and counts what it dropped", () => {
    const elements = Array.from({ length: MAX_TARGETS_PER_OPERATION + 5 }, (_, i) => element({ element_index: i + 1 }));
    const space = buildActionSpace(elements);
    expect(Object.keys(space.targets.CLICK)).toHaveLength(MAX_TARGETS_PER_OPERATION);
    expect(space.truncated.CLICK).toBe(5);
    expect(space.truncated.TYPE_TEXT).toBe(0);
    // The candidate table still lists every element; only the target head is capped.
    expect(space.candidates).toHaveLength(MAX_TARGETS_PER_OPERATION + 5);
  });
});
