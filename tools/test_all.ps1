# Runs every test of the project: unit tests, the end-to-end page test, the network stress script.
#   powershell -File tools\test_all.ps1 [-Quick] [-Engines wasmtime,wamr]
#   (-Quick skips the long network stress; the page, web API and workers end-to-end tests run once per Wasm engine)
param([switch]$Quick, [string[]]$Engines = @('wasmtime', 'wamr'))
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$failed = 0
function Step($name, [scriptblock]$body) {
    $out = & $body 2>&1 | Out-String
    $ok = $LASTEXITCODE -eq 0 -or $out -match 'All tests were successful'
    "{0} {1}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name
    if (-not $ok) { $script:failed++; ($out -split "`n" | Select-Object -Last 15) -join "`n" }
}

New-Item -ItemType Directory -Force build | Out-Null
foreach ($pkg in 'base', 'host', 'dom', 'html', 'url', 'http', 'cookies', 'csp', 'fetch', 'config', 'css', 'style', 'webfont', 'images', 'layout', 'forms', 'page', 'browser') {
    Step "unit tests: $pkg" { odin test "src/$pkg" -collection:toolkit=ext/gui_toolkit -collection:wb=src -vet -out:"build/${pkg}_test.exe" 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
}

Step 'unit tests: wasm (both engines)' { odin test src/wasm -collection:wb=src -vet -define:ODIN_TEST_THREADS=1 -out:build/wasm_test.exe 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
Step 'host-call thunks up to date' { odin run src/tools/wasmthunks -collection:wb=src -vet -out:build/wasmthunks.exe -- -check }

Step 'graphics toolkit tests (layers, filters, blend modes, clip shapes, blend spaces, text on DirectWrite; WARP)' { $o = ''; foreach ($t in 'layers', 'effects', 'blend_space', 'text') { $o += odin test "ext/gui_toolkit/tests/$t" -vet -out:"build/toolkit_${t}_test.exe" 2>&1 | Out-String }; $o -replace 'All tests were successful', 'passed'; $global:LASTEXITCODE = if (([regex]::Matches($o, 'All tests were successful')).Count -eq 4) { 0 } else { 1 } }
Step 'build guest e2e.wasm' { odin build examples/e2e -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:build/e2e.wasm -o:size }
Step 'build guest counter.wasm' { odin build examples/counter -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:examples/site/counter.wasm -o:size }
Step 'build guest formstest.wasm' { odin build examples/formstest -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:examples/site/formstest.wasm -o:size }
Step 'build guest mutation.wasm' { odin build examples/mutation -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:examples/site/mutation.wasm -o:size }
Step 'build guest mutation_class.wasm' { odin build examples/mutation_class -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:examples/site/mutation_class.wasm -o:size }
Step 'build formstest' { odin build src/tools/formstest -collection:wb=src -vet -out:build/formstest.exe }
Step 'build pagetest' { odin build src/tools/pagetest -collection:wb=src -vet -out:build/pagetest.exe }
Step 'build policytest' { odin build src/tools/policytest -collection:wb=src -vet -out:build/policytest.exe }
Step 'build web API test (guest + tool)' { odin build examples/webapitest -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:build/webapitest.wasm -o:size; if ($LASTEXITCODE -eq 0) { odin build src/tools/webapitest -collection:wb=src -vet -out:build/webapitest.exe } }
Step 'build fetch' { odin build src/tools/fetch -collection:wb=src -vet -out:build/fetch.exe }
Step 'build testserver' { Push-Location tools\testserver; go build -o ..\..\build\testserver.exe .; Pop-Location }

$srv = Start-Process (Join-Path $root 'build\testserver.exe') -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 1
try {
    Step 'network policy test (CORS, cookies, redirects, CSP, schemes)' {
        $p = Start-Process .\build\policytest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\pol.txt
        if (-not $p.WaitForExit(120000)) { $p.Kill(); Get-Content build\pol.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\pol.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)\b0 failure\(s\)') { 0 } else { 1 }
    }
    foreach ($engine in $Engines) {
    Step "end-to-end page test ($engine)" {
        $p = Start-Process .\build\pagetest.exe -ArgumentList 'build\e2e.wasm','examples\site\index.html','examples\site\counter.wasm','--pref',"wasm.engine=$engine" -NoNewWindow -PassThru -RedirectStandardOutput build\pt.txt
        if (-not $p.WaitForExit(90000)) { $p.Kill(); Get-Content build\pt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\pt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    }
    Step 'EventSource / WebSocket end-to-end test (netapitest)' {
        odin build examples/netapitest -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:build/netapitest.wasm -o:size
        if ($LASTEXITCODE -ne 0) { return }
        odin build src/tools/netapitest -collection:wb=src -vet -out:build/netapitest.exe
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\netapitest.exe -ArgumentList 'build\netapitest.wasm' -NoNewWindow -PassThru -RedirectStandardOutput build\nat.txt
        if (-not $p.WaitForExit(180000)) { $p.Kill(); Get-Content build\nat.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\nat.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    foreach ($engine in $Engines) {
    Step "web platform API test (timers, rAF, abort, fetch streams, encoding, crypto, storage, URL, history; $engine)" {
        $p = Start-Process .\build\webapitest.exe -ArgumentList 'build\webapitest.wasm','--pref',"wasm.engine=$engine" -NoNewWindow -PassThru -RedirectStandardOutput build\wt.txt
        if (-not $p.WaitForExit(90000)) { $p.Kill(); Get-Content build\wt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\wt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    }
    Step 'forms end-to-end test (controls, validation, FormData, submission)' {
        $p = Start-Process .\build\formstest.exe -ArgumentList 'examples\site\forms.html','examples\site\formstest.wasm' -NoNewWindow -PassThru -RedirectStandardOutput build\ft.txt
        if (-not $p.WaitForExit(90000)) { $p.Kill(); Get-Content build\ft.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\ft.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    foreach ($engine in $Engines) {
    Step "workers end-to-end test (messages, transfer, fetch, terminate, 16 in parallel; $engine)" {
        if ($engine -eq $Engines[0]) {
            odin build examples/workerstest -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:build/workerstest.wasm -o:size
            if ($LASTEXITCODE -ne 0) { return }
            odin build examples/workerstest_worker -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:examples/site/workerstest_worker.wasm -o:size
            if ($LASTEXITCODE -ne 0) { return }
            odin build src/tools/workerstest -collection:wb=src -vet -out:build/workerstest.exe
            if ($LASTEXITCODE -ne 0) { return }
        }
        $p = Start-Process .\build\workerstest.exe -ArgumentList 'build\workerstest.wasm','examples\site\workerstest_worker.wasm','--pref',"wasm.engine=$engine" -NoNewWindow -PassThru -RedirectStandardOutput build\wkt.txt
        if (-not $p.WaitForExit(180000)) { $p.Kill(); Get-Content build\wkt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\wkt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    }
    Step 'style run-time test (web fonts, transitions, animations)' {
        odin build src/tools/styletest -collection:wb=src -vet -out:build/styletest.exe 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\styletest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\stt.txt
        if (-not $p.WaitForExit(60000)) { $p.Kill(); Get-Content build\stt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\stt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
    Step 'images end-to-end test (events, srcset, picture, lazy, CSS images, cache, cancellation, 200 x 1 Mpx)' {
        odin build examples/imagestest -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:build/imagestest.wasm -o:size
        if ($LASTEXITCODE -ne 0) { return }
        odin build src/tools/imagestest -collection:wb=src -vet -out:build/imagestest.exe
        if ($LASTEXITCODE -ne 0) { return }
        $p = Start-Process .\build\imagestest.exe -ArgumentList 'build\imagestest.wasm' -NoNewWindow -PassThru -RedirectStandardOutput build\imt.txt
        if (-not $p.WaitForExit(180000)) { $p.Kill(); Get-Content build\imt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\imt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
} finally { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }

if (-not $Quick) {
    Step 'network stress' { powershell -NoProfile -File tools\net_stress.ps1 -SizeMB 100 }
}
"failed steps: $failed"
exit $failed
