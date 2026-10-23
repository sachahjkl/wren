# What "load a page, wait, capture" costs: the old way (a window on the screen, captured from the screen by tools\screenshot.ps1)
# against `wren ctl` (no window shown, captured from the renderer's frame).
#   powershell -NoProfile -File tools\remote_bench.ps1 [-Runs 5] [-Out build\tmp\remote_bench.txt]
# The old way holds desktop.lock (it uses the real screen), so it waits when another run captures; the new way takes no lock.
# Each line is the median of -Runs, in ms, for the whole call (PowerShell start-up included where a script is called).
param([int]$Runs = 5, [string]$Out = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\test_env.ps1"
. "$PSScriptRoot\wrenctl.ps1"
$tmp = Join-Path $env:TEMP "wren-remote-bench-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Median($xs) { $s = @($xs | Sort-Object); return $s[[int][Math]::Floor($s.Count / 2)] }
function Time-Runs([scriptblock]$block) {
    $t = @()
    for ($i = 0; $i -lt $Runs; $i++) { $sw = [Diagnostics.Stopwatch]::StartNew(); & $block; $t += $sw.ElapsedMilliseconds }
    return Median $t
}

$lines = @()
$server = Start-WrenTestServer
try {
    $url = "$($server.Origin)/site/remote/fixture.html"
    $png = Join-Path $tmp 'b.png'
    $old = Time-Runs { powershell -NoProfile -File "$PSScriptRoot\screenshot.ps1" -Url $url -Out $png | Out-Null }
    $lines += "old, screenshot.ps1 as it is (WaitMs 1500, SettleMs 300): $old ms"
    $oldTuned = Time-Runs { powershell -NoProfile -File "$PSScriptRoot\screenshot.ps1" -Url $url -Out $png -WaitMs 500 -SettleMs 100 | Out-Null }
    $lines += "old, waits cut to the least that gives the same picture (WaitMs 500, SettleMs 100): $oldTuned ms"
    $viaScript = Time-Runs { powershell -NoProfile -File "$PSScriptRoot\screenshot.ps1" -Url $url -Out $png -Remote | Out-Null }
    $lines += "new, screenshot.ps1 -Remote (a script call, PowerShell start-up included): $viaScript ms"
    $run = Time-Runs { $null = Wren-Run -Url $url -Shot $png -Size 1280x800 -Wait load }
    $lines += "new, wren ctl run (start the browser, load, capture, close): $run ms"
    $name = Start-Wren -Size 1280x800
    try {
        $null = Wren-Ctl nav $url
        $shot = Time-Runs { $null = Wren-Ctl shot $png }
        $lines += "new, a capture of a Wren that runs (wren ctl shot): $shot ms"
        $navShot = Time-Runs { $null = Wren-Ctl nav $url; $null = Wren-Ctl shot $png }
        $lines += "new, navigate + wait for load + capture, Wren already running: $navShot ms"
        $eval = Time-Runs { $null = Wren-Ctl eval '1+1' }
        $lines += "new, wren ctl eval '1+1' (a process start and one round trip): $eval ms"
    } finally { Stop-Wren $name }
} finally { Stop-WrenTestServer $server }
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
$lines
if ($Out) { Set-Content -Path $Out -Value $lines -Encoding UTF8 }
