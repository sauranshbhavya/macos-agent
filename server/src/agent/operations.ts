/**
 * The typed operations a Mac may declare in its manifest: what the planner may ask a Mac to do
 * without driving an app's interface.
 *
 * This file is the source. Each entry's argument schema is written out to
 * `contracts/v2/operations/<name>.v<version>.schema.json` for the Mac and for people, and
 * `test/contracts.test.ts` fails if the two ever differ (regenerate with
 * `WRITE_OPERATION_SCHEMAS=1 npx vitest run test/contracts.test.ts`).
 *
 * The `floor` is the least effect the operation can have; the Mac enforces the same floor and may
 * raise it further (an overwrite, a detected secret). A change to an argument schema is a new
 * version, never an edit in place, because Macs already in the field keep declaring the old one.
 * The descriptions are the gateway's; the Mac never sends one.
 */
import { z } from "zod/v4";
import type { Effect } from "./protocol.js";

export interface OperationSpec {
  readonly name: string;
  readonly version: number;
  readonly args: z.ZodType<Record<string, unknown>>;
  readonly floor: Effect;
  readonly description: string;
}

const text = (max: number) => z.string().min(1).max(max);
const path = text(1024).describe("A path on the Mac, as the user said it or as an earlier step reported it.");
const app = text(255).describe("The app's name or bundle id.");
const url = z
  .string()
  .max(2048)
  .regex(/^https?:\/\//, "an http or https URL")
  .describe("An http or https URL.");

export const OPERATIONS: readonly OperationSpec[] = [
  {
    name: "open_app",
    version: 1,
    args: z.strictObject({ app: text(255).describe("The app's name or bundle id, as the user said it.") }),
    floor: "navigate",
    description: "Open an installed app, or bring it forward if it is already running.",
  },
  {
    name: "switch_app",
    version: 1,
    args: z.strictObject({ app }),
    floor: "navigate",
    description:
      "Bring an app that is already running to the front. Launches nothing: if the app isn't running, it fails by name. Use open_app when the app may not be running.",
  },
  {
    name: "open_url",
    version: 1,
    args: z.strictObject({
      url,
      browser: text(100).optional().describe("Only when the user named a browser; URLs open in the default browser otherwise."),
    }),
    floor: "navigate",
    description: "Open a web page. Never ask which browser to use.",
  },
  {
    name: "open_app_search",
    version: 1,
    args: z.strictObject({ app, query: text(500) }),
    floor: "navigate",
    description:
      "Open an app's or website's own search page for a query, from a fixed list of supported search targets. It fails for a target it doesn't support; never invent a search URL.",
  },
  {
    name: "play_media",
    version: 1,
    args: z.strictObject({
      provider: z.enum(["apple_music", "spotify"]),
      title: text(300),
      artist: text(200).optional(),
      url: z.string().max(2048).optional().describe("Only an exact Apple Music or Spotify URI the user supplied."),
    }),
    floor: "navigate",
    description:
      "Play a song or album in Apple Music or Spotify, falling back to opening the provider's result or search. If the provider or title is missing, ask.",
  },
  {
    name: "open_file",
    version: 1,
    args: z.strictObject({ path }),
    floor: "navigate",
    description: "Open a file or folder on the Mac in its default app, for example a file an earlier step made.",
  },
  {
    name: "reveal_in_finder",
    version: 1,
    args: z.strictObject({ path }),
    floor: "navigate",
    description: "Show a file or folder in Finder.",
  },
  {
    name: "get_finder_selection",
    version: 1,
    args: z.strictObject({}),
    floor: "observe",
    description:
      "Read which files and folders are selected in Finder. The outcome's evidence lists their paths. Use it when the user says \"these\", \"the selected files\" or \"this folder\".",
  },
  {
    name: "find_largest_files",
    version: 1,
    args: z.strictObject({
      folder: path,
      count: z.number().int().min(1).max(50).optional().describe("How many; 3 when the user didn't say."),
    }),
    floor: "observe",
    description: "Find the largest files in a folder, skipping links. The evidence lists their paths and sizes.",
  },
  {
    name: "create_zip",
    version: 1,
    args: z.strictObject({
      paths: z.array(path).min(1).max(200),
      output_path: path.optional().describe("Where to save the archive; a timestamped name when omitted."),
    }),
    floor: "create",
    description: "Make a zip archive of the given files. The evidence names the archive.",
  },
  {
    name: "find_docx",
    version: 1,
    args: z.strictObject({ folder: path }),
    floor: "observe",
    description: "Find .docx files in a folder and its subfolders. The evidence lists their paths.",
  },
  {
    name: "convert_docx_to_pdf",
    version: 1,
    args: z.strictObject({
      paths: z.array(path).min(1).max(200),
      output_folder: path.optional(),
    }),
    floor: "create",
    description: "Convert .docx files to PDFs with Microsoft Word. The evidence lists the PDFs.",
  },
  {
    name: "write_file",
    version: 1,
    args: z.strictObject({
      content: text(200_000),
      title: text(200).optional(),
      path: path.optional().describe("Where to save; the Documents folder with a name from the title when omitted."),
    }),
    floor: "create",
    description:
      "Save text as a Markdown file on the Mac, for a note, a draft or research the gateway wrote. Replacing a file that exists asks first. This does not use Notes, Mail or any app.",
  },
  {
    name: "rename",
    version: 1,
    args: z.strictObject({
      path,
      new_name: text(255).describe("A bare name with no slashes; the item keeps its folder."),
    }),
    floor: "destructive",
    description: "Rename one file or folder where it is. One item only: for several, ask what to call each.",
  },
  {
    name: "read_calendar",
    version: 1,
    args: z.strictObject({ day: text(100).optional().describe("The day asked about, in the user's words; today when omitted.") }),
    floor: "observe",
    description: "List the events on the user's calendars for one day. Changes nothing.",
  },
  {
    name: "create_reminder",
    version: 1,
    args: z.strictObject({
      title: text(500),
      minutes_from_now: z.number().int().min(1).max(525_600).optional(),
      time: text(50).optional().describe("A clock time such as 17:30."),
      day: text(100).optional(),
    }),
    floor: "create",
    description:
      "Add one reminder with an alert to the user's Reminders. Give exactly one of minutes_from_now or time, and day when they named one. If they named no time, ask when.",
  },
  {
    name: "run_shortcut",
    version: 1,
    args: z.strictObject({ name: text(200), input: text(10_000).optional() }),
    floor: "unknown",
    description:
      "Run one of the user's existing Apple Shortcuts by name, with simple text input only when they supplied it. A shortcut can do anything, so this always asks first.",
  },
  {
    name: "save_snippet",
    version: 1,
    args: z.strictObject({ trigger: text(100), text: text(10_000) }),
    floor: "edit_local",
    description:
      "Save a text snippet under a short trigger, so typing the trigger later expands to the text. Use only a trigger and text the user supplied.",
  },
  {
    name: "check_permissions",
    version: 1,
    args: z.strictObject({}),
    floor: "observe",
    description:
      "Show whether Sonny has what it needs on this Mac: the account, microphone, hotkey, automation, file access, Accessibility, Screen Recording, Calendars and Reminders.",
  },
  {
    name: "start_watching",
    version: 1,
    args: z.strictObject({ url, subject: text(500).describe("What the user asked to be told about, in their words.") }),
    floor: "create",
    description: "Watch one public web page and tell the user when it changes. Sonny only notifies; it never acts on the change.",
  },
  {
    name: "save_routine",
    version: 1,
    args: z.strictObject({
      name: text(100),
      goal: text(4000).describe("What the routine does, in plain words; every run plans it again."),
      schedule: text(200).optional().describe("When it runs, in the user's words, if they said."),
    }),
    floor: "create",
    description:
      "Save a named routine as a goal. Each run is a new task that plans the goal again, so write the goal the way the user would say it.",
  },
  {
    name: "compose_mail",
    version: 1,
    args: z.strictObject({
      to: z.array(z.string().min(3).max(320)).min(1).max(20),
      cc: z.array(z.string().min(3).max(320)).max(20).optional(),
      subject: z.string().max(500),
      body: z.string().max(100_000),
    }),
    floor: "create",
    description:
      "Open a new message in Mail with the recipients, subject and body set, and leave it unsent. The evidence gives the draft's id for send_mail.",
  },
  {
    name: "send_mail",
    version: 1,
    args: z.strictObject({ draft: text(100).describe("The id compose_mail reported.") }),
    floor: "external",
    description:
      "Send a draft compose_mail made. The user approves the exact recipients and message first, and any change to the draft after that means asking again.",
  },
];

export function operationSpec(name: string, version: number): OperationSpec | undefined {
  return OPERATIONS.find((spec) => spec.name === name && spec.version === version);
}

/** An operation's argument schema as JSON Schema, which is what the contract files hold. */
export function operationJSONSchema(spec: OperationSpec): Record<string, unknown> {
  return {
    $schema: "https://json-schema.org/draft/2020-12/schema",
    $id: `https://sonny.app/contracts/v2/operations/${spec.name}.v${spec.version}.schema.json`,
    title: `${spec.name} v${spec.version}`,
    description: `${spec.description} Floor effect: ${spec.floor}.`,
    ...stripSchemaKey(z.toJSONSchema(spec.args) as Record<string, unknown>),
  };
}

function stripSchemaKey(schema: Record<string, unknown>): Record<string, unknown> {
  const { $schema: _unused, ...rest } = schema;
  return rest;
}
