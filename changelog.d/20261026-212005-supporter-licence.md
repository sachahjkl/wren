type: Added

**Supporter licence** ([docs/licence.md](docs/licence.md)): a key signed offline with Ed25519 and checked in Wren without any network access, entered in `about:wren` (paste it, choose a file, or drop a `.wrenlicense` file). It changes one line of `about:wren` and nothing else: every version stays free and complete during the beta. `tools\license.ps1` makes the key pair and issues licences; `browser.license.*` preferences.
