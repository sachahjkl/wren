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
$ver  = '16.0.0'
$cache = Join-Path $root "build\ucd\$ver"
$out   = Join-Path $root 'src\engine\unicode\tables_generated.odin'
$base  = "https://www.unicode.org/Public/$ver/ucd"

# path (relative to the UCD root) => pinned SHA-256 (empty string = learn-on-first-run, printed for pinning).
$files = [ordered]@{
  'UnicodeData.txt'                       = 'FF58E5823BD095166564A006E47D111130813DCF8BF234EF79FA51A870EDB48F'
  'DerivedCoreProperties.txt'             = '39D35161F2954497F69E08BDB9E701493F476A3D30222DE20028FEDA36C1DABD'
  'PropList.txt'                          = '53D614508E2A0B2305A8AA21CD60D993DE9326CDF65993660DFCCE4503548583'
  'Scripts.txt'                           = '9E88F0A677DF47311106340BE8EDE2ECDACD9C1C931831218D2BE6D5508E0039'
  'ScriptExtensions.txt'                  = '049117CE26B9769FE2749B06EEF51A50A89FAEF4A97764DD2D81DAA715980700'
  'CaseFolding.txt'                       = '6F1F9C588EB4A5C718D9E8F93B782685E5C7FEC872CF05E8E6878053599E09BB'
  'SpecialCasing.txt'                     = '8D5DE354EEF79F2395A54C9C7DCEBBAF3D30FC962D0F85611EA97AA973A0C451'
  'DerivedNormalizationProps.txt'         = '4D4C03892DEA9146D674B686E495DF2D55A28D071AC474041D73518F887ABDDC'
  'extracted/DerivedGeneralCategory.txt'  = '7676AB755A41EF82108460238569E60AD65C191DDAFE61B36C6765EC1353F293'
  'emoji/emoji-data.txt'                  = 'F1365A5173EEE18E1F98B240CDC492E84A25F1CE7E0C9D1094EB29C41A22696A'
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
