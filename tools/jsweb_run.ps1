# Runs src\tools\jswebtest (built in build\jswebtest.exe) with a test server on a block of ports of its own
# (tools\test_env.ps1): no lock, other runs keep theirs.
#   powershell -NoProfile -File tools\jsweb_run.ps1 [test names...]
param([int]$TimeoutSec = 600, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Tests = @())
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
. (Join-Path $PSScriptRoot 'test_env.ps1')
$srv = Start-WrenTestServer
try {
    $env:WREN_TEST_BASE_PORT = "$($srv.BasePort)"
    $argList = @($Tests | Where-Object { $_ })
    $p = if ($argList.Count -gt 0) { Start-Process .\build\jswebtest.exe -ArgumentList $argList -NoNewWindow -PassThru -RedirectStandardOutput build\jsw.txt } else { Start-Process .\build\jswebtest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\jsw.txt }
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill(); "jswebtest: killed after $TimeoutSec s" }
    Get-Content build\jsw.txt
    exit $p.ExitCode
} finally {
    Stop-WrenTestServer $srv
}
