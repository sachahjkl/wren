# Measures the chrome's UI build on about:config with the profiling build (build.bat profile -> build\browser_prof.exe):
# a quiet phase (no input: how many frames are drawn), a wheel scroll down then up the list, then the pointer moving
# over the rows. Prints the Build_UI time (ui build + layout of the chrome) and the boxes built per frame, per phase.
#   powershell -File tools\cfg_bench.ps1 [-Tag before] [-Exe build\browser_prof.exe] [-Url about:config]
# Opens the browser window: take the shared lock first (S:\wb_wt\BRIEF.md).
param([string]$Tag = "run", [string]$Exe = "build\browser_prof.exe", [string]$Url = "about:config", [int]$Width = 1280, [int]$Height = 1000,
      [int]$QuietMs = 2000, [int]$ScrollMs = 3000, [int]$HoverMs = 3000, [switch]$Sample, [string]$Extra = "",
      [int]$X = 40, [int]$Y = 40, [string]$From = "")
# -X / -Y: where the window goes (screen pixels); -From "x,y": where it is put first (another monitor: a DPI change)
# -Extra: one more argument for the browser (e.g. --pref=browser.title.stats=false)
# -Sample: the sampling profiler too (WREN_SAMPLE=1: build\cfgbench_<tag>.txt lists where the time went)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type @"
using System; using System.Runtime.InteropServices;
public class CB {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
}
"@
[CB]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$prefix = Join-Path $root "build\cfgbench_$Tag"
$profile = Join-Path $root "build\cfgbench_profile"
New-Item -ItemType Directory -Force $profile | Out-Null
$env:WREN_PROF = $prefix
if ($Sample) { $env:WREN_SAMPLE = '1' }
$p = Start-Process (Join-Path $root $Exe) -ArgumentList (@('--profile', $profile) + @($Extra | Where-Object { $_ }) + @($Url)) -PassThru
Remove-Item Env:WREN_PROF
if ($Sample) { Remove-Item Env:WREN_SAMPLE }
$marks = @{}
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    while (-not $p.HasExited -and $p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20; $p.Refresh() }
    $h = $p.MainWindowHandle
    if ($From) { $f = $From -split ','; [CB]::SetWindowPos($h, [IntPtr](-1), [int]$f[0], [int]$f[1], $Width, $Height, 0x10) | Out-Null; Start-Sleep -Milliseconds 1500 }
    [CB]::SetWindowPos($h, [IntPtr](-1), $X, $Y, $Width, $Height, 0x10) | Out-Null   # topmost, fixed size
    $r = New-Object CB+RECT; [CB]::GetClientRect($h, [ref]$r) | Out-Null
    $cx = [int]($r.R * 0.45); $cy = [int]($r.B * 0.6)
    $pt = New-Object CB+POINT; $pt.X = $cx; $pt.Y = $cy; [CB]::ClientToScreen($h, [ref]$pt) | Out-Null
    [CB]::SetCursorPos($pt.X + $r.R, $pt.Y) | Out-Null   # the real pointer away from the list
    Start-Sleep -Milliseconds 2500
    $t0 = $sw.ElapsedMilliseconds
    Start-Sleep -Milliseconds $QuietMs
    $marks.quiet = @($t0, $sw.ElapsedMilliseconds)
    # wheel: down then up, one notch per 16 ms (screen coordinates in lParam)
    $lpScreen = [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))
    $t1 = $sw.ElapsedMilliseconds
    while ($sw.ElapsedMilliseconds - $t1 -lt $ScrollMs) {
        $down = ($sw.ElapsedMilliseconds - $t1) -lt ($ScrollMs / 2)
        $delta = if ($down) { -120 } else { 120 }
        [CB]::PostMessage($h, 0x020A, [IntPtr](($delta -band 0xFFFF) -shl 16), $lpScreen) | Out-Null
        Start-Sleep -Milliseconds 16
    }
    Start-Sleep -Milliseconds 500
    $marks.scroll = @($t1, $sw.ElapsedMilliseconds)
    # hover: the pointer sweeps up and down over the rows (client coordinates)
    $t2 = $sw.ElapsedMilliseconds
    $i = 0
    while ($sw.ElapsedMilliseconds - $t2 -lt $HoverMs) {
        $y = [int]($r.B * 0.3 + ($r.B * 0.6) * [math]::Abs((($i % 120) - 60) / 60.0))
        [CB]::PostMessage($h, 0x0200, [IntPtr]::Zero, [IntPtr](($y -shl 16) -bor ($cx -band 0xFFFF))) | Out-Null
        $i++
        Start-Sleep -Milliseconds 16
    }
    $marks.hover = @($t2, $sw.ElapsedMilliseconds)
    [CB]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null   # WM_CLOSE: the profiler writes its report
    if (-not $p.WaitForExit(15000)) { $p.Kill(); throw "the browser did not exit" }
} finally { if (-not $p.HasExited) { $p.Kill() } }

# the profiler's clock starts at prof_init, some time after the process: the last frame (WM_CLOSE) aligns both clocks
$rows = Import-Csv "$prefix.csv"
$offset = [double]$rows[-1].t_ms - $marks.hover[1]
function In($r, $m) { $t = [double]$r.t_ms - $offset; return $t -ge $m[0] -and $t -lt $m[1] }
function Stats($name, $sel) {
    $b = @($sel | ForEach-Object { [double]$_.Build_UI }) | Sort-Object
    $n = $b.Count
    if ($n -eq 0) { "{0,-7} frames 0" -f $name; return }
    $boxes = @($sel | ForEach-Object { [int]$_.ui_boxes }) | Measure-Object -Average -Maximum
    $mean = ($b | Measure-Object -Average).Average
    "{0,-7} frames {1,5}  Build_UI mean {2,7:N3} ms  p50 {3,7:N3}  p95 {4,7:N3}  max {5,7:N3}  ui boxes avg {6,6:N0} max {7,6}" -f $name, $n, $mean, $b[[int]($n / 2)], $b[[math]::Min($n - 1, [int]($n * 0.95))], $b[$n - 1], $boxes.Average, $boxes.Maximum
}
$q = $rows | Where-Object { In $_ $marks.quiet }
$s = $rows | Where-Object { In $_ $marks.scroll }
$hv = $rows | Where-Object { In $_ $marks.hover }
"about:config bench ($Tag): $($rows.Count) frames in total"
Stats 'quiet' $q
Stats 'scroll' $s
Stats 'hover' $hv
