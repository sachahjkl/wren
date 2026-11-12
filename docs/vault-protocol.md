# The Vault helper protocol

Wren talks to its Vault helper, `wren-vault`, through two anonymous pipes: the helper's standard input carries the
requests, its standard output the answers. The design is in [bitwarden.md](bitwarden.md). The helper is a separate
program under GPL-3.0-only, in its own repository; its `README.md` has the same description. This page and that
README must stay equal: a change of the protocol changes both, and `PROTOCOL_VERSION` in `src/vault/protocol.odin` and
in the helper.

The protocol is generic: accounts, logins and plain values. No type of the Bitwarden SDK crosses the pipe.

Version 2 (helper 0.2.0). Changes from version 1: the server choice is Wren's (the helper gets URLs as before); `login`
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
| `hello` | `protocol` (2), `state_dir`, `identity_url`, `api_url`, `persist`, `device_name`, `client_version`, `idle_seconds` | `protocol`, `helper_version`, `account` (`none` or `locked`), `email`, `login` (`password` or `api_key`), `pin` (bool) |
| `login` | first step: `email`, `password`; second step: `email`, `code`, `provider`; a new code: `email`, `provider`, `resend` (true) | `result`: `ok`; or `need_two_factor` with `providers` and `email_sent`; or `need_device_code` |
| `login_api_key` | `client_id`, `client_secret`, `password` (the master password) | `result` (`ok`), `email` |
| `unlock` | `password` or `pin` | none; `bad_pin` errors carry `tries_left` |
| `lock` | none | none; the helper then exits |
| `logout` | none | none; the helper forgets the account (state, tokens, PIN), then exits |
| `sync` | none | `items`, `last_sync` (Unix seconds) |
| `pin_set` | `pin` (4 characters or more) | none |
| `pin_clear` | none | none |
| `logins_for` | `url`, `host`, `domain` (registrable domain by Wren's Public Suffix List, `""` if none) | `rows`: `{id, name, username, uri, match, has_totp}` |
| `fill` | `item`, `fields` (`username`, `password`) | `username`, `password` |
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

### Idle deadline

`hello`'s `idle_seconds` (0: none) is the helper's own lock. When no request (`keepalive` included) comes for that
long, the helper writes the event `locked` and exits. Wren sends it its own idle time and a margin
(`vault.lock.idle_minutes` × 60 + 120); Wren locks first, on its own timer, and sends a `keepalive` at most once a
minute while the user is active.

### Errors

`bad_request`, `bad_protocol`, `no_hello`, `bad_server`, `bad_credentials`, `unsupported_two_factor`,
`unsupported_account`, `network`, `login_failed`, `no_account`, `bad_password`, `bad_pin`, `pin_reset`, `no_pin`,
`no_state`, `locked`, `sync_failed`, `no_item`, `decrypt`, `state_write`, `state_format`. The helper's README says what
each means.

## The helper's identity at the server

The helper sends its own token request (the SDK's sends the device type `ChromeBrowser` and one device identifier for
every SDK user, and cannot carry the new-device code): client id `web`, device type 14 (`UnknownBrowser`), device name
`Wren`, and a random device identifier made at the first login and kept in the state. The SDK's HTTP client gets the
same device type (the `Device-Type` header). A renewal with an API key goes through the SDK and still names its fixed
device; no new-device check applies to API keys.

## Matching

The helper selects the logins whose saved URI matches the page: `Domain` (the URI's host is the page's registrable
domain or a subdomain of it; a page without a registrable domain uses `Host`) and `Host` (same host and port). The
other match types match nothing in this version. An item saved for `https` never matches an `http` page.

Wren checks every returned row again with its own Public Suffix List (`src/vault/match.odin`) on the blocking pool,
before the panel shows it. A row that fails the check is zeroed and dropped.

## Wren's side

`src/vault` (no interface, no dependency on the browser):

| File | What |
|---|---|
| `protocol.odin` | The requests, written into one buffer reserved large enough at once; the answers, decoded into owned values. Every string that can hold a value is zeroed before it is freed. |
| `transport.odin`, `process.odin` | The helper as a child process: a reader thread starts it, reads and decodes frames and posts each answer to the loop; a writer thread writes the queued frames in order and zeroes each. The loop thread never blocks on the helper. |
| `vault.odin` | The one state of the Vault, the requests and their deadlines (`vault.request.timeout_ms`), the fill's ticket, the idle and sync timers, the blocking jobs (locating the helper, the account file, the check of the rows, the join of an ended helper). |
| `match.odin` | Wren's match check. |
| `settings.odin` | The `vault.*` preferences and the server addresses (US, EU, self-hosted). |
