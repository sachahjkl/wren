import { createPrivateKey, createPublicKey, createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { b64urlEncode } from "../src/encoding.ts";
import type { Deps, DurableObjectId, DurableObjectNamespace, DurableObjectStub, Env, KVListResult, KVNamespace, OutgoingMail, SendEmail } from "../src/env.ts";
import { LicenseOrder } from "../src/order.ts";
import type { DurableObjectStateLike, DurableObjectStorage } from "../src/order.ts";

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = join(here, "..", "..", "..");

export function fixture(name: string): string {
	return readFileSync(join(here, "fixtures", name), "utf8");
}

// The development pair of src/license/dev_keys.odin, read from the Odin source so the two cannot drift apart.
const devKeys = readFileSync(join(repoRoot, "src", "license", "dev_keys.odin"), "utf8");

function odinSeed(name: string): Uint8Array {
	const line = devKeys.match(new RegExp(`^${name}\\s*:=\\s*\\[32\\]byte\\{(.*)\\}`, "m"));
	if (!line) throw new Error(`${name} not found in dev_keys.odin`);
	const chars = [...line[1].matchAll(/'(.)'/g)].map((m) => m[1].charCodeAt(0));
	if (chars.length !== 32) throw new Error(`${name} is not 32 bytes`);
	return Uint8Array.from(chars);
}

export const DEV_SEED = odinSeed("DEV_SEED");
export const OTHER_DEV_SEED = odinSeed("OTHER_DEV_SEED");
export const DEV_PUBLIC_KEY = devKeys.match(/^DEV_PUBLIC_KEY\s*::\s*"([^"]+)"/m)![1];

const PKCS8 = Buffer.from("302e020100300506032b657004220420", "hex");

// The public half of a seed, computed by Node (independently of the Worker's code).
export function publicKeyOf(seed: Uint8Array): string {
	const priv = createPrivateKey({ key: Buffer.concat([PKCS8, seed]), format: "der", type: "pkcs8" });
	return createPublicKey(priv).export({ format: "jwk" }).x!;
}

export class FakeKV implements KVNamespace {
	data = new Map<string, string>();
	writes = 0;
	async get(key: string): Promise<string | null> {
		return this.data.get(key) ?? null;
	}
	async put(key: string, value: string): Promise<void> {
		this.writes++;
		this.data.set(key, value);
	}
	async delete(key: string): Promise<void> {
		this.data.delete(key);
	}
	async list(options: { prefix?: string; cursor?: string; limit?: number } = {}): Promise<KVListResult> {
		const prefix = options.prefix ?? "";
		const keys = [...this.data.keys()].filter((k) => k.startsWith(prefix)).sort().map((name) => ({ name }));
		return { keys, list_complete: true };
	}
}

// A Durable Object storage backed by a Map, with a single pending alarm (the test fires it with runAlarms()).
class FakeStorage implements DurableObjectStorage {
	map = new Map<string, unknown>();
	alarm: number | null = null;
	async get<T>(key: string): Promise<T | undefined> {
		return this.map.get(key) as T | undefined;
	}
	async put<T>(key: string, value: T): Promise<void> {
		this.map.set(key, structuredClone(value));
	}
	async setAlarm(scheduledTime: number): Promise<void> {
		this.alarm = scheduledTime;
	}
	async getAlarm(): Promise<number | null> {
		return this.alarm;
	}
	async deleteAlarm(): Promise<void> {
		this.alarm = null;
	}
}

class FakeState implements DurableObjectStateLike {
	storage = new FakeStorage();
	// The real input gate serialises; the test is single-threaded, so running fn inline is enough.
	async blockConcurrencyWhile<T>(fn: () => Promise<T>): Promise<T> {
		return await fn();
	}
}

// A fake ORDERS namespace: one LicenseOrder per id, kept so a replay reaches the same object. The object uses the env's
// current `_deps` (the test's fake network and clock), set by the request wrappers before each call.
export class FakeOrders implements DurableObjectNamespace {
	private readonly env: TestEnv;
	readonly objects = new Map<string, { order: LicenseOrder; state: FakeState }>();
	constructor(env: TestEnv) {
		this.env = env;
	}
	idFromName(name: string): DurableObjectId {
		return { toString: () => name };
	}
	get(id: DurableObjectId): DurableObjectStub {
		const name = id.toString();
		let obj = this.objects.get(name);
		if (!obj) {
			const state = new FakeState();
			obj = { state, order: new LicenseOrder(state, this.env, this.env._deps) };
			this.objects.set(name, obj);
		}
		// rebuild with the current deps so a later call sees the test's current clock and network
		obj.order = new LicenseOrder(obj.state, this.env, this.env._deps);
		const order = obj.order;
		return { fetch: (input, init) => order.fetch(new Request(String(input), init)) };
	}
	// Fires every object whose alarm is due at or before `now`, as the runtime would. Returns how many ran.
	async runAlarms(now: number): Promise<number> {
		let ran = 0;
		for (const { order, state } of this.objects.values()) {
			if (state.storage.alarm !== null && state.storage.alarm <= now) {
				state.storage.alarm = null;
				await order.alarm();
				ran++;
			}
		}
		return ran;
	}
}

// A fake `send_email` binding: keeps every message it was asked to send; `fail` is called before each one and may
// throw (an Error with a `code`, as Email Service does) or return nothing to let the send succeed.
export class FakeEmail implements SendEmail {
	sent: OutgoingMail[] = [];
	attempts = 0;
	fail: ((n: number) => void | Promise<void>) | null = null;
	async send(message: OutgoingMail): Promise<{ messageId: string }> {
		this.attempts++;
		await this.fail?.(this.attempts);
		this.sent.push(message);
		return { messageId: `msg_${this.sent.length}` };
	}
}

export function emailError(code: string, message = "refused"): Error {
	return Object.assign(new Error(message), { code });
}

export const WEBHOOK_SECRET = "pdl_ntfset_01hv8x0000000000000000test_AbCdEfGh";
export const PRICE_SUPPORTER = "pri_01hsxyh9a1fnwv3xbg2zykm4sj";
export const PRICE_PATRON = "pri_01hsxyk2m7c4e8r5t3w9q6z1pd";
export const TXN = "txn_01hv8wptq8987qeep44cyrewp9";
export const NOW = Date.parse("2026-10-22T09:15:32Z");

export type TestEnv = Env & { LICENSES: FakeKV; EMAIL: FakeEmail; ORDERS: FakeOrders; _deps: Deps };

// `makeEnv({ EMAIL: undefined })` is a Worker with no mail binding.
export function makeEnv(extra: Partial<Env> = {}): TestEnv {
	const env = {
		LICENSES: new FakeKV(),
		EMAIL: new FakeEmail(),
		LICENSE_PRIVATE_KEY: b64urlEncode(DEV_SEED),
		LICENSE_PUBLIC_KEY: DEV_PUBLIC_KEY,
		PADDLE_WEBHOOK_SECRET: WEBHOOK_SECRET,
		PADDLE_API_KEY: "pdl_sdbx_apikey_test",
		PADDLE_API_BASE: "https://sandbox-api.paddle.com",
		MAIL_FROM: "Wren <licences@example.org>",
		PRICE_SUPPORTER,
		PRICE_PATRON,
		ALLOWED_ORIGIN: "https://sachahjkl.github.io",
		RESEND_ENABLED: "false",
		_deps: { fetch: (() => { throw new Error("no network set for this env"); }) as unknown as typeof fetch, now: () => NOW },
		...extra,
	} as TestEnv;
	env.ORDERS = new FakeOrders(env);
	return env;
}

export function paddleSignature(body: string, secret = WEBHOOK_SECRET, ts = Math.floor(NOW / 1000)): string {
	const h1 = createHmac("sha256", secret).update(`${ts}:${body}`).digest("hex");
	return `ts=${ts};h1=${h1}`;
}

export function webhookRequest(body: string, signature: string | null = paddleSignature(body)): Request {
	const headers: Record<string, string> = { "Content-Type": "application/json" };
	if (signature !== null) headers["Paddle-Signature"] = signature;
	return new Request("https://licences.example.workers.dev/paddle/webhook", { method: "POST", headers, body });
}

export interface Call {
	url: string;
	method: string;
	headers: Record<string, string>;
	body: string;
}

// A network that answers from a table of handlers (matched by URL prefix) and keeps what was asked.
export function fakeNetwork(routes: Record<string, (call: Call) => Response>) {
	const calls: Call[] = [];
	const fetchFn = (async (input: RequestInfo | URL, init?: RequestInit) => {
		const url = String(input);
		const call: Call = { url, method: init?.method ?? "GET", headers: Object.fromEntries(new Headers(init?.headers).entries()), body: String(init?.body ?? "") };
		calls.push(call);
		const route = Object.keys(routes).find((p) => url.startsWith(p));
		if (!route) throw new Error(`unexpected request to ${url}`);
		return routes[route](call);
	}) as typeof fetch;
	return { calls, deps: { fetch: fetchFn, now: () => NOW } satisfies Deps };
}

export const jsonResponse = (body: string, status = 200) => new Response(body, { status, headers: { "Content-Type": "application/json" } });

export const waiter = { waitUntil() {} };
