# Updates

Wren can install a new release itself. It never does so without you pressing "Install the update" in About Wren (or running the command of that name), and it only installs a program that Froment Software signed.

## How it works

1. **Check.** "Check for updates" (or the daily check, off by default: `browser.update.check_daily`) asks GitHub for the latest release.
2. **Verify.** For a newer release, Wren fetches `update-windows-x64.json` and `update-windows-x64.json.sig`. It checks, in this order: the Ed25519 signature with the update key built into Wren; that the manifest is for this platform; that its version is the one announced; that it is strictly newer than this program (no downgrade).
3. **Install.** The program is downloaded to memory; its length, then its SHA-256, must be the signed ones. It is written beside the program (`wren.exe.update`), read back and compared again; then the running file is renamed to `wren.exe.old` and the new one renamed in. If any step fails, the old program stays as it was.
4. **Restart.** The new version runs at the next start; the `.old` file is deleted then.

## Limits

- Windows only for now. On Linux Wren checks and tells you where the file is.
- Development and labelled builds are not releases: they are updated by hand.
- The update key is not the licence key. A leaked licence key cannot sign an update.

## Your own channel

A channel is four settings in `about:config`:

| Setting | Meaning | Default |
| --- | --- | --- |
| `browser.update.url` | What announces a release (a JSON document with `tag_name` and `html_url`, as GitHub's "latest release" answers) | the GitHub API of this repository |
| `browser.update.base_url` | Where the files are: `<base>v<version>/update-windows-x64.json`, its `.sig` and the program. `https://` (or `http://127.0.0.1`/`localhost`), ending in `/` | the GitHub releases of this repository |
| `browser.update.public_key` | The key (base64url, 32 bytes) the manifest must be signed with | empty: the key built into Wren |
| `browser.update.require_signature` | Refuse a manifest that is not validly signed | on |

Sign your manifests with `wrentool update keygen` / `manifest` / `sign`. Turning `require_signature` off makes Wren take an unsigned manifest: only the length and SHA-256 are then checked, which proves nothing about who made the file, and About Wren says "UNSIGNED". The version rules (for this platform, the announced version, strictly newer) apply either way.

## For maintainers

- The private key is `UPDATE_SIGNING_KEY` in `secrets/production.yaml` and the GitHub secret `WREN_UPDATE_SIGNING_KEY`. The public key is `src/update/public_key.odin`.
- `wrentool update keygen`, `pubkey`, `manifest`, `sign`, `verify`. The release workflow runs `wrentool package -RequireUpdateManifest` and publishes both files.
- Preferences for tests: `browser.update.base_url`, `browser.update.public_key`, `browser.update.allow_development_build`.
