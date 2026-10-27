# Makes the winget manifest for a published Wren release: the three YAML files winget wants (version, installer, locale),
# ready to put under manifests\f\FromentSoftware\Wren\<version>\ of a fork of microsoft/winget-pkgs and open a pull
# request with. It does NOT submit anything (that is Sacha's to do: see docs\winget.md).
#
#   powershell -NoProfile -File tools\winget_manifest.ps1 -Version 0.4.0
#   powershell -NoProfile -File tools\winget_manifest.ps1 -Version 0.4.0 -Url <exe url> -Sha256 <hash>
#   powershell -NoProfile -File tools\winget_manifest.ps1 -Version 0.4.0 -Out build\winget
#
# With only -Version it reads the published release of that version from GitHub (the releases API of the repository the
# update check uses, github.com/sachahjkl/wren): the download URL of wren-<version>-windows-x64.exe and its SHA-256 from
# SHA256SUMS.txt. -Url and -Sha256 override that (an offline run, a mirror, a release not public yet). The release is a
# single portable .exe (tools\package.ps1, release.yml), so the installer type is "portable".
#
# What it writes (schema 1.6.0, the manifest version winget's 1.6+ clients read):
#   FromentSoftware.Wren.yaml                 the version manifest (points at the two below)
#   FromentSoftware.Wren.installer.yaml       the installer (architecture, type, URL, hash, the command the portable exe
#                                             is reached by on the PATH)
#   FromentSoftware.Wren.locale.en-US.yaml    the English description, publisher, licence and links
# Validate them with `winget validate <folder>` and test an install with `winget install --manifest <folder>` before the
# pull request (docs\winget.md).

param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Url = '',
    [string]$Sha256 = '',
    [string]$Out = '',
    [string]$Repo = 'sachahjkl/wren',
    [string]$PackageIdentifier = 'FromentSoftware.Wren'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# the version is clean (winget: digits and dots); the exe name matches tools\package.ps1
$ver = $Version.TrimStart('v')
if ($ver -notmatch '^[0-9]+(\.[0-9]+)*$') { throw "version '$Version' is not a dotted number (e.g. 0.4.0)" }
$exeName = "wren-$ver-windows-x64.exe"
$tag = "v$ver"

# the download URL and the SHA-256: given, or read from the published release
if (-not $Url) { $Url = "https://github.com/$Repo/releases/download/$tag/$exeName" }
if (-not $Sha256) {
    Write-Host "Reading the release $tag of $Repo for the SHA-256 of $exeName ..."
    $headers = @{ 'User-Agent' = 'wren-winget-manifest'; 'Accept' = 'application/vnd.github+json' }
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$tag" -Headers $headers
    $sumsAsset = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
    if (-not $sumsAsset) { throw "the release $tag has no SHA256SUMS.txt: pass -Sha256 explicitly" }
    $sums = (Invoke-WebRequest -Uri $sumsAsset.browser_download_url -Headers $headers).Content
    $line = ($sums -split "`n") | Where-Object { $_ -match [regex]::Escape($exeName) } | Select-Object -First 1
    if (-not $line) { throw "SHA256SUMS.txt does not mention $exeName" }
    $Sha256 = ($line -split '\s+')[0]
}
$Sha256 = $Sha256.ToUpperInvariant()
if ($Sha256 -notmatch '^[0-9A-F]{64}$') { throw "the SHA-256 '$Sha256' is not 64 hex characters" }

if (-not $Out) { $Out = Join-Path $root "build\winget\$ver" }
New-Item -ItemType Directory -Force $Out | Out-Null

$manifestVersion = '1.6.0'
$releaseDate = (Get-Date -Format 'yyyy-MM-dd')

# The version manifest: ties the package identifier to the installer and locale files below.
$version = @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.version.1.6.0.schema.json
PackageIdentifier: $PackageIdentifier
PackageVersion: $ver
DefaultLocale: en-US
ManifestType: version
ManifestVersion: $manifestVersion
"@

# The installer manifest: one portable x64 .exe. `Commands` is what the user types after `winget install`: winget adds the
# exe to its own links folder (on the PATH) under that name, so `wren` launches it.
$installer = @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.installer.1.6.0.schema.json
PackageIdentifier: $PackageIdentifier
PackageVersion: $ver
InstallerType: portable
Commands:
  - wren
ReleaseDate: $releaseDate
Installers:
  - Architecture: x64
    InstallerUrl: $Url
    InstallerSha256: $Sha256
    InstallerType: portable
    NestedInstallerFiles:
      - RelativeFilePath: $exeName
        PortableCommandAlias: wren
ManifestType: installer
ManifestVersion: $manifestVersion
"@

# The locale manifest: what winget shows (description, publisher, licence, links). The release carries its own licences
# (about:licenses); the program's own licence is PolyForm Strict.
$locale = @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.defaultLocale.1.6.0.schema.json
PackageIdentifier: $PackageIdentifier
PackageVersion: $ver
PackageLocale: en-US
Publisher: Froment Software
PublisherUrl: https://froment.software
PublisherSupportUrl: https://sachahjkl.github.io/wren/support.html
PackageName: Wren
PackageUrl: https://github.com/$Repo
License: PolyForm Strict License 1.0.0
LicenseUrl: https://polyformproject.org/licenses/strict/1.0.0/
Copyright: Copyright (c) Sacha Froment
ShortDescription: A small browser where WebAssembly runs everything, JavaScript included.
Description: |-
  Wren is a web browser written in Odin where WebAssembly is the only execution engine: there is no separate JavaScript
  virtual machine for the platform, and the web APIs are WebAssembly imports. The JavaScript interpreter runs page
  scripts only; everything else of the browser is native. The release is a single portable executable with no installer:
  it carries its own licences, version and the Visual C++ runtime it needs. Run it, or install the desktop integration
  from within the program (Setup).
Moniker: wren
Tags:
  - browser
  - web-browser
  - webassembly
  - wasm
  - odin
ManifestType: defaultLocale
ManifestVersion: $manifestVersion
"@

# winget-pkgs wants CRLF and a trailing newline in every file.
function Write-Yaml([string]$name, [string]$text) {
    $path = Join-Path $Out $name
    [IO.File]::WriteAllText($path, (($text -replace "`r?`n", "`r`n").TrimEnd() + "`r`n"))
    Write-Host "wrote $path"
}
Write-Yaml "$PackageIdentifier.yaml" $version
Write-Yaml "$PackageIdentifier.installer.yaml" $installer
Write-Yaml "$PackageIdentifier.locale.en-US.yaml" $locale

Write-Host ''
Write-Host "winget manifest for $PackageIdentifier $ver is in $Out"
Write-Host "Next: winget validate `"$Out`"  then  winget install --manifest `"$Out`"  (see docs\winget.md). Do not submit automatically."
