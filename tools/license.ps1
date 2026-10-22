# Wren licences (docs/licence.md): the signing key pair and the licences issued to supporters. Offline.
#   tools\license.ps1 keygen [-private FILE] [-force]
#   tools\license.ps1 pubkey [-private FILE | -dev]
#   tools\license.ps1 issue -name "Jeanne Dupont" -email j@example.org -edition supporter -order WREN-0001 [-date 2026-10-22] [-private FILE | -dev] [-out FILE]
#   tools\license.ps1 verify FILE | -text KEY [-public KEY | -dev]
# The private key goes to %USERPROFILE%\.wren-license\private.key, outside the repository (keygen refuses a path inside
# a git work tree). Builds build\license.exe from src\tools\license when it is older than its sources.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    $exe = Join-Path $root 'build\license.exe'
    $sources = Get-ChildItem src\tools\license, src\license -Filter *.odin -Recurse | Where-Object { $_.Name -notlike '*_test.odin' }
    $stale = -not (Test-Path $exe) -or ($sources | Where-Object { $_.LastWriteTime -gt (Get-Item $exe).LastWriteTime })
    if ($stale) {
        New-Item -ItemType Directory -Force build | Out-Null
        & odin build src/tools/license -collection:wb=src -vet -out:build/license.exe
        if ($LASTEXITCODE -ne 0) { throw 'building tools\license failed' }
    }
    & $exe @args
    exit $LASTEXITCODE
} finally { Pop-Location }
