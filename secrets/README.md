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
