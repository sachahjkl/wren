// What is kept in KV, the globally-replicated read side of the shop.
//
//   txn:<paddle transaction id>   the licence and how it was delivered (projection the thank-you page reads)
//   order:<WREN-...>              -> the transaction id (to find a sale from the order number in a licence)
//   email:<sha256 of the address> -> JSON array of transaction ids (to mail the licences again to their buyer)
//   rl:<sha256 of the address>    -> number of mails sent again this hour
//   dead:<paddle transaction id>  a licence whose mail gave up (dead-letter; GET /admin/dead-letter lists them)
//
// The authority is no longer KV but one LicenseOrder Durable Object per transaction (src/order.ts): its input gate
// serialises everything done for a purchase, so a webhook delivered twice at the very same instant cannot issue two
// licences or send two mails. KV is written by the Durable Object as a copy for the fast read paths; where the two
// could disagree (a crash between writes), the Durable Object wins and heals the copy on its next wake.

import type { Edition } from "./licence.ts";
import type { KVNamespace } from "./env.ts";
import { sha256Hex } from "./encoding.ts";

// The mail state kept with a purchase. The Durable Object drives it; KV mirrors it.
//   pending: owed, waiting for an attempt (the first, or a retry scheduled by the alarm).
//   sending: an attempt is in flight and its outcome is not known yet; it is never repeated blindly.
//   sent:    delivered (final).
//   failed:  refused for good (a bad address, a bounce reported by the provider, the attempt cap reached): final.
//   dead:    the attempt cap was reached while every try was worth retrying (the provider stayed down): dead-letter.
//   skipped: no mail binding or MAIL_FROM yet; retried once they are there.
// "failed" and "dead" are both terminal defeats; "dead" says "resources were there but we ran out of patience", so it
// is the set worth a human look and a /resend once the provider is healthy again.
export type MailState = "pending" | "sending" | "sent" | "failed" | "dead" | "skipped";

export interface Stored {
	v: 1;
	txn: string;
	order: string;
	edition: Edition;
	name: string;
	email: string;
	date: string;
	licence: string;   // WREN1.…
	file: string;      // the .wrenlicense text
	issued_at: string;
	mail: MailState;
	mail_detail?: string;   // the Email Service error code of the last refusal (E_…); never an address
	mail_at?: string;
	mail_attempts?: number; // how many send() calls were made (for the backoff and the attempt cap)
	purged_at?: string;     // when the name and address were dropped (RGPD); the licence itself stays
}

export async function getTxn(kv: KVNamespace, txn: string): Promise<Stored | null> {
	const text = await kv.get(`txn:${txn}`);
	if (!text) return null;
	try {
		const s = JSON.parse(text) as Stored;
		return s.v === 1 ? s : null;
	} catch {
		return null;
	}
}

export async function putTxn(kv: KVNamespace, s: Stored): Promise<void> {
	await kv.put(`txn:${s.txn}`, JSON.stringify(s));
}

export async function emailKey(email: string): Promise<string> {
	return "email:" + (await sha256Hex(email.trim().toLowerCase()));
}

export async function index(kv: KVNamespace, s: Stored): Promise<void> {
	await kv.put(`order:${s.order}`, s.txn);
	const key = await emailKey(s.email);
	const known = parseList(await kv.get(key));
	if (!known.includes(s.txn)) await kv.put(key, JSON.stringify([...known, s.txn].slice(-20)));
}

export async function transactionsOf(kv: KVNamespace, email: string): Promise<string[]> {
	return parseList(await kv.get(await emailKey(email)));
}

// Drops a transaction from an address's index (RGPD purge). The key is removed when it was the only one, so the
// address's hash no longer appears in KV at all.
export async function unindexEmail(kv: KVNamespace, email: string, txn: string): Promise<void> {
	const key = await emailKey(email);
	const rest = (await transactionsOf(kv, email)).filter((id) => id !== txn);
	if (rest.length) await kv.put(key, JSON.stringify(rest));
	else await kv.delete(key);
}

// The dead-letter: a mail that gave up. A small record (no name, no address: only the order, the last code and when),
// so GET /admin/dead-letter can show it without handling personal data. Removed when the mail finally goes out.
export interface DeadLetter {
	txn: string;
	order: string;
	edition: Edition;
	reason: string;
	attempts: number;
	at: string;
}

export async function markDead(kv: KVNamespace, d: DeadLetter): Promise<void> {
	await kv.put(`dead:${d.txn}`, JSON.stringify(d));
}

export async function clearDead(kv: KVNamespace, txn: string): Promise<void> {
	await kv.delete(`dead:${txn}`);
}

export async function deadLetter(kv: KVNamespace, txn: string): Promise<DeadLetter | null> {
	const text = await kv.get(`dead:${txn}`);
	if (!text) return null;
	try {
		const d = JSON.parse(text) as DeadLetter;
		return d && typeof d.txn === "string" ? d : null;
	} catch {
		return null;
	}
}

// Lists the dead-letter (one KV list page by default, up to `limit`). For a hand consult, not a loop over thousands.
export async function listDeadLetters(kv: KVNamespace, limit = 100): Promise<DeadLetter[]> {
	const out: DeadLetter[] = [];
	let cursor: string | undefined;
	do {
		const page = await kv.list({ prefix: "dead:", cursor, limit: Math.min(limit - out.length, 1000) });
		for (const k of page.keys) {
			const d = await deadLetter(kv, k.name.slice("dead:".length));
			if (d) out.push(d);
			if (out.length >= limit) return out;
		}
		cursor = page.list_complete ? undefined : page.cursor;
	} while (cursor);
	return out;
}

function parseList(text: string | null): string[] {
	try {
		const v: unknown = text ? JSON.parse(text) : [];
		return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
	} catch {
		return [];
	}
}

// Best effort (KV is not atomic): true when one more mail may be sent to this address this hour.
export async function takeResendSlot(kv: KVNamespace, email: string, maxPerHour: number): Promise<boolean> {
	const key = "rl:" + (await sha256Hex(email.trim().toLowerCase()));
	const used = Number.parseInt((await kv.get(key)) ?? "0", 10) || 0;
	if (used >= maxPerHour) return false;
	await kv.put(key, String(used + 1), { expirationTtl: 3600 });
	return true;
}
