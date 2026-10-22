// The HTTP surface:
//
//   POST /paddle/webhook          Paddle Billing notifications (signed); transaction.completed issues the licence
//   GET  /licence?txn=txn_...     the licence of a transaction as JSON, for the checkout's success page (202 until it exists)
//   GET  /licence/txn_....wrenlicense   the same as a file to download
//   POST /resend                  {"email": ...} mails the licences bought with that address again (off unless RESEND_ENABLED)
//   GET  /health                  {"ok": bool, "missing": [names of settings not set]}

import { intSetting, missingSettings } from "./env.ts";
import type { Deps, Env, Waiter } from "./env.ts";
import { issue, log } from "./issue.ts";
import { licenceFileName } from "./licence.ts";
import { sendLicenceMail } from "./mail.ts";
import { TXN_ID, Transient, verifySignature } from "./paddle.ts";
import type { Event } from "./paddle.ts";
import { getTxn, takeResendSlot, transactionsOf } from "./store.ts";

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

export async function handle(request: Request, env: Env, _waiter: Waiter, deps: Deps = realDeps): Promise<Response> {
	const url = new URL(request.url);
	const path = url.pathname.replace(/\/+$/, "") || "/";
	const headers = cors(request, env);
	try {
		if (request.method === "OPTIONS") {
			return new Response(null, { status: 204, headers: { ...headers, "Access-Control-Allow-Methods": "GET, POST, OPTIONS", "Access-Control-Allow-Headers": "Content-Type", "Access-Control-Max-Age": "86400" } });
		}
		let res: Response;
		if (path === "/paddle/webhook") res = request.method === "POST" ? await webhook(request, env, deps) : json(405, { error: "POST only" }, { Allow: "POST" });
		else if (path === "/licence") res = request.method === "GET" ? await licenceJson(url, env) : json(405, { error: "GET only" }, { Allow: "GET" });
		else if (path.startsWith("/licence/") && path.endsWith(".wrenlicense")) res = request.method === "GET" ? await licenceFile(path, env) : json(405, { error: "GET only" }, { Allow: "GET" });
		else if (path === "/resend") res = request.method === "POST" ? await resend(request, env, deps) : json(405, { error: "POST only" }, { Allow: "POST" });
		else if (path === "/health") { const missing = missingSettings(env); res = json(missing.length ? 503 : 200, { ok: missing.length === 0, missing }); }
		else res = json(404, { error: "not found" });
		for (const [k, v] of Object.entries(headers)) res.headers.set(k, v);
		return res;
	} catch (e) {
		// a Transient failure (the Paddle API or Resend down) is worth a retry; Paddle redelivers on any non-2xx
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

	const outcome = await issue(env, deps, event.data);
	switch (outcome.kind) {
		case "issued":
		case "replayed":
			return json(200, { status: outcome.kind, order: outcome.stored.order, mail: outcome.stored.mail });
		case "ignored":
			log("webhook_ignored", { txn: event.data.id, reason: outcome.reason });
			return json(200, { status: "ignored", reason: outcome.reason });
		case "invalid":
			log("webhook_invalid", { txn: event.data.id, reason: outcome.reason });
			return json(422, { status: "invalid", reason: outcome.reason });
	}
}

async function licenceJson(url: URL, env: Env): Promise<Response> {
	const txn = url.searchParams.get("txn") ?? "";
	// The id is the only secret of this endpoint: a 26-character ULID whose 80 random bits cannot be guessed, known to
	// the buyer (Paddle puts it in the success URL) and to Paddle. What it gives is a licence that unlocks nothing.
	if (!TXN_ID.test(txn)) return json(400, { error: "not a transaction id" });
	const s = await getTxn(env.LICENSES, txn);
	if (!s) return json(202, { status: "pending", message: "Your licence is being made: try again in a few seconds." }, { "Retry-After": "3" });
	return json(200, { status: "ready", edition: s.edition, name: s.name, order: s.order, date: s.date, licence: s.licence, file: s.file, filename: licenceFileName(s.order) });
}

async function licenceFile(path: string, env: Env): Promise<Response> {
	const txn = path.slice("/licence/".length, -".wrenlicense".length);
	if (!TXN_ID.test(txn)) return json(400, { error: "not a transaction id" });
	const s = await getTxn(env.LICENSES, txn);
	if (!s) return json(404, { error: "no licence for this transaction (yet)" });
	return new Response(s.file, { headers: { "Content-Type": "application/octet-stream", "Content-Disposition": `attachment; filename="${licenceFileName(s.order)}"`, "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
}

// Same answer whether or not the address bought anything (nobody can find out who did), at most RESEND_MAX_PER_HOUR
// mails per address and hour, and KV is only written for an address that has a purchase (an attacker cannot use up the
// day's write quota with made-up addresses).
async function resend(request: Request, env: Env, deps: Deps): Promise<Response> {
	if (env.RESEND_ENABLED !== "true") return json(404, { error: "not found" });
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

	const hour = Math.floor(deps.now() / 3_600_000);
	for (const id of ids) {
		const s = await getTxn(env.LICENSES, id);
		if (!s) continue;
		const result = await sendLicenceMail(env, deps, s, `wren-resend-${id}-${hour}`);
		log("resend", { txn: id, state: result });
	}
	return answer;
}
