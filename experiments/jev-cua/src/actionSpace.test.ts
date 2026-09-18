import { describe, expect, it } from "vitest";
import { buildActionSpace, limitTargets, MAX_TARGETS_PER_OPERATION, normalizeRole, offeredCandidates, operationsFor } from "./actionSpace.ts";
import { element } from "./testSupport/fakes.ts";

describe("normalizeRole", () => {
  it("strips the AX prefix, separators and case so both driver spellings meet", () => {
    expect(normalizeRole("AXTextField")).toBe("textfield");
    expect(normalizeRole("text_field")).toBe("textfield");
    expect(normalizeRole("Text Field")).toBe("textfield");
  });
});

describe("operationsFor", () => {
  it("offers CLICK to a control that exposes a press-like action, whatever its role", () => {
    expect(operationsFor(element({ element_index: 1, role: "AXCell", actions: ["AXPress"] }))).toEqual(["CLICK"]);
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

  it("offers a combobox for both clicking and typing, web or native, since the tree cannot tell a dropdown from an entry", () => {
    expect(operationsFor(element({ element_index: 1, role: "AXComboBox", actions: ["AXPress"], in_web_content: true }))).toEqual(["CLICK", "TYPE_TEXT"]);
    expect(operationsFor(element({ element_index: 2, role: "AXComboBox", actions: ["AXPress"], in_web_content: false }))).toEqual(["CLICK", "TYPE_TEXT"]);
    expect(operationsFor(element({ element_index: 3, role: "AXTextField", actions: ["AXPress"], in_web_content: true }))).toEqual(["CLICK", "TYPE_TEXT"]);
  });

  it("never offers a password field as a typing target", () => {
    expect(operationsFor(element({ element_index: 1, role: "AXSecureTextField", actions: null }))).toEqual([]);
  });

  it("offers nothing to plain text unless it carries a real press, and never for a context menu alone", () => {
    expect(operationsFor(element({ element_index: 1, role: "AXStaticText", actions: null }))).toEqual([]);
    // WebKit's right-click menu, present on every node of Wikipedia's main page: not a press.
    expect(operationsFor(element({ element_index: 2, role: "AXStaticText", actions: ["AXShowMenu", "AXScrollToVisible"] }))).toEqual([]);
    // Google Flights' "One way": static text with a real press, inside a list.
    expect(operationsFor(element({ element_index: 3, role: "AXStaticText", actions: ["AXPress", "AXShowMenu"] }))).toEqual(["CLICK"]);
    expect(operationsFor(element({ element_index: 4, role: "AXList", actions: ["AXPress", "AXShowMenu"] }))).toEqual([]);
    expect(operationsFor(element({ element_index: 5, role: "AXImage", actions: ["AXPress"] }))).toEqual(["CLICK"]);
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

  it("labels menu items with their menu and sorts them after the window's own controls", () => {
    const space = buildActionSpace([
      element({ element_index: 0, role: "AXWindow", actions: ["AXRaise"], label: "Calculator" }),
      element({ element_index: 1, role: "AXMenuBar", actions: null, label: null }),
      element({ element_index: 2, role: "AXMenuBarItem", label: "File", parent_index: 1 }),
      element({ element_index: 3, role: "AXMenu", actions: null, label: null, parent_index: 2 }),
      element({ element_index: 4, role: "AXMenuItem", label: "New", parent_index: 3 }),
      element({ element_index: 5, label: "7", parent_index: 0 }),
    ]);
    expect(space.candidates.map((c) => [c.key, c.label])).toEqual([["5", "7"], ["2", "menu bar: File"], ["4", "menu File > New"]]);
  });

  it("on a browser window offers no menu items, and names and demotes the browser's own toolbar", () => {
    const space = buildActionSpace([
      element({ element_index: 1, role: "AXMenuBar", actions: null, label: null }),
      element({ element_index: 2, role: "AXMenuBarItem", label: "History", parent_index: 1 }),
      element({ element_index: 5, role: "AXTextField", actions: null, label: "smart search field", value: "https://x" }),
      element({ element_index: 3, role: "AXWebArea", actions: null, label: null }),
      element({ element_index: 4, role: "AXLink", label: "One way", parent_index: 3, in_web_content: true }),
      element({ element_index: 6, role: "AXTextField", actions: null, label: "Where else?", in_web_content: true }),
    ]);
    expect(space.candidates.map((c) => [c.key, c.label])).toEqual([["4", "One way"], ["6", "Where else?"], ["5", "browser toolbar: smart search field"]]);
  });

  it("lets the window's own controls take the cap before any menu item", () => {
    const menus = Array.from({ length: MAX_TARGETS_PER_OPERATION }, (_, i) => element({ element_index: i + 10, role: "AXMenuItem", label: `Item ${i}`, parent_index: 1 }));
    const space = buildActionSpace([element({ element_index: 1, role: "AXMenuBar", actions: null }), ...menus, element({ element_index: 5000, label: "Search" })]);
    expect(space.targets.CLICK["5000"]?.label).toBe("Search");
    expect(space.truncated.CLICK).toBe(1);
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

describe("limitTargets and offeredCandidates", () => {
  it("re-caps the same candidates and reports what the cap dropped, and offered lists only the pickable", () => {
    const space = buildActionSpace(Array.from({ length: 30 }, (_, i) => element({ element_index: i + 1 })));
    const limited = limitTargets(space, 10);
    expect(limited.candidates).toHaveLength(30);
    expect(Object.keys(limited.targets.CLICK)).toHaveLength(10);
    expect(limited.truncated.CLICK).toBe(20);
    expect(offeredCandidates(limited).map((c) => c.key)).toEqual(Array.from({ length: 10 }, (_, i) => String(i + 1)));
  });
});
