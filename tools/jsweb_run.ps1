# Runs src\tools\jswebtest (built in build\jswebtest.exe) with the test server, under the shared lock of the worktrees.
#   powershell -NoProfile -File tools\jsweb_run.ps1 [test names...]
param([int]$TimeoutSec = 600, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Tests = @())
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$lockPath = Join-Path (Split-Path $root -Parent) 'shared.lock'
while ($true) { try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None'); break } catch { Start-Sleep -Milliseconds 500 } }
try {
    $srv = Start-Process (Join-Path $root 'build\testserver.exe') -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 1
    $argList = @($Tests | Where-Object { $_ })
    $p = if ($argList.Count -gt 0) { Start-Process .\build\jswebtest.exe -ArgumentList $argList -NoNewWindow -PassThru -RedirectStandardOutput build\jsw.txt } else { Start-Process .\build\jswebtest.exe -NoNewWindow -PassThru -RedirectStandardOutput build\jsw.txt }
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill(); "jswebtest: killed after $TimeoutSec s" }
    Get-Content build\jsw.txt
    exit $p.ExitCode
} finally {
    Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
    $lock.Close()
}
