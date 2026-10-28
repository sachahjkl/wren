# Build the QuickJS-ng reference shim DLL and the Odin differential harness, then run it. The harness compares
# the Odin regexp/unicode engine against the reference C over thousands of inputs and prints divergences plus a
# ns/exec speed comparison. Test infrastructure only (not part of Wren).
#
#   powershell -NoProfile -File tools\rx_diff.ps1 [-Seed 12345] [-Fuzz 20000] [-NoC]
param([int]$Seed = 12345, [int]$Fuzz = 20000, [switch]$NoC)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$cref = Join-Path $root 'build\cref'
New-Item -ItemType Directory -Force $cref | Out-Null

# Copy the pinned QuickJS 0.17 sources used as the reference (same tree tools\build_js.ps1 fetches). The fetched
# tree may live in this worktree or in the main checkout (S:\wren); the files may also already be in build\cref.
$qjsCandidates = @(
    (Join-Path $root 'build\js\src\quickjs-0.17.0'),
    'S:\wren\build\js\src\quickjs-0.17.0'
)
$needed = 'libregexp.c','libregexp.h','libregexp-opcode.h','libunicode.c','libunicode.h','libunicode-table.h','cutils.h'
$haveAll = $true
foreach ($f in $needed) { if (-not (Test-Path (Join-Path $cref $f))) { $haveAll = $false } }
if (-not $haveAll) {
    $qjs = $qjsCandidates | Where-Object { Test-Path (Join-Path $_ 'libregexp.c') } | Select-Object -First 1
    if (-not $qjs) { throw "QuickJS 0.17 sources not found; run tools\build_js.ps1 first" }
    foreach ($f in $needed) { Copy-Item -Force (Join-Path $qjs $f) $cref }
}

Push-Location $cref
try {
    & zig cc -shared -O2 -o creflib.dll shim.c libregexp.c libunicode.c -D_CRT_SECURE_NO_WARNINGS
    if ($LASTEXITCODE -ne 0) { throw 'C shim build failed' }
} finally { Pop-Location }

# A big stack: the reference lre_exec recurses while backtracking.
& odin build (Join-Path $root 'src\engine\regexp\diff') "-collection:wb=$($root)\src" "-out:$cref\rxdiff.exe" -o:speed '-extra-linker-flags:/STACK:268435456'
if ($LASTEXITCODE -ne 0) { throw 'harness build failed' }

if ($NoC) { $env:RXDIFF_NO_C = '1' } else { Remove-Item Env:\RXDIFF_NO_C -ErrorAction SilentlyContinue }
Push-Location $cref
try {
    & .\rxdiff.exe $Seed $Fuzz
    $code = $LASTEXITCODE
} finally { Pop-Location }
Write-Host "rxdiff exit code: $code"
exit $code
