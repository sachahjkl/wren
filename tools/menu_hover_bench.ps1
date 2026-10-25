# Frame times and input -> screen latency while the pointer sweeps over the rows of the main menu (the burger menu).
# Needs build\wren_prof.exe (build.bat profile). Input is posted to the window (no desktop.lock); the run holds bench.lock.
#   powershell -File tools\menu_hover_bench.ps1 [-Exe wren_prof.exe] [-Tag suffix] [-Secs 6] [-Every 4] [-Out dir] [-Shot file.png]
# One line: the frames of the sweep (median / 95th percentile / worst CPU time of a frame), the time Build_UI and UI_Draw took,
# and the time from the pointer's move to the refresh that showed it (the profile's shown.csv: p50 / p95 / mean).
param([string]$Exe = 'wren_prof.exe', [string]$Tag = '', [int]$Secs = 6, [int]$Every = 4, [string]$Out = '', [string]$Shot = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$outDir = if ($Out) { $Out } else { Join-Path $root 'build\menubench' }
New-Item -ItemType Directory -Force $outDir | Out-Null
Add-Type @"
using System; using System.Runtime.InteropServices;
public class MB {
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
[MB]::SetProcessDPIAware() | Out-Null
. (Join-Path $PSScriptRoot 'test_env.ps1')
. (Join-Path $PSScriptRoot 'wrenctl.ps1')
$script:WrenExe = Join-Path $root "build\$Exe"
function Pct($v, $p) { if ($v.Count -eq 0) { return 0 }; $s = @($v | Sort-Object); $s[[Math]::Min($s.Count - 1, [Math]::Max(0, [int][Math]::Ceiling($s.Count * $p / 100) - 1))] }
function Rnd($x, $n = 1) { [math]::Round([double]$x, $n) }
function MakeLp([int]$x, [int]$y) { [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF)) }

$prefix = Join-Path $outDir "menu$Tag"
$env:WREN_PROF = $prefix
$env:WREN_SAMPLE = '0'
$prof = Join-Path $env:TEMP ("mb_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$rname = 'mb' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$env:WREN_REMOTE = $rname
$bench = Enter-WrenLock bench "menu_hover_bench"
$p = $null
try {
    $p = Start-Process $script:WrenExe -ArgumentList @("--remote=$rname", '--no-single-instance', '--profile', "`"$prof`"", 'about:blank') -PassThru
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20; $p.Refresh() }
    $h = $p.MainWindowHandle
    [MB]::SetWindowPos($h, [IntPtr]::Zero, 20, 20, 1280, 800, 0x14) | Out-Null
    Start-Sleep -Seconds 3
    Wren-Ctl cmd browser.main_menu | Out-Null
    Start-Sleep -Seconds 1
    $c = New-Object MB+RECT; [MB]::GetClientRect($h, [ref]$c) | Out-Null
    $x = $c.R - [int]($c.R * 0.06)
    $y0 = [int]($c.B * 0.2); $amp = [int]($c.B * 0.35)
    $t0 = $sw.ElapsedMilliseconds
    $next = 0; $shot = $false; $s2 = [Diagnostics.Stopwatch]::StartNew()
    while ($s2.ElapsedMilliseconds -lt $Secs * 1000) {
        if ($s2.ElapsedMilliseconds -ge $next) {
            $y = $y0 + [int]($amp * (0.5 + 0.5 * [Math]::Sin($s2.ElapsedMilliseconds / 300.0)))
            [MB]::PostMessage($h, 0x0200, [IntPtr]::Zero, (MakeLp $x $y)) | Out-Null
            $next = $s2.ElapsedMilliseconds + $Every
        }
        if ($Shot -and -not $shot -and $s2.ElapsedMilliseconds -gt $Secs * 500) { $shot = $true; Wren-Ctl shot $Shot --window | Out-Null }
        [Threading.Thread]::Yield() | Out-Null
    }
    $t1 = $sw.ElapsedMilliseconds
    [IO.File]::WriteAllText("$prefix.act", "$t0 $t1")
    [MB]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    if (-not $p.WaitForExit(30000)) { $p.Kill() }
} finally { if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null }; Exit-WrenLock $bench; Remove-Item -Recurse -Force $prof -ErrorAction SilentlyContinue }

$d = @(Import-Csv "$prefix.csv" | Where-Object { [double]$_.t_ms -ge $t0 -and [double]$_.t_ms -le $t1 })
$cpu = @($d | ForEach-Object { [double]$_.Frame - [double]$_.Wait - [double]$_.Present })
$lat = @(Import-Csv "$prefix.shown.csv" | Where-Object { [double]$_.t_ms -ge $t0 -and [double]$_.t_ms -le $t1 -and [double]$_.latency_ms -ge 0 } | ForEach-Object { [double]$_.latency_ms })
function Avg($col) { Rnd (($d | ForEach-Object { [double]$_.$col } | Measure-Object -Average).Average) 2 }
[pscustomobject]@{
    run = "menu$Tag"; frames = $d.Count; fps = Rnd ($d.Count / $Secs)
    cpu_p50 = Rnd (Pct $cpu 50) 2; cpu_p95 = Rnd (Pct $cpu 95) 2; cpu_max = Rnd ($cpu | Measure-Object -Maximum).Maximum
    build = Avg 'Build_UI'; draw = Avg 'UI_Draw'; submit = Avg 'Submit'; present = Avg 'Present'
    lat_n = $lat.Count; lat_p50 = Rnd (Pct $lat 50); lat_p95 = Rnd (Pct $lat 95); lat_mean = Rnd (($lat | Measure-Object -Average).Average)
} | Format-List | Out-String -Width 200 | Write-Host
