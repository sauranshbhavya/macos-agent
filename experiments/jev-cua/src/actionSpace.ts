import type { Element } from "./driver/types.ts";

/**
 * The action space: what Jev may pick from on one window snapshot. Following jev-ultrafast, one
 * observed element gets one index and each operation has its own set of valid targets, so one
 * TypeSafe request can ask "which operation?" and "which target, if that operation?" for every
 * operation at once, and the executor consumes only the target head the chosen operation names.
 */

export const TARGETED_OPERATIONS = ["CLICK", "TYPE_TEXT"] as const;
export type TargetedOperation = (typeof TARGETED_OPERATIONS)[number];

export const CONTROL_OPERATIONS = ["PRESS_RETURN", "PRESS_ESCAPE", "SCROLL_DOWN", "SCROLL_UP", "WAIT", "DONE", "BLOCKED"] as const;
export type ControlOperation = (typeof CONTROL_OPERATIONS)[number];

export type Operation = TargetedOperation | ControlOperation;

export interface Candidate {
  /** The key Jev picks: the driver's own `element_index` as a string, so a log line reads against the tree. */
  readonly key: string;
  readonly element: Element;
  readonly role: string;
  readonly label: string;
  readonly value: string | null;
  readonly operations: readonly TargetedOperation[];
}

export interface ActionSpace {
  /** Every candidate, in tree order — the indexed table Jev sees as state. */
  readonly candidates: readonly Candidate[];
  /** Per operation, the candidates it may target, keyed by `Candidate.key`. */
  readonly targets: Readonly<Record<TargetedOperation, Readonly<Record<string, Candidate>>>>;
  /** Candidates dropped past the cap, per operation — a non-zero here is a finding for the report. */
  readonly truncated: Readonly<Record<TargetedOperation, number>>;
}

/** Jev's Choice takes at most 255 options; 250 leaves room and matches jev-ultrafast's retention cap. */
export const MAX_TARGETS_PER_OPERATION = 250;

const PRESS_ACTIONS = new Set(["press", "pick", "confirm", "open", "showmenu"]);
const CLICK_ROLES = new Set([
  "button", "link", "menuitem", "menubaritem", "menubutton", "checkbox", "radiobutton", "popupbutton",
  "tab", "disclosuretriangle", "cell", "row", "incrementor", "combobox", "toolbarbutton", "switch",
]);
const TEXT_ROLES = new Set(["textfield", "textarea", "combobox", "searchfield"]);
/** Never a typing target: the loop must not be able to write into a password field. */
const NEVER_TYPE_ROLES = new Set(["securetextfield"]);

/** "AXTextField" → "textfield"; the driver has shipped both spellings across releases. */
export function normalizeRole(role: string): string {
  return role.replace(/^AX/, "").replace(/[\s_-]/g, "").toLowerCase();
}

function normalizeAction(action: string): string {
  return action.replace(/^AX/, "").replace(/[\s_-]/g, "").toLowerCase();
}

function clip(text: string, max: number): string {
  const single = text.replace(/\s+/g, " ").trim();
  return single.length > max ? `${single.slice(0, max - 1)}…` : single;
}

function isActionable(element: Element): boolean {
  if (element.enabled === false) return false;
  const frame = element.frame;
  // Virtualised off-viewport rows come back with a 1px frame (documented on get_window_state).
  if (frame && (frame.w <= 1 || frame.h <= 1)) return false;
  return true;
}

export function operationsFor(element: Element): TargetedOperation[] {
  const role = normalizeRole(element.role);
  const actions = new Set((element.actions ?? []).map(normalizeAction));
  const operations: TargetedOperation[] = [];
  const pressable = [...actions].some((a) => PRESS_ACTIONS.has(a));
  if (pressable || CLICK_ROLES.has(role)) operations.push("CLICK");
  if (TEXT_ROLES.has(role) && !NEVER_TYPE_ROLES.has(role)) operations.push("TYPE_TEXT");
  return operations;
}

export function buildActionSpace(elements: readonly Element[]): ActionSpace {
  const candidates: Candidate[] = [];
  const targets: Record<TargetedOperation, Record<string, Candidate>> = { CLICK: {}, TYPE_TEXT: {} };
  const truncated: Record<TargetedOperation, number> = { CLICK: 0, TYPE_TEXT: 0 };

  for (const element of elements) {
    if (!isActionable(element)) continue;
    const operations = operationsFor(element);
    if (operations.length === 0) continue;
    const label = element.label?.trim() ? clip(element.label, 120) : "";
    const value = element.value === null || element.value === undefined ? null : clip(String(element.value), 200);
    const candidate: Candidate = {
      key: String(element.element_index),
      element,
      role: normalizeRole(element.role),
      // An unlabeled control still needs words to be picked on; the role is the honest minimum.
      label: label || (value ?? "") || `unlabeled ${normalizeRole(element.role)}`,
      value,
      operations,
    };
    candidates.push(candidate);
    for (const operation of operations) {
      const group = targets[operation];
      if (Object.keys(group).length >= MAX_TARGETS_PER_OPERATION) {
        truncated[operation] += 1;
        continue;
      }
      group[candidate.key] = candidate;
    }
  }
  return { candidates, targets, truncated };
}
