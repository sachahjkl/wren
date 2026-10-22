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
(`core:crypto/ed25519`, package `src/license`). No server is involved in checking, and there is none in issuing: the
maintainer signs the licences with `tools\license.ps1` after a purchase and sends them.

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

### 4. Selling (later)

Nothing is for sale yet; [the support page](../site/support.html) says so. When it is time: a Stripe Payment Link with
Stripe Tax, then after each payment `tools\license.ps1 issue` and send the file; or a small stateless service (for
example a Cloudflare Worker holding the private key as a secret) that signs on the `checkout.session.completed` webhook.
The licence format does not change either way.
