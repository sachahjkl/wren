# Updates

Wren on Windows installs a new release itself, and only a program that Froment Software signed. The update state is in
about:settings, on the System page, under **Update by itself**: what the updater knows, **Check now**, **Install** when a
version is on offer, **Restart now** once it is in place. The status bar shows the same offer.

## How it works

1. **Check.** The updater reads `update-windows-x64.json` and `update-windows-x64.json.sig` of the latest release
   (`https://github.com/sachahjkl/wren/releases/latest/download/`). It checks the Ed25519 signature with the update key
   built into Wren, then that the manifest is for this platform and strictly newer than this program (no downgrade).
2. **Install.** The program is downloaded to memory; its length, then its SHA-256, must be the signed ones. It is written
   beside the program, read back and compared again; then the running file is renamed to `wren.exe.old` and the new one
   renamed in. If any step fails, the old program stays as it was.
3. **Restart.** The new version runs at the next start (**Restart now** starts it once this Wren has closed); the `.old`
   file is deleted then.

With **Update by itself** on (`update.auto`, off by default), the installed copy checks a while after the start, then
once a day, and installs what it finds. Any other copy (a standalone or portable one) checks only when you ask.

## Limits

- Windows only. The Linux release is a tar.gz, and the Nix package is updated by Nix: "Check for updates" opens the
  release page.
- Development and labelled builds are not releases: they have no updater and are updated by hand.
- The update key is not the license key. A leaked license key cannot sign an update.

## Another folder of releases

`update.base_url` (about:settings, System, Advanced) names a folder that holds `update-windows-x64.json`, its `.sig` and
the program, as a release publishes them. Its manifests are signed with Wren's key all the same.

## For maintainers

- The check, the download and the placement are the toolkit's (`prefs_page.Updates` over `update.Updater`:
  `ext/gui_toolkit/src/update`, its `docs/update.md`); `src/browser/updates.odin` gives them Wren's product
  (`src/update/product.odin`: name, signing context, key) and its repository. Intent: `src/md/features/settings-pages.md`.
- The private key is `UPDATE_SIGNING_KEY` in `secrets/production.yaml` and the GitHub secret `WREN_UPDATE_SIGNING_KEY`.
  The public key is `PRODUCT.public_key` in `src/update/product.odin`.
- `wrentool update keygen`, `pubkey`, `manifest`, `sign`, `verify`. The release workflow runs
  `wrentool package -RequireUpdateManifest` and publishes both files with the program.
