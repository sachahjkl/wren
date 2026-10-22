import { handle } from "./handler.ts";
import type { Env, Waiter } from "./env.ts";

export default {
	fetch(request: Request, env: Env, ctx: Waiter): Promise<Response> {
		return handle(request, env, ctx);
	},
};
