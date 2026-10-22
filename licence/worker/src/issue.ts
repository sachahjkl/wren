// A paid transaction becomes a licence: signed, kept, mailed. Safe to run any number of times for the same transaction
// (a webhook is delivered at least once): the licence is a function of the transaction, and a mail already sent is not
// sent again.

import type { Deps, Env } from "./env.ts";
import { cleanField, licenceFile, loadSigner } from "./licence.ts";
import { sendLicenceMail } from "./mail.ts";
import type { MailResult } from "./mail.ts";
import { dayOf, editionOf, fetchCustomer, orderNumber, TXN_ID, Transient } from "./paddle.ts";
import type { Transaction } from "./paddle.ts";
import { getTxn, index, putTxn } from "./store.ts";
import type { Stored } from "./store.ts";

export type Outcome =
	| { kind: "issued" | "replayed"; stored: Stored }
	| { kind: "ignored"; reason: string }
	| { kind: "invalid"; reason: string };   // will never work by retrying: needs a person (the notification can be replayed from Paddle)

export function log(evt: string, fields: Record<string, unknown> = {}): void {
	console.log(JSON.stringify({ evt, ...fields }));   // never a name, an e-mail address or a key
}

export async function issue(env: Env, deps: Deps, txn: Transaction): Promise<Outcome> {
	const id = txn.id ?? "";
	if (!TXN_ID.test(id)) return { kind: "invalid", reason: "no valid transaction id" };
	if (txn.status !== "completed") return { kind: "ignored", reason: `status ${txn.status ?? "?"}` };

	const existing = await getTxn(env.LICENSES, id);
	if (existing) return await deliver(env, deps, existing, "replayed");

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
		mail: "pending",
	};
	await putTxn(env.LICENSES, stored);
	await index(env.LICENSES, stored);
	log("issued", { txn: id, order: stored.order, edition });
	return await deliver(env, deps, stored, "issued");
}

// Mails the licence unless it was mailed. A mail that fails for a reason worth retrying makes the webhook answer 5xx
// (Paddle delivers it again, and only the mail is redone).
async function deliver(env: Env, deps: Deps, stored: Stored, kind: "issued" | "replayed"): Promise<Outcome> {
	if (stored.mail === "sent" || stored.mail === "failed") return { kind, stored };
	const result: MailResult = await sendLicenceMail(env, deps, stored, `wren-licence-${stored.txn}`);
	if (result === "retry") {
		log("mail_retry", { txn: stored.txn });
		throw new Transient("the mail could not be sent now");
	}
	const next: Stored = { ...stored, mail: result, mail_at: new Date(deps.now()).toISOString() };
	await putTxn(env.LICENSES, next);
	log("mail", { txn: stored.txn, state: result });
	return { kind, stored: next };
}
