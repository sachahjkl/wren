# Runs every test of the project: unit tests, the end-to-end page test, the network stress script.
#   powershell -File tools\test_all.ps1 [-Quick]       (-Quick skips the long network stress)
param([switch]$Quick)
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
foreach ($pkg in 'base', 'host', 'dom', 'html', 'url', 'http', 'cookies', 'csp', 'fetch') {
    Step "unit tests: $pkg" { odin test "src/$pkg" -collection:wb=src -vet -out:"build/${pkg}_test.exe" 2>&1 | Out-String | Tee-Object -Variable o | Out-Null; $o; if ($o -match 'All tests were successful') { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
}

Step 'build guest e2e.wasm' { odin build examples/e2e -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:build/e2e.wasm -o:size }
Step 'build guest counter.wasm' { odin build examples/counter -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:examples/site/counter.wasm -o:size }
Step 'build pagetest' { odin build src/tools/pagetest -collection:wb=src -vet -out:build/pagetest.exe }
Step 'build policytest' { odin build src/tools/policytest -collection:wb=src -vet -out:build/policytest.exe }
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
    Step 'end-to-end page test' {
        $p = Start-Process .\build\pagetest.exe -ArgumentList 'build\e2e.wasm','examples\site\index.html','examples\site\counter.wasm' -NoNewWindow -PassThru -RedirectStandardOutput build\pt.txt
        if (-not $p.WaitForExit(90000)) { $p.Kill(); Get-Content build\pt.txt; $global:LASTEXITCODE = 1; return }
        $o = Get-Content build\pt.txt | Out-String; $o
        $global:LASTEXITCODE = if ($o -match '(?m)^0 failure\(s\)') { 0 } else { 1 }
    }
} finally { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }

if (-not $Quick) {
    Step 'network stress' { powershell -NoProfile -File tools\net_stress.ps1 -SizeMB 100 }
}
"failed steps: $failed"
exit $failed
