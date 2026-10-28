# test262 on the Odin JavaScript engine (src/engine/frontend + src/engine/jsrt), judged against QuickJS-ng's results.
#   powershell -File tools\jsrt_test262.ps1 [-Filter built-ins/Array] [-Stride 1] [-Jobs 8] [-NoBuild] [-Ref]
# Builds the judge (src/engine/jsrt/judge) and runs the suite pinned by tools\test262.ps1
# (build\test262\run: test262/, test262.conf, test262_errors.txt) in worker processes. Source text is compiled by
# the Odin front-end; -Ref compiles with QuickJS-ng 0.17's own compiler instead (test-only DLL built from
# tools/jsrt_refcompiler.c with the pinned Zig), to tell a compiler bug from a runtime bug.
# Results: build\test262\jsrt_errors.txt (one failure per line) and build\test262\jsrt_table.md (% per directory).
param(
    [string]$Filter = "",
    [int]$Stride = 1,
    [int]$Jobs = 0,
    [switch]$NoBuild,
    [switch]$Ref
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$run = "S:\wren\build\test262\run"
if (-not (Test-Path "$run\test262.conf")) { $run = Join-Path $root "build\test262\run" }
if (-not (Test-Path "$run\test262.conf")) { throw "test262 not found: run tools\test262.ps1 first (build\test262\run)" }
if (-not $NoBuild) {
    if ($Ref) {
        $q = "S:\wren\build\js\src\quickjs-0.17.0"
        if (-not (Test-Path $q)) { $q = Join-Path $root "build\js\src\quickjs-0.17.0" }
        $zig = "S:\wren\build\tools\zig-x86_64-windows-0.15.2\zig.exe"
        if (-not (Test-Path $zig)) { $zig = Join-Path $root "build\tools\zig-x86_64-windows-0.15.2\zig.exe" }
        & $zig cc -shared -target x86_64-windows-gnu -O2 -funsigned-char -DQUICKJS_NG_BUILD -D_GNU_SOURCE `
            -DWIN32_LEAN_AND_MEAN -D_CRT_SECURE_NO_WARNINGS -I $q tools\jsrt_refcompiler.c "$q\libregexp.c" `
            "$q\libunicode.c" "$q\dtoa.c" -o build\jsrt_refcompiler.dll
        if ($LASTEXITCODE -ne 0) { throw "reference compiler build failed" }
    }
    # 64 MiB main-thread stack: the judge lets the engine use 48 MiB of it (deep recursion tests)
    odin build src/engine/jsrt/judge -collection:wb=src -out:build/jsrt_judge.exe -o:speed "-extra-linker-flags:/STACK:67108864"
    if ($LASTEXITCODE -ne 0) { throw "judge build failed" }
}
$env:JSRT_REFCOMPILER = if ($Ref) { "1" } else { "" }
$a = @("test262", "-dir", $run, "-stride", "$Stride")
if ($Filter) { $a += @("-filter", $Filter) }
if ($Jobs -gt 0) { $a += @("-j", "$Jobs") }
& build\jsrt_judge.exe @a
