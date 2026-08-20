// @ts-nocheck  throwaway probe, not product code
import { handle } from "./handler.js";
Deno.serve((req: Request) => handle(req, Deno.env.get("UPSTREAM_URL") ?? ""));
