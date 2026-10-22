# Runs every test of the project: unit tests, the end-to-end page test, the network stress script.
#   powershell -File tools\test_all.ps1 [-Quick] [-CI] [-Jobs n] [-BasePort n]
#   (-Quick skips the long network stress; -CI, for continuous integration runners: -Quick, end-to-end timeouts x3 for
#   slow shared machines, the whole output of a failed step instead of its last lines, one step at a time on the
#   default ports. Nothing here reaches the internet, and with -Quick nothing opens a window: the end-to-end tests use
#   the local test server on 127.0.0.1, the pixel tests WARP; only the pinned test suites, test262 and
#   web-platform-tests, are fetched once into build\. -CI and full runs also run the browser's check build, in a
#   window of its own that takes no input of the desktop.)
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
    $names = @{}
    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
        while ($running.Count -lt $Jobs -and $pending.Count -gt 0) {
            $s = $pending[0]; $pending.RemoveAt(0)
            $j = Start-Job -ScriptBlock $stepJob -ArgumentList $s.Name, $s.Body, $s.Server, $root, $Stack, $slow, [bool]$Quick, [bool]$CI, $BasePort, $s.Vars
            $running[$j.Id] = $j
            $names[$j.Id] = $s.Name
        }
        foreach ($j in @($running.Values)) {
            if ($j.State -eq 'Running' -or $j.State -eq 'NotStarted') { continue }
            $all = @(Receive-Job $j -ErrorAction SilentlyContinue -ErrorVariable jerr)
            $r = $all | Where-Object { $_.PSObject.Properties['Ok'] } | Select-Object -Last 1
            $why = "$($j.ChildJobs[0].JobStateInfo.Reason) $jerr"
            Remove-Job $j -Force; $running.Remove($j.Id)
            if (-not $r) { Report "$($names[$j.Id]) (ended without a result: job $($j.Id), $($j.State))" $false $why 0; continue }
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
# unit tests fail on a leak or a bad free (Odin's runner tracks each test's context.allocator but only warns by default)
$MemCheck = '-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true'
# the end-to-end tools track every allocation of the process (package base's tracker, every thread) and fail when
# anything is left once they have shut down (src\tools\testenv\memory.odin); never in the builds of the browser
$Track = '-define:WREN_TRACK_MEMORY=true'
$script:watchdog = Start-Watchdog
"test_all: $root, -Jobs $Jobs, test server ports from $BasePort, started $(Get-Date -Format 'HH:mm:ss')"
# the JavaScript engine every build below embeds (nothing to do when build\js is up to date)
Step 'JavaScript engine (tools\build_js.ps1; nothing to do when up to date)' { powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_js.ps1 | Out-Null }
if ($Jobs -gt 1) { Flush-Steps }
foreach ($pkg in 'base', 'host', 'dom', 'html', 'url', 'http', 'cookies', 'csp', 'httpcache', 'fetch', 'config', 'css', 'style', 'webfont', 'images', 'layout', 'forms', 'js', 'page', 'webauthn', 'license', 'browser') {
    Step "unit tests: $pkg" { odin test "src/$pkg" -use-separate-modules $MemCheck -collection:toolkit=ext/gui_toolkit -collection:wb=src -vet -out:"build/${pkg}_test.exe" $Stack 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
}

Step 'unit tests: wasm' { odin test src/wasm -use-separate-modules $MemCheck -collection:wb=src -vet -define:ODIN_TEST_THREADS=1 -out:build/wasm_test.exe $Stack 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
Step 'unit tests: bindgen (description language, determinism)' { odin test src/tools/bindgen/idl -use-separate-modules $MemCheck -collection:wb=src -vet -out:build/bindgen_test.exe $Stack 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
Step 'process allocators: no runtime.default_context / heap_allocator / default_allocator outside src\base\memory.odin (base.process_context, process_allocator, permanent_allocator: what the check builds track; a line that must not use the tracker says why after // memcheck:)' {
    $hits = @(Get-ChildItem src -Recurse -Filter *.odin | Where-Object { $_.Name -notlike '*_test.odin' -and $_.FullName -notlike '*\src\base\memory.odin' } |
        Select-String -Pattern 'runtime\.(default_context|heap_allocator|default_allocator)\(\)' | Where-Object { $_.Line -notmatch '// memcheck: ' } | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" })
    $hits
    $global:LASTEXITCODE = $hits.Count
}
Step 'generated web API up to date (bindgen -check)' { odin run src/tools/bindgen -collection:wb=src -vet -out:build/bindgen.exe $Stack -- -check }
Step 'test262 in the Wasm engine (-Quick: every 25th test; fails on a failure src\tools\test262\known_failures.txt does not list), then the JIT: examples\jsbench\jitcheck.js interpreted and compiled (every function and loop at once, synchronously and with the step path) and test262 the same way (one step: both runs build and write build\test262)' { $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\test262.ps1', '-NoNative'); if ($Quick) { $a += '-Quick' }; powershell @a; if ($LASTEXITCODE) { return }; odin build src/tools/jsengine -use-separate-modules -collection:wb=src -vet -o:speed -out:build\jsengine_jit.exe $Stack; if ($LASTEXITCODE) { return }; & build\jsengine_jit.exe verify -image build\js\wren_js.wasm -jit -jit-threshold 1 -jit-loop 1 -jit-sync examples\jsbench\jitcheck.js; if ($LASTEXITCODE) { return }; & build\jsengine_jit.exe verify -image build\js\wren_js.wasm -jit -jit-threshold 1 -jit-loop 1 -jit-sync -jit-step examples\jsbench\jitcheck.js; if ($LASTEXITCODE) { return }; $a += @('-Jit', '-JitSync', '-JitThreshold', '2', '-JitLoop', '1'); powershell @a }
Step 'web API conformance (generated cases: bounds, UTF-8, handles, enums, capacity)' {
    odin build examples/apiconformance -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -out:build/apiconformance.wasm -o:size
    if ($LASTEXITCODE -ne 0) { return }
    odin build src/tools/apiconformance -use-separate-modules -collection:wb=src -vet $Track -out:build/apiconformance.exe $Stack
    if ($LASTEXITCODE -ne 0) { return }
    .\build\apiconformance.exe build\apiconformance.wasm
}

Step 'graphics toolkit pixel tests (layers, projected planes, filters, kept filter results, blend modes, clip shapes, blend spaces, gradients, shadows, retained pictures, text on DirectWrite, color glyphs, masks, precompiled shaders, Slug text; WARP)' { $o = ''; $suites = 'layers', 'planes', 'effects', 'gpufx', 'blend_space', 'gradients', 'shadows', 'retained', 'text', 'color_glyphs', 'masks', 'shaders', 'slug'; foreach ($t in $suites) { $o += odin test "ext/gui_toolkit/tests/$t" -use-separate-modules $MemCheck -vet -out:"build/toolkit_${t}_test.exe" 2>&1 | Out-String }; $o -replace 'All tests were successful', 'passed'; $global:LASTEXITCODE = if (([regex]::Matches($o, 'All tests were successful|The test was successful')).Count -eq $suites.Count) { 0 } else { 1 } }
Step 'graphics toolkit keyboard tests (menus, lists, line edit history, wrapped text; no window)' { odin test ext/gui_toolkit/tests/keyboard -use-separate-modules $MemCheck -vet -define:ODIN_TEST_THREADS=1 -out:build/toolkit_keyboard_test.exe 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
Step 'graphics toolkit window chrome tests (title bar hit test and regions, virtual list, wrap cache, scroll curve; no window)' { odin test ext/gui_toolkit/tests/chrome -use-separate-modules $MemCheck -vet -define:ODIN_TEST_THREADS=1 -out:build/toolkit_chrome_test.exe 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
Step 'graphics toolkit cursor tests (CSS names, system or drawn, drawn shapes, custom cursors; a hidden window, never shown)' { odin test ext/gui_toolkit/tests/cursors -use-separate-modules $MemCheck -vet -define:ODIN_TEST_THREADS=1 -out:build/toolkit_cursors_test.exe 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
Step 'graphics toolkit status tests (sample history, frame graph; no window)' { odin test ext/gui_toolkit/tests/status -use-separate-modules $MemCheck -vet -define:ODIN_TEST_THREADS=1 -out:build/toolkit_status_test.exe 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
Step 'graphics toolkit interaction states tests (hover, press and selection at once, transitions on demand, palette cross-fade, state fills in both blend spaces; no window)' { odin test ext/gui_toolkit/tests/states -use-separate-modules $MemCheck -vet -define:ODIN_TEST_THREADS=1 -out:build/toolkit_states_test.exe 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
Step 'build guest e2e.wasm' { odin build examples/e2e -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:build/e2e.wasm -o:size }
Step 'build guest counter.wasm' { odin build examples/counter -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:examples/site/counter.wasm -o:size }
Step 'build guest formstest.wasm' { odin build examples/formstest -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:examples/site/formstest.wasm -o:size }
Step 'build guest mutation.wasm' { odin build examples/mutation -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:examples/site/mutation.wasm -o:size }
Step 'build guest mutation_class.wasm' { odin build examples/mutation_class -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:examples/site/mutation_class.wasm -o:size }
Step 'build formstest' { odin build src/tools/formstest -use-separate-modules -collection:wb=src -vet $Track -out:build/formstest.exe $Stack }
Step 'build pagetest' { odin build src/tools/pagetest -use-separate-modules -collection:wb=src -vet $Track -out:build/pagetest.exe $Stack }
Step 'JavaScript in pages (jstest: realm, scripts, bindings, events, wrappers and node lifetime, bytecode cache, interruption)' { odin build src/tools/jstest -use-separate-modules -collection:wb=src -vet $Track -out:build/jstest.exe -o:speed $Stack; if ($LASTEXITCODE -eq 0) { .\build\jstest.exe } }
Step 'build policytest' { odin build src/tools/policytest -use-separate-modules -collection:wb=src -vet $Track -out:build/policytest.exe $Stack }
Step 'build web API test (guest + tool)' { odin build examples/webapitest -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:build/webapitest.wasm -o:size; if ($LASTEXITCODE -eq 0) { odin build src/tools/webapitest -use-separate-modules -collection:wb=src -vet $Track -out:build/webapitest.exe $Stack } }
Step 'build fetch' { odin build src/tools/fetch -use-separate-modules -collection:wb=src -vet -out:build/fetch.exe $Stack }
Step 'licence tool (tools\license.ps1: a licence issued with the development pair verifies; an altered one and one of another key do not; keygen refuses a path inside the repository)' {
    odin build src/tools/license -use-separate-modules -collection:wb=src -vet -out:build/license.exe $Stack
    if ($LASTEXITCODE -ne 0) { return }
    $f = 'build\tmp\license_tool_test.wrenlicense'
    Remove-Item $f -ErrorAction SilentlyContinue
    & build\license.exe issue -dev -name 'Test Name' -email t@example.org -edition patron -order T-1 -out $f | Out-Null
    if ($LASTEXITCODE -ne 0) { 'issue failed'; return }
    $v = & build\license.exe verify $f -dev | Out-String; $v
    if ($LASTEXITCODE -ne 0 -or $v -notmatch 'VALID: Patron licence of Test Name') { 'verify failed'; $global:LASTEXITCODE = 1; return }
    $text = (Get-Content $f | Where-Object { $_ -notmatch '^#' }) -join ''
    $i = $text.IndexOf('.') + 12
    $bad = $text.Substring(0, $i) + $(if ($text[$i] -eq 'A') { 'B' } else { 'A' }) + $text.Substring($i + 1)
    & build\license.exe verify -text $bad -dev | Out-Null
    if ($LASTEXITCODE -eq 0) { 'an altered licence verified'; $global:LASTEXITCODE = 1; return }
    & build\license.exe verify $f -public AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA | Out-Null
    if ($LASTEXITCODE -eq 0) { 'a licence verified with another key'; $global:LASTEXITCODE = 1; return }
    & build\license.exe keygen -private build\tmp\license_tool_private.key 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { 'keygen wrote a private key inside the repository'; Remove-Item build\tmp\license_tool_private.key; $global:LASTEXITCODE = 1; return }
    $global:LASTEXITCODE = 0
}
Step 'licence Worker (licence\worker, no network: Paddle-Signature checks, transaction.completed, idempotency, KV, mail, and licences made with the development pair verified by Wren''s own tool; SKIP when neither node 22.18+ nor bun is installed)' {
    $node = $null
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $v = [version]((node -p 'process.versions.node') -replace '[^0-9.]', '')
        if ($v -ge [version]'22.18') { $node = $true }
    }
    $bun = Get-Command bun -ErrorAction SilentlyContinue
    if (-not $node -and -not $bun) { 'SKIP: neither node 22.18+ nor bun is installed'; $global:LASTEXITCODE = 0; return }
    odin build src/tools/license -use-separate-modules -collection:wb=src -vet -out:build/license_worker.exe $Stack
    if ($LASTEXITCODE -ne 0) { return }
    $env:WREN_LICENSE_EXE = (Resolve-Path build\license_worker.exe).Path
    Push-Location licence\worker
    try {
        if ($node) { node --test 'test/*.test.ts' 2>&1 | Where-Object { $_ -notmatch '^\{"evt"' } } else { bun test test/ 2>&1 | Where-Object { $_ -notmatch '^\{"evt"' } }
        if ($LASTEXITCODE -eq 0) { 'All tests were successful.' }
    } finally { Pop-Location }
}
Step 'file: folders end-to-end test (index file, listing, redirect to /, errors, who may open what; no server)' {
    odin build src/tools/filetest -use-separate-modules -collection:wb=src -vet $Track -out:build/filetest.exe $Stack
    if ($LASTEXITCODE -ne 0) { return }
    $o = .\build\filetest.exe | Out-String; $o
    $global:LASTEXITCODE = if ($o -match '(?m)\b0 failure\(s\)') { 0 } else { 1 }
}
Step 'DOM for JavaScript end-to-end test (jsdomtest: tree, elements, markup, selectors, CSSOM, geometry, UI events, MutationObserver, traversal, ranges, leaks, micro-benchmarks; no server)' {
    odin build src/tools/jsdomtest -use-separate-modules -collection:wb=src -vet $Track -out:build/jsdomtest.exe -o:speed $Stack
    if ($LASTEXITCODE -ne 0) { return }
    $o = .\build\jsdomtest.exe | Out-String; $o
    $global:LASTEXITCODE = if ($o -match '(?m)\b0 failure\(s\)') { 0 } else { 1 }
}
Step 'history end-to-end test (historytest: the tree as pages see it, scrollRestoration, pageshow / pagehide persisted, back/forward cache freezing, persisted form state; no server)' {
    odin build src/tools/historytest -use-separate-modules -collection:wb=src -vet $Track -out:build/historytest.exe $Stack
    if ($LASTEXITCODE -ne 0) { return }
    $o = .\build\historytest.exe | Out-String; $o
    $global:LASTEXITCODE = if ($o -match '(?m)\b0 failure\(s\)') { 0 } else { 1 }
}
Step 'Web Authentication end-to-end test (webauthntest: create then get from JavaScript on the virtual authenticator, signature checked; activation, RP ID, aborts, timer, mediation, JSON forms, secure context; no server)' {
    odin build src/tools/webauthntest -use-separate-modules -collection:wb=src -vet $Track -out:build/webauthntest.exe $Stack
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
    Step 'HTTP cache end-to-end test (cachetest: freshness, revalidation, Vary, cache modes, partitions, invalidation, stale-while-revalidate, disk cache across a restart)' {
        odin build src/tools/cachetest -use-separate-modules -collection:wb=src -vet $Track -out:build/cachetest.exe $Stack
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\cachetest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\cat.txt
        if (-not $p.WaitForExit(120000 * $slow)) { $p.Kill(); Get-Content build\cat.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\cat.txt | Out-String; $o
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
        odin build src/tools/netapitest -use-separate-modules -collection:wb=src -vet $Track -out:build/netapitest.exe $Stack
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\netapitest.exe -ArgumentList 'build\netapitest.wasm' -NoNewWindow -PassThru -RedirectStandardOutput build\nat.txt
        if (-not $p.WaitForExit(180000 * $slow)) { $p.Kill(); Get-Content build\nat.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\nat.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'WebSocket closing handshake test (wsclosetest: close right after a message or the upgrade, late, missing and crossing close frames, server cutting TCP; repeated)' {
        odin build src/tools/wsclosetest -use-separate-modules -collection:wb=src -vet $Track -out:build/wsclosetest.exe
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
        odin build src/tools/workerstest -use-separate-modules -collection:wb=src -vet $Track -out:build/workerstest.exe $Stack
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\workerstest.exe -ArgumentList 'build\workerstest.wasm','examples\site\workerstest_worker.wasm' -NoNewWindow -PassThru -RedirectStandardOutput build\wkt.txt
        if (-not $p.WaitForExit(180000 * $slow)) { $p.Kill(); Get-Content build\wkt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\wkt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'JavaScript loading end-to-end test (script order, document.write, dynamic scripts, modules, handlers, CSP, noscript, timers, errors, workers, cloning)' {
        odin build src/tools/jsloadtest -use-separate-modules -collection:wb=src -vet $Track -out:build/jsloadtest.exe $Stack
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\jsloadtest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\jlt.txt
        if (-not $p.WaitForExit(180000 * $slow)) { $p.Kill(); Get-Content build\jlt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\jlt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'nested documents end-to-end test (framestest: iframes, srcdoc, load events, postMessage across origins, cross-origin WindowProxy, sandbox, X-Frame-Options, frame-ancestors, frame-src, navigation, Permissions Policy)' {
        odin build src/tools/framestest -use-separate-modules -collection:wb=src -vet -out:build/framestest.exe $Stack
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\framestest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\frt.txt
        if (-not $p.WaitForExit(180000 * $slow)) { $p.Kill(); Get-Content build\frt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\frt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'site compatibility end-to-end test (sitecompattest: reduced fixtures of real sites: stylesheet load events, media swap, scroll events)' {
        odin build src/tools/sitecompattest -use-separate-modules -collection:wb=src -vet $Track -out:build/sitecompattest.exe $Stack
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\sitecompattest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\sct.txt
        if (-not $p.WaitForExit(120000 * $slow)) { $p.Kill(); Get-Content build\sct.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\sct.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'JavaScript web APIs end-to-end test (fetch, XHR, streams, URL, encoding, abort, storage, history, navigator, crypto, sockets, messaging; jswebtest)' {
        odin build src/tools/jswebtest -use-separate-modules -collection:wb=src -vet $Track -out:build/jswebtest.exe $Stack
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\jswebtest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\jswt.txt
        if (-not $p.WaitForExit(300000 * $slow)) { $p.Kill(); Get-Content build\jswt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\jswt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)\b0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'style run-time test (web fonts, transitions, animations)' {
        odin build src/tools/styletest -use-separate-modules -collection:wb=src -vet $Track -out:build/styletest.exe $Stack 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\styletest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\stt.txt
        if (-not $p.WaitForExit(60000 * $slow)) { $p.Kill(); Get-Content build\stt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\stt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'image formats end-to-end test (AVIF, WebP, SVG images and backgrounds, inline <svg>, Accept, <picture>)' {
        odin build src/tools/mediatest -use-separate-modules -collection:wb=src -vet $Track -out:build/mediatest.exe $Stack
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\mediatest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\mdt.txt
        if (-not $p.WaitForExit(90000 * $slow)) { $p.Kill(); Get-Content build\mdt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\mdt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'images end-to-end test (events, srcset, picture, lazy, CSS images, cache, cancellation, 200 x 1 Mpx)' {
        odin build examples/imagestest -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:build/imagestest.wasm -o:size
        if ($LASTEXITCODE -ne 0) { return }
        odin build src/tools/imagestest -use-separate-modules -collection:wb=src -vet $Track -out:build/imagestest.exe $Stack
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

# The browser's check build (build.bat check: every allocation tracked) drives itself through a session and through
# tabs opened and closed by the dozen (tools\memcheck_e2e.ps1, tools\endurance.ps1): nothing may be left allocated at
# exit, nor grow while it runs. It opens a window (no input of the desktop's): with -CI, and in full runs, where the
# endurance run is the long one (400 tabs, the native memory too).
if ($CI -or -not $Quick) {
    Step 'browser check build: a scripted session (tabs, JavaScript, images, forms, back/forward cache, palette, history) exits with nothing allocated; tabs opened and closed by the dozen leave nothing growing (tracked bytes, handles; the native memory too in full runs)' {
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\memcheck_e2e.ps1 -TimeoutSec (300 * $slow)
        if ($LASTEXITCODE) { return }
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\endurance.ps1', '-NoBuild', '-TimeoutSec', (1800 * $slow))
        if ($Quick) { $a += @('-Cycles', '8', '-Warmup', '3', '-NoNative') }
        powershell @a
    }
}
# AddressSanitizer on the unit tests of every package (tools\asan.ps1, about 3 minutes): -CI and full runs.
if ($CI -or -not $Quick) {
    Step 'unit tests under AddressSanitizer (overflows, use after free, double frees; tools\asan.ps1)' {
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\asan.ps1
    }
}
if (-not $Quick) {
    Step 'network stress' { powershell -NoProfile -File tools\net_stress.ps1 -SizeMB 100 }
    Step 'native WOFF2 decoder tests (real Google Fonts against their TrueType, collections, corruptions) and cssaudit' {
        $env:PATH = "$root\build\tools\nasm-2.16.03;$env:PATH"
        cargo test --release --manifest-path native\media\Cargo.toml --target-dir build\media\target woff2 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o
        $ok = $o -match 'test result: ok'
        odin build src/tools/cssaudit -use-separate-modules -collection:wb=src -vet -out:build/cssaudit.exe $Stack
        $global:LASTEXITCODE = if ($ok -and $LASTEXITCODE -eq 0) { 0 } else { 1 }
    }
}
if ($Jobs -gt 1) { Flush-Steps }
Stop-Job $script:watchdog; Remove-Job $script:watchdog -Force
[IO.File]::WriteAllText($timesFile, (($script:times.Keys | Sort-Object | ForEach-Object { "$_`t$($script:times[$_])" }) -join "`n") + "`n")
"failed steps: $failed ($([int]((Get-Date) - $runStart).TotalSeconds) s, -Jobs $Jobs)"
exit $failed
