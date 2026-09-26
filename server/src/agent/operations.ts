/**
 * The typed operations a Mac may declare in its manifest, with their argument schemas.
 *
 * Each entry mirrors `contracts/v2/operations/<name>.v<version>.schema.json`, and
 * `test/contracts.test.ts` checks the two agree on that operation's fixtures. The `floor` is the
 * least effect the operation can have; the Mac enforces the same floor and may raise it further.
 * A change to an argument schema is a new version, never an edit in place, because Macs already in
 * the field keep declaring the old one.
 */
import { z } from "zod/v4";
import type { Effect } from "./protocol.js";

export interface OperationSpec {
  readonly name: string;
  readonly version: number;
  readonly args: z.ZodType<Record<string, unknown>>;
  readonly floor: Effect;
}

export const OPERATIONS: readonly OperationSpec[] = [
  {
    name: "open_app",
    version: 1,
    args: z.strictObject({ app: z.string().min(1).max(255) }),
    floor: "navigate",
  },
];

export function operationSpec(name: string, version: number): OperationSpec | undefined {
  return OPERATIONS.find((spec) => spec.name === name && spec.version === version);
}
