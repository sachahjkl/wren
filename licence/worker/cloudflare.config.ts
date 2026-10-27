// The configuration `cf` reads (cf deploy, cf dev). `wrangler.jsonc` holds the same for `npx wrangler`: when you change
// a setting, change both. Secrets are not here (this file is committed): LICENSE_PRIVATE_KEY, PADDLE_WEBHOOK_SECRET,
// PADDLE_API_KEY go in secrets.env (git-ignored, see secrets.example.env):
//
//     cf deploy --secrets-file secrets.env                      production (live Paddle)
//     cf deploy --mode sandbox --secrets-file secrets.sandbox.env   a second Worker, with its own KV, for Paddle's sandbox
import { bindings, defineConfig } from "cf/config";

const settings = {
	// the sandbox and the live Paddle have other ids, other keys, another webhook secret
	production: {
		name: "wren-licence",
		PADDLE_API_BASE: "https://api.paddle.com",
		ALLOWED_ORIGIN: "https://sachahjkl.github.io",
	},
	sandbox: {
		name: "wren-licence-sandbox",
		PADDLE_API_BASE: "https://sandbox-api.paddle.com",
		ALLOWED_ORIGIN: "https://sachahjkl.github.io,http://localhost:8765",
	},
};

export default defineConfig(({ mode }) => {
	const s = mode === "sandbox" ? settings.sandbox : settings.production;
	return {
		worker: {
			name: s.name,
			compatibilityDate: "2026-10-01",
			entrypoint: "src/index.ts",
			workersDev: true,
			observability: { enabled: true },
			env: {
				// no id: the first deploy creates the namespace
				LICENSES: bindings.kv({}),
				// One LicenseOrder Durable Object per transaction: atomic idempotence, the mail retry queue (its alarm),
				// the RGPD purge. SQLite-backed, declared as a new_sqlite_classes migration (keep wrangler.jsonc alike).
				ORDERS: bindings.durableObject({ className: "LicenseOrder" }),
				// Cloudflare Email Service (the mail of the licence): sending to anyone needs the Workers Paid plan
				EMAIL: bindings.sendEmail({}),

				PADDLE_API_BASE: bindings.text(s.PADDLE_API_BASE),
				ALLOWED_ORIGIN: bindings.text(s.ALLOWED_ORIGIN),
				// to fill in (Paddle > Catalog > Prices: pri_...)
				PRICE_SUPPORTER: bindings.text(""),
				PRICE_PATRON: bindings.text(""),
				// the public key of src/license/public_key.odin (the line printed by tools\license.ps1 pubkey)
				LICENSE_PUBLIC_KEY: bindings.text(""),
				// "Wren <licences@your-domain>", an address of a domain onboarded in Email Service > Email Sending
				MAIL_FROM: bindings.text("Wren <licences@froment.software>"),
				MAIL_REPLY_TO: bindings.text("contact@froment.software"),
				WEBHOOK_TOLERANCE_SECONDS: bindings.text("300"),
				RESEND_ENABLED: bindings.text("false"),
				RESEND_MAX_PER_HOUR: bindings.text("3"),
				RESEND_REQUIRE_TOKEN: bindings.text("false"),
				// the mail retry queue: the backoff ladder (minutes), the number of tries before the dead-letter
				MAIL_BACKOFF_MINUTES: bindings.text("1,5,30,120,720,2880"),
				MAIL_MAX_ATTEMPTS: bindings.text("7"),
				// RGPD: days the buyer's name and address are kept after the mail is settled, then purged (0 = never)
				PII_RETENTION_DAYS: bindings.text("90"),

				LICENSE_PRIVATE_KEY: bindings.secret(),
				PADDLE_WEBHOOK_SECRET: bindings.secret(),
				PADDLE_API_KEY: bindings.secret(),
				// optional: a bearer token for /admin/* and (when RESEND_REQUIRE_TOKEN) /resend; a shared secret for the
				// mail provider's bounce webhook. Leave them out of the secrets file to keep those endpoints closed.
				ADMIN_TOKEN: bindings.secret(),
				MAIL_BOUNCE_SECRET: bindings.secret(),
			},
			migrations: [{ tag: "v1", newSqliteClasses: ["LicenseOrder"] }],
		},
	};
});
