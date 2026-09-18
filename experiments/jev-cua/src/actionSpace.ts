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

/**
 * `showmenu` is deliberately not here: it is the right-click context menu, and WebKit exposes it on
 * every node of a page — Wikipedia's main page carried it on 550 static-text nodes that have no
 * press at all (SONNY-517 live run). A press is a press.
 */
const PRESS_ACTIONS = new Set(["press", "pick", "confirm", "open"]);
const CLICK_ROLES = new Set([
  "button", "link", "menuitem", "menubaritem", "menubutton", "checkbox", "radiobutton", "popupbutton",
  "tab", "disclosuretriangle", "cell", "row", "incrementor", "combobox", "toolbarbutton", "switch",
]);
const TEXT_ROLES = new Set(["textfield", "textarea", "combobox", "searchfield"]);
/**
 * Structure, never a target, whatever actions it carries. Static text is NOT in this set: Google
 * Flights renders its ticket-type options as AXStaticText with a real AXPress inside an AXList, and
 * an earlier version of this set excluded them, which is why "One way" was never offered
 * (SONNY-517 live run). The list around them is structure; the texts are the options.
 */
const NEVER_CLICK_ROLES = new Set(["group", "webarea", "list", "scrollarea", "scrollbar", "window", "menubar", "menu", "toolbar", "application"]);
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
  if ((pressable && !NEVER_CLICK_ROLES.has(role)) || CLICK_ROLES.has(role)) operations.push("CLICK");
  // A web combobox is offered for typing even though some are dropdowns: Google Flights' "Change
  // ticket type" (a dropdown; typing delivers 0 of 7 characters and is refused) and its origin
  // entry "Where else?" (which takes typing) are both AXComboBox with the same actions and no
  // `focused` flag, so nothing in the tree tells them apart (SONNY-517 live run). A refused type
  // costs one step and Jev then clicks; withholding the operation made the entry field
  // unreachable and sent "Zurich" into Safari's address bar instead.
  if (TEXT_ROLES.has(role) && !NEVER_TYPE_ROLES.has(role)) operations.push("TYPE_TEXT");
  return operations;
}

/**
 * The menu bar's items arrive in the same tree as the window's controls — 151 of Calculator's 177
 * elements are menu items (SONNY-517 probe at 41a1529d). They stay offered, because "File > New" is
 * a real move, but each is labelled with its menu and sorted after the window's own controls so
 * the cap hits them last and the words on screen come first.
 */
function menuAncestry(element: Element, byIndex: ReadonlyMap<number, Element>): { isMenu: boolean; menu: string | null } {
  if (normalizeRole(element.role) === "menubaritem") return { isMenu: true, menu: null };
  let menu: string | null = null;
  let cursor = element.parent_index;
  for (let hops = 0; cursor !== null && cursor !== undefined && hops < 32; hops += 1) {
    const parent = byIndex.get(cursor);
    if (parent === undefined) break;
    const role = normalizeRole(parent.role);
    if (role === "menubaritem" && parent.label?.trim()) menu = parent.label.trim();
    if (role === "menubar") return { isMenu: true, menu };
    cursor = parent.parent_index;
  }
  return { isMenu: false, menu: null };
}

export function buildActionSpace(elements: readonly Element[], maxTargets: number = MAX_TARGETS_PER_OPERATION): ActionSpace {
  const own: Candidate[] = [];
  const menus: Candidate[] = [];
  const targets: Record<TargetedOperation, Record<string, Candidate>> = { CLICK: {}, TYPE_TEXT: {} };
  const truncated: Record<TargetedOperation, number> = { CLICK: 0, TYPE_TEXT: 0 };
  const byIndex = new Map(elements.map((e) => [e.element_index, e] as const));

  // A browser window's menu bar is never the way through a web page, and it competes with the
  // page: on Google Flights Jev picked "menu History > <page title>" three times because the
  // title matched the goal (SONNY-517 live run). Native apps keep their menus, after their controls.
  // The browser's own chrome — Safari's "smart search field" is its address bar — stays offered
  // but named for what it is and sorted after the page, because it took "Zurich" three times.
  const isWebPage = elements.some((e) => normalizeRole(e.role) === "webarea");
  const chrome: Candidate[] = [];

  for (const element of elements) {
    if (!isActionable(element)) continue;
    const operations = operationsFor(element);
    if (operations.length === 0) continue;
    const role = normalizeRole(element.role);
    const value = element.value === null || element.value === undefined ? null : clip(String(element.value), 200);
    // An unlabeled control still needs words to be picked on; the role is the honest minimum.
    const bare = (element.label?.trim() ? clip(element.label, 120) : "") || (value ?? "") || `unlabeled ${role}`;
    const { isMenu, menu } = menuAncestry(element, byIndex);
    const isChrome = isWebPage && !isMenu && element.in_web_content !== true;
    const label = role === "menubaritem" ? `menu bar: ${bare}` : menu !== null ? `menu ${menu} > ${bare}` : isChrome ? `browser toolbar: ${bare}` : bare;
    const candidate: Candidate = { key: String(element.element_index), element, role, label, value, operations };
    (isMenu ? menus : isChrome ? chrome : own).push(candidate);
  }

  return fillTargets(isWebPage ? [...own, ...chrome] : [...own, ...menus], maxTargets);
}

/** The same space with at most `maxTargets` per operation — how a request shrinks to Jev's budget. */
export function limitTargets(space: ActionSpace, maxTargets: number): ActionSpace {
  return fillTargets(space.candidates, maxTargets);
}

function fillTargets(candidates: readonly Candidate[], maxTargets: number): ActionSpace {
  const targets: Record<TargetedOperation, Record<string, Candidate>> = { CLICK: {}, TYPE_TEXT: {} };
  const truncated: Record<TargetedOperation, number> = { CLICK: 0, TYPE_TEXT: 0 };
  for (const candidate of candidates) {
    for (const operation of candidate.operations) {
      const group = targets[operation];
      if (Object.keys(group).length >= maxTargets) {
        truncated[operation] += 1;
        continue;
      }
      group[candidate.key] = candidate;
    }
  }
  return { candidates, targets, truncated };
}

/**
 * The same space without the named keys — how a target whose ladder was just exhausted is kept
 * off the next step's menu. Jev repeated System Settings' dead "Displays" sidebar row three times
 * to a stall with the failure in plain view in its history (SONNY-517, Jev-as-judge run); code
 * owning the workflow means code withholds the option rather than hoping the rules are read.
 */
export function withoutTargets(space: ActionSpace, keys: ReadonlySet<string>, maxTargets: number = MAX_TARGETS_PER_OPERATION): ActionSpace {
  if (keys.size === 0) return space;
  return fillTargets(space.candidates.filter((c) => !keys.has(c.key)), maxTargets);
}

/** The candidates Jev can actually pick — those in at least one target head — in tree order. */
export function offeredCandidates(space: ActionSpace): Candidate[] {
  const offered = new Set<string>();
  for (const operation of TARGETED_OPERATIONS) for (const key of Object.keys(space.targets[operation])) offered.add(key);
  return space.candidates.filter((c) => offered.has(c.key));
}
