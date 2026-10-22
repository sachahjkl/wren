# Wren licence Worker

A Cloudflare Worker (TypeScript, no runtime dependency) that turns a paid Paddle transaction into a Wren supporter
licence: it verifies the `Paddle-Signature` of the webhook, reads the customer from the Paddle API, signs the licence
(Ed25519, the format of `src/license/license.odin`), keeps it in KV, mails it with Cloudflare Email Service (the `send_email` binding) and serves it to the thank-you
page.

The whole procedure (keys, deploy with `cf`, Paddle sandbox then production, secrets, tests) is in
[docs/licence.md](../../docs/licence.md#selling-with-paddle). In short:

```powershell
pnpm install
cf deploy --mode sandbox --secrets-file secrets.sandbox.env    # secrets: see secrets.example.env
node --test "test/*.test.ts"                                   # no network
```

- `src/` the Worker: `handler.ts` (routes), `issue.ts` (transaction to licence), `paddle.ts`, `licence.ts`, `mail.ts`, `store.ts`.
- `cloudflare.config.ts` is what `cf` reads; `wrangler.jsonc` is the same for `npx wrangler`. Keep them alike.
- Why `licence` and not `license`: on Windows a folder `license` cannot sit next to the `LICENSE` file.
