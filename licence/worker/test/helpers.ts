import { createPrivateKey, createPublicKey, createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { b64urlEncode } from "../src/encoding.ts";
import type { Deps, Env, KVNamespace, OutgoingMail, SendEmail } from "../src/env.ts";

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

export type TestEnv = Env & { LICENSES: FakeKV; EMAIL: FakeEmail };

// `makeEnv({ EMAIL: undefined })` is a Worker with no mail binding.
export function makeEnv(extra: Partial<Env> = {}): TestEnv {
	return {
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
		...extra,
	} as TestEnv;
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
