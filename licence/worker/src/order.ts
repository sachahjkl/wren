// LicenseOrder: one Durable Object per Paddle transaction (`env.ORDERS.idFromName(txn)`). It is the single authority
// for a purchase. Cloudflare runs at most one instance of a given object at a time and serialises calls to it through
// its input gate, so two webhooks delivered at the very same instant are handled one after the other: the first issues
// the licence and sends the mail, the second finds the work done and sends nothing. That is the atomic idempotence KV
// could not give (KV reads and writes are not a transaction).
//
// State machine (what `state` holds):
//
//     received ──issue()──► issued ──mail sent──► mailed
//          │                   │                    
//          │                   └─mail refused/cap──► failed   (dead-letter when every try was worth retrying)
//          └─ no customer e-mail, no Wren price ──► failed / ignored (never becomes a licence)
//
// The mail queue is the object's own alarm: a send that is worth retrying schedules the next attempt on a backoff
// ladder (1, 5, 30, 120, 720, 2880 minutes by default) until the cap, then dead-letters. The mail is sent at least once
// (the alarm keeps trying) and never twice (only the "issued" state, held under the input gate, lets a send start, and
// it flips to "sending" first). A second alarm, far later, purges the buyer's name and address once the licence is
// settled (RGPD): the licence itself is kept (it is a function of the public transaction id), the person is not.
//
// Storage is the object's SQLite-backed key/value store (durable, transactional with the input gate). KV is still
// written, as the globally-replicated copy the thank-you page reads; the object heals that copy whenever it wakes.

import { backoffLadder, intSetting } from "./env.ts";
import type { Env } from "./env.ts";
import { buildStored, log } from "./issue.ts";
import { deliverMail, mailConfigured } from "./mail.ts";
import { Transient } from "./paddle.ts";
import type { Deps, Transaction } from "./paddle.ts";
import { clearDead, getTxn, index, markDead, putTxn, unindexEmail } from "./store.ts";
import type { Stored } from "./store.ts";

export type OrderStatus = "received" | "issued" | "mailed" | "failed";

// A line of the object's journal: what happened and when, with no personal data (an order number and a code at most).
export interface JournalEntry {
	at: string;
	evt: string;
	detail?: string;
}

export interface OrderState {
	status: OrderStatus;
	stored?: Stored;         // the licence and its mail state, once issued
	attempts: number;        // mail send() calls made
	next_attempt?: string;   // when the alarm will try the mail again (ISO), if a retry is scheduled
	journal: JournalEntry[];
}

// What the object is asked to do (the Worker posts one of these to it over fetch, on an internal URL). `id` is the
// transaction id the stub was named with: the object keeps it so it can rehydrate its KV copy if its own storage was
// ever reset, and so a resend knows which record to re-send.
type Command =
	| { op: "webhook"; id: string; txn: Transaction }
	| { op: "resend"; id: string }
	| { op: "status"; id: string };

const MAX_JOURNAL = 40;   // the last N lines; a purchase needs a handful, this leaves room for many retries

// The runtime shapes the Worker uses without pulling in @cloudflare/workers-types (the unit tests run in plain Node).
interface SqlStorage {
	get<T = unknown>(key: string): Promise<T | undefined>;
	put<T = unknown>(key: string, value: T): Promise<void>;
	setAlarm(scheduledTime: number): Promise<void>;
	getAlarm(): Promise<number | null>;
	deleteAlarm(): Promise<void>;
}

export interface DurableObjectStorage extends SqlStorage {}

export interface DurableObjectStateLike {
	storage: DurableObjectStorage;
	// Runs `fn` with the input gate held and no other alarm or request interleaving: the whole read-modify-write of the
	// state is one critical section even across awaits.
	blockConcurrencyWhile<T>(fn: () => Promise<T>): Promise<T>;
}

export class LicenseOrder {
	private readonly state: DurableObjectStateLike;
	private readonly env: Env;
	private readonly deps: Deps;
	private txnId = "";   // set from the command; the id the stub was named with (a transaction id)

	constructor(state: DurableObjectStateLike, env: Env, deps?: Deps) {
		this.state = state;
		this.env = env;
		this.deps = deps ?? { fetch: (input, init) => fetch(input, init), now: () => Date.now() };
	}

	// The only way in from the Worker. The body is a Command; the answer is the current OrderState (and an HTTP status
	// that tells the Worker what to tell Paddle: 200 done, 500 worth a retry, 422 never going to work).
	async fetch(request: Request): Promise<Response> {
		const path = new URL(request.url).pathname;
		if (path.endsWith("/bounce")) {
			let b: { id?: string; reason?: string };
			try {
				b = (await request.json()) as typeof b;
			} catch {
				return json(400, { error: "bad command" });
			}
			if (b.id) this.txnId = b.id;
			return json(200, await this.bounced(b.reason ?? "bounce"));
		}
		let cmd: Command;
		try {
			cmd = (await request.json()) as Command;
		} catch {
			return json(400, { error: "bad command" });
		}
		if (typeof cmd.id === "string" && cmd.id) this.txnId = cmd.id;
		try {
			if (cmd.op === "status") return json(200, await this.load());
			if (cmd.op === "resend") return json(200, await this.resend());
			if (cmd.op === "webhook") return await this.webhook(cmd.txn);
			return json(400, { error: "unknown op" });
		} catch (e) {
			// a Transient means "try again later": the Worker turns it into a 500 so Paddle redelivers the webhook.
			if (e instanceof Transient) return json(500, { error: "retry later" });
			throw e;
		}
	}

	private async load(): Promise<OrderState> {
		const saved = await this.state.storage.get<OrderState>("state");
		if (saved) return saved;
		// Empty storage but KV holds the licence (the object was reset, or this is a fresh isolate after a KV-only
		// write of an old build): rehydrate from the copy so a /resend still has what to send. The DO is authoritative
		// from here on.
		const fromKv = this.txnId ? await getTxn(this.env.LICENSES, this.txnId) : null;
		if (fromKv) return { status: fromKv.mail === "sent" ? "mailed" : "issued", stored: fromKv, attempts: fromKv.mail_attempts ?? 0, journal: [] };
		return { status: "received", attempts: 0, journal: [] };
	}

	private async save(s: OrderState): Promise<void> {
		await this.state.storage.put("state", s);
	}

	private note(s: OrderState, evt: string, detail?: string): void {
		s.journal.push({ at: new Date(this.deps.now()).toISOString(), evt, ...(detail ? { detail } : {}) });
		if (s.journal.length > MAX_JOURNAL) s.journal.splice(0, s.journal.length - MAX_JOURNAL);
	}

	// A paid transaction. The whole thing runs under the input gate: a second delivery that arrives while this one is in
	// flight waits, then finds `issued`/`mailed` and does nothing new.
	private async webhook(txn: Transaction): Promise<Response> {
		return await this.state.blockConcurrencyWhile(async () => {
			const s = await this.load();
			// A licence is owed as long as none was issued yet. An earlier delivery that was "invalid" (no customer
			// e-mail then) left `failed` with no `stored`; a later delivery may carry what was missing, so we try the
			// build again rather than treat the id as settled.
			const fresh = !s.stored;

			if (fresh) {
				const built = await buildStored(this.env, this.deps, txn);
				if (built.kind === "ignored") { this.note(s, "ignored", built.reason); await this.save(s); log("webhook_ignored", { reason: built.reason }); return json(200, { status: "ignored", reason: built.reason }); }
				if (built.kind === "invalid") { s.status = "failed"; this.note(s, "invalid", built.reason); await this.save(s); log("webhook_invalid", { reason: built.reason }); return json(422, { status: "invalid", reason: built.reason }); }
				// built.kind === "built"
				s.status = "issued";
				s.stored = built.stored;
				this.note(s, "issued", built.stored.order);
				await index(this.env.LICENSES, built.stored);   // order: and email: indexes, written once per purchase
				await this.save(s);
				log("issued", { txn: built.stored.txn, order: built.stored.order, edition: built.stored.edition });
			}

			// issued (or already mailed): try the mail now, synchronously, so the common case needs no alarm at all.
			if (s.stored) await this.pump(s, "webhook");
			await this.save(s);
			return this.answer(s, fresh);
		});
	}

	// POST /resend asked for this order's mail again (the Worker already checked the rate limit and the address). It
	// forces one more attempt whatever the current mail state, through the same single-flight path.
	private async resend(): Promise<OrderState> {
		return await this.state.blockConcurrencyWhile(async () => {
			const s = await this.load();
			if (!s.stored) return s;   // nothing issued for this id (should not happen: the index pointed here)
			// resend forces one more attempt whatever the mail state, "sending" included: it is the way out of a lost
			// outcome (the mail may have gone, but the buyer got nothing). The input gate still serialises it with the
			// webhook, so it cannot race a real in-flight send of this same object.
			s.stored = { ...s.stored, mail: "pending" };
			s.attempts = 0;
			await clearDead(this.env.LICENSES, s.stored.txn);
			this.note(s, "resend");
			await this.pump(s, "resend");
			await this.save(s);
			return s;
		});
	}

	// The retry queue: the alarm fires when a send is due again. The input gate still protects it from a concurrent
	// webhook or resend.
	async alarm(): Promise<void> {
		await this.state.blockConcurrencyWhile(async () => {
			const s = await this.load();
			const settled = s.stored && (s.stored.mail === "sent" || s.stored.mail === "failed" || s.stored.mail === "dead");
			if (settled) { await this.maybePurge(s); await this.save(s); return; }
			if (s.stored) await this.pump(s, "alarm");
			await this.save(s);
		});
	}

	// Sends the mail if it is owed, and schedules the next attempt (or dead-letters) if it is deferred. Never sends when
	// the state is `sending`, `sent`, `failed` or `dead`; `skipped` is retried only once a sender is configured.
	private async pump(s: OrderState, cause: string): Promise<void> {
		const stored = s.stored!;
		if (stored.mail === "sent" || stored.mail === "failed" || stored.mail === "dead" || stored.mail === "sending") return;
		if (!mailConfigured(this.env)) {
			if (stored.mail !== "skipped") { s.stored = { ...stored, mail: "skipped", mail_at: this.at() }; await this.publish(s.stored); this.note(s, "mail", "skipped"); }
			return;
		}

		// "sending" is committed to the object's own storage (and to KV) BEFORE send() is called. If the object is cut
		// off during the send, a later wake reads "sending" and does not send again: the attempt may have gone out and
		// cannot be confirmed. The buyer, who then has nothing, asks again (/resend), which forces one more attempt.
		s.stored = { ...stored, mail: "sending", mail_at: this.at() };
		s.attempts += 1;
		await this.save(s);
		await this.publish(s.stored);

		const { result, detail } = await deliverMail(this.env, s.stored);

		if (result === "retry") {
			const cap = intSetting(this.env.MAIL_MAX_ATTEMPTS, 7, 1, 50);
			if (s.attempts >= cap) {
				s.stored = { ...s.stored, mail: "dead", mail_detail: detail, mail_at: this.at(), mail_attempts: s.attempts };
				await this.publish(s.stored);
				await markDead(this.env.LICENSES, { txn: s.stored.txn, order: s.stored.order, edition: s.stored.edition, reason: detail ?? "retry", attempts: s.attempts, at: this.at() });
				this.note(s, "mail_dead", detail);
				log("mail_dead", { txn: s.stored.txn, order: s.stored.order, attempts: s.attempts, code: detail });
				this.schedulePurge(s);
				return;
			}
			// back off: pending again, alarm set for the next rung of the ladder (the last rung repeats for the tail)
			s.stored = { ...s.stored, mail: "pending", mail_detail: detail, mail_at: this.at(), mail_attempts: s.attempts };
			await this.publish(s.stored);
			const ladder = backoffLadder(this.env.MAIL_BACKOFF_MINUTES);
			const minutes = ladder[Math.min(s.attempts - 1, ladder.length - 1)];
			const when = this.deps.now() + minutes * 60_000;
			s.next_attempt = new Date(when).toISOString();
			await this.state.storage.setAlarm(when);
			this.note(s, "mail_deferred", detail);
			log("mail_deferred", { txn: s.stored.txn, order: s.stored.order, attempt: s.attempts, in_min: minutes, code: detail });
			return;
		}

		// sent or failed (final either way): record it, drop any dead-letter, stop the alarm, start the purge clock.
		s.stored = { ...s.stored, mail: result, mail_at: this.at(), mail_attempts: s.attempts, ...(detail ? { mail_detail: detail } : {}) };
		s.next_attempt = undefined;
		await this.state.storage.deleteAlarm();
		await this.publish(s.stored);
		if (result === "sent") await clearDead(this.env.LICENSES, s.stored.txn);
		this.note(s, "mail", result, detail);
		log("mail", { txn: s.stored.txn, order: s.stored.order, state: result, cause, ...(detail ? { code: detail } : {}) });
		this.schedulePurge(s);
	}

	// The provider told us (by its delivery webhook) that a message bounced: mark the mail failed and dead-letter it so
	// it shows up for a look. Idempotent (a second report changes nothing once failed).
	async bounced(reason: string): Promise<OrderState> {
		return await this.state.blockConcurrencyWhile(async () => {
			const s = await this.load();
			if (!s.stored || s.stored.mail === "failed" || s.stored.mail === "dead") return s;
			s.stored = { ...s.stored, mail: "failed", mail_detail: reason || "bounce", mail_at: this.at() };
			await this.state.storage.deleteAlarm();
			s.next_attempt = undefined;
			await this.publish(s.stored);
			await markDead(this.env.LICENSES, { txn: s.stored.txn, order: s.stored.order, edition: s.stored.edition, reason: reason || "bounce", attempts: s.attempts, at: this.at() });
			this.note(s, "bounce", reason || "bounce");
			log("mail_bounce", { txn: s.stored.txn, order: s.stored.order, code: reason || "bounce" });
			this.schedulePurge(s);
			await this.save(s);
			return s;
		});
	}

	// Arms the purge alarm for N days out, unless N is 0 (keep forever) or a purge already ran.
	private schedulePurge(s: OrderState): void {
		const days = intSetting(this.env.PII_RETENTION_DAYS, 90, 0, 3650);
		if (days === 0 || s.stored?.purged_at) return;
		void this.state.storage.setAlarm(this.deps.now() + days * 86_400_000);
	}

	// RGPD: once the licence is settled and the retention window has passed, drop the name and address. The licence and
	// the mail text already hold them, so they are blanked too; what stays is the signed key (it is public anyway, being
	// derived from the transaction id) and the order number.
	private async maybePurge(s: OrderState): Promise<void> {
		const days = intSetting(this.env.PII_RETENTION_DAYS, 90, 0, 3650);
		if (days === 0 || !s.stored || s.stored.purged_at) return;
		const settledAt = Date.parse(s.stored.mail_at ?? s.stored.issued_at);
		if (!Number.isFinite(settledAt) || this.deps.now() < settledAt + days * 86_400_000) {
			void this.state.storage.setAlarm(settledAt + days * 86_400_000);   // not due yet: re-arm
			return;
		}
		if (s.stored.email) await unindexEmail(this.env.LICENSES, s.stored.email, s.stored.txn);
		s.stored = { ...s.stored, name: "(purged)", email: "", licence: "", file: "", purged_at: this.at() };
		await this.publish(s.stored);
		this.note(s, "purged");
		log("purged", { txn: s.stored.txn, order: s.stored.order });
	}

	// Mirrors the record into KV (what thanks.html reads). The order and e-mail indexes are written once, at issue; this
	// only rewrites the txn: record as the mail state changes, so a purchase still costs four writes (txn, order, email,
	// then the txn update when the mail settles).
	private async publish(stored: Stored): Promise<void> {
		await putTxn(this.env.LICENSES, stored);
	}

	private answer(s: OrderState, fresh: boolean): Response {
		if (s.status === "failed") return json(200, { status: "failed", order: s.stored?.order, mail: s.stored?.mail });
		// a mail still owed and deferred is fine: it is queued, the alarm owns it now (Paddle need not redeliver).
		// "issued" the first time, "replayed" on a later delivery of the same webhook.
		return json(200, { status: fresh ? "issued" : "replayed", order: s.stored?.order, mail: s.stored?.mail });
	}

	private at(): string {
		return new Date(this.deps.now()).toISOString();
	}
}

function json(status: number, body: unknown): Response {
	return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });
}
