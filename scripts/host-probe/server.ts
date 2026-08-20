// Local control arm. Same handler, same runtime family as Supabase Edge Functions (Deno),
// no platform in between -- so anything the hosted arm adds is the host, not the probe.
import { handle } from "../handler.js";
const upstream = Deno.env.get("UPSTREAM_URL") ?? "";
Deno.serve({ port: Number(Deno.env.get("PORT") ?? 8787) }, (req) => handle(req, upstream));
