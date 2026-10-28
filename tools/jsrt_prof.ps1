# Sampling profile of the Odin JavaScript runtime on one script (hot functions, then hot source lines).
#   powershell -File tools\jsrt_prof.ps1 examples\jsbench\cases\calls.js [-Top 30] [-NoBuild] [-Lines]
# Builds the judge with -debug (PDB for the names) into build\jsrt_judge_prof.exe and runs `judge eval` with
# JSRT_PROF=1 (src/engine/jsrt/judge/prof_windows.odin: a thread samples the interpreter thread's RIP every ~1 ms).
param(
    [Parameter(Mandatory = $true)][string]$Script,
    [int]$Top = 30,
    [switch]$NoBuild,
    [switch]$Lines
)
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
if (-not $NoBuild) {
    cmd /c "odin build src/engine/jsrt/judge -collection:wb=src -out:build/jsrt_judge_prof.exe -o:speed -debug -extra-linker-flags:/STACK:67108864 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "build failed" }
}
$env:JSRT_PROF = "1"
$out = cmd /c "build\jsrt_judge_prof.exe eval $Script 2>&1"
$sec = 0
foreach ($l in $out) {
    if ($l -like "--- functions*") { $sec = 1; $n = 0 }
    elseif ($l -like "--- lines*") { $sec = 2; $n = 0 }
    elseif ($sec -eq 0) { $l; continue }
    if (($sec -eq 1 -or ($sec -eq 2 -and $Lines)) -and $n -le $Top) { $l; $n++ }
}
