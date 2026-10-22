// What is kept in KV (the free plan allows 1000 writes a day: a purchase writes four keys, nothing else writes).
//
//   txn:<paddle transaction id>   the licence and how it was delivered (the source of truth; idempotency)
//   order:<WREN-...>              -> the transaction id (to find a sale from the order number in a licence)
//   email:<sha256 of the address> -> JSON array of transaction ids (to mail the licences again to their buyer)
//   rl:<sha256 of the address>    -> number of mails sent again this hour

import type { Edition } from "./licence.ts";
import type { KVNamespace } from "./env.ts";
import { sha256Hex } from "./encoding.ts";

// pending: owed, nothing started (or the last attempt was refused for a passing reason). sending: an attempt was started
// and its outcome is not known: it is not repeated by itself (src/issue.ts). sent / failed / skipped: final, but skipped
// (no mail binding or sender configured) is tried again once they are.
export type MailState = "pending" | "sending" | "sent" | "failed" | "skipped";

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
