# What every frame of a drag of the docked developer tools' splitter costs, with the page's width at that frame: a profiler build
# (build.bat profile) driven by `wren ctl` (no window shown, synthetic input), the network allowed. One mouse move per step, a short
# pause after it so that the frames of a step are told apart. Prints the frames over -Over ms with their phases and the width.
#   powershell -NoProfile -File tools\dt_split_probe.ps1 [-Url https://sacha.house/projects] [-Step 14] [-Lo 300] [-Hi 900] [-Sample]
# Output: build\sp\<tag>.csv (the profiler's), <tag>.steps.csv (step, window x, page width in CSS px, time range) and the summary.
param([string]$Url = 'https://sacha.house/projects', [int]$Step = 14, [int]$Lo = 300, [int]$Hi = 900, [switch]$Sample, [string]$Tag = 'probe',
      [string]$Exe = 'wren_prof.exe', [double]$Over = 8, [string]$Size = '2000x1000', [int]$Pause = 45, [string[]]$Pref = @())
$ErrorActionPreference = 'Stop'
$Pref = @($Pref | ForEach-Object { $_ -split ',' } | Where-Object { $_ })   # (-File passes "a,b" as one string)
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
[Environment]::CurrentDirectory = $root
$env:WREN_EXE = Join-Path $root "build\$Exe"
. "$PSScriptRoot\wrenctl.ps1"
$out = Join-Path $root 'build\sp'
New-Item -ItemType Directory -Force $out | Out-Null
$pre = Join-Path $out $Tag
Remove-Item "$pre.*" -ErrorAction SilentlyContinue
$env:WREN_PROF = $pre
$env:WREN_SAMPLE = if ($Sample) { '1' } else { '0' }
$env:WREN_SAMPLE_STACK = if ($Sample) { '1' } else { '0' }
function Ev($t, $x, $y, $b = 'left') { $null = Wren-Ctl raw ('{"method":"Input.dispatchMouseEvent","params":{"type":"' + $t + '","x":' + $x + ',"y":' + $y + ',"button":"' + $b + '","space":"window"}}') }
Remove-Item -Recurse -Force (Join-Path $out 'profile') -ErrorAction SilentlyContinue   # (a profile remembers the open panel and the window)
$null = Start-Wren -Size $Size -Pref $Pref -ProfileDir (Join-Path $out 'profile')   # (a throwaway profile ends the process without the profiler's report)
$wrenPid = [int]((Wren-Ctl ping --json) | ConvertFrom-Json).pid
$t0 = (Get-Process -Id $wrenPid).StartTime
$now = { ((Get-Date) - $t0).TotalMilliseconds }
$steps = New-Object Collections.Generic.List[object]
try {
    Wren-Nav $Url -Wait idle | Out-Null
    Start-Sleep 2
    $null = Wren-Ctl devtools console --dock right
    Start-Sleep 1
    $info = (Wren-Eval "innerWidth+' '+devicePixelRatio") -split ' '
    $w0 = [double]$info[0]; $dpr = [double]$info[1]
    $x = [int]($w0 * $dpr + 3); $y = 500
    Ev mouseMoved $x $y; Start-Sleep -Milliseconds 200
    Ev mousePressed $x $y
    $k = 0
    $path = @()
    $cur = [int]($w0 * $dpr)
    $hiPx = [int]($Hi * $dpr); $loPx = [int]($Lo * $dpr)
    for ($v = $cur; $v -le $hiPx; $v += $Step) { $path += $v }
    for ($v = $hiPx; $v -ge $loPx; $v -= $Step) { $path += $v }
    for ($v = $loPx; $v -le $hiPx; $v += $Step) { $path += $v }
    foreach ($v in $path) {
        $a = & $now
        Ev mouseMoved ($v + 3) $y
        Start-Sleep -Milliseconds $Pause
        $b = & $now
        $w = [double](Wren-Eval 'innerWidth')
        $steps.Add([pscustomobject]@{ step = $k; x = $v + 3; width = $w; from = [int]$a; to = [int]$b }); $k++
    }
    Ev mouseReleased ($path[-1] + 3) $y
    Start-Sleep -Milliseconds 500
    Wren-Ctl console | Set-Content "$pre.console.txt"
} finally { try { Stop-Wren } catch {} }
Start-Sleep 3
$steps | Export-Csv "$pre.steps.csv" -NoTypeInformation
if (-not (Test-Path "$pre.csv")) { 'no profiler csv'; return }
$rows = @(Import-Csv "$pre.csv")
# the offset between the process's start and the profiler's clock: the first step's frame is the first one after its start
$first = $steps[0].from
$cand = @($rows | Where-Object { [double]$_.t_ms -ge 0 })
$ph = 'Events', 'Loop', 'Input', 'Animation', 'Build_UI', 'Styles', 'Layout', 'Paint_Items', 'Submit'
$res = foreach ($r in $rows) {
    $t = [double]$r.t_ms
    $cpu = [double]$r.Frame - [double]$r.Wait - [double]$r.Present
    $s = $steps | Where-Object { $t -ge $_.from -and $t -le ($_.to + 60) } | Select-Object -First 1
    if (-not $s) { continue }
    $top = $ph | Sort-Object { -[double]$r.$_ } | Select-Object -First 1
    [pscustomobject]@{ t = [int]$t; step = $s.step; width = $s.width; cpu = [math]::Round($cpu, 2); top = $top; topms = [math]::Round([double]$r.$top, 2); styles = [math]::Round([double]$r.Styles, 2); layout = [math]::Round([double]$r.Layout, 2); lay = $r.lay_pass; ev = [math]::Round([double]$r.Events, 2); loop = [math]::Round([double]$r.Loop, 2); inp = [math]::Round([double]$r.Input, 2); ui = [math]::Round([double]$r.Build_UI, 2) }
}
$res | Export-Csv "$pre.frames.csv" -NoTypeInformation
$c = @($res | ForEach-Object { $_.cpu } | Sort-Object)
function P($p) { $c[[int][math]::Floor(($c.Count - 1) * $p)] }
"frames in the drag: {0} | CPU p50 {1} p95 {2} max {3} | over 16.7 ms: {4} | over 8 ms: {5} | over 5.6 ms: {6}" -f $c.Count, (P 0.5), (P 0.95), $c[-1], @($c | Where-Object { $_ -gt 16.7 }).Count, @($c | Where-Object { $_ -gt 8 }).Count, @($c | Where-Object { $_ -gt 5.6 }).Count
$res | Where-Object { $_.cpu -gt $Over } | Format-Table -AutoSize | Out-String -Width 250

