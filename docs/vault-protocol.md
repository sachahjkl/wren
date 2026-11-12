# The Vault helper protocol

Wren talks to its Vault helper, `wren-vault`, through two anonymous pipes: the helper's standard input carries the
requests, its standard output the answers. The design is in [bitwarden.md](bitwarden.md). The helper is a separate
program under GPL-3.0-only, in its own repository; its `README.md` has the same description. This page and that
README must stay equal: a change of the protocol changes both, and `PROTOCOL_VERSION` in `src/vault/protocol.odin` and
in the helper.

The protocol is generic: accounts, items (logins, cards, identities) and plain values. No type of the Bitwarden SDK
crosses the pipe.

Version 5 (helper 0.5.0). Changes from version 4: new requests `save` (create a login, or update one) and `generate` (a
password or a passphrase, by the SDK's generator; the vault need not be unlocked); rows of `search` carry `kind`
(`login`, `card` or `identity`; secure notes and SSH keys are not listed), rows of `logins_for` carry `kind` `login`;
`fill` takes the fields of cards and identities; the error `save_failed`.

Version 4 (helper 0.4.0). Changes from version 3: new requests `password_hint`, `device_request`, `device_poll`,
`passkey_options` and `login_passkey`; `login` takes `remember`; `unlock` takes `prf` and `credential_id`; `hello`
answers `passkey`; the errors `denied`, `expired`, `no_passkey` and `account_locked`. Every token request carries the
headers `Auth-Email` (a password login) and `Bitwarden-Client-Version`, without which the server refuses it.

Version 3 (helper 0.3.0). Changes from version 2: new requests `search` and `totp`; `fill` takes the field `totp`;
`logins_for` applies the rules `StartsWith` and `Exact` and the account's equivalent domains, its rows carry the match
types `equivalent`, `starts_with` and `exact`, and its answer carries `equivalent`; the error `no_totp`.

Version 2 (helper 0.2.0) changed from version 1: the server choice is Wren's (the helper gets URLs as before); `login`
carries `code` and `provider` instead of `totp`, and answers `need_device_code`; new requests `login_api_key`,
`logout`, `pin_set`, `pin_clear`; `unlock` takes `pin`; `hello` takes `idle_seconds` and answers `login` and `pin`; the
event `locked`.

## Frames

- Each message is one frame: a 4-byte unsigned length, little-endian, then that many bytes of UTF-8 JSON (one object).
- The length is from 1 to 1 048 576 (1 MiB). A frame outside these bounds ends the connection.
- The helper answers each request, in the order of the requests. `keepalive` has no answer.
- The helper writes nothing else on its standard output, and no value of the vault on its standard error.
- The helper exits when its standard input closes, after it answers `lock` or `logout`, and at its idle deadline.

## Requests and answers

A request is `{"id": <integer from 1>, "op": "<name>", ...fields}`. The answer repeats the id:

- success: `{"id": n, "ok": true, ...fields}`
- failure: `{"id": n, "ok": false, "error": "<code>", "message": "<sentence>"}`

An event answers no request: `{"id": 0, "ok": true, "event": "<name>"}`.

| op | Request fields | Answer fields |
|---|---|---|
| `hello` | `protocol` (5), `state_dir`, `identity_url`, `api_url`, `persist`, `device_name`, `client_version`, `idle_seconds` | `protocol`, `helper_version`, `account` (`none` or `locked`), `email`, `login` (`password` or `api_key`), `pin` (bool), `passkey` (bool: a passkey of the account unlocks) |
| `login` | first step: `email`, `password`; second step: `email`, `code`, `provider`; a new code: `email`, `provider`, `resend` (true); `remember` (true): the server lets this device skip the second step next time | `result`: `ok`; or `need_two_factor` with `providers` and `email_sent`; or `need_device_code` |
| `login_api_key` | `client_id`, `client_secret`, `password` (the master password) | `result` (`ok`), `email` |
| `unlock` | `password`, `pin`, or `prf` and `credential_id` (a passkey) | none; `bad_pin` errors carry `tries_left` |
| `lock` | none | none; the helper then exits |
| `logout` | none | none; the helper forgets the account (state, tokens, PIN), then exits |
| `sync` | none | `items`, `last_sync` (Unix seconds) |
| `pin_set` | `pin` (4 characters or more) | none |
| `pin_clear` | none | none |
| `logins_for` | `url`, `host`, `domain` (registrable domain by Wren's Public Suffix List, `""` if none) | `rows`: `{id, kind, name, username, uri, match, has_totp}` (logins only, `kind` `login`); `equivalent`: the domains that the account makes equivalent to `domain` |
| `search` | `query`, `limit` (0: 50; at most 50) | `rows`: `{id, kind, name, username, uri, has_totp}` (no `match`; `uri`: a login's first `http(s)` address; see "Item kinds") |
| `fill` | `item`, `fields` (see "Fill fields") | one field per asked name that the item has (non-empty), named the same |
| `save` | `item` (`""`: a new login; else the id of the login to update), `name` (the item's name; on a creation Wren sends the site's host), `uri` (the page's address, `""` none), `username`, `password` | `item` (the id of the created or updated login) |
| `generate` | `kind` (`password` or `passphrase`); password: `length` (0: 20; 5 to 128), `uppercase`, `lowercase`, `numbers`, `special` (all false: all true), `min_numbers`, `min_special` (0: 1 when that class is on); passphrase: `words` (0: 5; 3 to 20), `separator` (`""`: `-`), `capitalize`, `include_number` | `value` (a secret, zeroed by the helper once written) |
| `totp` | `item` | `totp`, `period`, `remaining` (seconds) |
| `password_hint` | `email` | none; the server mails the hint to the account's address |
| `device_request` | `email` | `fingerprint` (the phrase the other device shows) |
| `device_poll` | none | `result`: `"pending"`, or `"ok"` (unlocked) with `email` |
| `passkey_options` | `purpose` (`"login"` or `"unlock"`), `rp_id` (the web vault's domain) | `options` (the WebAuthn request's options, JSON text) |
| `login_passkey` | `credential_id`, `authenticator_data`, `client_data_json`, `signature`, `user_handle` (each base64url), `prf` (the PRF output, base64url) | `result` (`"ok"`), `email` |
| `keepalive` | none | no answer; the idle deadline starts again |

### Login steps

- `provider` is `authenticator` (an authenticator app's code; the default), `email` (a code by email) or `device` (the
  code of the server's new-device mail). `providers` lists the second steps of the account that the helper supports
  (`authenticator`, `email`); an account with none of them gets `unsupported_two_factor`.
- A login with a second step is two requests or more. The first `login` (email and password) answers `need_two_factor`
  or `need_device_code`; the helper keeps the email, the password and the device identifier of that login. The
  second `login` carries the same email, the code and its provider: Wren sends the master password once. A failed
  second step forgets the kept password.
- `resend` asks for a code again. With `provider` `email`, the helper asks the server to mail the two-step code and
  answers `need_two_factor` with `email_sent` true. With `device`, it sends the first step again and the server mails a
  new code. `email_sent` is also true when the email code is the account's only second step: the server mailed it.

### Item kinds

- A card row: `name` the item's name, `username` the brand and the last 4 digits (`Visa *1234`, `""` when no number),
  `uri` `""`.
- An identity row: `name` the item's name, `username` the full name or else the email, `uri` `""`.
- `has_totp` is false for cards and identities. A row without `kind` is a login (version 4); Wren drops a row of a kind
  it does not know.

### Fill fields

- A login: `username`, `password`, `totp`.
- A card: `cardholder`, `number`, `exp_month` (as stored, `1` to `12`), `exp_year` (4 digits when stored so), `code`,
  `brand`.
- An identity: `title`, `first_name`, `middle_name`, `last_name`, `full_name` (first, middle and last, single spaces),
  `address1`, `address2`, `address3`, `city`, `state`, `postal_code`, `country`, `company`, `email`, `phone`,
  `username`, `ssn`, `passport`, `license`.
- A field of another kind of item gives nothing for it, and no error. `no_item`: an id that is neither a login, a card
  nor an identity.

### Save

- On an update, only the given non-empty fields change (`username`, `password`); the item keeps its password history
  as the SDK does it. The `uri` is added to the item's URIs when none matches it.
- The helper encrypts with the SDK, sends it to the server (`POST /api/ciphers` for a creation, `PUT
  /api/ciphers/{id}` for an update) and puts the result into its local copy of the vault: `logins_for`, `search` and
  `fill` see it at once, without a sync.
- Errors: `locked`, `no_item` (an update of an id that is not a login), `save_failed` (the server refused it or cannot
  be reached; the message says why).

### Idle deadline

`hello`'s `idle_seconds` (0: none) is the helper's own lock. When no request (`keepalive` included) comes for that
long, the helper writes the event `locked` and exits. Wren sends it its own idle time and a margin
(`vault.lock.idle_minutes` × 60 + 120); Wren locks first, on its own timer, and sends a `keepalive` at most once a
minute while the user is active.

### Errors

`bad_request`, `bad_protocol`, `no_hello`, `bad_server`, `bad_credentials`, `unsupported_two_factor`,
`unsupported_account`, `network`, `login_failed`, `no_account`, `bad_password`, `bad_pin`, `pin_reset`, `no_pin`,
`no_state`, `denied`, `expired`, `no_passkey`, `account_locked`, `locked`, `sync_failed`, `no_item`, `no_totp`,
`save_failed`, `decrypt`, `state_write`, `state_format`. The helper's README says what
each means.

## The helper's identity at the server

The helper sends its own token request (the SDK's sends the device type `ChromeBrowser` and one device identifier for
every SDK user, and cannot carry the new-device code): client id `web`, device type 14 (`UnknownBrowser`), device name
`Wren`, and a random device identifier made at the first login and kept in the state. The SDK's HTTP client gets the
same device type (the `Device-Type` header). A renewal with an API key goes through the SDK and still names its fixed
device; no new-device check applies to API keys.

## Matching

The helper selects the logins whose saved URI matches the page: `Domain` (the URI's host is the page's registrable
domain or a subdomain of it: `domain`; or one of the domains the account makes equivalent to it, or a subdomain of
one: `equivalent`; a page without a registrable domain uses `Host`), `Host` (same host and port), `StartsWith` (the
page's address starts with the URI) and `Exact` (the page's address is the URI), both addresses as the URL standard
serializes them. `RegularExpression` and `Never` match nothing. An item saved for `https` never matches an `http` page.
The equivalent domains are the account's own groups and the server's global groups it did not exclude, from the last
sync.

Wren checks every returned row again with its own Public Suffix List (`src/vault/match.odin`) on the blocking pool,
before a surface shows it. An `equivalent` row stays only if the saved host's registrable domain is in the answer's
`equivalent`. A row with a match type Wren does not know is dropped when the answer is read. A row that fails the
check is zeroed and dropped. `search` rows are not checked: a login of them fills only when the same item is also a
checked row of the focused document (docs/bitwarden.md 3.5, rule 10). Cards and identities have no site: they fill
only into the card or address fields where the user picked them (docs/bitwarden.md 4.10).

## Wren's side

`src/vault` (no interface, no dependency on the browser):

| File | What |
|---|---|
| `protocol.odin` | The requests, written into one buffer reserved large enough at once; the answers, decoded into owned values. Every string that can hold a value is zeroed before it is freed. |
| `transport.odin`, `process.odin` | The helper as a child process: a reader thread starts it, reads and decodes frames and posts each answer to the loop; a writer thread writes the queued frames in order and zeroes each. The loop thread never blocks on the helper. |
| `vault.odin` | The one state of the Vault, the requests and their deadlines (`vault.request.timeout_ms`), the four sets of rows (the tab's document, the focused frame's document, the search, every item), the fill's ticket, the copies, the save offer and its never-save list, the generated value, the idle and sync timers, the blocking jobs (locating the helper, the account and never-save files, the check of the rows, the join of an ended helper). |
| `match.odin` | Wren's match check. |
| `settings.odin` | The `vault.*` preferences and the server addresses (US, EU, self-hosted). |
