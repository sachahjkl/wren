# Peak working set (MiB) of several engines running one script.
#   powershell -File tools\jsrt_mem.ps1 -Exes base=build\jsrt_judge_base.exe,qjs=build\qjs_ref.exe -Script examples\jsbench\cases\memory.js
param(
    [Parameter(Mandatory = $true)][string[]]$Exes,
    [string]$Script = "examples\jsbench\cases\memory.js"
)
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
foreach ($e in ($Exes | ForEach-Object { $_ -split "," })) {
    $p = $e -split "=", 2
    $argv = if ($p[0] -like "qjs*") { @($Script) } else { @("eval", $Script) }
    $proc = Start-Process -FilePath $p[1] -ArgumentList $argv -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\jsrt_mem_out.txt" -RedirectStandardError "$env:TEMP\jsrt_mem_err.txt"
    $peak = 0
    while (-not $proc.HasExited) {
        try { $proc.Refresh(); if ($proc.PeakWorkingSet64 -gt $peak) { $peak = $proc.PeakWorkingSet64 } } catch {}
        Start-Sleep -Milliseconds 5
    }
    "{0,-8} peak working set {1,7:N1} MiB  ({2})" -f $p[0], ($peak / 1MB), (Get-Content "$env:TEMP\jsrt_mem_err.txt" -ErrorAction SilentlyContinue | Select-Object -First 1)
}
