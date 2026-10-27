# Runs the end-to-end tools that go through the network stack on one backend (network.backend: the WREN_NET_BACKEND
# environment variable, read by net.client_init), against one local test server: what proves the built-in stack (rust)
# does what WinHTTP did. tools\test_all.ps1 runs the same tools on the default backend.
#   powershell -NoProfile -File tools\net_parity.ps1 [-Backend rust|winhttp] [-Only name,name] [-NoBuild]
# Logs: build\parity\<backend>\<tool>.txt. Exit code: the number of tools that failed.
param([ValidateSet('rust', 'winhttp')][string]$Backend = 'rust', [string[]]$Only, [switch]$NoBuild)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
. (Join-Path $PSScriptRoot 'test_env.ps1')

$Track = '-define:WREN_TRACK_MEMORY=true'
$Stack = '-extra-linker-flags:/STACK:33554432'
$guest = @('-target:freestanding_wasm32', '-no-entry-point', '-default-to-nil-allocator', '-collection:web=sdk/odin', '-o:size')
$log = Join-Path $root "build\parity\$Backend"
New-Item -ItemType Directory -Force $log | Out-Null

# name, guests to build (source -> output), tool arguments, time limit (s)
$tools = @(
    @{ n = 'nettest';     g = @(); a = @(); t = 180 },
    @{ n = 'policytest';  g = @(); a = @(); t = 120 },
    @{ n = 'cachetest';   g = @(); a = @(); t = 120 },
    @{ n = 'pagetest';    g = @(@('examples/e2e', 'build/e2e.wasm'), @('examples/counter', 'examples/site/counter.wasm')); a = @('build\e2e.wasm', 'examples\site\counter.html', 'examples\site\counter.wasm'); t = 90 },
    @{ n = 'netapitest';  g = @(,@('examples/netapitest', 'build/netapitest.wasm')); a = @('build\netapitest.wasm'); t = 180 },
    @{ n = 'wsclosetest'; g = @(); a = @(); t = 180 },
    @{ n = 'webapitest';  g = @(,@('examples/webapitest', 'build/webapitest.wasm')); a = @('build\webapitest.wasm'); t = 90 },
    @{ n = 'workerstest'; g = @(@('examples/workerstest', 'build/workerstest.wasm'), @('examples/workerstest_worker', 'examples/site/workerstest_worker.wasm')); a = @('build\workerstest.wasm', 'examples\site\workerstest_worker.wasm'); t = 180 },
    @{ n = 'jsloadtest';  g = @(); a = @(); t = 180 },
    @{ n = 'framestest';  g = @(); a = @(); t = 180 },
    @{ n = 'jswebtest';   g = @(); a = @(); t = 300 }
)
if ($Only) {
    $names = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })   # (powershell -File passes "a,b" as one string)
    $tools = @($tools | Where-Object { $names -contains $_.n })
}

$failed = 0
if (-not $NoBuild) {
    foreach ($t in $tools) {
        foreach ($g in $t.g) {
            & odin build $g[0] @guest "-out:$($g[1])"
            if ($LASTEXITCODE -ne 0) { "BUILD FAILED: guest $($g[0])"; $failed++ }
        }
        & odin build "src/tools/$($t.n)" -use-separate-modules -collection:wb=src -vet $Track "-out:build/$($t.n).exe" $Stack
        if ($LASTEXITCODE -ne 0) { "BUILD FAILED: $($t.n)"; $failed++ }
    }
    if ($failed -gt 0) { exit $failed }
}

$env:WREN_NET_BACKEND = $Backend
$srv = Start-WrenTestServer
try {
    $env:WREN_TEST_BASE_PORT = "$($srv.BasePort)"
    foreach ($t in $tools) {
        $out = Join-Path $log "$($t.n).txt"
        $t0 = Get-Date
        $sp = @{ FilePath = (Join-Path $root "build\$($t.n).exe"); NoNewWindow = $true; PassThru = $true; RedirectStandardOutput = $out; RedirectStandardError = "$out.err" }
        if ($t.a.Count -gt 0) { $sp.ArgumentList = $t.a }
        $p = Start-Process @sp
        $ok = $p.WaitForExit($t.t * 1000)
        if (-not $ok) { $p.Kill() }
        $text = (Get-Content $out -Raw -ErrorAction SilentlyContinue) + ''
        $pass = $ok -and ($text -match '(?m)\b0 failure\(s\)')
        if (-not $pass) { $failed++ }
        '{0,-12} {1,-5} {2,6:n1} s  {3}' -f $t.n, $(if ($pass) { 'ok' } elseif (-not $ok) { 'TIME' } else { 'FAIL' }), ((Get-Date) - $t0).TotalSeconds, $out
    }
} finally {
    Stop-WrenTestServer $srv
    Remove-Item Env:\WREN_NET_BACKEND
}
"backend $Backend : $failed tool(s) failed"
exit $failed
