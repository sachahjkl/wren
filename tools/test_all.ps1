# Runs every test of the project: unit tests, the end-to-end page test, the network stress script.
#   powershell -File tools\test_all.ps1 [-Quick] [-CI] [-Jobs n] [-BasePort n]
#   (-Quick skips the long network stress; -CI, for continuous integration runners: -Quick, end-to-end timeouts x3 for
#   slow shared machines, the whole output of a failed step instead of its last lines, one step at a time on the
#   default ports. Nothing here opens a window or reaches the internet: the end-to-end tests use the local test server
#   on 127.0.0.1, the pixel tests WARP; only the pinned test suites, test262 and web-platform-tests, are fetched once
#   into build\.)
# Several runs at once (worktrees of several agents): nothing here takes a lock. The test server listens on a block of
# ports of this run (tools\test_env.ps1: -BasePort, default derived from the worktree's path, the next free block when
# it is taken; 8765 with -CI), the tools find it through WREN_TEST_BASE_PORT, and TEMP is build\tmp. Scripts that use
# the real desktop or measure performance take desktop.lock / bench.lock themselves, around that part only (a step
# that runs one of them waits there, not the whole run). S:\wb_wt\shared.lock is not used any more.
# -Jobs n (default: a quarter of the processors, at most 4; 1 with -CI): steps run n at a time, each in its own
# process, longest first (the durations of the last run, build\test_all_times.txt); each step that needs the test
# server starts its own (a block of ports and counters of its own). A step's result is printed whole when it ends.
# -Jobs 1: one step after the other, one server for all, as before.
param([switch]$Quick, [switch]$CI, [int]$StepTimeoutSec = 900, [int]$Jobs = 0, [int]$BasePort = 0)
if ($CI) { $Quick = $true }
$slow = if ($CI) { 3 } else { 1 }
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
. (Join-Path $PSScriptRoot 'test_env.ps1')
if ($Jobs -le 0) { $Jobs = if ($CI) { 1 } else { [Math]::Max(1, [Math]::Min(4, [int][Math]::Floor([Environment]::ProcessorCount / 4))) } }
if ($BasePort -le 0) { $BasePort = if ($CI) { 8765 } else { Get-WrenPreferredBasePort $root } }
$failed = 0
$runStart = Get-Date
# No step is ever run twice: a test checks properties (order, counts, state), never a wall-clock duration, so a slow
# shared runner takes longer but gets the same result. Waits for something that must come have generous bounds that
# only end a failing run.
# A test executable of this worktree that runs longer than -StepTimeoutSec is stopped, so a hung suite fails instead of
# blocking the run (Odin's test runner can hang when several tests hit fatal assertions at once). Other worktrees'
# processes are theirs to watch.
function Start-Watchdog {
    Start-Job -ArgumentList $StepTimeoutSec, (Join-Path $root 'build\') -ScriptBlock {
        param($limit, $dir)
        while ($true) {
            Start-Sleep -Seconds 5
            Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*_test' -and $_.Path -and $_.Path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) -and $_.StartTime -and ((Get-Date) - $_.StartTime).TotalSeconds -gt $limit } | ForEach-Object {
                "watchdog: stopped $($_.ProcessName) after $limit s"; Stop-Process -Id $_.Id -Force }
        }
    }
}

function Report($name, $ok, $out, $secs, $port = 0) {
    "{0} {1}{2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $(if ($CI -or $Jobs -gt 1) { " ($secs s$(if ($port) { ", server on $port" }))" } else { '' })
    if (-not $ok) { $script:failed++; if ($CI) { $out } else { ($out -split "`n" | Select-Object -Last 15) -join "`n" } }
}

# -Jobs 1: the step runs now. Otherwise it is queued (with whether it needs the test server) until Flush-Steps.
$script:queue = New-Object System.Collections.Generic.List[object]
$script:serverSteps = $false
function Step($name, [scriptblock]$body) {
    if ($Jobs -gt 1) {
        # the caller's variables the body reads (a loop's $pkg...), as values: the step runs in another process
        $vars = @{}
        foreach ($v in $body.Ast.FindAll({ $args[0] -is [Management.Automation.Language.VariableExpressionAst] }, $true)) {
            $n = $v.VariablePath.UserPath
            if ($vars.ContainsKey($n) -or $n -in 'Stack', 'slow', 'Quick', 'CI', 'root', 'BasePort', '_', 'args', 'true', 'false', 'null', 'LASTEXITCODE') { continue }
            $val = Get-Variable -Name $n -Scope 1 -ValueOnly -ErrorAction SilentlyContinue
            if ($val -is [string] -or $val -is [int] -or $val -is [bool]) { $vars[$n] = $val }
            elseif ($val -is [array] -and @($val | Where-Object { $_ -isnot [string] }).Count -eq 0) { $vars[$n] = [string[]]$val }
        }
        $script:queue.Add([pscustomobject]@{ Name = $name; Body = $body.ToString(); Server = $script:serverSteps; Vars = $vars })
        return
    }
    $t0 = Get-Date
    $out = & $body 2>&1 | Out-String
    $killed = Receive-Job $script:watchdog -ErrorAction SilentlyContinue
    if ($killed) { $out += "`n" + ($killed -join "`n"); $global:LASTEXITCODE = 1 }
    $ok = $LASTEXITCODE -eq 0 -or $out -match 'All tests were successful'
    $secs = [int]((Get-Date) - $t0).TotalSeconds
    $script:times[$name] = $secs
    Report $name $ok $out $secs
}

# What a queued step runs in its own process: the variables the steps use, its own test server if it needs one.
$stepJob = {
    param($name, $bodyText, $server, $root, $Stack, $slow, $Quick, $CI, $BasePort, $vars)
    Set-Location $root
    foreach ($k in $vars.Keys) { Set-Variable -Name $k -Value $vars[$k] }
    . (Join-Path $root 'tools\test_env.ps1')
    $t0 = Get-Date
    $srv = $null
    $out = ''
    $code = 1
    try {
        if ($server) {
            $srv = Start-WrenTestServer -BasePort $BasePort
            $env:WREN_TEST_BASE_PORT = "$($srv.BasePort)"
        }
        $global:LASTEXITCODE = 0
        $out = & ([scriptblock]::Create($bodyText)) 2>&1 | Out-String
        $code = $LASTEXITCODE
    } catch { $out += "`n$_" } finally { Stop-WrenTestServer $srv }
    [pscustomobject]@{ Name = $name; Ok = ($code -eq 0 -or $out -match 'All tests were successful'); Out = $out; Secs = [int]((Get-Date) - $t0).TotalSeconds; Port = $(if ($srv) { $srv.BasePort } else { 0 }) }
}

# Runs the queued steps, -Jobs at a time, the longest (last time) first; prints each result as it comes.
function Flush-Steps {
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($s in ($script:queue | Sort-Object { if ($script:times.ContainsKey($_.Name)) { -$script:times[$_.Name] } else { -60 } })) { $pending.Add($s) }
    $script:queue.Clear()
    $running = @{}
    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
        while ($running.Count -lt $Jobs -and $pending.Count -gt 0) {
            $s = $pending[0]; $pending.RemoveAt(0)
            $j = Start-Job -ScriptBlock $stepJob -ArgumentList $s.Name, $s.Body, $s.Server, $root, $Stack, $slow, [bool]$Quick, [bool]$CI, $BasePort, $s.Vars
            $running[$j.Id] = $j
        }
        foreach ($j in @($running.Values)) {
            if ($j.State -eq 'Running' -or $j.State -eq 'NotStarted') { continue }
            $r = Receive-Job $j -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties['Ok'] } | Select-Object -Last 1
            Remove-Job $j -Force; $running.Remove($j.Id)
            if (-not $r) { Report "(a step ended without a result: job $($j.Id))" $false '' 0; continue }
            $script:times[$r.Name] = $r.Secs
            Report $r.Name $r.Ok $r.Out $r.Secs $r.Port
        }
        $killed = Receive-Job $script:watchdog -ErrorAction SilentlyContinue
        if ($killed) { $killed }
        Start-Sleep -Milliseconds 200
    }
}

$timesFile = Join-Path $root 'build\test_all_times.txt'
$script:times = @{}
if (Test-Path $timesFile) { foreach ($line in Get-Content $timesFile) { $k, $v = $line -split "`t", 2; if ($v) { $script:times[$k] = [int]$v } } }

New-Item -ItemType Directory -Force build | Out-Null
# this run's temporary files (several runs at once share no fixed name under %TEMP%)
$env:TEMP = $env:TMP = (New-Item -ItemType Directory -Force (Join-Path $root 'build\tmp')).FullName
# Wasm calls run on the calling thread: every program that runs modules (the JavaScript engine needs 16 MiB of wasm
# stack, wasm.wasmtime.max_stack_bytes) is linked with a 32 MiB default thread stack
$Stack = '-extra-linker-flags:/STACK:33554432'
$script:watchdog = Start-Watchdog
"test_all: $root, -Jobs $Jobs, test server ports from $BasePort, started $(Get-Date -Format 'HH:mm:ss')"
# the JavaScript engine every build below embeds (nothing to do when build\js is up to date)
Step 'JavaScript engine (tools\build_js.ps1; nothing to do when up to date)' { powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_js.ps1 | Out-Null }
if ($Jobs -gt 1) { Flush-Steps }
foreach ($pkg in 'base', 'host', 'dom', 'html', 'url', 'http', 'cookies', 'csp', 'fetch', 'config', 'css', 'style', 'webfont', 'images', 'layout', 'forms', 'js', 'page', 'webauthn', 'browser') {
    Step "unit tests: $pkg" { odin test "src/$pkg" -collection:toolkit=ext/gui_toolkit -collection:wb=src -vet -out:"build/${pkg}_test.exe" $Stack 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
}

Step 'unit tests: wasm' { odin test src/wasm -collection:wb=src -vet -define:ODIN_TEST_THREADS=1 -out:build/wasm_test.exe $Stack 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
Step 'unit tests: bindgen (description language, determinism)' { odin test src/tools/bindgen/idl -collection:wb=src -vet -out:build/bindgen_test.exe $Stack 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
Step 'generated web API up to date (bindgen -check)' { odin run src/tools/bindgen -collection:wb=src -vet -out:build/bindgen.exe $Stack -- -check }
Step 'test262 in the Wasm engine (-Quick: every 25th test; fails on a failure src\tools\test262\known_failures.txt does not list)' { $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\test262.ps1', '-NoNative'); if ($Quick) { $a += '-Quick' }; powershell @a }
Step 'web API conformance (generated cases: bounds, UTF-8, handles, enums, capacity)' {
    odin build examples/apiconformance -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -out:build/apiconformance.wasm -o:size
    if ($LASTEXITCODE -ne 0) { return }
    odin build src/tools/apiconformance -collection:wb=src -vet -out:build/apiconformance.exe $Stack
    if ($LASTEXITCODE -ne 0) { return }
    .\build\apiconformance.exe build\apiconformance.wasm
}

Step 'graphics toolkit pixel tests (layers, filters, kept filter results, blend modes, clip shapes, blend spaces, gradients, shadows, retained pictures, text on DirectWrite, color glyphs, masks, precompiled shaders; WARP)' { $o = ''; $suites = 'layers', 'effects', 'gpufx', 'blend_space', 'gradients', 'shadows', 'retained', 'text', 'color_glyphs', 'masks', 'shaders'; foreach ($t in $suites) { $o += odin test "ext/gui_toolkit/tests/$t" -vet -out:"build/toolkit_${t}_test.exe" 2>&1 | Out-String }; $o -replace 'All tests were successful', 'passed'; $global:LASTEXITCODE = if (([regex]::Matches($o, 'All tests were successful|The test was successful')).Count -eq $suites.Count) { 0 } else { 1 } }
Step 'graphics toolkit keyboard tests (menus, lists, line edit history, wrapped text; no window)' { odin test ext/gui_toolkit/tests/keyboard -vet -define:ODIN_TEST_THREADS=1 -out:build/toolkit_keyboard_test.exe 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
Step 'graphics toolkit window chrome tests (title bar hit test and regions, virtual list, wrap cache, scroll curve; no window)' { odin test ext/gui_toolkit/tests/chrome -vet -define:ODIN_TEST_THREADS=1 -out:build/toolkit_chrome_test.exe 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
Step 'graphics toolkit status tests (sample history, frame graph; no window)' { odin test ext/gui_toolkit/tests/status -vet -define:ODIN_TEST_THREADS=1 -out:build/toolkit_status_test.exe 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
Step 'build guest e2e.wasm' { odin build examples/e2e -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:build/e2e.wasm -o:size }
Step 'build guest counter.wasm' { odin build examples/counter -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:examples/site/counter.wasm -o:size }
Step 'build guest formstest.wasm' { odin build examples/formstest -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:examples/site/formstest.wasm -o:size }
Step 'build guest mutation.wasm' { odin build examples/mutation -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:examples/site/mutation.wasm -o:size }
Step 'build guest mutation_class.wasm' { odin build examples/mutation_class -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:examples/site/mutation_class.wasm -o:size }
Step 'build formstest' { odin build src/tools/formstest -collection:wb=src -vet -out:build/formstest.exe $Stack }
Step 'build pagetest' { odin build src/tools/pagetest -collection:wb=src -vet -out:build/pagetest.exe $Stack }
Step 'JavaScript in pages (jstest: realm, scripts, bindings, events, wrappers and node lifetime, bytecode cache, interruption)' { odin build src/tools/jstest -collection:wb=src -vet -out:build/jstest.exe -o:speed $Stack; if ($LASTEXITCODE -eq 0) { .\build\jstest.exe } }
Step 'build policytest' { odin build src/tools/policytest -collection:wb=src -vet -out:build/policytest.exe $Stack }
Step 'build web API test (guest + tool)' { odin build examples/webapitest -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:build/webapitest.wasm -o:size; if ($LASTEXITCODE -eq 0) { odin build src/tools/webapitest -collection:wb=src -vet -out:build/webapitest.exe $Stack } }
Step 'build fetch' { odin build src/tools/fetch -collection:wb=src -vet -out:build/fetch.exe $Stack }
Step 'file: folders end-to-end test (index file, listing, redirect to /, errors, who may open what; no server)' {
    odin build src/tools/filetest -collection:wb=src -vet -out:build/filetest.exe $Stack
    if ($LASTEXITCODE -ne 0) { return }
    $o = .\build\filetest.exe | Out-String; $o
    $global:LASTEXITCODE = if ($o -match '(?m)\b0 failure\(s\)') { 0 } else { 1 }
}
Step 'DOM for JavaScript end-to-end test (jsdomtest: tree, elements, markup, selectors, CSSOM, geometry, UI events, MutationObserver, traversal, ranges, leaks, micro-benchmarks; no server)' {
    odin build src/tools/jsdomtest -collection:wb=src -vet -out:build/jsdomtest.exe -o:speed $Stack
    if ($LASTEXITCODE -ne 0) { return }
    $o = .\build\jsdomtest.exe | Out-String; $o
    $global:LASTEXITCODE = if ($o -match '(?m)\b0 failure\(s\)') { 0 } else { 1 }
}
Step 'history end-to-end test (historytest: the tree as pages see it, scrollRestoration, pageshow / pagehide persisted, back/forward cache freezing, persisted form state; no server)' {
    odin build src/tools/historytest -collection:wb=src -vet -out:build/historytest.exe $Stack
    if ($LASTEXITCODE -ne 0) { return }
    $o = .\build\historytest.exe | Out-String; $o
    $global:LASTEXITCODE = if ($o -match '(?m)\b0 failure\(s\)') { 0 } else { 1 }
}
Step 'Web Authentication end-to-end test (webauthntest: create then get from JavaScript on the virtual authenticator, signature checked; activation, RP ID, aborts, timer, mediation, JSON forms, secure context; no server)' {
    odin build src/tools/webauthntest -collection:wb=src -vet -out:build/webauthntest.exe $Stack
    if ($LASTEXITCODE -ne 0) { return }
    $o = .\build\webauthntest.exe | Out-String; $o
    $global:LASTEXITCODE = if ($o -match '(?m)\b0 failure\(s\)') { 0 } else { 1 }
}
Step 'build testserver (and its tests: /site/ index, listings, extensionless pages, types)' { Push-Location tools\testserver; go test . 2>&1; if ($LASTEXITCODE -eq 0) { go build -o ..\..\build\testserver.exe . }; Pop-Location }
# what the steps below use is built: the queued steps run before them
if ($Jobs -gt 1) { Flush-Steps }

# The steps below talk to the test server: -Jobs 1, one server for all, on this run's block of ports (ready once it
# listens on all of them, not after a fixed delay: a slow runner may take longer to start it); otherwise each step
# starts its own when it runs.
$srv = $null
if ($Jobs -le 1) {
    try { $srv = Start-WrenTestServer -BasePort $BasePort; $env:WREN_TEST_BASE_PORT = "$($srv.BasePort)" } catch { Report 'test server' $false "$_" 0 }
}
$script:serverSteps = $true
try {
    Step 'network policy test (CORS, cookies, redirects, CSP, schemes)' {
        $p = Start-Process .\build\policytest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\pol.txt
        if (-not $p.WaitForExit(120000 * $slow)) { $p.Kill(); Get-Content build\pol.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\pol.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)\b0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'end-to-end page test' {
        $p = Start-Process .\build\pagetest.exe -ArgumentList 'build\e2e.wasm','examples\site\counter.html','examples\site\counter.wasm' -NoNewWindow -PassThru -RedirectStandardOutput build\pt.txt
        if (-not $p.WaitForExit(90000 * $slow)) { $p.Kill(); Get-Content build\pt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\pt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'EventSource / WebSocket end-to-end test (netapitest)' {
        odin build examples/netapitest -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:build/netapitest.wasm -o:size
        if ($LASTEXITCODE -ne 0) { return }
        odin build src/tools/netapitest -collection:wb=src -vet -out:build/netapitest.exe $Stack
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\netapitest.exe -ArgumentList 'build\netapitest.wasm' -NoNewWindow -PassThru -RedirectStandardOutput build\nat.txt
        if (-not $p.WaitForExit(180000 * $slow)) { $p.Kill(); Get-Content build\nat.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\nat.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'WebSocket closing handshake test (wsclosetest: close right after a message or the upgrade, late, missing and crossing close frames, server cutting TCP; repeated)' {
        odin build src/tools/wsclosetest -collection:wb=src -vet -out:build/wsclosetest.exe
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\wsclosetest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\wct.txt
        if (-not $p.WaitForExit(180000 * $slow)) { $p.Kill(); Get-Content build\wct.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\wct.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'web platform API test (timers, rAF, abort, fetch streams, encoding, crypto, storage, URL, history)' {
        $p = Start-Process .\build\webapitest.exe -ArgumentList 'build\webapitest.wasm' -NoNewWindow -PassThru -RedirectStandardOutput build\wt.txt
        if (-not $p.WaitForExit(90000 * $slow)) { $p.Kill(); Get-Content build\wt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\wt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'forms end-to-end test (controls, validation, FormData, submission)' {
        $p = Start-Process .\build\formstest.exe -ArgumentList 'examples\site\forms.html','examples\site\formstest.wasm' -NoNewWindow -PassThru -RedirectStandardOutput build\ft.txt
        if (-not $p.WaitForExit(90000 * $slow)) { $p.Kill(); Get-Content build\ft.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\ft.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'workers end-to-end test (messages, transfer, fetch, terminate, 16 in parallel)' {
        odin build examples/workerstest -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:build/workerstest.wasm -o:size
        if ($LASTEXITCODE -ne 0) { return }
        odin build examples/workerstest_worker -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:examples/site/workerstest_worker.wasm -o:size
        if ($LASTEXITCODE -ne 0) { return }
        odin build src/tools/workerstest -collection:wb=src -vet -out:build/workerstest.exe $Stack
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\workerstest.exe -ArgumentList 'build\workerstest.wasm','examples\site\workerstest_worker.wasm' -NoNewWindow -PassThru -RedirectStandardOutput build\wkt.txt
        if (-not $p.WaitForExit(180000 * $slow)) { $p.Kill(); Get-Content build\wkt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\wkt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'JavaScript loading end-to-end test (script order, document.write, dynamic scripts, modules, handlers, CSP, noscript, timers, errors, workers, cloning)' {
        odin build src/tools/jsloadtest -collection:wb=src -vet -out:build/jsloadtest.exe $Stack
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\jsloadtest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\jlt.txt
        if (-not $p.WaitForExit(180000 * $slow)) { $p.Kill(); Get-Content build\jlt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\jlt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'JavaScript web APIs end-to-end test (fetch, XHR, streams, URL, encoding, abort, storage, history, navigator, crypto, sockets, messaging; jswebtest)' {
        odin build src/tools/jswebtest -collection:wb=src -vet -out:build/jswebtest.exe $Stack
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\jswebtest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\jswt.txt
        if (-not $p.WaitForExit(300000 * $slow)) { $p.Kill(); Get-Content build\jswt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\jswt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)\b0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'style run-time test (web fonts, transitions, animations)' {
        odin build src/tools/styletest -collection:wb=src -vet -out:build/styletest.exe $Stack 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\styletest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\stt.txt
        if (-not $p.WaitForExit(60000 * $slow)) { $p.Kill(); Get-Content build\stt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\stt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'image formats end-to-end test (AVIF, WebP, SVG images and backgrounds, inline <svg>, Accept, <picture>)' {
        odin build src/tools/mediatest -collection:wb=src -vet -out:build/mediatest.exe $Stack
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\mediatest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\mdt.txt
        if (-not $p.WaitForExit(90000 * $slow)) { $p.Kill(); Get-Content build\mdt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\mdt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'images end-to-end test (events, srcset, picture, lazy, CSS images, cache, cancellation, 200 x 1 Mpx)' {
        odin build examples/imagestest -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:build/imagestest.wasm -o:size
        if ($LASTEXITCODE -ne 0) { return }
        odin build src/tools/imagestest -collection:wb=src -vet -out:build/imagestest.exe $Stack
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\imagestest.exe -ArgumentList 'build\imagestest.wasm' -NoNewWindow -PassThru -RedirectStandardOutput build\imt.txt
        if (-not $p.WaitForExit(180000 * $slow)) { $p.Kill(); Get-Content build\imt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\imt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'web-platform-tests (wpt\suites.txt, pinned; -Quick: a sample; fails on a regression against wpt\expectations)' {
        # the WPT origin of the step's server: the fourth port of its block
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\wpt.ps1', '-NoServer', '-Port', ([int]$env:WREN_TEST_BASE_PORT + 3), '-TimeoutMs', (10000 * $slow))
        if ($Quick) { $a += '-Quick' }
        powershell @a
    }
    if ($Jobs -gt 1) { Flush-Steps }
} finally {
    Stop-WrenTestServer $srv
    $script:serverSteps = $false
    Remove-Item Env:\WREN_TEST_BASE_PORT -ErrorAction SilentlyContinue
    # (interrupted: the steps still running end, and their servers with them)
    Get-Job | Where-Object { $_.Id -ne $script:watchdog.Id } | Remove-Job -Force -ErrorAction SilentlyContinue
}

if (-not $Quick) {
    Step 'network stress' { powershell -NoProfile -File tools\net_stress.ps1 -SizeMB 100 }
    Step 'native WOFF2 decoder tests (real Google Fonts against their TrueType, collections, corruptions) and cssaudit' {
        $env:PATH = "$root\build\tools\nasm-2.16.03;$env:PATH"
        cargo test --release --manifest-path native\media\Cargo.toml --target-dir build\media\target woff2 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o
        $ok = $o -match 'test result: ok'
        odin build src/tools/cssaudit -collection:wb=src -vet -out:build/cssaudit.exe $Stack
        $global:LASTEXITCODE = if ($ok -and $LASTEXITCODE -eq 0) { 0 } else { 1 }
    }
}
if ($Jobs -gt 1) { Flush-Steps }
Stop-Job $script:watchdog; Remove-Job $script:watchdog -Force
[IO.File]::WriteAllText($timesFile, (($script:times.Keys | Sort-Object | ForEach-Object { "$_`t$($script:times[$_])" }) -join "`n") + "`n")
"failed steps: $failed ($([int]((Get-Date) - $runStart).TotalSeconds) s, -Jobs $Jobs)"
exit $failed
