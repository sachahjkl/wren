// Turning a paid transaction into a stored licence. This is the pure, side-effect-light part: it validates the
// transaction, reads the customer, signs the licence and builds the record. It does NOT decide idempotence or send the
// mail; the LicenseOrder Durable Object (src/order.ts) does, because only it can serialise two deliveries of the same
// webhook. `buildStored` is called once, under the object's input gate, when an order is first seen.

import type { Deps, Env } from "./env.ts";
import { cleanField, licenceFile, loadSigner } from "./licence.ts";
import { mailConfigured } from "./mail.ts";
import { dayOf, editionOf, fetchCustomer, orderNumber, TXN_ID } from "./paddle.ts";
import type { Transaction } from "./paddle.ts";
import type { Stored } from "./store.ts";

export type Built =
	| { kind: "built"; stored: Stored }
	| { kind: "ignored"; reason: string }
	| { kind: "invalid"; reason: string };   // will never work by retrying: needs a person (the notification can be replayed from Paddle)

export function log(evt: string, fields: Record<string, unknown> = {}): void {
	console.log(JSON.stringify({ evt, ...fields }));   // never a name, an e-mail address or a key
}

// Validates and signs. Throws Transient (via fetchCustomer) when the Paddle API is down, so the webhook answers 500 and
// Paddle redelivers; returns "invalid" when nothing could ever make it work (no customer e-mail).
export async function buildStored(env: Env, deps: Deps, txn: Transaction): Promise<Built> {
	const id = txn.id ?? "";
	if (!TXN_ID.test(id)) return { kind: "invalid", reason: "no valid transaction id" };
	if (txn.status !== "completed") return { kind: "ignored", reason: `status ${txn.status ?? "?"}` };

	const edition = editionOf(txn.items, env);
	if (!edition) return { kind: "ignored", reason: "no Wren price in this transaction" };

	let who = txn.customer?.email ? { name: txn.customer.name?.trim() || "", email: txn.customer.email.trim() } : null;
	if (!who) {
		if (!txn.customer_id) return { kind: "invalid", reason: "the transaction has no customer" };
		who = await fetchCustomer(env, deps, txn.customer_id);
		if (!who) return { kind: "invalid", reason: "the customer has no e-mail address" };
	}
	const email = cleanField(who.email);
	const fields = {
		edition,
		name: cleanField(who.name) || email,   // Paddle's name is optional: the e-mail address then
		email,
		date: dayOf(txn, deps.now()),
		order: orderNumber(id),
	};
	const signer = await loadSigner(env.LICENSE_PRIVATE_KEY, env.LICENSE_PUBLIC_KEY);
	const licence = await signer.sign(fields);

	const stored: Stored = {
		v: 1,
		txn: id,
		...fields,
		licence,
		file: licenceFile(licence, fields),
		issued_at: new Date(deps.now()).toISOString(),
		mail: mailConfigured(env) ? "pending" : "skipped",
		mail_attempts: 0,
	};
	return { kind: "built", stored };
}
