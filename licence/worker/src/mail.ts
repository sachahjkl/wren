// The licence by e-mail, through Cloudflare Email Service (the `send_email` binding, `env.EMAIL`):
// https://developers.cloudflare.com/email-service/api/send-emails/workers-api/
//
// The binding takes no idempotency key: a second send() is a second mail. The LicenseOrder Durable Object (src/order.ts)
// is what guarantees a single send per purchase (it flips the record to "sending" before calling this, under its input
// gate); here, only the errors that mean "nothing was sent" are reported as worth another attempt ("retry").

import { b64Encode, utf8 } from "./encoding.ts";
import type { EmailAddress, Env, OutgoingMail } from "./env.ts";
import { editionTitle, licenceFileName } from "./licence.ts";
import type { Stored } from "./store.ts";

export type MailResult = "sent" | "skipped" | "failed" | "retry";

const ADDRESS = /^[^\s<>@,;"]+@[^\s<>@,;"]+\.[^\s<>@,;"]+$/;

const SEND_TIMEOUT_MS = 10_000;

// Rejected before anything left Cloudflare, and likely to pass later: the webhook may be delivered again.
// Everything else is final (a bad or refused address, a sender that is not onboarded, a suspended account, a delivery
// that failed, or an outcome we cannot know such as a timeout): trying again could only send a second mail, or fail the same way.
const RETRY_CODES = new Set(["E_RATE_LIMIT_EXCEEDED", "E_DAILY_LIMIT_EXCEEDED", "E_INTERNAL_SERVER_ERROR"]);

export function mailText(s: Stored): string {
	const key = s.licence.match(/.{1,76}/g)!.join("\n");
	return `Hello ${s.name},

Thank you for supporting Wren! Your ${editionTitle(s.edition)} licence is below, and attached as a file.

Wren is a beta under development and every version is free; a licence only supports its development. It unlocks
nothing, and nothing in Wren will ever ask you for it. It makes the "About Wren" page say who the supporter is.

To register it:

  1. Open Wren and go to about:wren (menu, "About Wren").
  2. Paste the whole key below into the box and press "Register",
     or drop the attached ${licenceFileName(s.order)} file onto the Wren window.

Your key (the line breaks do not matter):

${key}

Order: ${s.order}
Date: ${s.date}
Licensed to: ${s.name} <${s.email}>

Keep this message: the key works for every version of Wren, on every computer you use. It is checked on your computer,
without any network access.

Wren is developed by Froment Software.
`;
}

export function mailConfigured(env: Env): boolean {
	return Boolean(env.EMAIL && env.MAIL_FROM);
}

// "Wren <licences@example.org>" becomes { email, name }; a bare address stays a string.
export function parseSender(from: string): string | EmailAddress {
	const m = from.trim().match(/^(.*?)\s*<([^<>]+)>$/);
	if (!m) return from.trim();
	const name = m[1].trim().replace(/^"(.*)"$/, "$1");
	return name ? { email: m[2].trim(), name } : m[2].trim();
}

export interface MailOutcome {
	result: MailResult;
	detail?: string;   // the error code (E_RATE_LIMIT_EXCEEDED, for one), kept in the stored record: never an address
}

// The code of a failed send(): the binding throws an Error with a `code`. Anything else is named by its class only,
// because a message could carry the address.
function errorCode(e: unknown): string {
	const code = (e as { code?: unknown } | null)?.code;
	if (typeof code === "string" && /^[A-Za-z0-9_]{1,48}$/.test(code)) return code;
	return e instanceof Error && /^[A-Za-z0-9_]{1,48}$/.test(e.name) ? e.name : "UNKNOWN";
}

async function withTimeout<T>(p: Promise<T>): Promise<T> {
	let timer: ReturnType<typeof setTimeout> | undefined;
	try {
		return await Promise.race([p, new Promise<never>((_, reject) => { timer = setTimeout(() => reject(Object.assign(new Error("timeout"), { code: "E_TIMEOUT" })), SEND_TIMEOUT_MS); })]);
	} finally {
		clearTimeout(timer);
	}
}

// Sends the licence once. Never throws. The log line carries the error code and the order number: never the address, the
// name or the key.
export async function deliverMail(env: Env, s: Stored): Promise<MailOutcome> {
	if (!env.EMAIL || !env.MAIL_FROM) return { result: "skipped" };
	if (!ADDRESS.test(s.email)) {
		console.log(JSON.stringify({ evt: "mail_refused", code: "invalid_address", order: s.order }));
		return { result: "failed", detail: "invalid_address" };
	}
	const message: OutgoingMail = {
		to: s.email,
		from: parseSender(env.MAIL_FROM),
		subject: `Your Wren licence (order ${s.order})`,
		text: mailText(s),
		attachments: [{ content: b64Encode(utf8(s.file)), filename: licenceFileName(s.order), type: "application/octet-stream", disposition: "attachment" }],
	};
	if (env.MAIL_REPLY_TO) message.replyTo = env.MAIL_REPLY_TO;
	try {
		await withTimeout(env.EMAIL.send(message));
		return { result: "sent" };
	} catch (e) {
		const code = errorCode(e);
		const result: MailResult = RETRY_CODES.has(code) ? "retry" : "failed";
		console.log(JSON.stringify({ evt: result === "retry" ? "mail_attempt_deferred" : "mail_refused", code, order: s.order }));
		return { result, detail: code };
	}
}
