/**
 * What Sonny knows about one site, read from a `*.skillpack.json` file: the TypeScript port of the
 * Mac's `SkillPack.swift` decoder (V2 plan section 5). The Swift doc comments hold the history of
 * each rule; this file keeps the rules and says what each is for.
 *
 * **A pack is instructions, never permission.** It carries no field that could make anything ask
 * less, and the decoder refuses any key it does not know, so such a field cannot be smuggled in
 * under a new name either.
 *
 * **Two depths.** A `deep` pack carries task flows, and every flow cites the public page its steps
 * came from. A `shallow` pack carries only facts a lookup settles.
 *
 * A pack that breaks a rule does not load at all; `SkillPackLoadError` names what its author has to
 * fix. The cases and their fields mirror the Swift `SkillPackLoadError` one for one.
 */
import { credentialViolation, moneyViolation, stopLine, stopProblem, STOP_HEADER, urlCarriesCredential } from "./rules.js";
import type { SkillPackStopProblem } from "./rules.js";
import { isAReadingDay, isOnSite, startPageViolation } from "./start-pages.js";
import type { SkillPackStartPage, SkillPackStartPageOffer } from "./start-pages.js";
import { trimmed } from "./text.js";
import { componentsHostOf, hostOf, parsePackURL, type PackURL } from "./url.js";

/** The one format this build reads. A pack declaring another does not load. */
export const SKILL_PACK_FORMAT_VERSION = 1;

export const SKILL_PACK_FILE_SUFFIX = ".skillpack.json";

/**
 * The ceiling on one pack's rendered guidance, in UTF-8 bytes. A pack over it does not load rather
 * than being truncated: a flow cut off half way stops before the step that mattered.
 */
export const GUIDANCE_BYTE_LIMIT = 6_000;

export type SkillPackDepth = "deep" | "shallow";

export interface SkillPackFlow {
  readonly title: string;
  readonly startURL: PackURL;
  readonly steps: readonly string[];
  /** The acts this flow stops before and never performs. Empty for most flows. */
  readonly stops: readonly string[];
  /** The public page these steps were taken from. */
  readonly source: PackURL;
}

export interface SkillPack {
  readonly id: string;
  readonly name: string;
  readonly domain: string;
  readonly category: string;
  readonly summary: string;
  /** `undefined` for a site with no sign-in page of its own (the file says `null`). */
  readonly signInURL: PackURL | undefined;
  readonly triggers: readonly string[];
  readonly sections: readonly string[];
  readonly depth: SkillPackDepth;
  readonly flows: readonly SkillPackFlow[];
  /** One signed-out reading per distinct start URL; evidence for a reader, never part of `guidance`. */
  readonly startPages: readonly SkillPackStartPage[];
  /** The text this pack adds to a planning prompt when a task names it. */
  readonly guidance: string;
}

export type SkillPackLoadError =
  | { readonly kind: "notAJSONObject" }
  | { readonly kind: "unknownField"; readonly field: string }
  | { readonly kind: "missingField"; readonly field: string }
  | { readonly kind: "wrongType"; readonly field: string }
  | { readonly kind: "unsupportedFormat"; readonly format: number }
  | { readonly kind: "invalidID"; readonly id: string }
  | { readonly kind: "duplicateID"; readonly id: string }
  | { readonly kind: "notHTTPS"; readonly field: string }
  | { readonly kind: "unknownDepth"; readonly depth: string }
  | { readonly kind: "deepPackHasNoFlows" }
  | { readonly kind: "shallowPackHasFlows" }
  | { readonly kind: "flowHasNoSteps"; readonly flow: string }
  | { readonly kind: "flowHasNoCitation"; readonly flow: string }
  | { readonly kind: "startPageOffSite"; readonly flow: string; readonly host: string }
  | { readonly kind: "startPageNotRecorded"; readonly flow: string }
  | { readonly kind: "startPageRecordedTwice"; readonly url: string }
  | { readonly kind: "startPageUnused"; readonly url: string }
  | { readonly kind: "startPageNotAStartPage"; readonly url: string; readonly offers: string }
  | { readonly kind: "landedURLCarriesQuery"; readonly url: string }
  | { readonly kind: "landingHostNotPairedWithSite"; readonly url: string; readonly host: string; readonly site: string }
  | { readonly kind: "identityHostLandingIsNotSignIn"; readonly url: string; readonly host: string }
  | { readonly kind: "startPageCreatesAnAccount"; readonly url: string }
  /** `field` is `summary`, `sections[n]` or `flows[n]`; `words` is what moved money. */
  | { readonly kind: "movesMoney"; readonly field: string; readonly words: string }
  | { readonly kind: "mentionsCredential"; readonly field: string; readonly phrase: string }
  | { readonly kind: "urlCarriesCredential"; readonly field: string }
  | { readonly kind: "stopIsNotOneAct"; readonly flow: string; readonly problem: SkillPackStopProblem }
  | { readonly kind: "guidanceTooLong"; readonly bytes: number };

export type SkillPackDecodeResult =
  | { readonly ok: true; readonly pack: SkillPack }
  | { readonly ok: false; readonly error: SkillPackLoadError };

/** Thrown inside the decoder so each check can stop it; never escapes `decodeSkillPack`. */
class Refusal extends Error {
  constructor(readonly error: SkillPackLoadError) {
    super(error.kind);
  }
}

function refuse(error: SkillPackLoadError): never {
  throw new Refusal(error);
}

type JSONObject = Record<string, unknown>;

const PACK_FIELDS = new Set([
  "format", "id", "name", "domain", "category", "summary", "signInURL",
  "triggers", "sections", "depth", "flows", "startPages",
]);
const FLOW_FIELDS = new Set(["title", "startURL", "steps", "stops", "source"]);
const START_PAGE_FIELDS = new Set(["url", "landedURL", "title", "otherTitles", "heading", "offers", "read"]);

const utf8 = new TextDecoder("utf-8", { fatal: true });

/** Reads one pack file and holds it to every rule. Accepts the file's bytes or its text. */
export function decodeSkillPack(data: Uint8Array | string): SkillPackDecodeResult {
  try {
    return { ok: true, pack: decode(parseObject(data)) };
  } catch (error) {
    if (error instanceof Refusal) return { ok: false, error: error.error };
    throw error;
  }
}

function parseObject(data: Uint8Array | string): JSONObject {
  let parsed: unknown;
  try {
    // A fatal decoder, because the Mac's JSON reader refuses bytes that are not UTF-8 rather than
    // replacing them. A leading byte-order mark is dropped, as it was there.
    parsed = JSON.parse(typeof data === "string" ? data : utf8.decode(data));
  } catch {
    refuse({ kind: "notAJSONObject" });
  }
  return isObject(parsed) ? parsed : refuse({ kind: "notAJSONObject" });
}

function decode(root: JSONObject): SkillPack {
  refuseUnknownKeys(root, PACK_FIELDS, "");

  const format = requiredInteger(root, "format");
  if (format !== SKILL_PACK_FORMAT_VERSION) refuse({ kind: "unsupportedFormat", format });

  const id = requiredText(root, "id");
  if (!/^[a-z0-9][a-z0-9_]*$/.test(id)) refuse({ kind: "invalidID", id });
  const name = requiredText(root, "name");
  const domain = requiredText(root, "domain");
  const category = requiredText(root, "category");
  const summary = requiredText(root, "summary");
  const signInURL = optionalHTTPSURL(root, "signInURL");
  const triggers = requiredTextList(root, "triggers", "", false);
  const sections = requiredTextList(root, "sections", "", true);

  const depthText = requiredText(root, "depth");
  if (depthText !== "deep" && depthText !== "shallow") refuse({ kind: "unknownDepth", depth: depthText });
  const depth: SkillPackDepth = depthText;

  if (!Object.hasOwn(root, "flows")) refuse({ kind: "missingField", field: "flows" });
  const rawFlows = root["flows"];
  if (!Array.isArray(rawFlows) || !rawFlows.every(isObject)) refuse({ kind: "wrongType", field: "flows" });
  const flows = rawFlows.map((flow, index) => decodeFlow(flow, index, domain));

  if (depth === "deep" && flows.length === 0) refuse({ kind: "deepPackHasNoFlows" });
  if (depth === "shallow" && flows.length > 0) refuse({ kind: "shallowPackHasFlows" });

  const startPages = decodeStartPages(root, flows.length > 0);
  const startPageError = startPageViolation(flows, startPages, domain);
  if (startPageError) refuse(startPageError);

  // Everything that reaches the planner as a description of the site: each flow as one unit (its
  // money act is often split between title and steps), the summary, and each section on its own,
  // so two section labels cannot pair into a refusal. A flow's `stops` are read by neither rule;
  // the stop rule in `decodeFlow` holds them instead.
  const moneyUnits: Array<{ field: string; texts: string[] }> = [
    ...flows.map((flow, index) => ({ field: `flows[${index}]`, texts: [flow.title, ...flow.steps] })),
    { field: "summary", texts: [summary] },
    ...sections.map((section, index) => ({ field: `sections[${index}]`, texts: [section] })),
  ];
  for (const unit of moneyUnits) {
    const words = moneyViolation(unit.texts);
    if (words !== undefined) refuse({ kind: "movesMoney", field: unit.field, words });
  }

  const texts: Array<{ field: string; text: string }> = [
    { field: "name", text: name },
    { field: "domain", text: domain },
    { field: "summary", text: summary },
    ...triggers.map((text) => ({ field: "triggers", text })),
    ...sections.map((text) => ({ field: "sections", text })),
    ...flows.flatMap((flow) => [
      { field: "flows.title", text: flow.title },
      ...flow.steps.map((text) => ({ field: "flows.steps", text })),
    ]),
  ];
  for (const entry of texts) {
    const phrase = credentialViolation(entry.text);
    if (phrase !== undefined) refuse({ kind: "mentionsCredential", field: entry.field, phrase });
  }

  const guidance = renderGuidance({ name, domain, summary, signInURL, sections, flows });
  const bytes = Buffer.byteLength(guidance, "utf8");
  if (bytes > GUIDANCE_BYTE_LIMIT) refuse({ kind: "guidanceTooLong", bytes });

  return { id, name, domain, category, summary, signInURL, triggers, sections, depth, flows, startPages, guidance };
}

/**
 * The planner's text for one pack: plain lines, because a model reads it beside the rest of a prose
 * prompt. Every flow keeps its citation beside its steps, and its stops sit above step 1 so a stop is
 * read before anything the flow does. Byte-for-byte what the Mac's `SkillPack.guidance` rendered.
 */
function renderGuidance(pack: {
  name: string;
  domain: string;
  summary: string;
  signInURL: PackURL | undefined;
  sections: readonly string[];
  flows: readonly SkillPackFlow[];
}): string {
  const lines = [`Skill: ${pack.name} (${pack.domain})`, pack.summary];
  if (pack.signInURL) lines.push(`Sign-in page: ${pack.signInURL.text}`);
  if (pack.sections.length > 0) lines.push(`Top-level sections: ${pack.sections.join(", ")}`);
  if (pack.flows.length > 0) {
    lines.push("Tasks:");
    for (const flow of pack.flows) {
      lines.push(`- ${flow.title}, starting at ${flow.startURL.text}:`);
      if (flow.stops.length > 0) {
        lines.push(`  ${STOP_HEADER}`);
        lines.push(...flow.stops.map((stop) => `  ${stopLine(stop)}`));
      }
      flow.steps.forEach((step, index) => lines.push(`  ${index + 1}. ${step}`));
      lines.push(`  (steps from ${flow.source.text})`);
    }
  }
  return lines.join("\n");
}

function decodeFlow(flow: JSONObject, index: number, domain: string): SkillPackFlow {
  const prefix = `flows[${index}].`;
  refuseUnknownKeys(flow, FLOW_FIELDS, prefix);
  const title = requiredText(flow, "title", prefix);
  const startURL = requiredHTTPSURL(flow, "startURL", prefix);
  const startHost = (hostOf(startURL) ?? "").toLowerCase();
  if (!isOnSite(startHost, domain)) refuse({ kind: "startPageOffSite", flow: title, host: startHost });
  const rawSource = flow["source"];
  if (typeof rawSource !== "string" || trimmed(rawSource) === "") refuse({ kind: "flowHasNoCitation", flow: title });
  const source = requiredHTTPSURL(flow, "source", prefix);
  const steps = requiredTextList(flow, "steps", prefix, true);
  if (steps.length === 0) refuse({ kind: "flowHasNoSteps", flow: title });
  // Optional, and never empty when present: most flows stop before nothing, and one that says it
  // does has to say what.
  const stops = Object.hasOwn(flow, "stops") ? requiredTextList(flow, "stops", prefix, false) : [];
  for (const stop of stops) {
    const problem = stopProblem(stop);
    if (problem) refuse({ kind: "stopIsNotOneAct", flow: title, problem });
  }
  return { title, startURL, steps, stops, source };
}

/** Required of a pack with flows, optional for one without; whether each record matches a flow is `startPageViolation`'s. */
function decodeStartPages(root: JSONObject, hasFlows: boolean): SkillPackStartPage[] {
  if (!Object.hasOwn(root, "startPages")) {
    if (hasFlows) refuse({ kind: "missingField", field: "startPages" });
    return [];
  }
  const raw = root["startPages"];
  if (!Array.isArray(raw) || !raw.every(isObject)) refuse({ kind: "wrongType", field: "startPages" });
  return raw.map((object, index) => {
    const prefix = `startPages[${index}].`;
    refuseUnknownKeys(object, START_PAGE_FIELDS, prefix);
    const url = requiredHTTPSURL(object, "url", prefix);
    const landedURL = requiredHTTPSURL(object, "landedURL", prefix);
    // Both present and both allowed to be empty: a page with no title is recorded as having none.
    const title = requiredString(object, "title", prefix);
    const otherTitles = Object.hasOwn(object, "otherTitles") ? requiredTextList(object, "otherTitles", prefix, false) : [];
    const heading = requiredString(object, "heading", prefix);
    const offersText = requiredText(object, "offers", prefix);
    if (offersText !== "sign-in" && offersText !== "product") {
      refuse({ kind: "startPageNotAStartPage", url: url.text, offers: offersText });
    }
    const offers: SkillPackStartPageOffer = offersText;
    const read = requiredText(object, "read", prefix);
    // The shape alone let `2026-13-45` load, so the date is checked as a date too.
    if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(read) || !isAReadingDay(read)) {
      refuse({ kind: "wrongType", field: `${prefix}read` });
    }
    return { url, landedURL, title: trimmed(title), otherTitles, heading: trimmed(heading), offers, read };
  });
}

function isString(value: unknown): value is string {
  return typeof value === "string";
}

function isObject(value: unknown): value is JSONObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function refuseUnknownKeys(object: JSONObject, allowed: ReadonlySet<string>, prefix: string): void {
  const unknown = Object.keys(object)
    .sort()
    .find((key) => !allowed.has(key));
  if (unknown !== undefined) refuse({ kind: "unknownField", field: prefix + unknown });
}

/** Present, and not `null`: a `null` is the wrong type, as it was on the Mac. */
function requiredValue(object: JSONObject, key: string, prefix: string): unknown {
  if (!Object.hasOwn(object, key)) refuse({ kind: "missingField", field: prefix + key });
  return object[key];
}

/**
 * An integer, as the Mac's `as? Int` read one: a whole number, including one written `1.0`, and a
 * boolean as 1 or 0, because Foundation's JSON numbers bridge booleans that way.
 */
function requiredInteger(object: JSONObject, key: string): number {
  const value = requiredValue(object, key, "");
  if (typeof value === "boolean") return value ? 1 : 0;
  if (typeof value === "number" && Number.isSafeInteger(value)) return value;
  return refuse({ kind: "wrongType", field: key });
}

function requiredString(object: JSONObject, key: string, prefix: string): string {
  const value = requiredValue(object, key, prefix);
  return typeof value === "string" ? value : refuse({ kind: "wrongType", field: prefix + key });
}

/** A string that is present and not blank, trimmed. A blank field is reported as missing. */
function requiredText(object: JSONObject, key: string, prefix = ""): string {
  const value = trimmed(requiredString(object, key, prefix));
  return value === "" ? refuse({ kind: "missingField", field: prefix + key }) : value;
}

function requiredTextList(object: JSONObject, key: string, prefix: string, allowEmpty: boolean): string[] {
  const value = requiredValue(object, key, prefix);
  if (!Array.isArray(value) || !value.every(isString)) refuse({ kind: "wrongType", field: prefix + key });
  const values = value.map(trimmed);
  if (values.includes("") || (!allowEmpty && values.length === 0)) refuse({ kind: "missingField", field: prefix + key });
  return values;
}

function requiredHTTPSURL(object: JSONObject, key: string, prefix: string): PackURL {
  return httpsURL(requiredText(object, key, prefix), prefix + key);
}

/** May be `null` for a site with no sign-in page; absent is still refused, so an author says so. */
function optionalHTTPSURL(object: JSONObject, key: string): PackURL | undefined {
  const value = requiredValue(object, key, "");
  if (value === null) return undefined;
  if (typeof value !== "string") refuse({ kind: "wrongType", field: key });
  return httpsURL(trimmed(value), key);
}

function httpsURL(text: string, field: string): PackURL {
  const url = parsePackURL(text);
  if (!url || url.scheme?.toLowerCase() !== "https" || !componentsHostOf(url)) refuse({ kind: "notHTTPS", field });
  if (url.hasUserInfo || urlCarriesCredential(url)) refuse({ kind: "urlCarriesCredential", field });
  return url;
}
