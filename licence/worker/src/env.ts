// What the Worker is configured with (wrangler.jsonc "vars" and the secrets; licence/worker/README.md).

export interface KVNamespace {
	get(key: string): Promise<string | null>;
	put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
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

export interface Env {
	// bindings
	LICENSES: KVNamespace;
	EMAIL?: SendEmail;               // Cloudflare Email Service; absent (or MAIL_FROM empty) = not mailed (the thank-you page still shows the licence)

	// secrets
	LICENSE_PRIVATE_KEY: string;     // the 32-byte seed of the Ed25519 key, base64url (tools\license.ps1 keygen)
	PADDLE_WEBHOOK_SECRET: string;   // the notification destination's secret key (pdl_ntfset_...)
	PADDLE_API_KEY: string;          // server-side API key, to read the customer (name, e-mail)

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
	return missing;
}

export function intSetting(value: string | undefined, fallback: number, min: number, max: number): number {
	const n = Number.parseInt(value ?? "", 10);
	return Number.isFinite(n) && n >= min && n <= max ? n : fallback;
}
