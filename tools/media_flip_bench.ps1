# What a window width that crosses a media query breakpoint costs: a profiler build (build.bat profile) driven by `wren ctl`
# (no window shown, synthetic input), the window made narrower and wider than a breakpoint in turn (-Narrow / -Wide, in CSS px at
# 96 dpi), -Flips times, the page then left still. Prints the frames that did a style pass (CPU, style ms, layout ms) and the
# profiler's own count of full and partial passes and their reasons. A measurement: nothing asserts.
#   powershell -NoProfile -File tools\media_flip_bench.ps1 [-Url https://sacha.house/projects] [-Narrow 600] [-Wide 700] [-Flips 40] [-Sample] [-Tag flip]
param([string]$Url = 'https://sacha.house/projects', [int]$Narrow = 600, [int]$Wide = 700, [int]$Flips = 40, [switch]$Sample, [string]$Tag = 'flip',
      [string]$Exe = 'wren_prof.exe', [int]$Height = 800, [string[]]$Pref = @())
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
Remove-Item -Recurse -Force (Join-Path $out 'profile') -ErrorAction SilentlyContinue   # (a profile remembers the open panel and the window)
$null = Start-Wren -Size "${Wide}x$Height" -Dpi 96 -Pref $Pref -ProfileDir (Join-Path $out 'profile')
$wrenPid = [int]((Wren-Ctl ping --json) | ConvertFrom-Json).pid
$t0 = (Get-Process -Id $wrenPid).StartTime
$now = { ((Get-Date) - $t0).TotalMilliseconds }
try {
    Wren-Nav $Url -Wait idle | Out-Null
    Start-Sleep 3
    $a = & $now
    for ($i = 0; $i -lt $Flips; $i++) {
        $w = if ($i % 2 -eq 0) { $Narrow } else { $Wide }
        $null = Wren-Ctl window --size "${w}x$Height"
        Start-Sleep -Milliseconds 400
    }
    $b = & $now
    Start-Sleep -Milliseconds 300
} finally { try { Stop-Wren } catch {} }
Start-Sleep 3
if (-not (Test-Path "$pre.csv")) { 'no profiler csv'; return }
$rows = @(Import-Csv "$pre.csv" | Where-Object { [double]$_.t_ms -ge $a -and [double]$_.t_ms -le $b + 300 })
$inv = [Globalization.CultureInfo]::InvariantCulture
$sty = @($rows | Where-Object { [double]::Parse($_.Styles, $inv) -gt 0.5 })
$ms = @($sty | ForEach-Object { [double]::Parse($_.Styles, $inv) } | Sort-Object)
$cpu = @($rows | ForEach-Object { [double]::Parse($_.Frame, $inv) - [double]::Parse($_.Wait, $inv) - [double]::Parse($_.Present, $inv) } | Sort-Object)
"frames {0} | frames with a style pass over 0.5 ms: {1} | style ms p50 {2} max {3}" -f $rows.Count, $sty.Count, $(if ($ms.Count) { $ms[[int][math]::Floor(($ms.Count - 1) * 0.5)] } else { 0 }), $(if ($ms.Count) { $ms[-1] } else { 0 })
"frame CPU: p50 {0} p95 {1} max {2} | over 16.7 ms: {3} | over 8 ms: {4} | over 5.6 ms: {5}" -f $cpu[[int][math]::Floor(($cpu.Count - 1) * 0.5)], $cpu[[int][math]::Floor(($cpu.Count - 1) * 0.95)], $cpu[-1], @($cpu | Where-Object { $_ -gt 16.7 }).Count, @($cpu | Where-Object { $_ -gt 8 }).Count, @($cpu | Where-Object { $_ -gt 5.6 }).Count
Select-String -Path "$pre.txt" -Pattern 'style passes|style engine rebuilds|full pass x|partial pass x' | ForEach-Object { $_.Line }


$inv2 = [Globalization.CultureInfo]::InvariantCulture
$rows | Where-Object { [double]::Parse($_.Frame, $inv2) - [double]::Parse($_.Wait, $inv2) - [double]::Parse($_.Present, $inv2) -gt 8 } | ForEach-Object {
    "  t {0,8:N0}  cpu {1,6:N1}  styles {2,6:N1}  layout {3,6:N1} ({4})  paint {5,5:N1}  loop {6,6:N1}  anim {7,6:N1}  ui {8,5:N1}" -f [double]::Parse($_.t_ms, $inv2), ([double]::Parse($_.Frame, $inv2) - [double]::Parse($_.Wait, $inv2) - [double]::Parse($_.Present, $inv2)), [double]::Parse($_.Styles, $inv2), [double]::Parse($_.Layout, $inv2), $_.lay_pass, [double]::Parse($_.Paint_Items, $inv2), [double]::Parse($_.Loop, $inv2), [double]::Parse($_.Animation, $inv2), [double]::Parse($_.Build_UI, $inv2)
}