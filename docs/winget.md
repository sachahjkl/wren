# Publishing Wren on winget

Wren can be offered through the Windows Package Manager (`winget`), so that `winget install FromentSoftware.Wren` installs
it. This is not automatic: a published release does not reach winget on its own. The step below makes the manifest; the
submission to Microsoft's `winget-pkgs` repository is a manual pull request, and only Sacha does it.

There is **no Microsoft Store** package (the Store needs an MSIX and a developer account; the release is a single portable
`.exe`, which winget supports directly as a `portable` installer).

## What the release is

Every release publishes one file, `wren-<version>-windows-x64.exe` (see `tools\package.ps1` and
`.github\workflows\release.yml`), plus `SHA256SUMS.txt` with its SHA-256. It is not an installer: it is the program
itself, which carries its licences, its version and the Visual C++ runtime it needs, and integrates into the desktop from
within (Setup). So the winget installer type is **`portable`**: winget downloads the `.exe`, keeps it, and adds a link
named `wren` to its own links folder (on the `PATH`), so `wren` launches it from a terminal.

## 1. Make the manifest

After the release `vX.Y.Z` is published on GitHub:

```powershell
powershell -NoProfile -File tools\winget_manifest.ps1 -Version X.Y.Z
```

With only `-Version`, the script reads the published release of that version from GitHub
(`api.github.com/repos/sachahjkl/wren`): the download URL of `wren-X.Y.Z-windows-x64.exe` and its SHA-256 from
`SHA256SUMS.txt`. Pass `-Url` and `-Sha256` to override them (an offline run, a mirror, a release not public yet):

```powershell
powershell -NoProfile -File tools\winget_manifest.ps1 -Version X.Y.Z -Url https://.../wren-X.Y.Z-windows-x64.exe -Sha256 <hash>
```

It writes three YAML files under `build\winget\X.Y.Z\` (schema 1.6.0):

- `FromentSoftware.Wren.yaml` — the version manifest;
- `FromentSoftware.Wren.installer.yaml` — the installer (x64, `portable`, the URL, the hash, the `wren` command alias);
- `FromentSoftware.Wren.locale.en-US.yaml` — the English description, publisher, licence and links.

`-Out <folder>` changes where they go; `-PackageIdentifier` and `-Repo` change the identifier and the GitHub repository if
they ever move.

## 2. Check the manifest locally

With winget installed:

```powershell
winget validate build\winget\X.Y.Z
winget install --manifest build\winget\X.Y.Z    # a real install from the local manifest, to try it
```

`winget validate` must pass with no error. An install should put `wren` on the `PATH` and `winget list` should show
`FromentSoftware.Wren`. `winget uninstall FromentSoftware.Wren` removes it.

## 3. Submit the pull request (Sacha only)

The manifests live in Microsoft's community repository, `microsoft/winget-pkgs`, under
`manifests\f\FromentSoftware\Wren\X.Y.Z\`. To submit:

1. Fork `microsoft/winget-pkgs` (once).
2. Copy the three files from `build\winget\X.Y.Z\` into `manifests\f\FromentSoftware\Wren\X.Y.Z\` of the fork.
3. Open a pull request. The repository's CI validates the manifest and installs the package in a sandbox; a reviewer or
   the automated moderator merges it.

Alternatively, `wingetcreate update FromentSoftware.Wren --version X.Y.Z --urls <exe url>` can make and submit the update
in one step once the package exists; the files this script writes are the same shape and can seed the first submission.

Do **not** let any script submit automatically: the pull request is reviewed and merged by hand.

## The package identifier

The identifier is `FromentSoftware.Wren`, which matches the program's AppUserModelID (`FromentSoftware.Wren`,
`src\browser\desktop_shell.odin`) and the publisher "Froment Software". If the winget publisher moniker is ever chosen
differently (for example `SachaFroment`), pass `-PackageIdentifier` to the script and use the same folder path under
`manifests\` in the pull request.
