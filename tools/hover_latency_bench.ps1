# Input -> screen latency of a pointer sweep, stage by stage (WREN_LATENCY=1: the `latency` field of `wren ctl stats`).
# The pointer moves over the rows of the main menu (-Scenario menu) or along the toolbar (-Scenario toolbar); input is posted to
# the window (no desktop.lock), the run holds bench.lock.
#   powershell -File tools\hover_latency_bench.ps1 [-Exe wren_prof.exe] [-Scenario menu|toolbar] [-Secs 6] [-Every 4] [-Pref "name=value",...] [-Shot f.png] [-Gap 0]
# -Every: ms between two moves (4 = a 250 Hz mouse). -Gap n: pause n ms every 200 ms. -Isolated: one `wren ctl hover` every ~120 ms
# (lone moves after a pause, alternating between two points) instead of a stream. Synthetic input only, never the real mouse; the
# window is never shown (--headless) unless -Visible: the scan-out stage of a window nobody composes is not the real one, the others are.
# One line per run: refresh period, frames, samples and for each stage (wait for the frame, build + draw, Present, scan-out) and the
# total: p50 / p95 / max in ms, and the total in refreshes of the monitor.
param([string]$Exe = 'wren_prof.exe', [string]$Scenario = 'menu', [int]$Secs = 6, [int]$Every = 4, [string[]]$Pref = @(), [string]$Shot = '', [int]$Gap = 0, [string]$Tag = '', [switch]$Isolated, [switch]$Visible)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type @"
using System; using System.Runtime.InteropServices;
public class HB {
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  // The top-level window of a process, shown or not (Process.MainWindowHandle only sees shown ones).
  public static IntPtr WindowOf(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p != pid) return true;
      var sb = new System.Text.StringBuilder(64); GetClassName(h, sb, 64);
      if (found == IntPtr.Zero && !sb.ToString().StartsWith("IME") && !sb.ToString().StartsWith("MSCTFIME")) found = h; return true; }, IntPtr.Zero);
    return found;
  }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
[HB]::SetProcessDPIAware() | Out-Null
. (Join-Path $PSScriptRoot 'test_env.ps1')
. (Join-Path $PSScriptRoot 'wrenctl.ps1')
$script:WrenExe = Join-Path $root "build\$Exe"
function MakeLp([int]$x, [int]$y) { [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF)) }
$prof = Join-Path $env:TEMP ("hl_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$rname = 'hl' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$env:WREN_REMOTE = $rname
$env:WREN_LATENCY = '1'
$bench = Enter-WrenLock bench "hover_latency_bench"
$p = $null
$res = $null
try {
    $argv = @("--remote=$rname", '--no-single-instance', '--profile', "`"$prof`"")
    if (-not $Visible) { $argv += '--headless' }
    foreach ($pr in $Pref) { $argv += @('--pref', $pr) }
    $argv += 'about:blank'
    $p = Start-Process $script:WrenExe -ArgumentList $argv -PassThru
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $h = [IntPtr]::Zero
    while (-not $p.HasExited -and $h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 50; $h = [HB]::WindowOf([uint32]$p.Id) }
    if ($h -eq [IntPtr]::Zero) { throw 'no window for the Wren process' }
    Wren-Ctl window --size 1280x800 | Out-Null
    Start-Sleep -Seconds 3
    if ($Scenario -eq 'menu') { Wren-Ctl cmd browser.main_menu | Out-Null; Start-Sleep -Seconds 1 }
    $c = New-Object HB+RECT; [HB]::GetClientRect($h, [ref]$c) | Out-Null
    if ($Scenario -eq 'menu') {
        $x0 = $c.R - [int]($c.R * 0.06); $x1 = $x0; $y0 = [int]($c.B * 0.2); $y1 = $y0 + [int]($c.B * 0.35)
    } else {
        $x0 = 10; $x1 = [int]($c.R * 0.12); $y0 = 58; $y1 = 58
    }
    Wren-Ctl stats --reset-latency | Out-Null
    if ($Isolated) {
        $n = 0; $s2 = [Diagnostics.Stopwatch]::StartNew()
        while ($s2.ElapsedMilliseconds -lt $Secs * 1000) {
            $f = $n % 2; $n++
            Wren-Ctl hover --window ("{0},{1}" -f [int]($x0 + ($x1 - $x0) * $f), [int]($y0 + ($y1 - $y0) * $f)) | Out-Null
            Start-Sleep -Milliseconds (80 + (Get-Random -Maximum 80))
        }
        $Secs = 0
    }
    $next = 0; $shot = $false; $s2 = [Diagnostics.Stopwatch]::StartNew(); $quiet = 0
    while ($s2.ElapsedMilliseconds -lt $Secs * 1000) {
        $t = $s2.ElapsedMilliseconds
        if ($Gap -gt 0 -and ($t % 200) -lt 20 -and $t -ge $quiet) { $quiet = $t + $Gap; Start-Sleep -Milliseconds $Gap; continue }
        if ($t -ge $next) {
            $f = 0.5 + 0.5 * [Math]::Sin($t / 300.0)
            [HB]::PostMessage($h, 0x0200, [IntPtr]::Zero, (MakeLp ([int]($x0 + ($x1 - $x0) * $f)) ([int]($y0 + ($y1 - $y0) * $f)))) | Out-Null
            $next = $t + $Every
        }
        if ($Shot -and -not $shot -and $t -gt $Secs * 500) { $shot = $true; Wren-Ctl shot $Shot --window | Out-Null }
        [Threading.Thread]::Yield() | Out-Null
    }
    Start-Sleep -Milliseconds 300
    $res = (Wren-Ctl stats --json) -join ''
    [HB]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    if (-not $p.WaitForExit(30000)) { $p.Kill() }
} finally { if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null }; Exit-WrenLock $bench; Remove-Item -Recurse -Force $prof -ErrorAction SilentlyContinue }

$j = $res | ConvertFrom-Json
$r = if ($j.result) { $j.result } else { $j }
$l = $r.latency
function S($st) { '{0,6:N1} {1,6:N1} {2,6:N1}' -f $st.p50, $st.p95, $st.max }
"{0} {1}  refresh {2:N2} ms  frames/s {3}  samples {4}  CPU p50 {5:N2} ms" -f $Scenario, $Tag, $l.refreshMs, $r.fps, $l.samples, $r.cpuMs
"  frames on screen {0}, from input {1}; swap chain queue (frames not yet on screen at a present) mean {2:N2} max {3}; tearing supported {4}, used {5}" -f $l.framesShown, $l.framesShownFromInput, $l.queueMean, $l.queueMax, $l.tearingSupported, $l.tearing
"  stage      p50    p95    max   (ms)"
"  wait    $(S $l.waitMs)"
"  work    $(S $l.workMs)"
"  present $(S $l.presentMs)"
"  scan    $(S $l.scanMs)"
"  TOTAL   $(S $l.totalMs)"
"  refreshes (total / period)  {0:N1} {1:N1} {2:N1}" -f $l.totalRefreshes.p50, $l.totalRefreshes.p95, $l.totalRefreshes.max
