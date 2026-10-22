// The licence by e-mail, through Resend (https://resend.com/docs/api-reference/emails/send-email).

import { b64Encode, utf8 } from "./encoding.ts";
import type { Deps, Env } from "./env.ts";
import { editionTitle, licenceFileName } from "./licence.ts";
import type { Stored } from "./store.ts";

export type MailResult = "sent" | "skipped" | "failed" | "retry";

const ADDRESS = /^[^\s<>@,;"]+@[^\s<>@,;"]+\.[^\s<>@,;"]+$/;

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

export async function sendLicenceMail(env: Env, deps: Deps, s: Stored, idempotencyKey: string): Promise<MailResult> {
	if (!env.RESEND_API_KEY || !env.MAIL_FROM) return "skipped";
	if (!ADDRESS.test(s.email)) return "failed";
	const body: Record<string, unknown> = {
		from: env.MAIL_FROM,
		to: [s.email],
		subject: `Your Wren licence (order ${s.order})`,
		text: mailText(s),
		attachments: [{ filename: licenceFileName(s.order), content: b64Encode(utf8(s.file)) }],
	};
	if (env.MAIL_REPLY_TO) body.reply_to = env.MAIL_REPLY_TO;
	let res: Response;
	try {
		res = await deps.fetch("https://api.resend.com/emails", {
			method: "POST",
			headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "Content-Type": "application/json", "Idempotency-Key": idempotencyKey },
			body: JSON.stringify(body),
			signal: AbortSignal.timeout(3000),
		});
	} catch {
		return "retry";
	}
	if (res.ok) return "sent";
	if (res.status === 429 || res.status === 409 || res.status >= 500) return "retry";
	// a 4xx will not change by trying again (bad key, unverified sender domain, refused address)
	console.log(JSON.stringify({ evt: "mail_refused", status: res.status, txn: s.txn }));
	return "failed";
}
