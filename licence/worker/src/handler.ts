// The HTTP surface:
//
//   POST /paddle/webhook          Paddle Billing notifications (signed); transaction.completed issues the licence
//   POST /mail/bounce             the mail provider's delivery webhook (bounces), shared-secret or signed; marks failed
//   GET  /licence?txn=txn_...     the licence of a transaction as JSON, for the checkout's success page (202 until it exists)
//   GET  /licence/txn_....wrenlicense   the same as a file to download
//   POST /resend                  {"email": ...} mails the licences bought with that address again (off unless RESEND_ENABLED)
//   GET  /admin/dead-letter       the mails that gave up (Bearer ADMIN_TOKEN); POST /admin/dead-letter/retry re-queues one
//   GET  /health                  {"ok": bool, "missing": [names of settings not set]}
//
// Every per-transaction action goes through the LicenseOrder Durable Object (one per transaction id): the Worker only
// validates the request, picks the stub by id, and relays the answer. That is what makes a double webhook safe.

import { intSetting, missingSettings } from "./env.ts";
import type { Deps, DurableObjectStub, Env, Waiter } from "./env.ts";
import { log } from "./issue.ts";
import { licenceFileName } from "./licence.ts";
import { TXN_ID, Transient, verifySignature } from "./paddle.ts";
import type { Event } from "./paddle.ts";
import type { OrderState } from "./order.ts";
import { getTxn, listDeadLetters, takeResendSlot, transactionsOf } from "./store.ts";
import { timingSafeEqual } from "./encoding.ts";

const MAX_WEBHOOK_BYTES = 512 * 1024;
const MAX_RESEND_BYTES = 2048;

export const realDeps: Deps = { fetch: (input, init) => fetch(input, init), now: () => Date.now() };

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
	return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...headers } });
}

// CORS for the pages of the site (thanks.html calls GET /licence from another origin).
function cors(request: Request, env: Env): Record<string, string> {
	const allowed = (env.ALLOWED_ORIGIN ?? "").split(",").map((s) => s.trim()).filter(Boolean);
	const origin = request.headers.get("Origin");
	const headers: Record<string, string> = { Vary: "Origin" };
	if (allowed.includes("*")) headers["Access-Control-Allow-Origin"] = "*";
	else if (origin && allowed.includes(origin)) headers["Access-Control-Allow-Origin"] = origin;
	return headers;
}

// The stub for one transaction's object. `idFromName(txn)` is stable: the same id always lands on the same object, so
// every delivery of the same webhook is serialised by that one object.
function orderStub(env: Env, txn: string): DurableObjectStub {
	return env.ORDERS.get(env.ORDERS.idFromName(txn));
}

// Posts a command to the object and returns its parsed answer and HTTP status (200 done, 500 retry, 422 never).
async function tellOrder(env: Env, txn: string, body: unknown): Promise<{ status: number; body: Record<string, unknown> }> {
	const res = await orderStub(env, txn).fetch("https://order/", { method: "POST", body: JSON.stringify(body) });
	const parsed = (await res.json()) as Record<string, unknown>;
	return { status: res.status, body: parsed };
}

export async function handle(request: Request, env: Env, _waiter: Waiter, deps: Deps = realDeps): Promise<Response> {
	const url = new URL(request.url);
	const path = url.pathname.replace(/\/+$/, "") || "/";
	const headers = cors(request, env);
	try {
		if (request.method === "OPTIONS") {
			return new Response(null, { status: 204, headers: { ...headers, "Access-Control-Allow-Methods": "GET, POST, OPTIONS", "Access-Control-Allow-Headers": "Content-Type, Authorization", "Access-Control-Max-Age": "86400" } });
		}
		let res: Response;
		if (path === "/paddle/webhook") res = request.method === "POST" ? await webhook(request, env, deps) : json(405, { error: "POST only" }, { Allow: "POST" });
		else if (path === "/mail/bounce") res = request.method === "POST" ? await mailBounce(request, env) : json(405, { error: "POST only" }, { Allow: "POST" });
		else if (path === "/licence") res = request.method === "GET" ? await licenceJson(url, env) : json(405, { error: "GET only" }, { Allow: "GET" });
		else if (path.startsWith("/licence/") && path.endsWith(".wrenlicense")) res = request.method === "GET" ? await licenceFile(path, env) : json(405, { error: "GET only" }, { Allow: "GET" });
		else if (path === "/resend") res = request.method === "POST" ? await resend(request, env) : json(405, { error: "POST only" }, { Allow: "POST" });
		else if (path === "/admin/dead-letter") res = request.method === "GET" ? await deadLetterList(request, env) : json(405, { error: "GET only" }, { Allow: "GET" });
		else if (path === "/admin/dead-letter/retry") res = request.method === "POST" ? await deadLetterRetry(request, env) : json(405, { error: "POST only" }, { Allow: "POST" });
		else if (path === "/health") { const missing = missingSettings(env); res = json(missing.length ? 503 : 200, { ok: missing.length === 0, missing }); }
		else res = json(404, { error: "not found" });
		for (const [k, v] of Object.entries(headers)) res.headers.set(k, v);
		return res;
	} catch (e) {
		// a Transient failure (the Paddle API down, or Email Service refusing for now) is worth a retry; Paddle redelivers on any non-2xx
		log("error", { transient: e instanceof Transient, message: e instanceof Error ? e.message : "?" });
		return json(500, { error: "retry later" }, headers);
	}
}

async function webhook(request: Request, env: Env, deps: Deps): Promise<Response> {
	const declared = Number(request.headers.get("Content-Length") ?? "0");
	if (declared > MAX_WEBHOOK_BYTES) return json(413, { error: "too large" });
	const body = new Uint8Array(await request.arrayBuffer());
	if (body.length > MAX_WEBHOOK_BYTES) return json(413, { error: "too large" });

	const tolerance = intSetting(env.WEBHOOK_TOLERANCE_SECONDS, 300, 1, 86400);
	const verdict = await verifySignature(body, request.headers.get("Paddle-Signature"), env.PADDLE_WEBHOOK_SECRET, deps.now(), tolerance);
	if (verdict !== "ok") {
		log("webhook_rejected", { why: verdict });
		return json(401, { error: "bad signature" });
	}

	let event: Event;
	try {
		event = JSON.parse(new TextDecoder().decode(body)) as Event;
	} catch {
		return json(400, { error: "not JSON" });
	}
	if (event.event_type !== "transaction.completed" || !event.data) return json(200, { status: "ignored", event: String(event.event_type ?? "") });
	const txn = event.data.id ?? "";
	if (!TXN_ID.test(txn)) return json(422, { status: "invalid", reason: "no valid transaction id" });

	const { status, body: answer } = await tellOrder(env, txn, { op: "webhook", id: txn, txn: event.data });
	return json(status, answer);
}

// The mail provider's delivery webhook (a bounce or a complaint): mark the mail failed and dead-letter it. Protected by
// a shared secret in MAIL_BOUNCE_SECRET (a header the provider is told to send), closed when that is unset. The body is
// expected to carry the Wren order or transaction id and a reason (no Email Service webhook on Cloudflare today, so this
// is deliberately provider-agnostic: see docs/licence.md).
async function mailBounce(request: Request, env: Env): Promise<Response> {
	if (!env.MAIL_BOUNCE_SECRET) return json(404, { error: "not found" });
	const given = request.headers.get("X-Bounce-Secret") ?? bearer(request) ?? "";
	if (!timingSafeEqual(given, env.MAIL_BOUNCE_SECRET)) return json(401, { error: "bad secret" });

	const text = await request.text();
	if (text.length > MAX_RESEND_BYTES) return json(413, { error: "too large" });
	let v: { txn?: unknown; order?: unknown; reason?: unknown };
	try {
		v = JSON.parse(text) as typeof v;
	} catch {
		return json(400, { error: "expected JSON" });
	}
	const reason = typeof v.reason === "string" ? v.reason.slice(0, 64).replace(/[^\w .:-]/g, "") : "bounce";
	let txn = typeof v.txn === "string" && TXN_ID.test(v.txn) ? v.txn : "";
	if (!txn && typeof v.order === "string") txn = (await env.LICENSES.get(`order:${v.order.trim()}`)) ?? "";
	if (!TXN_ID.test(txn)) return json(404, { error: "no such order" });

	const res = await orderStub(env, txn).fetch("https://order/bounce", { method: "POST", body: JSON.stringify({ id: txn, reason }) });
	const state = (await res.json()) as OrderState;
	return json(200, { status: "ok", mail: state.stored?.mail });
}

async function licenceJson(url: URL, env: Env): Promise<Response> {
	const txn = url.searchParams.get("txn") ?? "";
	// The id is the only secret of this endpoint: a 26-character ULID whose 80 random bits cannot be guessed, known to
	// the buyer (Paddle puts it in the success URL) and to Paddle. What it gives is a licence that unlocks nothing.
	if (!TXN_ID.test(txn)) return json(400, { error: "not a transaction id" });
	const s = await getTxn(env.LICENSES, txn);
	if (!s || !s.licence) return json(202, { status: "pending", message: "Your licence is being made: try again in a few seconds." }, { "Retry-After": "3" });
	return json(200, { status: "ready", edition: s.edition, name: s.name, order: s.order, date: s.date, licence: s.licence, file: s.file, filename: licenceFileName(s.order) });
}

async function licenceFile(path: string, env: Env): Promise<Response> {
	const txn = path.slice("/licence/".length, -".wrenlicense".length);
	if (!TXN_ID.test(txn)) return json(400, { error: "not a transaction id" });
	const s = await getTxn(env.LICENSES, txn);
	if (!s || !s.file) return json(404, { error: "no licence for this transaction (yet)" });
	return new Response(s.file, { headers: { "Content-Type": "application/octet-stream", "Content-Disposition": `attachment; filename="${licenceFileName(s.order)}"`, "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
}

// Same answer whether or not the address bought anything (nobody can find out who did), at most RESEND_MAX_PER_HOUR
// mails per address and hour, and KV is only written for an address that has a purchase (an attacker cannot use up the
// day's write quota with made-up addresses). Every mail goes back through the object, never sent from here.
async function resend(request: Request, env: Env): Promise<Response> {
	if (env.RESEND_ENABLED !== "true") return json(404, { error: "not found" });
	if (env.RESEND_REQUIRE_TOKEN === "true" && !adminOk(request, env)) return json(401, { error: "admin token required" });
	const text = await request.text();
	if (text.length > MAX_RESEND_BYTES) return json(413, { error: "too large" });
	let email = "";
	try {
		const v = JSON.parse(text) as { email?: unknown };
		email = typeof v.email === "string" ? v.email.trim() : "";
	} catch {
		return json(400, { error: "expected {\"email\": \"...\"}" });
	}
	if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) return json(400, { error: "not an e-mail address" });

	const answer = json(202, { status: "ok", message: "If that address bought a licence, it has been sent there again." });
	const ids = await transactionsOf(env.LICENSES, email);
	if (ids.length === 0) return answer;
	if (!(await takeResendSlot(env.LICENSES, email, intSetting(env.RESEND_MAX_PER_HOUR, 3, 1, 100)))) return answer;

	for (const id of ids) {
		const res = await orderStub(env, id).fetch("https://order/", { method: "POST", body: JSON.stringify({ op: "resend", id }) });
		const state = (await res.json()) as OrderState;
		log("resend", { txn: id, state: state.stored?.mail });
	}
	return answer;
}

// The dead-letter, for a person with the admin token. No name, no address: an order, a code, a count, a time.
async function deadLetterList(request: Request, env: Env): Promise<Response> {
	if (!adminOk(request, env)) return json(401, { error: "admin token required" });
	const items = await listDeadLetters(env.LICENSES, 200);
	return json(200, { count: items.length, items });
}

// Re-queue one dead-lettered mail (the provider is healthy again): POST {"txn": "txn_..."} with the admin token.
async function deadLetterRetry(request: Request, env: Env): Promise<Response> {
	if (!adminOk(request, env)) return json(401, { error: "admin token required" });
	let txn = "";
	try {
		const v = JSON.parse(await request.text()) as { txn?: unknown };
		txn = typeof v.txn === "string" ? v.txn.trim() : "";
	} catch {
		return json(400, { error: "expected {\"txn\": \"...\"}" });
	}
	if (!TXN_ID.test(txn)) return json(400, { error: "not a transaction id" });
	const res = await orderStub(env, txn).fetch("https://order/", { method: "POST", body: JSON.stringify({ op: "resend", id: txn }) });
	const state = (await res.json()) as OrderState;
	return json(200, { status: "requeued", mail: state.stored?.mail });
}

function bearer(request: Request): string | null {
	const h = request.headers.get("Authorization") ?? "";
	const m = /^Bearer\s+(.+)$/i.exec(h);
	return m ? m[1].trim() : null;
}

// True when the request carries the admin token and one is configured (constant-time compare, no token = closed).
function adminOk(request: Request, env: Env): boolean {
	const token = env.ADMIN_TOKEN ?? "";
	if (!token) return false;
	return timingSafeEqual(bearer(request) ?? "", token);
}
