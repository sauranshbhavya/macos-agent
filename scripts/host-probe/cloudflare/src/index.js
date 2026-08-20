import { handle } from "./handler.js";
export default { fetch: (request, env) => handle(request, env.UPSTREAM_URL || "") };
