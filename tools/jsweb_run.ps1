# Runs src\tools\jswebtest (the tests of core:testing built in build\jswebtest.exe) with a test server on a block of ports of its
# own (tools\test_env.ps1): no lock, other runs keep theirs. The names are those of its tests, one per section: core, fetch_api,
# webgl_api, webgl_process, media_queries, storage_event... (src\tools\jswebtest\sections.odin).
#   powershell -NoProfile -File tools\jsweb_run.ps1 [test names...]
param([int]$TimeoutSec = 600, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Tests = @())
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
. (Join-Path $PSScriptRoot 'test_env.ps1')
$srv = Start-WrenTestServer
try {
    $env:WREN_TEST_BASE_PORT = "$($srv.BasePort)"
    $names = @($Tests | Where-Object { $_ })
    $p = if ($names.Count -gt 0) { Start-Process .\build\jswebtest.exe -ArgumentList "-tests:$($names -join ',')" -NoNewWindow -PassThru -RedirectStandardOutput build\jsw.txt -RedirectStandardError build\jsw.err.txt } else { Start-Process .\build\jswebtest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\jsw.txt -RedirectStandardError build\jsw.err.txt }
    $null = $p.Handle   # (without it the exit code of a process started so is lost)
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill(); "jswebtest: killed after $TimeoutSec s" }
    Get-Content build\jsw.txt
    Get-Content build\jsw.err.txt
    exit $p.ExitCode
} finally {
    Stop-WrenTestServer $srv
}
