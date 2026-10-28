# Speed of the Odin JavaScript runtime (src/engine/jsrt) against QuickJS-ng in C, on the same script.
#   powershell -File tools\jsrt_bench.ps1 [-Rounds 3] [-Script examples\jsbench\micro.js]
# Needs build\jsrt_judge.exe (odin build src/engine/jsrt/judge ...) and build\qjs_ref.exe (QuickJS-ng 0.17
# qjs, built with the pinned Zig from build\js\src\quickjs-0.17.0; see -BuildQjs). Both run the script
# in alternation, Rounds times; each case keeps its best time; the table gives the ratio QuickJS/jsrt
# (100 % = as fast as QuickJS, more = faster). Takes bench.lock while it measures.
param(
    [int]$Rounds = 3,
    [string]$Script = "examples\jsbench\micro.js",
    [switch]$BuildQjs
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$q = "S:\wren\build\js\src\quickjs-0.17.0"
$zig = "S:\wren\build\tools\zig-x86_64-windows-0.15.2\zig.exe"
if ($BuildQjs -or -not (Test-Path build\qjs_ref.exe)) {
    $stub = Join-Path $env:TEMP "qjs_ref_stub.c"
    Set-Content $stub "#include <stdint.h>`nconst uint8_t qjsc_repl[1] = {0}; const uint32_t qjsc_repl_size = 0;`nconst uint8_t qjsc_standalone[1] = {0}; const uint32_t qjsc_standalone_size = 0;`n"
    & $zig cc -target x86_64-windows-gnu -O2 -funsigned-char -DQUICKJS_NG_BUILD -D_GNU_SOURCE -DWIN32_LEAN_AND_MEAN -D_CRT_SECURE_NO_WARNINGS -I $q "$q\qjs.c" "$q\quickjs-libc.c" "$q\quickjs.c" "$q\libregexp.c" "$q\libunicode.c" "$q\dtoa.c" $stub -o build\qjs_ref.exe
}
. tools\test_env.ps1 -ErrorAction SilentlyContinue 2>$null
function Run-Case([string]$exe, [string[]]$args) {
    $out = & $exe @args 2>&1 | Out-String
    $r = @{}
    foreach ($line in ($out -split "`n")) {
        $p = $line.Trim() -split "`t"
        if ($p.Count -ge 3 -and $p[0] -eq "MICRO" -and $p[1] -ne "checksum") { $r[$p[1]] = [double]$p[2] }
        if ($p.Count -ge 3 -and $p[1] -eq "checksum") { $r["#checksum"] = $p[2] }
    }
    return $r
}
$best = @{ jsrt = @{}; qjs = @{} }
$order = @()
$measure = {
    for ($i = 0; $i -lt $Rounds; $i++) {
        foreach ($eng in "jsrt", "qjs") {
            $res = if ($eng -eq "jsrt") { Run-Case "build\jsrt_judge.exe" @("eval", $Script) } else { Run-Case "build\qjs_ref.exe" @($Script) }
            foreach ($k in $res.Keys) {
                if ($k -eq "#checksum") { $best[$eng][$k] = $res[$k]; continue }
                if (-not $script:order.Contains($k)) { $script:order += $k }
                if (-not $best[$eng].ContainsKey($k) -or $res[$k] -lt $best[$eng][$k]) { $best[$eng][$k] = $res[$k] }
            }
        }
    }
}
if (Get-Command Use-WrenLock -ErrorAction SilentlyContinue) { Use-WrenLock bench $measure } else { & $measure }
"| case | jsrt ns | QuickJS ns | QuickJS/jsrt |"
"|---|---:|---:|---:|"
$logsum = 0.0; $n = 0
foreach ($k in $order) {
    $a = $best.jsrt[$k]; $b = $best.qjs[$k]
    if (-not $a -or -not $b) { continue }
    $ratio = $b / $a
    $logsum += [Math]::Log($ratio); $n++
    "| {0} | {1:N2} | {2:N2} | {3:P0} |" -f $k, $a, $b, $ratio
}
if ($n -gt 0) { "| **geometric mean** | | | **{0:P0}** |" -f [Math]::Exp($logsum / $n) }
"checksums: jsrt {0}, QuickJS {1}" -f $best.jsrt["#checksum"], $best.qjs["#checksum"]
