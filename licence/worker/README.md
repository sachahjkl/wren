# Wren licence Worker

A Cloudflare Worker (TypeScript, no runtime dependency) that turns a paid Paddle transaction into a Wren supporter
licence: it verifies the `Paddle-Signature` of the webhook, reads the customer from the Paddle API, signs the licence
(Ed25519, the format of `src/license/license.odin`), keeps it in KV, mails it with Cloudflare Email Service (the `send_email` binding) and serves it to the thank-you
page.

Each purchase is handled by **one `LicenseOrder` Durable Object** (`env.ORDERS.idFromName(txn)`), whose input gate
serialises everything done for that transaction: a webhook delivered twice at the same instant issues one licence and
sends one mail. The object owns the **mail retry queue** (its alarm, exponential backoff, an attempt cap, then a
dead-letter), reports **bounces** (`POST /mail/bounce`) and **purges the buyer's name and address** after
`PII_RETENTION_DAYS`. KV stays as the globally-replicated copy the thank-you page reads.

The whole procedure (keys, deploy with `cf`, Paddle sandbox then production, secrets, tests) is in
[docs/licence.md](../../docs/licence.md#selling-with-paddle). In short:

```powershell
pnpm install
cf deploy --mode sandbox --secrets-file secrets.sandbox.env    # secrets: see secrets.example.env; needs Workers Paid (Durable Objects)
node --test "test/*.test.ts"                                   # no network
```

- `src/` the Worker: `handler.ts` (routes), `order.ts` (the `LicenseOrder` Durable Object: idempotence, the retry
  queue, the purge), `issue.ts` (transaction to signed record), `paddle.ts`, `licence.ts`, `mail.ts`, `store.ts` (KV).
- The Durable Object is declared in both config files: `durable_objects.bindings` + `migrations.new_sqlite_classes`
  in `wrangler.jsonc`, `bindings.durableObject` + `migrations.newSqliteClasses` in `cloudflare.config.ts`. The first
  deploy runs the `v1` migration (SQLite-backed class); it needs the **Workers Paid** plan.
- `cloudflare.config.ts` is what `cf` reads; `wrangler.jsonc` is the same for `npx wrangler`. Keep them alike.
- Why `licence` and not `license`: on Windows a folder `license` cannot sit next to the `LICENSE` file.
- Admin endpoints (set `ADMIN_TOKEN`): `GET /admin/dead-letter` lists the mails that gave up (order, code, count,
  time: no personal data); `POST /admin/dead-letter/retry {"txn":"txn_…"}` re-queues one once the provider is healthy.
