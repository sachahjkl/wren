import { handle } from "./handler.ts";
import type { Env, Waiter } from "./env.ts";

export { LicenseOrder } from "./order.ts";   // the Durable Object (one per transaction); declared in wrangler.jsonc

export default {
	fetch(request: Request, env: Env, ctx: Waiter): Promise<Response> {
		return handle(request, env, ctx);
	},
};
