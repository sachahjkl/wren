# Secrets

SOPS-encrypted secrets of the licence system (see `docs/licence.md`). The files here are meant to be committed: their
values are encrypted for the maintainer's age key.

| File | Use |
|---|---|
| `development.yaml` | the development pair: its seed is public on purpose (`src/license/dev_keys.odin`), for tests, screenshots and `tools\license.ps1 issue -dev` |
| `production.yaml` | the real signing key and the services' keys, used to deploy `licence/worker` |

Fields (the Worker's `licence/worker/src/env.ts`):

| Key | What it is |
|---|---|
| `LICENSE_PRIVATE_KEY` | the 32-byte Ed25519 seed, base64url: the line of `%USERPROFILE%\.wren-license\private.key` that is not a `#` comment (`tools\license.ps1 keygen`) |
| `PADDLE_WEBHOOK_SECRET` | Paddle > Developer tools > Notifications > the destination > Secret key (`pdl_ntfset_...`) |
| `PADDLE_API_KEY` | Paddle > Developer tools > Authentication > API keys (server side, `customer.read`) |

Code signing of the executables (`tools\sign.ps1`, called by `tools\package.ps1`):

| Key (`development.yaml`) | What it is |
|---|---|
| `CODESIGN_TEST_PFX_BASE64` | a **self-signed test certificate** (RSA 3072, SHA-256, `CN=Froment Software (self-signed test certificate)`, thumbprint `58FB196C112DD2E5B16550D03770E87768C27F4E`, valid until 2028-10-23), as a base64 PFX. It exercises the signing, timestamp and verification of the release pipeline. **Windows does not trust it**: a file signed with it is as unknown to SmartScreen and to antivirus engines as an unsigned one. Never ship a release with it. |
| `CODESIGN_TEST_PFX_PASSWORD` | the password of that PFX |

To sign with it: decode the PFX to a file, then `SIGN_PFX=<file> SIGN_PFX_PASSWORD=<password> SIGN_TEST=1 powershell -File tools\sign.ps1 -Files wren.exe`.

A real certificate does not go here as a PFX: since 2023 certificate authorities keep the private key of a public code
signing certificate in a hardware module or a cloud service, never in an exportable file. What `production.yaml` will hold
is the **credentials of the signing service** (for example the Azure service principal, or SignPath's API token); the
variables `tools\sign.ps1` reads are described in its header.

The mail of the licence needs no secret: the Worker sends it through its Cloudflare Email Service binding (`EMAIL`;
`MAIL_FROM` is a plain setting, see `docs/licence.md`).

## Key

The age identity is the maintainer's, outside the repository:

```
~/.config/sops/age/keys.txt        (WSL; the recipient is in .sops.yaml at the repository root)
```

`C:\Users\sacha\.config\sops\age\keys.txt` is the same path on the Windows side; keep both in step if you use one from
Windows.

## Editing

From WSL (sops and age are in the nix profile):

```sh
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops /mnt/s/wren/secrets/production.yaml
```

Or in place, without opening an editor:

```sh
sops --set '["LICENSE_PRIVATE_KEY"] "…"' /mnt/s/wren/secrets/production.yaml
```

## Deploying the Worker

The Worker takes a dotenv file of secrets (`licence/worker/README.md`):

```sh
sops --decrypt --output-type dotenv /mnt/s/wren/secrets/production.yaml > /mnt/s/wren/licence/worker/secrets.env
```

`licence/worker/secrets*.env` is git-ignored; delete the file once the secrets are uploaded.

## Rules

- Never commit a decrypted copy: `secrets/*.plain.*` is git-ignored, keep it that way.
- The production seed signs every licence: back it up outside this computer (a password manager), and never put it in a
  build or a page.
