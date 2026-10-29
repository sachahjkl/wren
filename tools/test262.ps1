# test262 (the ECMAScript conformance suite) in Wren's JavaScript engine compiled to Wasm.
#   powershell -NoProfile -File tools\test262.ps1 [-Quick] [-Update] [-Stride k] [-Threads n]
# Pinned inputs: the test262 commit QuickJS-ng 0.17.0 runs (its submodule), as a GitHub archive checked by SHA-256 below;
# QuickJS-ng's own runner configuration (test262.conf, test262_errors.txt) and runner (run-test262.c) from the engine's
# release source, which tools\build_js.ps1 pins (its version and digest are read from that script).
# Steps (each skipped when its output is up to date), in build\test262:
#   run\test262\       the suite;  run\test262.conf, run\test262_errors.txt: QuickJS-ng's, unchanged
#   ..\js-test262\     the test image of the engine: tools\build_js.ps1 -Out build\js-test262 -ExtraFlags -DWREN_TEST262=1
#                      (the shipped engine plus native\js\runtime\test262_host.c: $262, print, the module loader)
#   test262.exe        src\tools\test262 (the runner of the Wasm engine; run-test262's rules, one realm per test)
# Outputs: wasm_errors.txt (run-test262's error-file format).
# -Quick: every 25th test, Wasm only (a few seconds; the tools\test_all.ps1 step). Exit status 1 on a regression: a test
# failing in Wasm that src\tools\test262\known_failures.txt does not list. -Update rewrites that list from a full run.
# -Jit: the engine's JIT on (javascript.jit.*), compiling every function at its -JitThreshold-th call (1: all of them),
# -JitStep: compiled code runs every op through the interpreter's code; -JitSync: compiled before the call goes on (no
# background thread: every function and loop runs compiled from its threshold on); the same known failures apply.
param([switch]$Quick, [switch]$Update, [switch]$NoNative, [int]$Stride = 0, [int]$Threads = 0, [switch]$Jit, [int]$JitThreshold = 1, [int]$JitLoop = 1, [switch]$JitStep, [switch]$JitSync)
# (-NoNative is kept for the callers: there is no native QuickJS-ng run any more)
# (failures are checked by exit status: what native tools write on stderr is not an error; throw stops the script)
$ErrorActionPreference = 'Continue'
$Test262Commit = '5ef1e5723be95296f36afb0386676fed0205869c'
$Test262Sha256 = 'd67ff29d7bcee3493f38b3ef54db068ea5ad6d5a67b67b3f505dfee581dd3879'

$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build\test262'
$run = Join-Path $out 'run'
$known = Join-Path $root 'src\tools\test262\known_failures.txt'
New-Item -ItemType Directory -Force $out | Out-Null
if ($Quick) { $NoNative = [switch]$true; if ($Stride -eq 0) { $Stride = 25 } }
if ($Update) { $Stride = 1 }
if ($Stride -le 0) { $Stride = 1 }

function Get-Pinned([string]$url, [string]$file, [string]$sha) {
    if ((Test-Path $file) -and (Get-FileHash $file -Algorithm SHA256).Hash -eq $sha.ToUpper()) { return }
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    "downloading $url"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -ErrorAction Stop
    $got = (Get-FileHash $file -Algorithm SHA256).Hash
    if ($got -ne $sha.ToUpper()) { Remove-Item $file -Force; throw "SHA-256 mismatch for $url`: expected $sha, got $got" }
}

# the engine's pins, from the script that builds it
$buildJs = Get-Content (Join-Path $PSScriptRoot 'build_js.ps1') -Raw
function Pin([string]$name) { $m = [regex]::Match($buildJs, "\`$$name = '([^']+)'"); if (-not $m.Success) { throw "build_js.ps1 has no `$$name" }; $m.Groups[1].Value }
$QjsVersion = Pin 'QjsVersion'; $QjsSha256 = Pin 'QjsSha256'
$tools = Join-Path $root 'build\tools'

# the suite
$tarball = Join-Path $out "test262-$Test262Commit.tar.gz"
$stamp = Join-Path $run 'test262\COMMIT'
if (-not (Test-Path $stamp) -or (Get-Content $stamp -Raw).Trim() -ne $Test262Commit) {
    Get-Pinned "https://codeload.github.com/tc39/test262/tar.gz/$Test262Commit" $tarball $Test262Sha256
    if (Test-Path (Join-Path $run 'test262')) { [IO.Directory]::Delete((Join-Path $run 'test262'), $true) }
    New-Item -ItemType Directory -Force $run | Out-Null
    & tar -xzf $tarball -C $run
    if ($LASTEXITCODE -ne 0) { throw "tar failed ($LASTEXITCODE)" }
    Rename-Item (Join-Path $run "test262-$Test262Commit") 'test262'
    [IO.File]::WriteAllText($stamp, $Test262Commit)
}

# QuickJS-ng's release source, unpatched: the runner's configuration
$qjsTar = Join-Path $tools "quickjs-ng-v$QjsVersion.tar.gz"
Get-Pinned "https://github.com/quickjs-ng/quickjs/archive/refs/tags/v$QjsVersion.tar.gz" $qjsTar $QjsSha256
$qjs = Join-Path $out "quickjs-$QjsVersion"
if (-not (Test-Path (Join-Path $qjs 'run-test262.c'))) {
    & tar -xzf $qjsTar -C $out
    if ($LASTEXITCODE -ne 0) { throw "tar failed ($LASTEXITCODE)" }
}
foreach ($f in 'test262.conf', 'test262-fast.conf', 'test262_errors.txt') { Copy-Item (Join-Path $qjs $f) $run -Force }

# the test image of the engine
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build_js.ps1') -Out build\js-test262 -ExtraFlags '-DWREN_TEST262=1' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'building the test image of the engine failed (tools\build_js.ps1 -Out build\js-test262)' }
$image = Join-Path $root 'build\js-test262\wren_js.wasm'

# the Wasm runner
$exe = Join-Path $root 'build\test262.exe'
Push-Location $root
try {
    # Wasm calls run on the main thread too: room for wasm.wasmtime.max_stack_bytes
    # (-Quick: one module per package, 1 s instead of 4; and test_all runs this script twice: the second run finds the program built)
    . (Join-Path $PSScriptRoot 'test_env.ps1')
    $modules = @(if ($Quick) { '-use-separate-modules' })
    $ok = Invoke-WrenBuildIfStale $exe "test262 $($modules -join ' ')" { & odin build src/tools/test262 -collection:wb=src -vet -o:speed @modules -out:$exe "-extra-linker-flags:/STACK:33554432" }
    if (-not $ok) { throw 'building src\tools\test262 failed' }
} finally { Pop-Location }

$threadArgs = if ($Threads -gt 0) { @('-threads', $Threads) } else { @() }
$wasmErrors = Join-Path $out 'wasm_errors.txt'
$nativeErrors = Join-Path $out 'native_errors.txt'
$wasmArgs = @('-c', 'test262.conf', '-a', '-image', $image, '-stride', $Stride, '-errors', $wasmErrors) + $threadArgs
if (-not $Update) { $wasmArgs += @('-known', $known) }
if ($Jit) { $wasmArgs += @('-jit', '-jit-threshold', $JitThreshold, '-jit-loop', $JitLoop); if ($JitStep) { $wasmArgs += '-jit-step' }; if ($JitSync) { $wasmArgs += '-jit-sync' } }

Push-Location $run
try {
    & $exe @wasmArgs 2>$null
    $status = $LASTEXITCODE
} finally { Pop-Location }
if ($Update -and $status -eq 0) {
    Copy-Item $wasmErrors $known -Force
    "known failures updated: $known"
}
if (Test-Path (Join-Path $out 'table.md')) { if (-not $Quick) { Get-Content (Join-Path $out 'table.md') | Select-Object -First 8 } }
exit $status
