// Paddle Billing: the webhook signature, the transaction, the customer.

import { concat, hexDecode, utf8 } from "./encoding.ts";
import type { Deps, Env } from "./env.ts";
import type { Edition } from "./licence.ts";

export interface SignatureHeader {
	ts: string;
	h1: string[];
}

// "ts=1671552777;h1=eb4d..." (several h1 while the secret is being rotated)
export function parseSignatureHeader(header: string | null): SignatureHeader | null {
	if (!header) return null;
	let ts = "";
	const h1: string[] = [];
	for (const part of header.split(";")) {
		const eq = part.indexOf("=");
		if (eq < 0) continue;
		const k = part.slice(0, eq).trim();
		const v = part.slice(eq + 1).trim();
		if (k === "ts") ts = v;
		else if (k === "h1") h1.push(v);
	}
	return /^\d{1,12}$/.test(ts) && h1.length > 0 ? { ts, h1 } : null;
}

export type SignatureResult = "ok" | "missing" | "malformed" | "stale" | "mismatch";

// HMAC-SHA256 of `ts:` + the body exactly as received, keyed with the destination's secret, compared by WebCrypto
// (constant time), and the timestamp within `toleranceSeconds` of now (a recorded request cannot be replayed later).
export async function verifySignature(body: Uint8Array, header: string | null, secret: string, nowMs: number, toleranceSeconds: number): Promise<SignatureResult> {
	if (!header) return "missing";
	const sig = parseSignatureHeader(header);
	if (!sig || !secret) return "malformed";
	if (Math.abs(nowMs / 1000 - Number(sig.ts)) > toleranceSeconds) return "stale";
	const key = await crypto.subtle.importKey("raw", utf8(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
	const data = concat(utf8(sig.ts + ":"), body);
	for (const h of sig.h1) {
		const mac = hexDecode(h);
		if (mac && mac.length === 32 && (await crypto.subtle.verify("HMAC", key, mac, data))) return "ok";
	}
	return "mismatch";
}

// The parts of a Paddle Billing transaction (notification `data`) that matter here.
export interface Item {
	price_id?: string;
	price?: { id?: string };
}

export interface Transaction {
	id?: string;
	status?: string;
	customer_id?: string | null;
	customer?: { name?: string | null; email?: string | null } | null;
	items?: Item[];
	billed_at?: string | null;
	created_at?: string | null;
}

export interface Event {
	event_id?: string;
	event_type?: string;
	data?: Transaction;
}

export const TXN_ID = /^txn_[0-9a-z]{20,40}$/;
const CUSTOMER_ID = /^ctm_[0-9a-z]{20,40}$/;

function priceIds(list: string | undefined): Set<string> {
	return new Set((list ?? "").split(/[\s,]+/).filter(Boolean));
}

// The best edition among the items bought (patron over supporter), or null when none is a Wren price.
export function editionOf(items: Item[] | undefined, env: Pick<Env, "PRICE_SUPPORTER" | "PRICE_PATRON">): Edition | null {
	const supporter = priceIds(env.PRICE_SUPPORTER);
	const patron = priceIds(env.PRICE_PATRON);
	let found: Edition | null = null;
	for (const it of items ?? []) {
		const id = it.price_id ?? it.price?.id ?? "";
		if (!id) continue;
		if (patron.has(id)) return "patron";
		if (supporter.has(id)) found = "supporter";
	}
	return found;
}

// A readable order number from the transaction id: WREN-XXXX-XXXX-XXXX, the last twelve characters of its ULID.
export function orderNumber(txn: string): string {
	const tail = txn.replace(/^txn_/, "").slice(-12).toUpperCase();
	return `WREN-${tail.slice(0, 4)}-${tail.slice(4, 8)}-${tail.slice(8, 12)}`;
}

// The day of the purchase (UTC), from the transaction, else today.
export function dayOf(t: Transaction, nowMs: number): string {
	for (const s of [t.billed_at, t.created_at]) {
		const ms = s ? Date.parse(s) : NaN;
		if (Number.isFinite(ms)) return new Date(ms).toISOString().slice(0, 10);
	}
	return new Date(nowMs).toISOString().slice(0, 10);
}

export class Transient extends Error {}   // worth retrying later (Paddle retries a webhook that did not get a 2xx)

export interface Customer {
	name: string;
	email: string;
}

// The webhook of a transaction carries the customer's id, not the name and e-mail: GET /customers/{id}.
export async function fetchCustomer(env: Env, deps: Deps, id: string): Promise<Customer | null> {
	if (!CUSTOMER_ID.test(id)) return null;
	let res: Response;
	try {
		res = await deps.fetch(`${env.PADDLE_API_BASE.replace(/\/+$/, "")}/customers/${id}`, {
			headers: { Authorization: `Bearer ${env.PADDLE_API_KEY}`, "Paddle-Version": "1", Accept: "application/json" },
			signal: AbortSignal.timeout(3000),
		});
	} catch {
		throw new Transient("the Paddle API did not answer");
	}
	if (res.status === 404) return null;
	if (!res.ok) {
		if (res.status === 429 || res.status >= 500) throw new Transient(`the Paddle API said ${res.status}`);
		throw new Error(`the Paddle API refused the request (${res.status}): is PADDLE_API_KEY right, and PADDLE_API_BASE the same environment (sandbox or live) as the webhook?`);
	}
	const body = (await res.json()) as { data?: { name?: string | null; email?: string | null } };
	const email = body.data?.email?.trim();
	return email ? { name: body.data?.name?.trim() || "", email } : null;
}
