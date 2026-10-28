# Fetch the pinned Unicode Character Database files, verify their SHA-256, then run the Odin generator that writes
# src/engine/unicode/tables_generated.odin. Same idiom as tools/build_js.ps1 (pinned URL + SHA, cached download).
#
# The Unicode version and every file's SHA-256 are pinned below. A download whose hash does not match is deleted
# and the script fails: the generated tables are reproducible from the authoritative source, never copied from
# QuickJS's libunicode-table.h.
#
#   powershell -NoProfile -File tools\gen_unicode.ps1 [-Force]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$ver  = '17.0.0'
$cache = Join-Path $root "build\ucd\$ver"
$out   = Join-Path $root 'src\engine\unicode\tables_generated.odin'
$base  = "https://www.unicode.org/Public/$ver/ucd"

# path (relative to the UCD root) => pinned SHA-256 (empty string = learn-on-first-run, printed for pinning).
$files = [ordered]@{
  'UnicodeData.txt'                       = '2E1EFC1DCB59C575EEDF5CCAE60F95229F706EE6D031835247D843C11D96470C'
  'DerivedCoreProperties.txt'             = '24C7FED1195C482FAAEFD5C1E7EB821C5EE1FB6DE07ECDBAA64B56A99DA22C08'
  'PropList.txt'                          = '130DCDDCAADAF071008BDFCE1E7743E04FDFBC910886F017D9F9AC931D8C64DD'
  'Scripts.txt'                           = '9F5E50D3ABAEE7D6CE09480F325C706F485AE3240912527E651954D2D6B035BF'
  'ScriptExtensions.txt'                  = 'EC2107E58825A1586ACEE8E0911CE18260394AC8B87E535CA325F1CCBEB06BC6'
  'CaseFolding.txt'                       = 'FF8D8FEFBF123574205085D6714C36149EB946D717A0C585C27F0F4EF58C4183'
  'SpecialCasing.txt'                     = 'EFC25FAF19DE21B92C1194C111C932E03D2A5EAF18194E33F1156E96DE4C9588'
  'DerivedNormalizationProps.txt'         = '71FD6A206A2C0CDD41FEB6B7F656AA31091DB45E9CEDC926985D718397F9E488'
  'extracted/DerivedGeneralCategory.txt'  = 'D62E5BAB70CA74F099343F71224FA051CB1FDD61A1AB45C0488C44CFC0B6102E'
  'emoji/emoji-data.txt'                  = '2CB2BB9455CDA83E8481541ECF5B6DFDA66A3BB89EFA3FA7C5297ECCF607B72B'
}

function Sha256Of([string]$path) {
  $h = [Security.Cryptography.SHA256]::Create()
  $s = [IO.File]::OpenRead($path)
  try { return ([BitConverter]::ToString($h.ComputeHash($s)) -replace '-', '').ToUpper() } finally { $s.Dispose(); $h.Dispose() }
}

New-Item -ItemType Directory -Force $cache | Out-Null
foreach ($rel in $files.Keys) {
  $want = $files[$rel]
  $dst  = Join-Path $cache $rel
  if ((Test-Path $dst) -and (-not $Force) -and $want -and (Sha256Of $dst) -eq $want) { continue }
  New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
  $url = "$base/$rel"
  Write-Host "downloading $url"
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing
  $got = Sha256Of $dst
  if ($want) {
    if ($got -ne $want) { Remove-Item $dst -Force; throw "SHA-256 mismatch for $url`: expected $want, got $got" }
  } else {
    Write-Host "  pin this SHA-256 for $rel : $got"
  }
}

# A VERSION marker the Odin generator stamps into the output.
Set-Content -Path (Join-Path $cache 'VERSION') -Value $ver -NoNewline -Encoding ascii

$genExe = Join-Path $root 'build\unicode_gen.exe'
& odin build (Join-Path $root 'src\engine\unicode\gen') "-out:$genExe" -o:speed
if ($LASTEXITCODE -ne 0) { throw 'generator build failed' }
& $genExe $cache $out
if ($LASTEXITCODE -ne 0) { throw 'generator run failed' }
Write-Host "wrote $out"
