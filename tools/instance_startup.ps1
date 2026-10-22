# What the single instance costs a start: the time from the process start to the first present (TOOLKIT_RENDER_TRACE) of
# wren_prof.exe with WREN_SINGLE_INSTANCE=off and with =on (the same binary, a scratch profile each run), interleaved, and the
# time a second start takes to hand its address over and end. Medians over the runs. Holds bench.lock (the runs are timed).
#   powershell -NoProfile -File tools\instance_startup.ps1 [-Exe wren_prof.exe] [-Runs 9]
param([string]$Exe = 'wren_prof.exe', [int]$Runs = 9, [int]$SettleMs = 2500)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'test_env.ps1')
function Median($v) { $s = @($v | Sort-Object); if ($s.Count -eq 0) { return 0 }; $s[[int][Math]::Floor(($s.Count - 1) / 2)] }
$exe = Join-Path $root "build\$Exe"
$scratch = Join-Path $root "build\tmp\instance_startup_$([guid]::NewGuid().ToString('N').Substring(0, 6))"
New-Item -ItemType Directory -Force $scratch | Out-Null
$bench = Enter-WrenLock bench 'instance_startup.ps1'
$times = @{ off = @(); on = @() }
$second = @()
try {
    for ($i = 0; $i -lt $Runs; $i++) {
        foreach ($mode in 'off', 'on') {
            $env:WREN_SINGLE_INSTANCE = $mode
            $env:TOOLKIT_RENDER_TRACE = '1'
            $err = "$scratch\err_$mode.txt"
            $p = Start-Process $exe -ArgumentList '--profile', "$scratch\p_$mode`_$i", 'about:home' -PassThru -RedirectStandardError $err -RedirectStandardOutput "$scratch\out.txt"
            Start-Sleep -Milliseconds $SettleMs
            if ($mode -eq 'on' -and $i -lt 5) {
                # a second start with the same profile: hand-over time
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $b = Start-Process $exe -ArgumentList '--profile', "$scratch\p_$mode`_$i", 'about:wren' -PassThru
                $b.WaitForExit(10000) | Out-Null
                $second += $sw.Elapsed.TotalMilliseconds
            }
            $p.Kill(); $p.WaitForExit(5000) | Out-Null
            $m = Select-String -Path $err -Pattern 'first present ([\d\.]+) ms' | Select-Object -First 1
            if ($m) { $times[$mode] += [double]$m.Matches[0].Groups[1].Value }
            Remove-Item Env:TOOLKIT_RENDER_TRACE -ErrorAction SilentlyContinue
        }
    }
} finally {
    Exit-WrenLock $bench
    Remove-Item Env:TOOLKIT_RENDER_TRACE -ErrorAction SilentlyContinue
    $env:WREN_SINGLE_INSTANCE = 'off'
    if (Test-Path $scratch) { try { [IO.Directory]::Delete($scratch, $true) } catch { } }
}
"first present, WREN_SINGLE_INSTANCE=off: median {0:N1} ms  ({1})" -f (Median $times.off), (($times.off | ForEach-Object { '{0:N0}' -f $_ }) -join ' ')
"first present, WREN_SINGLE_INSTANCE=on : median {0:N1} ms  ({1})" -f (Median $times.on), (($times.on | ForEach-Object { '{0:N0}' -f $_ }) -join ' ')
"difference of the medians: {0:N1} ms" -f ((Median $times.on) - (Median $times.off))
"a second start (hand over and end): median {0:N0} ms  ({1})" -f (Median $second), (($second | ForEach-Object { '{0:N0}' -f $_ }) -join ' ')
