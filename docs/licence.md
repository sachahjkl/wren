# Wren licences

Wren is a beta under development and every version is free. A **supporter licence** only supports its development: it
unlocks nothing, nothing in Wren checks it, and no window or reminder asks for one. The only visible effect is one
line of `about:wren`:

- without a licence: `Unregistered — free during the beta · Support Wren`;
- with one: `Registered to <name>`, with the edition, the date, the order number and a thank-you.

The code stays under the MIT licence ([LICENSE](../LICENSE)). The licence is separate from the code.

## How it works

A licence is a statement signed offline with an **Ed25519** private key that only the maintainer has. Wren holds the
matching public key and checks the signature on the user's computer, **without any network access**
(`core:crypto/ed25519`, package `src/license`). No server is involved in checking. Issuing is either manual (the
maintainer signs a licence with `tools\license.ps1` and sends it) or automatic: licences are sold through
[Paddle](https://www.paddle.com) (the seller of record, who handles VAT), and a small Cloudflare Worker
([`licence/worker`](../licence/worker/), free plan) signs the licence when Paddle reports a paid transaction, keeps it,
mails it, and shows it on the thank-you page. Both produce byte-identical licences; see
[Selling with Paddle](#selling-with-paddle).

(The folder is `licence`, not `license`: on Windows `license` would collide with the `LICENSE` file at the root.)

### Format

The text of a licence (what is pasted in `about:wren`, or kept in a `.wrenlicense` file):

```
WREN1.<payload>.<signature>
```

- `payload`: base64url (no padding) of a JSON object
  `{"product":"wren","edition":"supporter","name":"…","email":"…","date":"2026-10-22","order":"WREN-0001"}`.
  `edition` is `supporter` or `patron` (the same licence, a stronger support); unknown fields and unknown editions are
  read and ignored, so an older Wren keeps working with a newer licence. Each field is at most 256 bytes.
- `signature`: base64url (no padding) of the Ed25519 signature over `"wren-license-v1\n"` followed by the payload's
  bytes exactly as they appear in the text (nothing to canonicalize; the prefix keeps a signature made for another use
  from passing as a licence).

White space is ignored and lines starting with `#` are comments, so a key may be wrapped in an e-mail, and a
`.wrenlicense` file starts with a header of comments:

```
# Wren licence (Supporter) for Jeanne Dupont
# Order WREN-0001, 2026-10-22. Open this file with Wren, or paste the key in about:wren.
WREN1.eyJwcm9kdWN0Ijoid3JlbiIs…
…
```

### In Wren

- **Enter** a key: `about:wren` (menu → *About Wren*, or the command palette) has a text box (*Register*), a *Choose a
  file…* button, and accepts a `.wrenlicense` file dropped on the window, typed in the address bar, or given on the
  command line (`wren.exe jeanne.wrenlicense`). A key that does not check out is refused with the reason and nothing is
  kept.
- **Stored** in `license.wrenlicense` in the profile folder (`browser.license.path` points elsewhere; with
  `browser.profile.persist` off it lives in memory for the session). It is read and checked only when `about:wren` is
  opened.
- **Remove** it with *Remove the licence from this computer* on the same page.
- Preferences (`about:config`): `browser.license.path`, `browser.license.public_key` (replaces the built-in key, to
  read licences of another issuer), `browser.license.support_url` (the *Support Wren* link, a web page).

## The maintainer's procedure

### 1. Make the key pair (once)

```powershell
tools\license.ps1 keygen
```

This writes the **private** key to `%USERPROFILE%\.wren-license\private.key` (outside the repository: `keygen` refuses a
path inside a git work tree, and `.gitignore` keeps `.wren-license/`, `private.key` and `*.wrenlicense` out of git) and
prints the public key and the line to paste in `src/license/public_key.odin`:

```odin
PRODUCTION_PUBLIC_KEY :: "…"
```

Rebuild Wren. **Back up the private key outside this computer** (a password manager): if it is lost, no new licence can
be issued for the builds that carry the public key, and if it leaks, anyone can issue licences. `keygen` will not
overwrite an existing key without `-force`; a new key invalidates every licence issued with the old one.

Until the public key is set, builds read no licence: `about:wren` stays on *Unregistered*, and pasting a key says that
this build has no key to check it with.

### 2. Issue a licence

```powershell
tools\license.ps1 issue -name "Jeanne Dupont" -email jeanne@example.org -edition supporter -order WREN-0001
```

`-edition` is `supporter` or `patron`; `-date` defaults to today; `-private FILE` uses another key. The tool verifies
what it signed, prints the key, and writes `%USERPROFILE%\.wren-license\issued\WREN-0001.wrenlicense` (`-out FILE` to
choose). Send the file (or the key) to the buyer.

Other commands: `tools\license.ps1 pubkey` (print the public key), `tools\license.ps1 verify FILE` (check a licence
against the built-in key; `-public KEY` against another).

### 3. Development key

`-dev` uses a development pair that is public on purpose (`src/license/dev_keys.odin`: the tests and screenshots use
it). A licence made with it is refused by a build that carries the production key. To try one in a build: 
`tools\license.ps1 issue -dev …` and `--pref browser.license.public_key=<tools\license.ps1 pubkey -dev>`.

### 4. Without the Worker

`tools\license.ps1 issue` still works for a gift, a refund replacement or a licence given by hand, with the same key.
Use an order number that does not look like a Worker one (`GIFT-0001`).

## Selling with Paddle

Nothing is for sale until the steps below are done: [the support page](../site/support.html) shows *Coming soon* while
its settings are empty. Cost: nothing but Paddle's fee per sale (the free plans of Cloudflare Workers + KV and of Resend
are plenty).

```
buyer ── Paddle checkout (overlay on support.html) ── pays
                │                                       │
                │ checkout.completed (browser)          │ transaction.completed (signed webhook)
                ▼                                       ▼
        thanks.html?txn=txn_…                    Worker POST /paddle/webhook
                │                                  verifies Paddle-Signature, reads the customer (Paddle API),
                │ GET /licence?txn=txn_…           signs the licence, stores it in KV, mails it (Resend)
                └──────────────► Worker ◄───────────────────────────┘
                     shows the key, the .wrenlicense download
```

### What the Worker does

| Endpoint | |
|---|---|
| `POST /paddle/webhook` | Checks `Paddle-Signature` (`ts=…;h1=…`: HMAC-SHA256 of `ts:` + the raw body with the destination's secret, compared in constant time, `ts` within `WEBHOOK_TOLERANCE_SECONDS`, 300 by default; several `h1` are accepted during a secret rotation). Only `transaction.completed` acts. Edition from the price ids, name and e-mail from the Paddle API (`GET /customers/{id}`), licence signed, stored under `txn:<id>`, mailed. Answers 200 when done, **401** for a bad signature, **422** for a transaction that can never work (no customer e-mail: nothing to retry), **500** when something may work later (Paddle API or Resend down: Paddle then delivers the webhook again, and only the missing step is redone). A transaction with no Wren price is acknowledged and ignored. |
| `GET /licence?txn=txn_…` | For `thanks.html`. 200 with the licence, 202 (`Retry-After: 3`) while the webhook has not been processed. |
| `GET /licence/txn_….wrenlicense` | The file, as a download. |
| `POST /resend` `{"email": "…"}` | Mails the licences bought with that address again. **Off** unless `RESEND_ENABLED` is `true`. Same answer whether or not the address bought something; at most `RESEND_MAX_PER_HOUR` (3) mails per address and hour. |
| `GET /health` | `{"ok": true}`, or 503 with the names of the settings not set yet. |

Properties worth knowing:

- **Idempotent.** The licence is a function of the transaction (Ed25519 signatures are deterministic, the date is the
  transaction's own, the order number is derived from its id: `txn_01hv8wptq8987qeep44cyrewp9` gives
  `WREN-EEP4-4CYR-EWP9`). A webhook delivered twice, or at the same time as another, gives the same licence and sends one
  mail (Resend `Idempotency-Key`). `order:<number>` in KV finds the transaction of an order number.
- **The id is the only secret of `GET /licence`.** It is a ULID (80 random bits): not guessable, known to the buyer and to
  Paddle. What it yields is a licence that unlocks nothing. Responses carry `Cache-Control: no-store`, and CORS is limited
  to `ALLOWED_ORIGIN`.
- **The key never leaves unchecked.** The Worker verifies each signature against `LICENSE_PUBLIC_KEY` before using it, and
  refuses to start signing when the private key and the public key are not a pair.
- **Names are made safe to sign**: control and bidi characters become spaces, 256 bytes at most (what Wren accepts). A
  customer without a name gets their e-mail address as name.
- **Logs** hold event names, transaction ids, order numbers and statuses: never a name, an address, a key or a secret.
- **KV writes**: four per purchase (free plan: 1000 a day). Nothing else writes, except `/resend` for an address that
  really bought (so a flood of made-up addresses uses none).
- KV keeps the buyer's name and e-mail address next to the licence (that is how it is shown and mailed again). Paddle holds
  them anyway; delete a key on request: `npx wrangler kv key delete --binding LICENSES --remote "txn:txn_…"` (and
  `order:…`; the `email:` index only holds a hash).

### 1. Accounts

- **Cloudflare** (free): `cf auth login` (the CLI is `cf`, a pnpm package: `pnpm add -g cf`).
- **Resend** (free: 100 mails a day, 3000 a month): add and verify the domain you send from (DNS records), create an API key
  with *Sending access*. `MAIL_FROM` is an address of that domain, for example `Wren <licences@froment.software>`.
- **Paddle**: a **sandbox** account first (<https://sandbox-vendors.paddle.com>: separate from the live one, no
  verification, no money), the live account later.

### 2. Keys

```powershell
tools\license.ps1 keygen     # once; see "Make the key pair". Public key -> src/license/public_key.odin, rebuild Wren
tools\license.ps1 pubkey     # prints it again (LICENSE_PUBLIC_KEY)
```

`LICENSE_PRIVATE_KEY` is the line of `%USERPROFILE%\.wren-license\private.key` that is not a `#` comment.

### 3. Deploy the Worker (sandbox first)

The Worker needs Paddle's webhook secret, which Paddle only gives once the Worker has an address. So: deploy, create the
destination in Paddle, then put the secrets in.

```powershell
cd licence\worker
pnpm install                                   # cf and wrangler, dev dependencies used to build and deploy
cf auth login
copy secrets.example.env secrets.sandbox.env   # fill LICENSE_PRIVATE_KEY now; the others after step 4
```

Edit the `settings` and `env` in **`cloudflare.config.ts`** (it is what `cf` reads; `wrangler.jsonc` is the same thing for
`npx wrangler`, keep the two alike): `LICENSE_PUBLIC_KEY`, `MAIL_FROM`, `MAIL_REPLY_TO` if you want one. Then:

```powershell
cf deploy --mode sandbox --secrets-file secrets.sandbox.env
```

`--mode sandbox` is a second Worker, `wren-licence-sandbox`, with its own KV namespace (created by the first deploy), so
the sandbox and the live shop never mix. The command prints the address,
`https://wren-licence-sandbox.<your-subdomain>.workers.dev`. Check it: `https://…/health` lists what is still missing.

`cf deploy --dry-run --mode sandbox` builds and shows the bindings without uploading. To change one secret later:
`cf workers secrets update PADDLE_API_KEY --worker wren-licence-sandbox --text …`, or edit the file and deploy again. To
create the namespace yourself: `cf kv namespaces create --title wren-licences-sandbox`, then
`LICENSES: bindings.kv({ id: "…" })`.

Same with Wrangler (what `cf` runs underneath; use it if `cf` lacks a command):

```powershell
npx wrangler deploy --env sandbox                       # production: npx wrangler deploy
npx wrangler secret bulk secrets.sandbox.json --env sandbox    # {"LICENSE_PRIVATE_KEY": "...", ...}
npx wrangler tail --env sandbox                         # live logs
```

### 4. Paddle sandbox

1. **Catalog → Products → New product**: "Wren licence" (category: standard digital goods). Add two **one-time** prices
   (no billing period): *Supporter* 29 EUR and *Patron* 79 EUR, tax mode "inclusive" so that the buyer pays the displayed
   price, quantity 1 to 1. Copy both **price ids** (`pri_…`).
2. **Developer tools → Notifications → New destination**: type *Webhook*, URL
   `https://wren-licence-sandbox.<subdomain>.workers.dev/paddle/webhook`, **only** the event `transaction.completed`, active.
   Open the destination and copy its **Secret key** (`pdl_ntfset_…`).
3. **Developer tools → Authentication → API keys → New**: server side, with the permission *customer: read* only. This is
   `PADDLE_API_KEY`. Under **Client-side tokens → New**, create the token for Paddle.js (`test_…` in the sandbox).
4. Put the secret, the API key and the prices where they belong:
   - `secrets.sandbox.env`: `PADDLE_WEBHOOK_SECRET`, `PADDLE_API_KEY`, `RESEND_API_KEY`;
   - `cloudflare.config.ts` (and `wrangler.jsonc`): `PRICE_SUPPORTER`, `PRICE_PATRON` (several ids may be separated by
     commas);
   - then `cf deploy --mode sandbox --secrets-file secrets.sandbox.env` again, and check `/health`.
5. **Checkout → Checkout settings**: *Default payment link* = `https://sachahjkl.github.io/wren/support.html`.
6. **The site** (`site/support.html`, the `<div id="buy">`): `data-environment="sandbox"`, `data-client-token`,
   `data-price-supporter`, `data-price-patron`, `data-worker` (the Worker's address, no trailing slash), and in
   `site/thanks.html` `<main data-worker="…">` the same address. Publish `site/` (GitHub Pages), or serve the folder
   locally for the test (`python -m http.server 8765 --directory site`: `http://localhost:8765/support.html`, which the
   sandbox Worker lets call it).
7. **Try it**: press *Supporter*, pay with the test card `4242 4242 4242 4242`, any future expiry, CVC `100`. The browser
   goes to `thanks.html?txn=txn_…` and shows the key; the e-mail arrives with the file. Check the key:

   ```powershell
   tools\license.ps1 verify -text "WREN1.…" -public <the public key>
   ```

   and paste it in `about:wren`. If something is missing: *Developer tools → Notifications → the destination → Logs* shows
   what Paddle sent and got back (a *Replay* button redelivers it), and `npx wrangler tail --env sandbox` shows the
   Worker's side (`webhook_rejected` with the reason, `issued`, `mail`…).
8. Try the failure paths once if you like: a wrong `PADDLE_WEBHOOK_SECRET` gives 401 and nothing is stored; a wrong
   `RESEND_API_KEY` records `mail: failed` (see `mail_refused` in the logs) while the thank-you page still shows the key.

### 5. Production

Same, in the **live** Paddle account (its own products, prices, ids, destination, secret, API key and client token: the
sandbox ones do not exist there). Paddle asks to verify the business and to **approve the website domain**
(*Checkout → Website approval*: `sachahjkl.github.io`, or the domain you use). Then:

```powershell
copy secrets.example.env secrets.env      # live webhook secret, live API key, Resend, the private key
# cloudflare.config.ts / wrangler.jsonc: PRICE_* (live ids), LICENSE_PUBLIC_KEY, MAIL_FROM
cf deploy --secrets-file secrets.env
```

Create the live destination with `https://wren-licence.<subdomain>.workers.dev/paddle/webhook`, and in `support.html` set
`data-environment="production"`, the live `data-client-token` (`live_…`), the live price ids and `data-worker`; in
`thanks.html` the same `data-worker`. A custom domain for the Worker (for example `licences.froment.software`) is a
`triggers.fetch` in `cloudflare.config.ts` (`routes` in `wrangler.jsonc`) once the zone is on Cloudflare.

Make a real purchase of your own (and refund it from Paddle) before announcing anything.

### Settings reference

Set in `cloudflare.config.ts` / `wrangler.jsonc` (`vars`), not secret:

| Name | |
|---|---|
| `PADDLE_API_BASE` | `https://sandbox-api.paddle.com` or `https://api.paddle.com`: must match the webhook's environment |
| `PRICE_SUPPORTER`, `PRICE_PATRON` | price ids, comma separated; the patron price wins when both are bought |
| `LICENSE_PUBLIC_KEY` | the public key of `src/license/public_key.odin` |
| `MAIL_FROM`, `MAIL_REPLY_TO` | sender (an address of a domain verified in Resend) and optional reply address |
| `ALLOWED_ORIGIN` | origins that may call `GET /licence` from a page, comma separated (`*` = any) |
| `WEBHOOK_TOLERANCE_SECONDS` | how old a webhook may be (300) |
| `RESEND_ENABLED`, `RESEND_MAX_PER_HOUR` | `POST /resend` on/off (false) and its limit per address (3) |

Secrets (`secrets.env`, uploaded by `cf deploy --secrets-file`, never in a committed file): `LICENSE_PRIVATE_KEY`,
`PADDLE_WEBHOOK_SECRET`, `PADDLE_API_KEY`, `RESEND_API_KEY` (empty: licences are not mailed, the thank-you page still
shows them).

### Tests

```powershell
cd licence\worker
node --test "test/*.test.ts"      # Node 22.18+ (or: bun test test/); no network, no dependency
```

`tools\test_all.ps1` runs them (SKIP when neither node nor bun is installed). They cover the webhook signature (valid,
altered, wrong secret, too old, malformed, rotation), a `transaction.completed` in Paddle Billing's format
(`licence/worker/test/fixtures`), idempotency, retries, the endpoints, `/resend`, and the cross-check: licences made by
the Worker with the development pair (`DEV_SEED` of `src/license/dev_keys.odin`, read from the Odin source) are verified
by Wren's own tool (`license.exe verify -dev`) as a key and as a `.wrenlicense` file; altered ones and ones of another
key are refused; and for the same fields the Worker and `license.exe issue -dev` produce the very same text.

### Losing or changing the key

A new key pair invalidates every licence issued with the old one (Wren builds carry one public key). Keep the private key
backed up outside this computer; if it leaks, anyone can issue licences, and the only remedy is a new pair, a new Wren
build, and a re-issue to every buyer (`order:` and `txn:` in KV list them).
