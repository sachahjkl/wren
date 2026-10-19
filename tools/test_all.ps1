# Runs every test of the project: unit tests, the end-to-end page test, the network stress script.
#   powershell -File tools\test_all.ps1 [-Quick] [-CI]
#   (-Quick skips the long network stress; -CI, for continuous integration runners: -Quick, end-to-end timeouts x3 for
#   slow shared machines, the whole output of a failed step instead of its last lines. Nothing here opens a window or
#   reaches the internet: the end-to-end tests use the local test server on 127.0.0.1, the pixel tests WARP.)
param([switch]$Quick, [switch]$CI, [int]$StepTimeoutSec = 900)
if ($CI) { $Quick = $true }
$slow = if ($CI) { 3 } else { 1 }
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$failed = 0
$flaky = 0
# With -CI a failed step runs once more: shared runners are slow and noisy, and a few tests have timing assumptions
# (thread scheduling order, a close handshake racing a pong). A step that passes on its second run is reported as
# FLAKY with the output of the failed run, and counted at the end; it does not fail the build.
# A test executable that runs longer than -StepTimeoutSec is stopped, so a hung suite fails instead of blocking the run
# (Odin's test runner can hang when several tests hit fatal assertions at once).
function Start-Watchdog {
    Start-Job -ArgumentList $StepTimeoutSec -ScriptBlock {
        param($limit)
        while ($true) {
            Start-Sleep -Seconds 5
            Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*_test' -and $_.StartTime -and ((Get-Date) - $_.StartTime).TotalSeconds -gt $limit } | ForEach-Object {
                "watchdog: stopped $($_.ProcessName) after $limit s"; Stop-Process -Id $_.Id -Force }
        }
    }
}

function Step($name, [scriptblock]$body) {
    $t0 = Get-Date
    $out = & $body 2>&1 | Out-String
    $killed = Receive-Job $script:watchdog -ErrorAction SilentlyContinue
    if ($killed) { $out += "`n" + ($killed -join "`n"); $global:LASTEXITCODE = 1 }
    $ok = $LASTEXITCODE -eq 0 -or $out -match 'All tests were successful'
    if (-not $ok -and $CI) {
        $first = $out
        $out = & $body 2>&1 | Out-String
        $ok = $LASTEXITCODE -eq 0 -or $out -match 'All tests were successful'
        if ($ok) {
            $script:flaky++
            "FLAKY {0} (failed, then passed on retry; {1} s)" -f $name, [int]((Get-Date) - $t0).TotalSeconds
            ($first -split "`n" | Where-Object { $_ -match 'FAIL|ERROR|failure|failed' } | Select-Object -First 20) -join "`n"
            return
        }
    }
    "{0} {1}{2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $(if ($CI) { " ($([int]((Get-Date) - $t0).TotalSeconds) s)" } else { '' })
    if (-not $ok) { $script:failed++; if ($CI) { $out } else { ($out -split "`n" | Select-Object -Last 15) -join "`n" } }
}

New-Item -ItemType Directory -Force build | Out-Null
# Wasm calls run on the calling thread: every program that runs modules (the JavaScript engine needs 16 MiB of wasm
# stack, wasm.wasmtime.max_stack_bytes) is linked with a 32 MiB default thread stack
$Stack = '-extra-linker-flags:/STACK:33554432'
$script:watchdog = Start-Watchdog
foreach ($pkg in 'base', 'host', 'dom', 'html', 'url', 'http', 'cookies', 'csp', 'fetch', 'config', 'css', 'style', 'webfont', 'images', 'layout', 'forms', 'js', 'page', 'browser') {
    Step "unit tests: $pkg" { odin test "src/$pkg" -collection:toolkit=ext/gui_toolkit -collection:wb=src -vet -out:"build/${pkg}_test.exe" $Stack 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
}

Step 'unit tests: wasm' { odin test src/wasm -collection:wb=src -vet -define:ODIN_TEST_THREADS=1 -out:build/wasm_test.exe $Stack 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
Step 'unit tests: bindgen (description language, determinism)' { odin test src/tools/bindgen/idl -collection:wb=src -vet -out:build/bindgen_test.exe $Stack 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
Step 'generated web API up to date (bindgen -check)' { odin run src/tools/bindgen -collection:wb=src -vet -out:build/bindgen.exe $Stack -- -check }
Step 'web API conformance (generated cases: bounds, UTF-8, handles, enums, capacity)' {
    odin build examples/apiconformance -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -out:build/apiconformance.wasm -o:size
    if ($LASTEXITCODE -ne 0) { return }
    odin build src/tools/apiconformance -collection:wb=src -vet -out:build/apiconformance.exe $Stack
    if ($LASTEXITCODE -ne 0) { return }
    .\build\apiconformance.exe build\apiconformance.wasm
}

Step 'graphics toolkit pixel tests (layers, filters, kept filter results, blend modes, clip shapes, blend spaces, gradients, shadows, retained pictures, text on DirectWrite, color glyphs, masks; WARP)' { $o = ''; $suites = 'layers', 'effects', 'gpufx', 'blend_space', 'gradients', 'shadows', 'retained', 'text', 'color_glyphs', 'masks'; foreach ($t in $suites) { $o += odin test "ext/gui_toolkit/tests/$t" -vet -out:"build/toolkit_${t}_test.exe" 2>&1 | Out-String }; $o -replace 'All tests were successful', 'passed'; $global:LASTEXITCODE = if (([regex]::Matches($o, 'All tests were successful')).Count -eq $suites.Count) { 0 } else { 1 } }
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
Step 'build testserver (and its tests: /site/ index, listings, extensionless pages, types)' { Push-Location tools\testserver; go test . 2>&1; if ($LASTEXITCODE -eq 0) { go build -o ..\..\build\testserver.exe . }; Pop-Location }

$srv = Start-Process (Join-Path $root 'build\testserver.exe') -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 1
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
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_js.ps1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return }
        odin build src/tools/jsloadtest -collection:wb=src -vet -out:build/jsloadtest.exe $Stack
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\jsloadtest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\jlt.txt
        if (-not $p.WaitForExit(180000 * $slow)) { $p.Kill(); Get-Content build\jlt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\jlt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
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
} finally { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }

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
if ($CI) { "flaky steps (passed on retry): $flaky" }
Stop-Job $script:watchdog; Remove-Job $script:watchdog -Force
"failed steps: $failed"
exit $failed
