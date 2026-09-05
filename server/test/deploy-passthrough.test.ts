import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { BILLING_REQUIREMENT_NAMES, BILLING_TRIGGER } from "../src/billing/deps.js";

/**
 * What `scripts/deploy.sh local` actually hands to `docker run`, measured by running the script's
 * own code (SONNY-405).
 *
 * **Why this drives bash rather than grepping the file.** The two passthrough arrays sit under
 * several screens of comments that name every variable they discuss — including all seven billing
 * names, several times over. A regex for `BILLING_WEBHOOK_SECRET` inside the `PASSTHROUGH=(…)`
 * region is satisfied by the paragraph explaining why it is there, so it would pass with the entry
 * itself deleted. That is `CLAUDE.md`'s citation-matches-its-own-text defect, and the cheapest way
 * out of it is not a better regex but a parser that already knows what a comment is: bash's. The
 * probe below sources the real script with an unrecognised target, so every declaration and function
 * is evaluated and the `case` falls through to `usage`, which exits before `docker` is named — and
 * an `EXIT` trap then calls the script's own `collect_passthrough` and prints what it built.
 *
 * **So a name is proved to reach the container in the only sense this repository can prove without
 * one**: it appears as `-e NAME` in the argument list `docker run` is given, which is Docker's
 * pass-from-the-environment form. The container's side of that is Docker's, not this script's.
 */

const SERVER_DIR = fileURLToPath(new URL("..", import.meta.url));
const SCRIPT = "scripts/deploy.sh";

/**
 * Two names that have been on their respective arrays since long before this file existed. They are
 * the fixed points every assertion here is calibrated against: if the probe stops finding these, it
 * has stopped reading the script, and every membership check below would otherwise pass by finding
 * nothing.
 */
const LONG_STANDING_CREDENTIAL = "OPENAI_API_KEY";
const LONG_STANDING_SETTING = "MODEL_ROUTE_PLAN";

/**
 * A name `config.ts` reads and this script deliberately does not forward (the deploy script's own
 * comment records the founder decision). It is the negative control: a probe that simply echoed its
 * environment back would forward this, and every other assertion in this file would still pass.
 */
const DELIBERATELY_NOT_FORWARDED = "SUPABASE_SERVICE_ROLE_KEY";

/**
 * The value every name in this file is set to. **It has spaces in it deliberately**: several of the
 * names below are on `check:secrets`' name-anchored list, and that scanner reads
 * `BILLING_WEBHOOK_SECRET: <sixteen or more credential-shaped characters>` as a planted credential
 * — correctly, and it did, on this file's first draft. Nothing here needs a realistic value, since
 * what is under test is that the *name* travels and the value does not.
 */
const NOT_A_SECRET = "not a real value";

const PROBE = [
  "( trap 'collect_passthrough",
  'for n in ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}; do printf "CREDENTIAL %s\\n" "$n"; done',
  'for n in ${PASSTHROUGH_SETTINGS[@]+"${PASSTHROUGH_SETTINGS[@]}"}; do printf "SETTING %s\\n" "$n"; done',
  'for a in ${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}; do printf "ARG %s\\n" "$a"; done',
  'for n in ${PASSTHROUGH_ABSENT[@]+"${PASSTHROUGH_ABSENT[@]}"}; do printf "ABSENT %s\\n" "$n"; done',
  "printf \"PROBE_OK\\n\"' EXIT",
  `source ./${SCRIPT} __unrecognised_target__ )`,
  // The subshell above is what makes the script's `exit 2` survivable: it ends the subshell, the
  // trap fires inside it, and this line is still reached. Without it `execFileSync` would see a
  // non-zero exit and throw away the output it was called for.
  "exit 0",
].join("\n");

interface Forwarding {
  /** `PASSTHROUGH`, in file order — the names whose absence is reported one by one. */
  readonly credentials: readonly string[];
  /** `PASSTHROUGH_SETTINGS`, in file order — the names whose absence is reported as a count. */
  readonly settings: readonly string[];
  /** The flat argument list handed to `docker run`: `-e`, name, `-e`, name, … */
  readonly dockerArgs: readonly string[];
  /** The names those arguments forward, with the `-e` flags dropped. */
  readonly forwarded: readonly string[];
  /** What the `not set here, so not forwarded:` line would list. */
  readonly absentByName: readonly string[];
}

const cache = new Map<string, Forwarding>();

/** Runs the real script's collection step with exactly the environment given, and nothing else. */
function forwardingWith(environment: Record<string, string>): Forwarding {
  const key = JSON.stringify(environment, Object.keys(environment).sort());
  const cached = cache.get(key);
  if (cached !== undefined) return cached;

  const stdout = execFileSync("bash", ["-c", PROBE, SCRIPT], {
    cwd: SERVER_DIR,
    // Replaced wholesale rather than merged: the developer's own exported credentials must not
    // reach this, or a machine that happens to have OPENAI_API_KEY set would pass the negative
    // control for the wrong reason.
    env: { PATH: process.env.PATH ?? "/usr/bin:/bin", ...environment },
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  const lines = stdout.split("\n");
  const tagged = (tag: string): string[] =>
    lines.filter((line) => line.startsWith(`${tag} `)).map((line) => line.slice(tag.length + 1));

  expect(lines).toContain("PROBE_OK");
  const dockerArgs = tagged("ARG");
  const result: Forwarding = {
    credentials: tagged("CREDENTIAL"),
    settings: tagged("SETTING"),
    dockerArgs,
    forwarded: dockerArgs.filter((argument) => argument !== "-e"),
    absentByName: tagged("ABSENT"),
  };
  cache.set(key, result);
  return result;
}

describe("what the deploy script forwards into the container", () => {
  it("runs the real script, and a name it refuses to forward stays unforwarded", () => {
    // **The controls, and they come first because every other test in this file is a membership
    // check that an empty or an all-forwarding probe would satisfy.** A scan that finds nothing
    // passes a `not.toContain`, and a probe that echoed its environment passes a `toContain`; one
    // assertion in each direction is what rules both out.
    const nothingSet = forwardingWith({});
    expect(nothingSet.credentials).toContain(LONG_STANDING_CREDENTIAL);
    expect(nothingSet.settings).toContain(LONG_STANDING_SETTING);
    expect(nothingSet.forwarded).toEqual([]);

    const set = forwardingWith({
      [LONG_STANDING_CREDENTIAL]: NOT_A_SECRET,
      [LONG_STANDING_SETTING]: "anthropic",
      [DELIBERATELY_NOT_FORWARDED]: NOT_A_SECRET,
    });
    expect(set.forwarded).toContain(LONG_STANDING_CREDENTIAL);
    expect(set.forwarded).toContain(LONG_STANDING_SETTING);
    // Set in the environment the script was run with, and still not forwarded: the list decides,
    // not the shell.
    expect(set.forwarded).not.toContain(DELIBERATELY_NOT_FORWARDED);
  });

  it("names every value it forwards and carries none of them", () => {
    // The script's own claim — `-e NAME`, never `-e NAME=value`, so no value reaches a command line
    // or anything that reads one. Asserted at the argument list because that is where it would
    // break, and because the whole billing set below is credentials.
    const set = forwardingWith({ BILLING_WEBHOOK_SECRET: NOT_A_SECRET });
    expect(set.dockerArgs).toEqual(["-e", "BILLING_WEBHOOK_SECRET"]);
    for (const argument of set.dockerArgs) {
      expect(argument).not.toContain("=");
      expect(argument).not.toContain(NOT_A_SECRET);
    }
  });
});

describe("billing reaches the container", () => {
  /**
   * The trigger and its requirements, taken from `billing/deps.ts` rather than copied. A sixth
   * requirement added there fails this file until `deploy.sh` forwards it, which is the link whose
   * absence is the whole of SONNY-405: SONNY-216 added `BILLING_PROVIDER_ACCESS_TOKEN` to that list
   * and nothing carried it — or the four beside it — across to the deploy script.
   */
  const required = [BILLING_TRIGGER, ...BILLING_REQUIREMENT_NAMES];

  it("takes its population from the code that refuses to start without it", () => {
    // Pinned, so that a `BILLING_REQUIREMENTS` emptied by a bad edit cannot satisfy every loop below
    // by iterating nothing — the clean-zero rule, applied to this file's own population.
    expect(required).toEqual([
      "BILLING_PROVIDER",
      "BILLING_WEBHOOK_SECRET",
      "BILLING_CHECKOUT_URL",
      "BILLING_PROVIDER_ACCESS_TOKEN",
      "BILLING_PLANS",
    ]);
  });

  it("forwards the trigger and every name the trigger makes required", () => {
    const set = forwardingWith(Object.fromEntries(required.map((name) => [name, "polar"])));
    for (const name of required) expect(set.forwarded).toContain(name);
  });

  it("reports each of them by name when it is missing, rather than as a count", () => {
    // The founders' three billing rows begin by exporting these. What this asserts is the difference
    // between the two arrays: on the credential array a name that did not survive the shell is
    // printed before the container starts, on the settings array it would be one unit of a count.
    const nothingSet = forwardingWith({});
    for (const name of required) {
      expect(nothingSet.credentials).toContain(name);
      expect(nothingSet.settings).not.toContain(name);
      expect(nothingSet.absentByName).toContain(name);
    }
  });

  it("puts the by-name list into the line a founder reads", () => {
    // A text claim, and labelled as one: the assertions above measure the array, and the `local`
    // branch renders it with this one expansion. Nothing else in this file covers that step, because
    // reaching that branch means reaching `docker build`.
    const script = readFileSync(`${SERVER_DIR}${SCRIPT}`, "utf8");
    expect(script).toContain("not set here, so not forwarded: ${PASSTHROUGH_ABSENT[*]}");
  });

  it("forwards billing's two optional overrides silently, on the other array", () => {
    // Neither is required when the trigger is set, both have a real default, neither is a secret —
    // so absence is the ordinary correct state and a by-name line for either would be noise. They are
    // forwarded all the same, or the founders' `BILLING_API_BASE_URL` row cannot be run at all and
    // the grace window is a number no deployment can be told.
    const optional = ["BILLING_API_BASE_URL", "BILLING_GRACE_DAYS"];
    const nothingSet = forwardingWith({});
    for (const name of optional) {
      expect(nothingSet.settings).toContain(name);
      expect(nothingSet.credentials).not.toContain(name);
      expect(nothingSet.absentByName).not.toContain(name);
    }

    const set = forwardingWith({ BILLING_API_BASE_URL: "https://api.example.test", BILLING_GRACE_DAYS: "21" });
    for (const name of optional) expect(set.forwarded).toContain(name);
  });

  it("gives a container that asked for no billing nothing about billing", () => {
    // The other half of the placement decision: putting the five on the credential array changes
    // what is printed, never what is forwarded, so a deployment that takes no payments still starts
    // with no billing name in its environment and mounts no billing route.
    const nothingSet = forwardingWith({});
    expect(nothingSet.forwarded.filter((name) => name.startsWith("BILLING_"))).toEqual([]);
  });
});
