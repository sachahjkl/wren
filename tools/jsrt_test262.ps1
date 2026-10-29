# test262 on the Odin JavaScript engine (src/engine/frontend + src/engine/jsrt), judged against QuickJS-ng's results.
#   powershell -File tools\jsrt_test262.ps1 [-Filter built-ins/Array] [-Stride 1] [-Jobs 8] [-NoBuild]
# Builds the judge (src/engine/jsrt/judge) and runs the suite pinned by tools\test262.ps1
# (build\test262\run: test262/, test262.conf, test262_errors.txt) in worker processes. Source text is compiled by
# the Odin front-end.
# Results: build\test262\jsrt_errors.txt (one failure per line) and build\test262\jsrt_table.md (% per directory).
param(
    [string]$Filter = "",
    [int]$Stride = 1,
    [int]$Jobs = 0,
    [switch]$NoBuild
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$run = "S:\wren\build\test262\run"
if (-not (Test-Path "$run\test262.conf")) { $run = Join-Path $root "build\test262\run" }
if (-not (Test-Path "$run\test262.conf")) { throw "test262 not found: run tools\test262.ps1 first (build\test262\run)" }
if (-not $NoBuild) {
    # 64 MiB main-thread stack: the judge lets the engine use 48 MiB of it (deep recursion tests)
    odin build src/engine/jsrt/judge -collection:wb=src -out:build/jsrt_judge.exe -o:speed "-extra-linker-flags:/STACK:67108864"
    if ($LASTEXITCODE -ne 0) { throw "judge build failed" }
}
$a = @("test262", "-dir", $run, "-stride", "$Stride")
if ($Filter) { $a += @("-filter", $Filter) }
if ($Jobs -gt 0) { $a += @("-j", "$Jobs") }
& build\jsrt_judge.exe @a
