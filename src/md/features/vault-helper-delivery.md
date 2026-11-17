# The Vault's helper: release, delivery, updates

The Vault runs `wren-vault`, a separate GPL-3.0-only program in its own public repository (`sachahjkl/wren-vault`;
[docs/bitwarden.md](../../../docs/bitwarden.md), 2.3). Every Wren user must have it with nothing to install. This file
says how wren-vault is released, how it reaches a user, and how it stays current. It replaces the plan of 4.1 and 3.7
of docs/bitwarden.md.

## The irreducible constraints

- The helper is not a part of `wren.exe` (licence verdict, condition 2): no link, no `#load` as `wren.com` has.
- Each Wren speaks one protocol version. A helper of another version answers `bad_protocol`, or worse, answers
  differently. So **Wren chooses its helper**: a helper newer than the one Wren was tested with must never arrive behind
  its back.
- The Windows release is one file, `wren-<version>-windows-x64.exe`: the winget manifest, Setup and the update
  (the toolkit's Updater, `updates.odin`) all take one program. It has no archive to put a second file in.
- The Linux release is a `tar.gz`: a folder, where a second program and its licence can sit beside `wren`.
- Wren runs only a helper it can vouch for: in a release, the bytes of the helper are known in advance.

## The design

One file pins the helper: `vault.version` at the root of Wren. It names a wren-vault version and, for each platform,
the size and the SHA-256 of its program. Wren's binary embeds it (`src/vault/pin`). Everything else follows from it.

```
version 0.5.0
windows-x64 14680064 <64 hex>
linux-x64 13107200 <64 hex>
```

### 1. A wren-vault release

- The automation is `wrentool vault` (Wren's Odin tool); wren-vault has no tool of its own. Reasons: the project rule
  (automation is a command of an Odin tool); the manifest and its signature are the toolkit's `gt:update`, in Odin; a
  second tool in wren-vault would copy that code, or put the toolkit into a GPL repository. wrentool is a build tool:
  none of its code goes into the helper.
- `wrentool vault prepare <version>` (in the checkout of `WREN_VAULT_SOURCE`, `../wren-vault` by default): assembles
  wren-vault's `changelog.d/` into its `CHANGELOG.md` (the changelog command, with the repository of wren-vault in the
  link references), writes the version in `Cargo.toml` and `Cargo.lock`. The person commits, then tags `v<version>`
  (annotated) and pushes the tag.
- wren-vault's `.github/workflows/release.yml`, on the tag: checks the tag against `Cargo.toml` and the changelog's
  section; builds the program on `windows-2025` and in `debian:bookworm` (glibc 2.36, the oldest Wren's Linux build
  needs), Rust 1.99.1, `cargo build --release --locked`, then `cargo test --locked`; a last job checks out Wren, builds
  wrentool, and runs `wrentool vault sign -Dir dist -Version <version>`, then publishes the release.
- What a release publishes (the toolkit's update format, product `wren-vault`, no channels):

  | Asset | What it is |
  |---|---|
  | `wren-vault-<v>-windows-x64.exe`, `wren-vault-<v>-linux-x64` | the program (`update.expected_file_name`) |
  | `update-windows-x64.json`, `update-linux-x64.json` | the manifests: version, platform, file, size, SHA-256 |
  | the same names + `.sig` | Ed25519 signature of `wren-vault-update-v1\n` + the manifest |
  | `SHA256SUMS.txt` | the programs' SHA-256, for a person who checks by hand |
  | the tag's source archives (GitHub's) | the complete source of that build (licence verdict, condition 5) |

- The key: an Ed25519 key of its own, not Wren's update key (a stolen helper key must not ship a Wren). Its public half
  is `vault_pin.PRODUCT.public_key`; its private half is the secret `WREN_VAULT_SIGNING_KEY` of the wren-vault
  repository, kept in Wren's `secrets/production.yaml` under the same name. `wrentool vault sign` refuses a key whose
  public half is not the one built in: a release no `vault pin` can check is never published.

### 2. Wren pins a release

`wrentool vault pin <version>` downloads the two manifests and their signatures from the release, checks them with the
public key built in (`update.verify`, for each platform, and the version asked), and writes `vault.version`. A
developer commits it with the Wren change that needs that helper (a new protocol, a fix). The pin is checked once, by
the person who changes it; the binary then carries exact bytes, which proves more than a signature (any release of the
key) and needs no key in the browser.

### 3. What a Wren release carries

- Linux: `wrentool package` puts, beside `wren` in the tar.gz, `wren-vault`, `wren-vault-LICENSE.txt` (the GPL text,
  from the tag) and `wren-vault-SOURCE.txt` (the version, the tag's source address, a line saying it is a separate
  program). It gets them with `wrentool vault fetch` (in `build/vault/pinned/<version>/`), which checks the program
  against the pin. A pin without a `linux-x64` line stops the package: a release without its helper is not one.
  This is simple aggregation of two programs in one archive, which the GPL allows.
- Windows: nothing more. The one file stays one file; the helper comes at the first use (below). `wrentool package`
  refuses a release (not `-Dev`, no label) whose pin has no `windows-x64` line.
- A development build keeps `wrentool build vault` (`build/vault/wren-vault`, beside `build/wren`'s `vault/` folder).

### 4. What a running Wren does

The setup job of the Vault (on the blocking pool, `src/vault`) decides where the helper is. Three cases, by the build:

| Build | Where | Checked |
|---|---|---|
| development (`IS_DEV_BUILD`) | `<exe dir>/vault/wren-vault`, else beside | no: the developer's own build |
| in the Nix store | beside (`libexec/wren/`: `bin/wren` is a wrapper; the flake fetches the pinned program by `vault.version`) | no: the package manager's |
| release | beside `wren(.exe)` | its size and SHA-256 must be the pin's |

In a release, a helper that is missing or not the pinned one makes the state `Installing`: the shell downloads
`<release folder of the pinned version>/<file>` with Wren's own fetch (at most the pinned size), the Vault places it
on the pool (the pin's size and SHA-256 again, a program of this system, written as `<path>.update`, read back,
renamed), then locates it again. A failure is `Helper_Missing` with the reason, and the panel offers "Try again". The
panel says what comes while it downloads: the version, GPL-3.0, the source's address.

### 5. How it stays current

A new Wren pins a new helper. Its first setup job finds the old helper beside it, not the pinned one, and replaces it
before the first unlock. On Windows the update of Wren is the toolkit's Updater (`updates.odin`); on Linux a person
extracts a new tar.gz, which carries the new helper. No second updater runs, and no helper changes without a Wren.

## Refused

- **A second toolkit Updater for the product wren-vault, following its latest release.** A helper of a newer protocol
  would reach every Wren that does not speak it: the day wren-vault 0.6.0 ships protocol 6, every installed Wren's
  Vault breaks. It also adds a daily check, a second key in the browser and the question of the current version of a
  file that no process runs.
- **The toolkit's manifest carrying a companion file.** It changes the format of every program's update for one
  product. Wren's own update is not the toolkit's Updater, and the Linux release has no updater: it would serve only
  the Windows update, which the pin already covers.
- **Wren's release re-publishing the helper in its own assets.** Wren's release would then convey GPL object code and
  must carry the source offer too. Downloading from wren-vault's release takes the program from the place that also
  holds its source.
- **The helper inside `wren.exe`, written beside it by Setup.** Condition 2 of the licence verdict.
- **`<data dir>/vault/<version>/` (the plan of 4.1).** A second place to search, and old versions to delete. Beside the
  executable is where every package (the tar.gz, Nix) puts it, and the one place `locate` reads.
- **`vault.helper.path`.** Every case has its place: a release beside, a development build in `build/vault/`, a package
  beside. A path from a preference would run a helper that nothing checked; tests give the folder to the Vault
  directly (`Vault.helper_dir`). Removed, with its row in the settings.

## Subtleties

- Placement on Windows: `update.place` renames the program in place aside first, so it refuses a first placement (no
  file yet). The Vault writes `<path>.update`, reads it back and renames it when no file is there; else it calls
  `update.place`. The running helper is never replaced: the job runs only before a helper is started, and a helper
  that runs keeps its file open (Linux) or was renamed aside (Windows: `.old`, removed at the next setup job).
- A standalone copy of Wren in a downloads folder writes `wren-vault.exe` there at the first use of the Vault. Setup's
  install folder gets its own at its first use: the toolkit's Setup does not copy a companion file yet.
- The setup job hashes the helper at each enable (about 15 MB, some tens of milliseconds, on the pool).
- Before the first wren-vault release, `vault.version` names a version and no platform: a release build cannot get a
  helper and says so; the Linux package stops.
