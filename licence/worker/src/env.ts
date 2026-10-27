// What the Worker is configured with (wrangler.jsonc "vars" and the secrets; licence/worker/README.md).

export interface KVListResult {
	keys: { name: string }[];
	list_complete: boolean;
	cursor?: string;
}

export interface KVNamespace {
	get(key: string): Promise<string | null>;
	put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
	delete(key: string): Promise<void>;
	list(options?: { prefix?: string; cursor?: string; limit?: number }): Promise<KVListResult>;
}

// The part of Cloudflare Email Service's `send_email` binding that is used (Email Sending Workers API:
// https://developers.cloudflare.com/email-service/api/send-emails/workers-api/). A failure is an Error with a `code`.
export interface EmailAddress {
	email: string;
	name?: string;
}

export interface OutgoingMail {
	to: string;
	from: string | EmailAddress;
	subject: string;
	text: string;
	replyTo?: string;
	attachments?: { content: string; filename: string; type: string; disposition: "attachment" }[];   // content: base64
}

export interface SendEmail {
	send(message: OutgoingMail): Promise<{ messageId: string }>;
}

// The slice of the Durable Object namespace the Worker uses (workers-types has the full type, but the Worker keeps its
// own minimal interface so the unit tests can run in Node without the Cloudflare runtime). One object per transaction:
// `idFromName(txn)` names it, and its input gate serialises everything done for that purchase.
export interface DurableObjectId {
	toString(): string;
}

export interface DurableObjectStub {
	fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response>;
}

export interface DurableObjectNamespace {
	idFromName(name: string): DurableObjectId;
	get(id: DurableObjectId): DurableObjectStub;
}

export interface Env {
	// bindings
	LICENSES: KVNamespace;
	ORDERS: DurableObjectNamespace;  // one LicenseOrder per transaction; the webhook and /resend go through it
	EMAIL?: SendEmail;               // Cloudflare Email Service; absent (or MAIL_FROM empty) = not mailed (the thank-you page still shows the licence)

	// secrets
	LICENSE_PRIVATE_KEY: string;     // the 32-byte seed of the Ed25519 key, base64url (tools\license.ps1 keygen)
	PADDLE_WEBHOOK_SECRET: string;   // the notification destination's secret key (pdl_ntfset_...)
	PADDLE_API_KEY: string;          // server-side API key, to read the customer (name, e-mail)
	ADMIN_TOKEN?: string;            // bearer token for the admin endpoints (/resend when RESEND_REQUIRE_TOKEN, /admin/*); unset = those are closed
	MAIL_BOUNCE_SECRET?: string;     // shared secret of the mail provider's delivery webhook (bounces); unset = that endpoint is closed

	// plain settings
	LICENSE_PUBLIC_KEY: string;      // the matching public key (src/license/public_key.odin); a licence is checked against it before it leaves
	PADDLE_API_BASE: string;         // https://sandbox-api.paddle.com or https://api.paddle.com
	PRICE_SUPPORTER: string;         // Paddle price id(s) (pri_...) of the supporter edition, comma separated
	PRICE_PATRON: string;            // the same for the patron edition
	MAIL_FROM: string;               // "Wren <licences@example.org>", an address of a domain onboarded in Email Service > Email Sending
	MAIL_REPLY_TO?: string;
	ALLOWED_ORIGIN?: string;         // sites that may call GET /licence from a browser (comma separated); "*" = any
	WEBHOOK_TOLERANCE_SECONDS?: string;
	RESEND_ENABLED?: string;         // "true" turns POST /resend (mail the licence again) on
	RESEND_MAX_PER_HOUR?: string;
	RESEND_REQUIRE_TOKEN?: string;   // "true" = /resend also needs the Authorization: Bearer ADMIN_TOKEN header
	MAIL_BACKOFF_MINUTES?: string;   // the backoff ladder between send attempts, comma separated (default "1,5,30,120,720,2880")
	MAIL_MAX_ATTEMPTS?: string;      // tries before a mail goes to the dead-letter (default 7, i.e. the ladder plus the first try)
	PII_RETENTION_DAYS?: string;     // days a buyer's name and address are kept after the licence is settled, then purged (default 90; 0 = never)
}

export interface Deps {
	fetch: typeof fetch;
	now: () => number;   // milliseconds
}

export interface Waiter {
	waitUntil(p: Promise<unknown>): void;
}

// The names the Worker cannot work without, for GET /health.
export const REQUIRED = ["LICENSE_PRIVATE_KEY", "LICENSE_PUBLIC_KEY", "PADDLE_WEBHOOK_SECRET", "PADDLE_API_KEY", "PADDLE_API_BASE"] as const;

export function missingSettings(env: Env): string[] {
	const missing: string[] = REQUIRED.filter((k) => !env[k]);
	if (!env.PRICE_SUPPORTER && !env.PRICE_PATRON) missing.push("PRICE_SUPPORTER");
	if (!env.LICENSES) missing.push("LICENSES");
	if (!env.ORDERS) missing.push("ORDERS");
	return missing;
}

export function intSetting(value: string | undefined, fallback: number, min: number, max: number): number {
	const n = Number.parseInt(value ?? "", 10);
	return Number.isFinite(n) && n >= min && n <= max ? n : fallback;
}

// The backoff ladder (minutes between attempts), parsed from a comma list, clamped and bounded in length so a bad
// setting cannot make a mail retry forever or at a silly cadence.
export function backoffLadder(value: string | undefined): number[] {
	const parts = (value ?? "").split(/[\s,]+/).filter(Boolean).map((s) => Number.parseInt(s, 10));
	const ok = parts.filter((n) => Number.isFinite(n) && n >= 1 && n <= 10080).slice(0, 12);
	return ok.length ? ok : [1, 5, 30, 120, 720, 2880];
}
