# The cost of a frame with many tabs (a measure: never in the CI; run it by hand, it prints numbers and asserts nothing
# unless -Perf or WREN_PERF=1 is given, then the budget of a 180 Hz frame applies to the median).
# A session of N tabs (restored, not loaded: as after a restart), in groups of ten every other ten, is opened in a Wren
# started by hand; frames are made (the toolkit rebuilds the tab bar each one) and the CPU time of a frame is read from
# `wren ctl stats`, for the row of tabs and the sidebar, with 10 and with N tabs.
#   powershell -NoProfile -File tools\sidebar_perf.ps1 [-Exe build\wren.exe] [-Tabs 1000] [-Frames 240] [-Perf]
param([string]$Exe = '', [int]$Tabs = 1000, [int]$Frames = 240, [switch]$Perf)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\wrenctl.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
$strict = $Perf -or $env:WREN_PERF -eq '1'
if ($env:CI) { $strict = $false }

function Measure-Case([int]$n, [string]$position) {
    $prof = Join-Path $env:TEMP "wren-sidebar-perf-$PID-$n-$position"
    New-Item -ItemType Directory -Force $prof | Out-Null
    $page = Join-Path $prof 'p.html'
    [IO.File]::WriteAllText($page, '<!doctype html><title>p</title>p')
    $u = 'file:///' + ($page -replace '\\', '/')
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append("wren-session 2`ncurrent 0`n")
    for ($g = 1; $g -le [Math]::Ceiling($n / 20); $g++) { [void]$sb.Append("tgroup`t$g`tblue`t0`tGroup $g`n") }
    for ($i = 0; $i -lt $n; $i++) {
        [void]$sb.Append("tab $u`?n=$i`n")
        if ([Math]::Floor($i / 10) % 2 -eq 0) { [void]$sb.Append("group $([Math]::Floor($i / 20) + 1)`n") }
    }
    [IO.File]::WriteAllText((Join-Path $prof 'session.txt'), $sb.ToString())
    $name = "side-perf-$PID-$n"
    $proc = Start-Process -PassThru -FilePath $env:WREN_EXE -ArgumentList "--remote=$name", '--profile', "`"$prof`"", '--headless', '--no-single-instance',
        '--pref', "browser.tabs.position=$position", '--pref', 'browser.session.restore=true', '--pref', "browser.session.max_tabs=$([Math]::Max($n, 100))"
    $env:WREN_REMOTE = $name
    try {
        $until = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $until) { Wren-Ctl ping | Out-Null; if ($WrenExit -eq 0) { break }; Start-Sleep -Milliseconds 200 }
        Wren-Ctl wait frames 30 | Out-Null
        $count = @((Wren-Ctl tabs --json | ConvertFrom-Json).targetInfos).Count
        Wren-Ctl stats --json --reset-frames | Out-Null
        Wren-Ctl wait frames $Frames | Out-Null
        $st = Wren-Ctl stats --json | ConvertFrom-Json
        return [pscustomobject]@{ tabs = $count; position = $position; cpuMs = $st.cpuMs; cpuP95Ms = $st.cpuP95Ms; cpuMaxMs = $st.cpuMaxMs; frames = $st.framesDrawn }
    } finally {
        Wren-Ctl quit | Out-Null
        if (-not $proc.WaitForExit(30000)) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        $env:WREN_REMOTE = ''
        Remove-Item -Recurse -Force $prof -ErrorAction SilentlyContinue
    }
}

$rows = @()
foreach ($pos in 'top', 'left') {
    foreach ($n in 10, $Tabs) { $rows += Measure-Case $n $pos }
}
$rows | Format-Table -AutoSize | Out-String | Write-Host
$fail = 0
if ($strict) {
    foreach ($r in $rows) {
        if ($r.cpuMs -gt 5.5) { "FAIL  $($r.tabs) tabs, $($r.position): $($r.cpuMs) ms of CPU a frame (the 180 Hz budget is 5.5)"; $fail++ }
    }
} else { 'perf: no budget asserted, run with -Perf' }
if ($fail) { exit 1 }
