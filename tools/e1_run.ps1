# E1 parity: rebuild the judge, compile the positive and the negative-syntax manifests, and print the summary
# (bytecode identity per folder, then syntax-verdict agreement on the negative tests).
param([switch]$NoBuild, [switch]$PositiveOnly)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$o = 'C:\Users\sacha\AppData\Local\Temp\opencode\e1_oracle'
if (-not $NoBuild) {
    Push-Location $root
    cmd /c "odin build src/engine/frontend/judge -collection:wb=src -o:speed -extra-linker-flags:/STACK:268435456 -out:build/e1j.exe 2>&1" | Select-Object -First 30
    Pop-Location
}
& (Join-Path $PSScriptRoot 'e1_batch.ps1') | Out-Null
& "$root\build\e1j.exe" diff-batch "$o\positive.manifest" "$o\ref2" "$o\ours2" | Select-Object -First 30
if ($PositiveOnly) { return }
& (Join-Path $PSScriptRoot 'e1_batch.ps1') -Manifest "$o\negparse.txt" -OutDir "$o\nours" -Status "$o\nours_status.txt" | Out-Null
$r = @{}; foreach ($l in [IO.File]::ReadAllLines("$o\nref_status.txt")) { $p = $l -split "`t"; $r[$p[0]] = $p[1] }
$agree = 0; $dis = 0
foreach ($l in [IO.File]::ReadAllLines("$o\nours_status.txt")) {
    $p = $l -split "`t"
    if (($p[1] -eq 'ok') -eq ($r[$p[0]] -eq 'ok')) { $agree++ } else { $dis++ }
}
"negative-syntax verdicts: $agree agree, $dis disagree of $($agree + $dis)"
