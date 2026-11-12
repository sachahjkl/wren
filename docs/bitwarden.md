# Vault: a native client for Bitwarden accounts

Status: phases 0 and 1 are written, phases 2 and 3 for the most part (see [Implementation state](#implementation-state)).
The rest is the plan. The protocol between Wren and the helper is in [vault-protocol.md](vault-protocol.md).

The feature gives Wren a built-in password manager client for Bitwarden® accounts. It is optional and off by default.
It needs no WebExtension. The interface name of the feature is **Vault**. "Bitwarden" appears only as the name of the
compatible service (see [Trademark](#trademark)).

The main design decision comes from the license of the SDK (section 2.3):
**the SDK cannot be linked into `wren.exe`. It runs in a separate program, `wren-vault`, under GPL-3.0.**
The separate program is also the stronger security design (section 3).

## 1. Scope

### 1.1 User flows

| Flow | What the user does | Phase |
|---|---|---|
| Enable | Sets `vault.enabled` in the settings. Wren installs the helper and shows the Vault toolbar button. | 1 |
| Log in | Types the email and the master password. Types a TOTP code if the account asks for one. | 1 |
| Unlock | Types the master password in the unlock dialog. | 1 |
| Fill from the panel | Opens the Vault panel, sees the logins for the current site, selects one. Wren fills the form. | 1 |
| Server choice | Selects US, EU, or a self-hosted server URL before the login. | 2 |
| Other login methods | Email 2FA code, new-device verification code, personal API key. | 2 |
| Unlock on start | Wren starts locked with the account remembered. The user unlocks with the master password or a PIN. | 2 |
| Lock | Wren locks after an idle time, on system sleep, on demand, and at exit. | 2 |
| Sync | Wren syncs after unlock, on a timer, and on demand. | 2 |
| Fill from a key | Presses the fill shortcut. Wren fills the only match, or opens the list of matches. | 3 |
| Fill from a field | Focuses a login field. A dropdown anchored to the field lists the matches. | 3 |
| Fill from the address bar | A chip in the address bar shows the number of matches. A click opens the list. | 3 |
| Vault search | Types the Vault prefix in the command palette. Selects an item to fill it, copy a value, or open its site. | 3 |
| Per-site list | The panel lists every login of the current site, with copy actions for user name, password and TOTP code. | 3 |
| TOTP | Copies the current code, or fills a one-time-code field. The clipboard is cleared after a delay. | 3 |
| Save or update | After a form submit, Wren asks to save a new login or to update a changed password. | 4 |
| Generator | In a new-password field, the dropdown offers a generated password. | 4 |
| Passkeys | The vault is an authenticator for `navigator.credentials.create()` and `get()`. | 5 |

### 1.2 Non-goals for phases 1 to 5

- Login with SSO, trusted devices, Key Connector, or "log in with device".
- 2FA with WebAuthn, Duo, or YubiKey OTP. Workaround: log in with a personal API key (phase 2).
- Unlock with biometrics, and "never lock".
- Cards, identities, secure notes, SSH keys: no fill, no edit. The search lists logins only.
- Attachments, Send, import, export, emergency access, account registration, master password change.
- Organization administration, collection management, policies that change the interface.
- Several accounts at the same time. One account per profile.
- URI match type "regular expression". Such a URI matches nothing until a later phase.
- Automatic fill on page load. Wren fills only after a user action (section 3.5).
- macOS.

## 2. The SDK

### 2.1 Which repository

| Repository | Content | Use |
|---|---|---|
| `bitwarden/sdk-internal` | The Password Manager SDK that the official clients use: crypto, login, sync, vault, TOTP, generators, passkeys. | **This one.** |
| `bitwarden/sdk-sm` (the older `bitwarden/sdk`; crate `bitwarden` 2.1.0 on crates.io) | The public Secrets Manager SDK. It has no vault of logins. | Not applicable. |

State of `sdk-internal` on 2026-11-12: commit `300aea5`, workspace version 4.0.0, tag `rust-v4.0.0`
(`b865d1db`), minimum Rust 1.89.0, edition 2024. Wren's toolchain (1.99.1) is sufficient.

### 2.2 Stability

- The README says: "The password manager interface is unstable and will change without warning."
- Each crate says: "This crate does not follow semantic versioning."
- Bitwarden gives no support for third-party use.
- crates.io has only a part of the crates (`bitwarden-core`, `bitwarden-crypto`, `bitwarden-auth`, `bitwarden-state`,
  `bitwarden-generators` at 4.0.0). `bitwarden-pm`, `bitwarden-vault` 4.x, `bitwarden-sync`, `bitwarden-unlock` and
  `bitwarden-fido` are not published.

Consequences:

- Depend on the Git repository, with one exact `rev` for all crates. Start with tag `rust-v4.0.0` if it contains
  `bitwarden-pm`, `bitwarden-sync` and `bitwarden-unlock`. If not, use commit `300aea5`.
- An SDK update is a planned task with its own test run. It is never automatic.
- All SDK calls stay in one Rust module of the helper (`vault/src/sdk.rs`). The protocol to Wren does not show SDK types.
- The server API changes with time. An old pinned SDK can fail against a new server. Plan one SDK update per quarter.

### 2.3 License verdict

Every crate we need declares `GPL-3.0-only OR LicenseRef-Bitwarden-SDK`. We must select one of the two.
Wren's code is under PolyForm Strict 1.0.0, and Wren is distributed to third parties and sells licenses.

**Bitwarden SDK License Agreement v2 (7 October 2025): blocking.**

- Section 3.1 permits only: (a) to develop, test and demonstrate a Compatible Application; (b) personal use by your
  family; (c) internal business operations with a paid Bitwarden server license.
- Section 3.1 ends: "in no case above may the Compatible Application be offered, licensed, or sold to a third party."
- Section 3.4 forbids redistribution of the SDK or any part of it.
- Section 1.3 requires the application to work with the official server products.

A distributed browser, free or paid, is not permitted under this license.

**GPL-3.0-only, linked into `wren.exe`: blocking.**

A static link makes one combined work. The whole work must then be under GPL-3.0. PolyForm Strict is not compatible
with GPL-3.0. Wren does not change its license for this feature.

**GPL-3.0-only, in a separate program: compatible, with conditions.**

The helper `wren-vault` is a separate program under GPL-3.0-only. Wren starts it and talks to it through pipes.
The conditions are:

1. The helper has its own source directory with its own `LICENSE` (GPL-3.0-only). Its source is public, complete, and
   includes the build instructions and the pinned SDK revision.
2. The helper is not a part of `wren.exe`. It is a separate file with its own license notice. `about:licenses` names it.
3. The protocol between Wren and the helper is documented and generic: requests and answers about accounts and logins.
   It does not pass SDK data structures. The helper has no dependency on Wren.
4. No Wren code under PolyForm Strict is copied into the helper. Code that the two share (none is planned) must be
   licensed for both by its author.
5. Each release of the helper keeps its matching source available (a tagged commit).
6. The copyright and license notices of the SDK stay intact.

Residual risk: the FSF position is that two programs that talk through pipes are normally separate works, unless the
communication is "intimate". Condition 3 addresses this. This document is not legal advice. The safest path is a written
confirmation from Bitwarden Inc. (see section 6).

The GPL option has two benefits. We can patch the SDK when needed (section 2.5). We can test against Vaultwarden,
which the SDK License does not permit.

### Trademark

The Bitwarden Trademark Guidelines apply whatever the code license is.

- Do not use the Bitwarden logo. The toolbar icon is Wren's own (a vault or a shield).
- Do not put "Bitwarden" in a product, feature, file or domain name. The feature is "Vault". The helper is `wren-vault`.
- Refer to the service as an adjective, with the mark on first mention: "Use a Bitwarden® account".
- Do not suggest endorsement. The settings page says that the feature is not made or supported by Bitwarden Inc.

### 2.4 Crates and API surface

The helper depends on `bitwarden-pm` (the `PasswordManagerClient` that groups the sub-clients). Features: default
only. Do not enable `wasm`, `uniffi`, `bitwarden-license`, `no-memory-hardening`, `dangerous-crypto-debug` or
`debug-capabilities`. The directory `bitwarden_license/` (commercial code) is never compiled.

| Need | SDK call | State in the SDK |
|---|---|---|
| Client, server URLs, device | `PasswordManagerClient::builder()`, `ClientSettings { identity_url, api_url, user_agent, device_type, device_identifier }` | Present. US, EU and self-hosted are only URLs. |
| KDF parameters | `auth().prelogin(email)` | Present (PBKDF2, Argon2id). |
| Login, master password | `auth().login_password(PasswordLoginRequest { email, password, two_factor })` | Present. Hard-codes device type `ChromeBrowser`, a fixed device identifier and client id `web`. |
| 2FA TOTP and email | `TwoFactorRequest { token, provider, remember }`, `auth().send_two_factor_email()` | Present. |
| 2FA WebAuthn, Duo, YubiKey | `TwoFactorProvider` values exist. The client must produce the token. | No flow in the SDK. |
| Login, API key | `auth().login_api_key(ApiKeyLoginRequest { client_id, client_secret, password })` | Present. |
| New-device verification | Only the generated endpoint `resend_new_device_otp`. | No flow in the SDK. The helper adds the code to the token request (patch or own request). |
| SSO | Mentioned in `bitwarden-auth` only. | Absent. |
| New login API | `bitwarden-auth` `LoginClient::login_via_password` with `LoginDeviceRequest` | Present, but 2FA is not implemented yet. Move to it when it has 2FA. |
| Unlock | `crypto().initialize_user_crypto(InitUserCryptoMethod::MasterPasswordUnlock / PinState / PinEnvelope)`, `unlock()` | Present. |
| PIN | `crypto().enroll_pin(pin)`, `auth().validate_pin()` | Present. |
| Biometrics, never lock | `InitUserCryptoMethod::DecryptedKey`, `crypto().get_user_encryption_key()` | Present. The host must protect the key. Non-goal. |
| Sync | `PasswordManagerClient::new_with_sync()`, `sync().sync(SyncRequest)`, `sync().last_sync()` | Present. The comment says more handlers will come. |
| State on disk | `bitwarden-state`: SQLite (`rusqlite`, bundled) or memory. `save_to_state` / `load_from_state`. | Present. |
| Tokens | `ClientManagedTokens` trait, `new_with_client_tokens()` | Present: the host can own the token store. |
| List and read logins | `vault().ciphers().list()`, `get(id)`, `decrypt()`; `LoginUriView`, `UriMatchType` | Present. No URI matching function and no Public Suffix List. |
| Create and edit | `vault().ciphers().create()`, `edit()` | Present. |
| TOTP codes | `vault().totp().generate_totp(key, time)` | Present. |
| Folders | `vault().folders()` | Present. |
| Generator | `generators().password()`, `passphrase()`, `password_rules()` | Present. |
| Passkeys | `bitwarden-fido`: `Fido2Authenticator::make_credential`, `get_assertion`, `silently_discover_credentials`; traits `Fido2UserInterface`, `Fido2CredentialStore` | Present. Depends on a Git fork of `passkey-rs`. |
| Send, attachments, export, import | `bitwarden-send`, `attachments()`, `bitwarden-exporters`, `bitwarden-importers` | Present. Non-goals. |

The SDK repository contains `crates/bw`, a test CLI in Rust. It is the reference for a native consumer.

### 2.5 Build

The request was a crate `wren_vault` in `native/`, behind a C ABI. The license forbids this. The design is:

- A new top-level directory `vault/`: one Cargo workspace, one crate `wren-vault` (a binary), its own `Cargo.lock`,
  its own `LICENSE` (GPL-3.0-only) and `README.md`. It is not a member of `native/`.
- `wrentool build vault` runs `cargo build --locked` with the `release` or `quick` profile, as `wrentool build native`
  does. The output is `build/vault/wren-vault` (`.exe` on Windows). `build.bat` and `build.sh` do not build it by
  default: the browser builds and runs without it.
- All versions are exact. The SDK and `passkey-rs` are Git dependencies with an exact `rev`. The Nix flake vendors
  them with `importCargoLock` and `outputHashes`.
- `wrentool gen rust-crates` writes a second list for the helper. `about:licenses` shows it under its own heading.
- Patches to the SDK, if needed (device type, new-device code), are files in `vault/patches/`, applied to the vendored
  source by `wrentool build vault`. Keep the number of patches small. Offer each patch upstream.

Reasons other than the license to keep the SDK out of `wren.exe`:

- `bitwarden-crypto` installs a `#[global_allocator]` (a zeroizing allocator). In `wren_native` it would replace the
  allocator of all Rust code of the browser: decoders, network, WebGL.
- Wren writes minidumps on a crash. A vault in the process would put keys in the dump.
- `rusqlite` with bundled SQLite adds a C build to `wren_native`.

Cost. These are estimates. Phase 0 measures them and writes the numbers here.

| Item | Estimate |
|---|---|
| Crates in the helper's lock file | 350 to 450 (the full SDK workspace has 734, with WASM, UniFFI and CLI code) |
| Clean build, `release` | 2 to 4 minutes |
| Helper size, stripped | 6 to 12 MB |
| `wren.exe` size and build time | No change |
| Helper start | Less than 50 ms |

### 2.6 Async runtime

The helper runs one tokio runtime (`rt-multi-thread`, 2 worker threads). One task reads requests from stdin. One task
writes answers to stdout. Each request runs as its own task. Wren's process gets no new runtime.

### 2.7 Network

The SDK makes its own HTTP calls with `reqwest` 0.13, `rustls` (ring) and `rustls-platform-verifier`.

| Topic | SDK client in the helper (selected) | Wren's stack (`src/net`, `src/fetch`) |
|---|---|---|
| Work | None. | Replace the transport under about 60 generated API calls, through IPC. Not practical. |
| TLS roots | The system trust store. The same policy as `wren_net`. | Same. |
| `network.tls.extra_ca_file` | Not applied. A private CA must be in the system store. | Applied. |
| Proxy | `reqwest` reads the proxy environment variables. Phase 0 checks the system proxy on Windows. | System proxy. |
| Cookies, cache, blocker, DevTools | Not involved. Vault traffic is invisible to pages and to DevTools. This is intended. | Would need exclusions. |
| HTTP/3 | No. | Yes. Not needed here. |

Rules:

- The helper connects only to the configured server: the identity URL and the API URL. It follows no other URL.
  Icons of sites are not fetched in the first phases.
- `https` is mandatory. `http` is accepted only for a loopback host (`127.0.0.1`, `[::1]`, `localhost`). The tests use it.
- The user agent is `Wren/<version> wren-vault/<version>`. The device identifier is a random UUID made at the first login
  and kept in the helper's state. The device name is "Wren".

## 3. Security model

### 3.1 Where secrets live

| Data | Location |
|---|---|
| Master key, user key, organization keys, private key | Helper memory only. Never sent on the pipe. |
| Decrypted items (names, user names, URIs, passwords, TOTP seeds, passkey private keys) | Helper memory only, decrypted on demand. |
| Access token, refresh token | Helper memory. At rest: see 3.4. |
| Master password, PIN, 2FA code | Typed in Wren's dialog. Sent once on the pipe. Wren zeroes its buffer after the send. |
| Rows on screen (item id, name, user name, matched host, flags) | Wren memory, only while the panel, dropdown or palette that shows them is open. Zeroed on close. |
| One password, one TOTP code | Crosses the pipe only at a fill or a copy that the user asked for. |

The helper inherits the SDK's protections: `zeroize` on key types, the zeroizing global allocator, keys pinned on the
heap. Do not disable them.

The helper adds:

- No core dump: `PR_SET_DUMPABLE=0` and `RLIMIT_CORE=0` on Linux; no Windows Error Reporting dump on Windows.
- No debugger attach from a process of the same user on Linux (the same `PR_SET_DUMPABLE=0`).
- It exits when stdin closes. A dead Wren leaves no unlocked helper.
- It writes no secret to stderr. The SDK's `tracing` output is off in release builds.

### 3.2 Lock is process exit

**Locked means: no helper process holds keys.** To lock, Wren sends `lock`. The helper drops the SDK client and exits.
The operating system then frees every page. Wren starts a new helper at the next unlock.

This removes one class of defects: no code path has to find and clear each copy of a key.

Lock triggers: the toolbar or palette command, the idle timer (`vault.lock.idle_minutes`), system sleep or session
lock, the exit of the last window, a disabled `vault.enabled`. The helper has its own idle deadline as a second guard:
Wren sends a `keepalive` on user activity; without one, the helper locks itself.

### 3.3 What crosses the boundary

The boundary is one pair of anonymous pipes (stdin, stdout) that the helper inherits. No socket and no named pipe
exist: no other process can connect.

Frames are a 4-byte length and a JSON object. Maximum frame: 1 MiB. Each request has an id; each answer repeats it.

| Request | Carries to the helper | Carries to Wren |
|---|---|---|
| `hello` | Protocol version, state directory, server URLs, device name | Helper version, account state (`none`, `locked`) and email |
| `login` | Email, master password, optional 2FA or new-device code | `ok`, or `need_two_factor` with the providers, or `need_device_code`, or an error |
| `login_api_key` | Client id, client secret, master password | `ok` or an error |
| `unlock` | Master password or PIN | `ok` or an error with the tries left |
| `lock`, `logout` | Nothing | `ok` |
| `sync` | Nothing | Counts and the last sync time |
| `logins_for` | Page URL, host, registrable domain (from Wren's Public Suffix List) | Rows: id, name, user name, matched host, match type, has TOTP, has passkey |
| `search` | Query text, offset, limit, kinds | Rows as above, and the count of all matches |
| `fill` | Item id, the wanted fields (`username`, `password`, `totp`) | The values |
| `totp` | Item id | Code and seconds left |
| `save_login`, `update_password` | Site URL, user name, password, optional item id | New item id |
| `generate` | Options | One password |
| `pin_set`, `pin_clear` | PIN | `ok` |
| `passkey_*` (phase 5) | The authenticator request | The authenticator response |
| `keepalive` | Nothing | Nothing |

Events from the helper: `state` (locked, unlocked, syncing, logged out), `sync_done`, `error`.

Rules in Wren for these values:

- Never log a frame, a row, or a value. The package `src/vault` has no log call that takes payload data.
- Crash reports hold no vault data: Wren holds rows only while a surface is open, and passwords only during a fill.
- Remote control (`wren ctl`), CDP and BiDi have no vault method. They cannot read rows, trigger a fill, or unlock.
  Captures draw the Vault surfaces as an empty box. Only `vault.test.remote` (default off) lifts this, for e2e tests
  with a throwaway profile and a test account.
- DevTools shows no vault traffic and no vault state.
- The accessibility tree exposes rows as the screen shows them. It never exposes a masked value.
- A page's scripts cannot reach `src/vault`: no `api/*.widl` function exists for it. This is rule 6 of
  [architecture.md](architecture.md): the guest cannot reach host memory.
- Session restore, history, `bfcache` snapshots and form restoration never store a value that the vault filled.

### 3.4 State on disk

Directory: `<profile>/vault/` (mode `0700`). With `browser.profile.persist` off, the helper uses the SDK's memory
database and nothing is written.

| File | Content | Protection |
|---|---|---|
| `state.sqlite` (SDK-managed) | Items, folders, organization data: encrypted by the server-side scheme with the user key. Account email, server URLs, KDF parameters, device identifier. The PIN envelope when a PIN is set. | File mode `0600`. Useless without the master password or the PIN. |
| Tokens | Access and refresh tokens. | Phase 1: in `state.sqlite`. Phase 2: the helper implements `ClientManagedTokens` over the system store. |

System store for tokens (phase 2), with the Rust crate `keyring`:

- Windows: Credential Manager (DPAPI, bound to the user account).
- Linux: Secret Service (GNOME Keyring, KWallet) when a service answers. If none answers, a file of mode `0600`.
  This is the same level as Chromium without a keyring, and as `src/wasm/crypto_unix.odin`.

A stolen token alone gives only encrypted data. The user key is never stored, except inside the PIN envelope.
A PIN is weaker than the master password: the helper counts wrong PINs in its state and deletes the envelope after 5.

Phase 0 must list exactly what the SDK writes to `state.sqlite` at the pinned revision, and update this table.

`logout` deletes the directory content and the system store entry.

### 3.5 Phishing resistance of fill

Definitions: the **frame origin** is the origin of the document that contains the field. The **top origin** is the
origin of the tab's top document.

1. **A fill needs a user action.** Wren never fills on page load. The action is a click on a row, the fill shortcut, or
   a selection in the dropdown. The action must come from the user's input device, not from a script or remote control.
2. **Matching uses the frame origin**, never the page title, the form action, or the top origin.
3. **Match rules** follow the item's URI match type:
   - `Domain` (the default): the registrable domain of the URI host equals the registrable domain of the frame host.
     Wren's Public Suffix List decides (`src/url/psl.odin`). A host with no registrable domain (an IP address,
     `localhost`, a public suffix) uses the `Host` rule.
   - `Host`: host and port are equal.
   - `StartsWith`: the frame URL starts with the URI.
   - `Exact`: the frame URL equals the URI.
   - `Never`: no match.
   - `RegularExpression`: no match (non-goal).
   - The account's equivalent domains (`GlobalDomains`) extend `Domain` from phase 3.
4. **One list decides.** The helper selects candidates with the registrable domain that Wren sends. Wren checks each
   returned row again with its own list before it shows the row. The two sides use one Public Suffix List.
5. **Scheme.** An item saved for `https` does not match an `http` frame. On an `http` frame (not loopback), Wren shows a
   warning with the origin and needs a confirmation for each fill. `vault.fill.insecure` can set this to `never`.
6. **Certificate errors.** No fill on a page that the user opened through a certificate warning.
7. **Frames.**
   - Same origin as the top document: fill.
   - Cross-origin frame: rows are for the frame origin. The list shows the frame origin in a warning line. Each fill
     needs a confirmation.
   - Opaque origin (sandboxed frame, `data:`, `about:blank` without an inherited origin): no fill.
8. **Fields.** Wren fills only fields that are visible, enabled and editable, and that belong to the same form (or the
   same form-less group) as the field the user acted on. A password goes only into `type=password` fields.
9. **No fill into a field whose frame changed** between the request and the answer. The fill carries the page's handle
   and navigation id. A dead handle drops the fill (rule 2 of architecture.md).
10. **Search results from the palette** fill only when the item matches the current frame by the rules above.
    For a non-matching item, the palette offers "open the site" and "copy", not "fill".

A filled value is in the page. Its scripts can read it. This is the nature of every password manager. Rules 1 to 10
limit which page gets it.

### 3.6 Clipboard

A copied password or TOTP code is removed from the clipboard after `vault.clipboard.clear_seconds` (default 30), if
the clipboard still holds that value. On Windows, the copy is marked to stay out of the clipboard history.

### 3.7 Helper integrity

Wren runs the helper only from a path that it controls, and only when its SHA-256 equals the value built into this
Wren version. `vault.helper.path` (for development and for packagers) overrides the path; a policy file can forbid it.

## 4. Integration design

### 4.1 Distribution of the helper

`wren.exe` has no file beside it. This rule stays. When the user enables the feature:

1. Wren shows what will happen: a download of `wren-vault` (size, license GPL-3.0, link to the source).
2. Wren downloads the helper of its own version from the release assets, with the code of `gui_toolkit` `update`.
3. Wren checks the SHA-256 that is built into `wren.exe`, then stores the file in `<data dir>/vault/<version>/`.
4. A Wren update downloads the matching helper before the first unlock. Old versions are deleted.

Linux packages (Nix, others) install `wren-vault` beside `wren`. Wren finds it there and downloads nothing.

### 4.2 Packages

| Package | Role |
|---|---|
| `vault/` (Rust, GPL) | The helper: protocol, SDK calls, state, token store. |
| `src/vault` (Odin) | The client: protocol codec, process start and stop, the state machine, the match check, settings. No UI. No dependency on `browser` or `page`. |
| `src/forms/credentials.odin` | Finds login fields in a document (4.6). |
| `src/browser/vault_*.odin` | The shell: toolbar button, dialogs, panel, dropdown, prompts, palette source, settings section. |
| `src/webauthn/platform_vault.odin` | The vault as a WebAuthn `Platform` (phase 5). |

### 4.3 State machine

One explicit state per App, in `src/vault`. Every surface reads it. No surface keeps its own copy.

```
Disabled -> Helper_Missing -> Installing -> Logged_Out -> Logging_In -> (Need_Two_Factor | Need_Device_Code) -> Unlocked
                                            Locked -> Unlocking -> Unlocked -> (Syncing) -> Unlocked
Unlocked -> Locked            (lock, idle, sleep)
any -> Failed(reason)         (helper exit, protocol error); the next user action starts again from Locked or Logged_Out
```

`Logged_Out` or `Locked` at start comes from a small file that Wren owns (`<profile>/vault/account`: email and server
URLs only). Wren does not start the helper to draw the locked icon.

A second machine exists per fill: `Requested -> Answered -> Applied | Dropped`. A request has a deadline
(`vault.request.timeout_ms`). A late answer is dropped and zeroed.

### 4.4 Threads

- The vault state belongs to the App and changes only on the loop thread (rule 3 of architecture.md).
- One reader thread per helper process blocks on the pipe. It only decodes a frame and calls `host.post`.
- Writes to the pipe go through the blocking pool, in order. The loop thread never blocks on the helper.
- Thread memory starts from `base.process_context()`. Frame buffers come from a `base.Arena` per frame, zeroed on free.
- With `browser.shell.page_thread`, the loop hands a fill to the page's thread as it hands input events.
- Two Apps in one process (the e2e `two_apps` test) have two helpers and two state machines. No global is added.

### 4.5 Preferences

All in `src/vault/settings.odin`, registered in `src/browser/settings.odin`.

| Name | Type, default | Meaning |
|---|---|---|
| `vault.enabled` | Bool, `false` | The one switch. Off: no button, no helper, no prompt, no network call. |
| `vault.server.region` | String, `us` | `us`, `eu`, or `self`. |
| `vault.server.url` | String, empty | Base URL of a self-hosted server (`self` only). |
| `vault.lock.idle_minutes` | Int, 15, 0 to 1440 | Lock after this idle time. 0: only on demand and at exit. |
| `vault.lock.on_sleep` | Bool, `true` | Lock on system sleep and session lock. |
| `vault.sync.interval_minutes` | Int, 30, 5 to 1440 | Time between two background syncs while unlocked. |
| `vault.fill.dropdown` | Bool, `true` | Show the dropdown on a focused login field. |
| `vault.fill.shortcut` | String, `Ctrl+Shift+L` | The key of the command `vault.fill`. Empty or invalid: no key. |
| `vault.fill.insecure` | String, `ask` | `ask` or `never`, for `http` pages. |
| `vault.save.offer` | Bool, `true` | Offer to save or update a login after a login form is sent (4.10). |
| `vault.totp.autofill` | Bool, `true` | Fill the code into the site's code field that comes within 2 minutes of a login's fill (4.10). |
| `vault.totp.copy_on_fill` | Bool, `false` | Copy the code of a login when the Vault fills it. |
| `vault.generator.kind` | String, `password` | `password` or `passphrase`: what the generator makes first. |
| `vault.generator.length` | Int, 20, 5 to 128 | The length of a generated password. |
| `vault.generator.uppercase`, `.lowercase`, `.numbers`, `.special` | Bool, `true` | The classes of a generated password. |
| `vault.generator.min_numbers`, `.min_special` | Int, 1, 0 to 9 | The fewest digits and special characters. |
| `vault.generator.words` | Int, 5, 3 to 20 | The words of a generated passphrase. |
| `vault.generator.separator` | String, `-` | What goes between its words. |
| `vault.generator.capitalize`, `.include_number` | Bool, `false` | Capital first letters; a digit after a word. |
| `vault.clipboard.clear_seconds` | Int, 30, 0 to 600 | 0: never clear. |
| `vault.passkeys.enabled` | Bool, `true` | Offer the vault as an authenticator (phase 5). |
| `vault.request.timeout_ms` | Int, 15000, 1000 to 120000 | Deadline of one helper request. |
| `vault.helper.path` | String, empty | Override of the helper path. |
| `vault.test.remote` | Bool, `false` | For automated tests only: remote control can drive the Vault surfaces. |

### 4.6 Forms

What `src/forms` has today: control kinds, `Input_Type` (with `Password`, `Email`, `Tel`, `Text`), values with the
`user_edited` flag, form ownership, submission (`submit.odin`). It has no reading of the `autocomplete` attribute and no
login detection.

New, in `src/forms/credentials.odin`, as pure functions over the DOM and the forms model:

- `autocomplete_tokens(node)`: parses the attribute by the HTML rules (section prefix, `username`, `current-password`,
  `new-password`, `one-time-code`, `email`, `webauthn`).
- `login_fields(document, anchor)`: returns the group of the anchor field: user name, current password, new password
  (and its confirmation), one-time code. The group is the field's form, or the nearest common ancestor for fields
  with no form.
- Order of evidence: `autocomplete` tokens; then `type=password`; then for the user name the nearest text, email or tel
  field before the password; then `name`, `id` and `inputmode` hints for one-time codes (`otp`, `totp`, `2fa`, 6 digits).
- A multi-step login (user name page, then password page) gives a group with one field. It is valid.

The fill writes through the forms model as a user edit: it sets `user_edited`, and dispatches `input` and `change` as
typing does. Frameworks then see the value.

The save offer (phase 4) hooks the submission path in `src/forms/submit.odin` through the `Host` (`submitting`); 4.10
says how. The card and address fields are in `src/forms/autofill.odin` (4.10).

### 4.7 Shell surfaces

All are toolkit widgets drawn by the chrome. None is a web page. None lives in a page's DOM, so a page cannot read,
cover or style them.

- **Toolbar button**: one icon with three states (logged out, locked, unlocked) and a count of matches for the tab.
  Hidden when `vault.enabled` is off.
- **Login dialog and unlock dialog**: modal for the window, like `confirm_shell`. The password field is a toolkit
  secure field: masked, no copy, zeroed on close. The dialog shows the account email and the server host.
- **Panel**: anchored to the toolbar button. Lists the matches for the active tab, then a search field. Row actions:
  fill, copy user name, copy password, copy TOTP code, open the site. Footer: sync, lock, settings.
- **Field dropdown**: anchored to the focused login field with the geometry that `forms_shell` records while painting
  (`Painted`). Drawn in the overlay pass, as the select list is. Keyboard: Down opens, Enter fills, Escape closes.
  When locked, it shows one row: "Unlock the vault".
- **Address bar chip**: shown when the active tab has matches. A click opens the panel.
- **Palette source**: a `Palette_Source` with its own prefix. It asks the helper for rows when the palette opens in
  that mode, and releases them on close. Commands: lock, unlock, sync, open the panel, generate a password.
- **Save and update offer**: under the toolbar's Vault button (4.10). It never steals focus. Actions: save, update,
  never for this site, not now.
- **Settings section**: account (email, server, log out), lock, fill, save, clipboard, the license and source link of
  the helper, the "not made by Bitwarden Inc." line. If generic parts emerge (secure text field, anchored list), they
  go into `gui_toolkit`.
- **Strings** go through `i18n`.

### 4.8 Passkeys (phase 5)

Wren's `src/webauthn` keeps the client work: options, RP ID check, `clientDataJSON`, timeouts, extensions.
`platform_vault.odin` implements the `Platform` interface. `make_credential` and `get_assertion` send the authenticator
request to the helper, which runs `bitwarden-fido`'s `Fido2Authenticator`. The helper implements `Fido2CredentialStore`
over the vault, and `Fido2UserInterface` as protocol events that Wren answers with its own prompt (pick a credential,
confirm the creation, unlock first).

The page's conditions do not change (secure context, user activation, focused tab, one ceremony at a time).

Selection between authenticators: when the vault is enabled, a chooser lists "Vault" and "This device or a security
key". For `get()` with an allow list, the helper answers first whether it holds one of the credentials
(`silently_discover_credentials`). If it holds none, Wren goes directly to the system authenticator.
Conditional mediation (`autocomplete="webauthn"`) then becomes possible through the field dropdown.

### 4.9 WebExtensions

`docs/extensions.md` does not exist yet. The Vault does not depend on it and uses none of its mechanisms.

If the user also installs the Bitwarden extension:

- The two run side by side. They share no state and no session. Each has its own login and its own lock.
- A login field then shows two dropdowns: Wren's and the extension's inline menu. Wren does not hide either.
- An extension that replaces `navigator.credentials` in the page takes the passkey call before Wren's code.
- Wren detects the extension by its identifier and shows one line in the Vault settings: use one of the two.
  It disables nothing by itself.
- Wren does not provide the native-messaging host of the Bitwarden desktop application.

### 4.10 Saving, the generator, the code after a login, cards and identities

Protocol 5 (`save`, `generate`, the kinds of items, the fields of cards and identities: [vault-protocol.md](vault-protocol.md)).

- **Save offer** (`vault.save.offer`). `forms.Host.submitting` runs inside a submission, after its validation and before
  its `submit` event (whose listeners may empty the fields), and for `form.submit()` too. The page hands it to the shell
  (`page.Forms_Embedder.submitting`), which reads the form's user name and password (`forms.sent_login`: a filled
  new-password field first) and gives them to `vault_offer_capture`. The Vault compares them with the site's rows: a
  document's set that is ready for that address, else for another address of the same host (the page after a login).
  When none is ready yet (the Vault was unlocked a moment before, the rows are on their way), the offer waits for them
  (`Waiting`) at most 10 s (`OFFER_WAIT_MS`), then is dropped. No login with this user name (case does not matter):
  Save. One: its password is asked of the helper (a `fill` whose answer goes to no hook), then Update if it differs,
  nothing if it is the same. The offer's state machine: `None`, [`Waiting`], [`Checking`], `Save` or `Update`,
  `Saving`, `None`.
- **A login sent by a script** (no form submission: a click handler reads the fields and posts them with `fetch`).
  `forms.Forms.typed_password` is the password field the person last typed into (`set_edit_text`: only the person's
  edits, never a script's value or a fill). A form submission that owns it clears it (`typed_sent`): the submission's
  offer had it. The page asks `forms.unsent_login` once, when the document goes (`page_unload`, `page_freeze` for the
  back/forward cache, `forms_detach` for a closed tab; before `pagehide`, whose listeners may empty the field) or when
  the field leaves the document (the DOM's removal hook; looked at again at the next task, so that a form a script only
  moves is not taken). It gives a login when the field still holds a value that the person typed (a script's value
  over it gives nothing) and is a password field; the user name is the group's (its form, or the fields with no form,
  in the field's own tree: a removed form still holds its fields): autocomplete `username` or `email`, else the nearest
  text field before the password. The page hands it to the shell (`page.Forms_Embedder.login_left`), which captures it
  as a form's login: the offer shows over the tab's next page.
- The offer hangs under the toolbar's Vault button: the host, the user name, Save or Update, Not now, Never for this
  site. It is not modal and takes no focus. Save creates a login named after the host with the page's address; Update
  changes the password (and adds the address when no URI of the login matches it). The rows are asked again after the
  answer. "Never for this site" keeps the host in `<profile>/vault/never_save` (one host a line, written by a blocking
  job, one write at a time); no offer is made there again.
- The captured password is a secret: it is zeroed when it crossed to the helper, at a dismissal, at another capture
  and at a lock.
- **Generator** (`vault.generator.*`). Under a password field that takes a new password (autocomplete `new-password`,
  or two password fields in its form) or of a site with no login yet, the dropdown ends with "Generate a password":
  the helper generates it, and it fills every new password field of the form (the password and its confirmation).
  The shell keeps the value for that form until it is sent, for the save offer. The panel's "Generator…" opens a
  dialog: password or passphrase, its length or its words, its classes; the value is made again at each change, with
  Regenerate and Copy (the clipboard is cleared after `vault.clipboard.clear_seconds`).
- **The code after a login** (`vault.totp.autofill`). After a fill of a login that has a code, when its form had no
  code field, the shell waits 2 minutes for a one-time-code field (`forms.one_time_code_field`) in the focused document
  of the same site (the same registrable domain), and fills the code there once. The document is looked at again only
  when its tree or its attributes change. Never in a frame of another origin or on a plain http page.
  `vault.totp.copy_on_fill` copies the code right after the login's fill.
- **Panel search**: the field at the top of the unlocked panel. Empty: the page's logins. Typed: the whole vault
  (`search`), every kind, "N items" (the helper's `total`) under the field, each row with the icon of its kind and its
  acts: a login fills (when it is one of the page's) and copies its user name, password and code; a card copies its
  number and security code; an identity its email. The list is the toolkit's lazy column (`ui.lazy_begin`): only the
  rows near the view are built. The helper answers one page of 100 rows (`SEARCH_PAGE`); when the rows built come
  within half a page of the last row held, the next page is asked (`vault_search_more`) and appended, one page at a
  time, until `total`. A page of an older query (another `gen` of the set) or of another offset is dropped; a page that
  fails ends the paging of that query and keeps its rows.
- **Cards and identities** (`src/forms/autofill.odin`). `autofill_role` gives a field's role from its autocomplete
  (`cc-name`, `cc-number`, `cc-exp`, `cc-exp-month`, `cc-exp-year`, `cc-csc`, `cc-type`; `name`, `given-name`,
  `additional-name`, `family-name`, `honorific-prefix`, `email`, `tel`, `organization`, `street-address`,
  `address-line1` to `3`, `address-level1` and `2`, `postal-code`, `country`, `country-name`), else from the words of
  its name and id (`cardnumber`, `cvv`, `expmonth`, `firstname`, `zip`, `city`...). A login's role wins over it. The
  dropdown under such a field lists the vault's cards or identities (an empty `search` with `kinds` `["card"]` or
  `["identity"]`, kept in its own set, `Items`, while such a field has the focus; more than 6 rows scroll in a lazy
  column, which asks the next page as it nears the end); a pick fills every field of that kind in the form: an expiry
  date as `MM/YY` or
  `MM/YYYY` by the field's placeholder and maxlength, a select by its option's value or text. Social security,
  passport and licence numbers are never asked.

## 5. Phases

Each phase ends with something the user can try. Each phase adds to a product that works.

### Test strategy (decided)

| Level | What | When it runs |
|---|---|---|
| Odin unit tests | `src/vault` and `src/forms/credentials.odin` against a **fake helper**: an in-process implementation of the transport that answers from a table. Covers the codec, the state machine, deadlines, match rules, zeroing. | Always (`test_all`). |
| Rust tests | The helper against **wiremock** on loopback (the SDK's own test dependency): prelogin, token, 2FA, sync, errors. Fixtures are made once from a test account. | `wrentool test vault` (`cargo test --locked`), in CI. |
| e2e | Wren headless + the real helper + **Vaultwarden** on loopback, with a seeded account. Scenarios in `src/tools/e2e/vault_*.odin`. | Opt-in (`-Vault`). CI on Linux only; the flake provides `vaultwarden`. |
| Manual | One login, sync and fill against bitwarden.com (US and EU) with a real account. | Before each release that changes the helper or the SDK revision. |

No automated test contacts bitwarden.com. Tests wait for a state with a bound, never for a fixed delay.

### Phase 0: foundation

- Record the license decision of section 6.
- `vault/` with `LICENSE`, the pinned SDK, `hello` and the frame codec. `wrentool build vault`, `wrentool test vault`.
- Flake: vendored Git dependencies, a check that builds the helper, hooks for the new Rust and TOML files.
- Measure and write in 2.5: crate count, build time, size. Write in 3.4 what the SDK persists. Check the proxy
  behaviour and the device type value that the server accepts.
- Try: `wrentool vault probe --server http://127.0.0.1:<port>` logs in to a local Vaultwarden and prints the item count.

### Phase 1: enable, log in, unlock, list, fill

- `src/vault`: settings, process start, codec, state machine, fake helper. Requests: `hello`, `login` (email, master
  password, TOTP 2FA), `unlock`, `lock`, `sync` (once after unlock), `logins_for`, `fill`.
- Helper: `Domain` and `Host` matching; state in `state.sqlite`; US server by default, `vault.server.url` for tests.
- `src/forms/credentials.odin`: user name and password fields.
- Shell: the preference in the settings, the install step, the toolbar button, the login and unlock dialogs, the panel
  with the matches of the active tab, fill of the top frame.
- Tests: unit (state machine, match rules with PSL cases such as `github.io`, IP hosts, ports, scheme); Rust (login
  with and without TOTP, wrong password, sync); e2e (enable, log in, fill a form of `examples/site`, check that
  `wren ctl` cannot read rows).
- Try: enable the Vault, log in with TOTP, open a login page, fill it from the panel. Restart Wren, unlock, fill again.

### Phase 2: session life

- Server region (US, EU, self-hosted). Email 2FA, new-device code, API key login, logout.
- PIN unlock, idle lock, lock on sleep, helper self-lock, periodic sync, sync command.
- Tokens in the system store (`ClientManagedTokens`).
- Tests: PIN try counter, lock triggers with an injected clock, token store fallback on Linux without Secret Service.
- Try: use a self-hosted or EU account; leave Wren idle and see it lock; unlock with a PIN.

### Phase 3: fill everywhere

- Fill shortcut, field dropdown, address bar chip, palette source, per-site list, copy actions with clipboard clearing.
- TOTP copy and fill of one-time-code fields. Frames (rule 7). `StartsWith`, `Exact`, `Never`, equivalent domains.
- Tests: dropdown geometry under transforms and scroll, frame rules, palette rows released on close.
- Try: focus a login field and fill from the dropdown with the keyboard only.

### Phase 4: write to the vault

- Save and update prompt, "never for this site", generator in new-password fields, folders in the save prompt.
- Tests: submit detection for form posts and script logins, no prompt in private windows, conflict when the item
  changed on the server.
- Try: create an account on a site with a generated password; accept the save prompt; see the item on another device.

### Phase 5: passkeys

- `platform_vault.odin`, the chooser, `passkey_*` requests, conditional mediation.
- Tests: the WebAuthn vectors of `src/webauthn` against the vault platform; e2e registration and login on a local
  relying party of `src/testserver`.
- Try: register a passkey on a site into the vault, then sign in with it.

### Later

2FA with WebAuthn, Duo and YubiKey; SSO; biometrics unlock; regular expression URIs; site icons.

## 6. Risks and open questions

### Risks

- **SDK instability.** The API changes without notice. Mitigation: one pinned revision, one module that calls it.
- **Server drift.** A new server can refuse an old client. Mitigation: a quarterly SDK update; an error that tells the
  user to update Wren.
- **License change.** Bitwarden can change the license of future SDK versions (it did so in 2024 and 2025). The pinned
  GPL revision stays usable. A fallback exists: implement the protocol without the SDK, as `rbw` does.
- **Legal reading of "separate program".** See 2.3. Not tested in court for this case.
- **Client identity.** The SDK login sends device type `ChromeBrowser`. The server shows the device to the user and can
  apply rules per client type. Phase 0 selects a truthful value and patches the SDK if needed.
- **Account risk.** Bitwarden's terms for its hosted service apply to the user. A third-party client is not forbidden
  today (`rbw` and others exist), but Bitwarden gives no guarantee.
- **Supply chain.** The helper adds some hundreds of crates and two Git dependencies. All are pinned by hash.

### Decisions taken (2026-11-12)

1. License: the GPL-3.0 helper as a separate program.
2. Source: a separate repository, `wren-vault` (locally `../wren-vault`), not a `vault/` directory of Wren. It holds no
   Wren code. It must be public before the first release that offers the Vault.
3. Delivery: download on enable. Phase 1 locates the helper only (see "Implementation state").
4. Naming: "Vault", with "Use a Bitwarden® account" in the settings.
5. Test server: Vaultwarden on loopback, Linux CI only (not written yet).
6. Private CA: the system store.

### Decisions for you (as first written)

1. **License path.** Accept the GPL-3.0 helper as a separate program (recommended), or ask Bitwarden Inc. first for a
   written permission or a commercial agreement. A permission would also allow a static link, but the separate process
   stays the better security design.
2. **Source location of the helper.** A directory `vault/` in the Wren repository with its own GPL license
   (recommended: one build, one version), or a separate public repository. If the Wren repository is private, the
   helper source must be public elsewhere.
3. **Delivery.** Download on enable (recommended: `wren.exe` stays one file), or ship the helper in the installer.
4. **Naming.** "Vault" with "Use a Bitwarden® account" in the settings (recommended), or another name. A name that
   contains "Bitwarden" needs a written permission.
5. **Test server.** Vaultwarden on loopback for opt-in e2e tests, Linux CI only (recommended). The alternative is the
   official self-hosted server in a container, which is heavier. A dedicated test account on bitwarden.com is needed
   for the manual checks: who creates and owns it.
6. **Private CA for self-hosted servers.** Accept "install the CA in the system store" (recommended), or patch the SDK
   client to read `network.tls.extra_ca_file`.

## Implementation state

Phases 0 and 1, and phases 2 and 3 for the most part, as written on 2026-11-12 and 2026-11-13. Where the code differs from the plan above,
this section is the truth.

### The helper (`wren-vault`, a separate repository)

- SDK: `bitwarden/sdk-internal` at `300aea5933ef3bc139e430575b6868b9a9b1d4a7` (workspace 4.0.0). The helper depends on
  the crates it calls (`bitwarden-core` with `internal`, `bitwarden-auth`, `bitwarden-vault`, `bitwarden-sync`,
  `bitwarden-crypto-sync-handler`, `bitwarden-api-api`, `bitwarden-crypto`), not on `bitwarden-pm`: fewer crates to
  build, and the same calls. All SDK calls are in `src/sdk.rs`.
- Login: the helper sends its own token request (`src/identity.rs`), not the SDK's `login_password`, which sends device
  type `ChromeBrowser`, one device identifier for every SDK user, and no new-device code (2.4). No SDK patch is needed.
  The SDK still does the prelogin, the master password hash (`MasterPasswordAuthenticationData::derive`), the sync, the
  keys (`initialize_user_crypto` with the sync's unlock data), the PIN and the items. The request names client id
  `web`, device type 14 (`UnknownBrowser`, also the SDK client's `Device-Type`), the device name `Wren` and the
  account's own random device identifier. A renewal with an API key goes through the SDK and names its fixed device.
- Second steps: the authenticator code (provider 0) and the email code (provider 1; the helper asks the server to mail
  it with the SDK's `send_two_factor_email`, and the server mails it by itself when it is the account's only second
  step); the new-device code as `newDeviceOtp`, sent from the same device identifier as the first step. Duo, WebAuthn
  and YubiKey: `unsupported_two_factor`, and the personal API key logs in (`client_credentials`).
- Sync: the SDK's `SyncClient` with a sync handler of the helper that keeps the encrypted items, the master password
  unlock data, the account keys, the organization keys and the account's email (an API key login learns it there).
- Unlock after a restart: `initialize_user_crypto` with `MasterPasswordUnlock` and the kept unlock data, or with
  `PinEnvelope` and the kept PIN envelope. The refresh token (or the API key) and the login method go back into the
  client's state with an expired empty access token; the SDK's token handler renews it at the first request.
- PIN: `crypto().enroll_pin`; the envelope and a try counter are in `state.json`; the fifth wrong PIN in a row deletes
  the envelope. Not with `browser.profile.persist` off (the helper refuses: `no_state`).
- Tokens (3.4): not `ClientManagedTokens`. The SDK's own token handler keeps the tokens in the client's memory; the
  helper writes the refresh token and an API key's client secret to the system store after each login and sync when
  they changed (`src/tokens.rs`): keyring-core with `dbus-secret-service-keyring-store` (libdbus, synchronous, on
  tokio's blocking threads) on Linux and `windows-native-keyring-store` on Windows; else `tokens.json` (mode 0600).
  The access token is never stored. Only a short text goes to the store: the Credential Manager takes at most 2560
  bytes, less than an access token.
- State: `state.json` version 2 (mode 0600, directory 0700), not the SDK's SQLite database: the SDK's own persistence
  is moving between revisions, and one file of encrypted values is easier to audit. The helper's README lists its
  fields. A version 1 state is not read: the account logs in again.
- Requests run one after the other, in the order they come (not a task each): the answers keep the order of the
  requests, and a `hello` sent with a `login` is always handled first. The loop waits on the next frame and on the idle
  deadline at once (`FrameReader` is cancel safe); at the deadline it writes the event `locked` and exits.
- Protocol 3 (helper 0.3.0, phase 3): `search` (each word of the query in the name, the user name or a URI; sorted by
  name; at most 50 rows; no password); `totp` and `fill` with `totp` (the SDK's `generate_totp`: otpauth, steam and
  base32 keys); `logins_for` applies `StartsWith` and `Exact` (the URL standard's serializations) and the equivalent
  domains. The sync asks for the domains (`excludeDomains=false`) and keeps the groups (the account's own, then the
  global ones it did not exclude) in `state.json` (`equivalent_domains`).
- Not yet: the successful-login fixtures of the wiremock tests (they need a test account), the
  measures of 2.5, the list of what the SDK writes (3.4: the SDK writes nothing; the helper writes `state.json` and
  `tokens.json` or the system store's entry).

### Wren

- `src/vault`: the state machine (`Disabled`, `Locating`, `Helper_Missing`, `Logged_Out`, `Logging_In`,
  `Need_Two_Factor`, `Need_Device_Code`, `Locked`, `Unlocking`, `Unlocked`, `Failed`), the fill's own machine
  (`Requested`, `Answered`, `Applied`, `Dropped`), the codec, the transport, the match check, the settings. Tests run
  it against a fake helper, the timers on a virtual clock.
- Servers: `vault.server.region` (`us`, `eu`, `self`) and `vault.server.url`. The account file
  (`<profile>/vault/account`) holds the email, the server's identity address and the PIN mark; an account of another
  server is not remembered. A private CA: the system store (decision 6), said in the preference and in the dialog.
- Timers of an unlocked Vault, on the loop: the idle lock (`vault.lock.idle_minutes`; input of the browser window
  postpones it, `main.odin` calls `vault_shell_activity` with each frame's events) and the sync
  (`vault.sync.interval_minutes`). Activity sends a `keepalive` at most once a minute; the helper's own deadline is the
  Vault's and 120 s. A change of `vault.lock.idle_minutes` while unlocked moves Wren's timer at once and the helper's
  deadline at the next unlock.
- Threads: writes go through a writer thread per helper, not the blocking pool: one thread keeps the order, and the
  pool's workers do not wait on a pipe. The blocking pool locates the helper, reads and writes the account file (one
  job at a time: a logout's removal is never undone by an older write), checks the rows and joins an ended helper's
  threads.
- Shell (`src/browser/vault_shell.odin`): the toolbar button (in the toolbar row; not yet in the sidebar's title bar),
  its panel (rows, Sync, Lock, Set a PIN / Remove the PIN, Log out), the login dialog (server, email and password or
  API key, then the authenticator or email code, or the new-device code), the unlock dialog (master password or PIN),
  the PIN dialog, the question before a fill on plain http, the fill of the top document.
- Remote control: while it is on (unless `vault.test.remote`), the panel is an empty box, the tooltip is not shown, and
  the dialogs close and zero their fields: a capture of the window shows nothing of the Vault.
- Forms (`src/forms/credentials.odin`): `autocomplete_tokens`, `login_fields`, `fill_field`. A filled field is marked
  (`Control.vault_filled`, until a reset or a script's value): history restoration (`page/history_state.odin`) skips
  it, and a document with a filled field is not kept in the back/forward cache (`Forms.vault_filled`). Session files
  hold no form values at all. The fill clears the field's undo steps.
- The helper is found, not downloaded: `vault.helper.path`, else `wren-vault` beside the browser, else in its `vault`
  folder (`build/vault/` beside `build/wren`). The download on enable (4.1), with the SHA-256 built into Wren (3.7),
  needs release assets of the helper: a later step.
- Automation: `wrentool build vault`, `wrentool vault test`, `wrentool vault probe` (it asks for a second step's code
  on its input).
- Phase 3 (`src/browser/vault_fill.odin`):
  - The target of a fill is the document that holds the focused field: the focused frame's, else the tab's. The Vault
    keeps four sets of rows (`Row_Slot`): the tab's document (`Page`), the focused frame's document (`Frame`), the
    search of the palette or the panel (`Search`), the cards or the identities while a card or address field has the
    focus (`Items`). `Search` and `Items` hold their search page by page. **This changes 3.1**: the rows of the tab's document stay in Wren's memory while the
    Vault is unlocked, not only while a surface shows them: the chip, the fill shortcut and the dropdown need them
    without a round trip to the helper. They are zeroed at a lock, at another address, and when remote control
    starts. Search rows go when the palette closes. No password and no code is ever in a row.
  - Fill shortcut: the command `vault.fill` (Ctrl+Shift+L, `vault.fill.shortcut`; `guarded`: the key is the page's while
    the Vault is off). Locked: the unlock or login dialog. Unlocked: the only row at once; several: the dropdown on a
    login field, else the panel. Other commands: `vault.search`, `vault.unlock`, `vault.lock`, `vault.sync`,
    `vault.panel`.
  - Dropdown: toolkit boxes over the page (`vault_dropdown_build`, after the palette), at the field's painted bounds
    (`forms_control_screen_rect`: the bounds of the transformed box, so a rotated or scrolled field anchors where it
    shows); under the field, above it without room. `hud_captures` keeps presses on it from the page. Keys
    (`vault_dropdown_key`, before the page's keydown, while it shows): Down and Up move (Up past the first row gives the
    keys back to the field), Enter fills the chosen row (no row chosen: Enter is the page's), Escape hides it on this
    field until Down. The field's role (`forms.login_role`: user name, password, one-time code) is computed again only
    when the focus, the document's tree or its attributes change. On a one-time-code field it lists the logins with a
    code and fills the code. Locked: one row, "Unlock the Vault".
  - Chip (`vault_chip`, in `address_chips`): the number of the tab's logins (a click opens the panel); locked, on a
    login field, "Vault locked" (a click opens the unlock dialog).
  - Palette: the source "Vault", prefix `$`, not in the plain search. `items` asks the helper (`vault_search`, once per
    query: the helper searches, off the interface thread) and lists, per login, its acts: "Fill" (only when the item is
    a checked row of the focused document: rule 10), copy the user name, the password or the code, open the site. The
    palette lists the first page (100 rows) and its own fuzzy match runs on those.
  - Per-site list: the panel's rows have Copy user name, Copy password and Copy code. A copy is a `fill` (or `totp`)
    request whose answer goes to the `copy` hook, never to a page. The clipboard is cleared after
    `vault.clipboard.clear_seconds` if it still holds the value: Wren keeps only its hash and length.
  - TOTP: a fill writes the code into the group's one-time-code field (`Login_Fields.one_time_code`: autocomplete
    `one-time-code`, or a name or id with otp, totp, 2fa, mfa..., or a numeric field named code of 4 to 8 characters)
    when the row has a code.
  - Frames (rule 7): `frame_fill_rule`. The frame's own origin and address decide its rows. Same origin as the top
    document: fill. Another origin: the dropdown names it, and each fill asks first (the question names the frame's
    host; a yes fills only the document it was asked for: same tab, same frame or not, same forms model). Opaque
    origin: no rows, no fill. `about:blank` and `srcdoc` frames have no web address: no fill, even with an inherited
    origin. The fill's ticket names the document (`page`, its forms model's id, the field): a frame that went or
    navigated drops the fill.
  - Not yet: rule 6 (no fill after a certificate warning: the browser has no such bypass state to read yet); the
    Windows clipboard history exclusion (3.6: the toolkit's clipboard has no such flag; a `gui_toolkit` change);
    the dropdown in a frame whose fields the shell paints in another document's pass (`Forms_View.painted` holds one
    document at a time: the dropdown then does not show, the shortcut and the panel still fill); the e2e scenarios of
    phase 3.
- Phase 4 and cards (`src/browser/vault_save.odin`, `src/forms/autofill.odin`, protocol 5): see 4.10. Not yet: folders
  in the offer, a conflict when the item changed on the server.
- Not yet: lock on system sleep and session lock (`vault.lock.on_sleep`: the toolkit reports no such event yet); the
  fill on the page thread when `browser.shell.page_thread` is on (the fill runs on the loop thread, as the chrome's
  focus moves do); the e2e tests against Vaultwarden; `about:licenses` listing the helper; the flake's check of the
  helper.
