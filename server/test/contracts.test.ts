import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Ajv2020 } from "ajv/dist/2020.js";
import { describe, expect, it } from "vitest";
import { operationSpec, OPERATIONS } from "../src/agent/operations.js";
import { clientMessageSchema, serverMessageSchema } from "../src/agent/protocol.js";

// The shared V2 contract at the repository root. The Swift suite reads the same files
// (Tests/MacAgentCoreTests/Kernel/WireContractTests.swift).
const CONTRACTS = fileURLToPath(new URL("../../contracts/v2/", import.meta.url));
const FIXTURES = join(CONTRACTS, "fixtures");

function readJSON(path: string): unknown {
  return JSON.parse(readFileSync(path, "utf8"));
}

function fixtures(dir: string): Array<[string, unknown]> {
  return readdirSync(join(FIXTURES, dir))
    .filter((name) => name.endsWith(".json"))
    .sort()
    .map((name) => [name, readJSON(join(FIXTURES, dir, name))]);
}

const ajv = new Ajv2020({ allErrors: true, strict: true, strictTypes: false, strictRequired: false });
const protocol = readJSON(join(CONTRACTS, "protocol.schema.json")) as { $id: string };
ajv.addSchema(protocol);
const validateClient = ajv.getSchema(`${protocol.$id}#/$defs/ClientMessage`)!;
const validateServer = ajv.getSchema(`${protocol.$id}#/$defs/ServerMessage`)!;

const directions = [
  { side: "client", zod: clientMessageSchema, json: validateClient },
  { side: "server", zod: serverMessageSchema, json: validateServer },
] as const;

describe.each(directions)("$side messages", ({ side, zod, json }) => {
  const valid = fixtures(`${side}/valid`);
  const invalid = fixtures(`${side}/invalid`);

  it("has fixtures to check", () => {
    expect(valid.length).toBeGreaterThan(5);
    expect(invalid.length).toBeGreaterThan(5);
  });

  it.each(valid)("%s decodes and re-encodes unchanged", (_name, fixture) => {
    const parsed = zod.parse(fixture);
    expect(JSON.parse(JSON.stringify(parsed))).toEqual(fixture);
  });

  it.each(valid)("%s satisfies the JSON Schema", (_name, fixture) => {
    expect(json(fixture), JSON.stringify(json.errors)).toBe(true);
  });

  it.each(invalid)("%s is refused by the Zod mirror", (_name, fixture) => {
    expect(zod.safeParse(fixture).success).toBe(false);
  });

  it.each(invalid)("%s is refused by the JSON Schema", (_name, fixture) => {
    expect(json(fixture)).toBe(false);
  });
});

describe("operation argument schemas", () => {
  const dirs = readdirSync(join(FIXTURES, "operations")).sort();

  it("every operation the gateway knows has a contract schema and fixtures", () => {
    const known = OPERATIONS.map((spec) => `${spec.name}.v${spec.version}`).sort();
    expect(dirs).toEqual(known);
  });

  describe.each(dirs)("%s", (dir) => {
    const match = /^(.+)\.v(\d+)$/.exec(dir)!;
    const spec = operationSpec(match[1]!, Number(match[2]))!;
    const schema = ajv.compile(readJSON(join(CONTRACTS, "operations", `${dir}.schema.json`)) as object);

    it.each(fixtures(`operations/${dir}/valid`))("%s is accepted by both", (_name, args) => {
      expect(spec.args.safeParse(args).success).toBe(true);
      expect(schema(args)).toBe(true);
    });

    it.each(fixtures(`operations/${dir}/invalid`))("%s is refused by both", (_name, args) => {
      expect(spec.args.safeParse(args).success).toBe(false);
      expect(schema(args)).toBe(false);
    });
  });
});
