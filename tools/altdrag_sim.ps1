# What AltSnap (Alt + right button drag) does to a window, without a mouse and without AltSnap: from another thread, a run of
# SetWindowPos calls that change the size every few ms, between a WM_ENTERSIZEMOVE and a WM_EXITSIZEMOVE that AltSnap
# POSTS to the window (hooks.c, NotifySizeMoveStaEnd: PostMessage). Before each step it also SendMessageTimeout's WM_SIZING
# (LetWindowKickBack), as AltSnap does. Not a real system size loop: that one needs the mouse (resize_e2e.ps1).
#   powershell -NoProfile -File tools\altdrag_sim.ps1 [-Exe build\wren.exe] [-Secs 3] [-StepMs 6] [-Variants altsnap,plain] [-Page about:wren]
# Variants: `altsnap` = the posted messages around the steps and the WM_SIZING before each; `enterexit` = only the posted
# messages; `sizing` = only the WM_SIZING; `null` = a WM_NULL sent before each step (any cross-process send); `plain` = the
# steps alone. SMT = how long the SendMessageTimeout took to return.
# The window is shown but invisible to the person at the screen: fully transparent, click-through, not activated (the real
# mouse is not used). With -OffScreen it sits at x = -32000 instead; a window with no visible region gets no WM_PAINT, so
# the `plain` numbers then say little (the drag is not painted at all).
# For each variant it prints, from `wren ctl stats` (reset before the run): frames presented, the gap between two presents
# (p50 / p95 / max), frames made from the window procedure (paintFrames), the loops of the system entered (modalLoops), the
# WM_ENTERSIZEMOVE that were ignored, CPU time, and how long one SetWindowPos took to return (p50 / p95 / max): the time our
# thread needs to answer the caller's synchronous calls. Measures of time: for us to read, never asserted (not for the CI).
param([string]$Exe = '', [double]$Secs = 3, [int]$StepMs = 6, [string[]]$Variants = @('plain', 'altsnap'), [string]$Page = 'about:wren', [int]$Rounds = 1, [switch]$OffScreen)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$Variants = @($Variants | ForEach-Object { $_ -split ',' })   # (-File passes "a,b" as one string)
$env:WREN_EXE = (Resolve-Path $Exe).Path
$env:WREN_SINGLE_INSTANCE = 'off'
$env:WREN_LATENCY = '1'
. "$PSScriptRoot\wrenctl.ps1"
Add-Type @"
using System; using System.Collections.Generic; using System.Diagnostics; using System.Runtime.InteropServices; using System.Text; using System.Threading;
public class AltDrag {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, ref RECT l, uint f, uint t, out IntPtr r);
  [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
  [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint ms);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  const uint NOZORDER = 0x4, NOACTIVATE = 0x10, NOOWNERZORDER = 0x200;
  public static IntPtr FindWren(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); var sb = new StringBuilder(64); GetClassName(h, sb, 64);
      if (p == pid && sb.ToString() == "gui_toolkit_window") { found = h; return false; } return true; }, IntPtr.Zero);
    return found;
  }
  [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetLong(IntPtr h, int i);
  [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetLong(IntPtr h, int i, IntPtr v);
  [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
  public static void Close(IntPtr h) { PostMessage(h, 0x10, IntPtr.Zero, IntPtr.Zero); }
  public static int X = -32000;
  // ghost: the window keeps a place on a screen but is fully transparent (WS_EX_LAYERED alpha 0), click-through
  // (WS_EX_TRANSPARENT), out of the taskbar and never activated: a window off every screen gets no WM_PAINT at all (its
  // visible region is empty), which is not what a window being dragged over a screen does. Otherwise: off every screen.
  // Shown without activation, before anything else is seen of it.
  public static void Park(IntPtr h, int w, int hh, bool ghost) {
    if (ghost) {
      X = 200;
      long ex = GetLong(h, -20).ToInt64() | 0x80000 | 0x20 | 0x80 | 0x8000000;   // LAYERED | TRANSPARENT | TOOLWINDOW | NOACTIVATE
      SetLong(h, -20, (IntPtr)ex);
      SetLayeredWindowAttributes(h, 0, 0, 2);
    }
    SetWindowPos(h, IntPtr.Zero, X, 100, w, hh, NOZORDER | NOACTIVATE | NOOWNERZORDER);
    ShowWindow(h, 4);
  }
  // size sweep between (w0,h0) and (w1,h1) for ms milliseconds; returns the SetWindowPos durations in ms
  // notify: post WM_ENTERSIZEMOVE / WM_EXITSIZEMOVE around the run; sizing: SendMessageTimeout WM_SIZING before each step
  public static List<double> Send = new List<double>();
  public static double[] Drag(IntPtr h, bool notify, int sizing, int w0, int h0, int w1, int h1, int ms, int stepMs) {
    var times = new List<double>();
    timeBeginPeriod(1);
    try {
      if (notify) PostMessage(h, 0x231, IntPtr.Zero, IntPtr.Zero);
      var clock = Stopwatch.StartNew(); long step = 0;
      while (clock.ElapsedMilliseconds < ms) {
        double t = clock.ElapsedMilliseconds / 1000.0;
        int w = (int)(w0 + (w1 - w0) * (0.5 + 0.5 * Math.Sin(t * 5.0)));
        int hh = (int)(h0 + (h1 - h0) * (0.5 + 0.5 * Math.Sin(t * 3.0)));
        if (sizing > 0) { var rc = new RECT { L = X, T = 100, R = X + w, B = 100 + hh }; IntPtr r; long s0 = Stopwatch.GetTimestamp(); SendMessageTimeout(h, sizing == 1 ? 0x214u : 0u, (IntPtr)8, ref rc, 2, 64, out r); Send.Add((Stopwatch.GetTimestamp() - s0) * 1000.0 / Stopwatch.Frequency); }
        long a = Stopwatch.GetTimestamp();
        SetWindowPos(h, IntPtr.Zero, X, 100, w, hh, NOZORDER | NOACTIVATE | NOOWNERZORDER);
        times.Add((Stopwatch.GetTimestamp() - a) * 1000.0 / Stopwatch.Frequency);
        step++;
        long next = step * stepMs; long left = next - clock.ElapsedMilliseconds;
        if (left > 1) Thread.Sleep((int)(left - 1)); while (clock.ElapsedMilliseconds < next) { }
      }
      if (notify) PostMessage(h, 0x232, IntPtr.Zero, IntPtr.Zero);
    } finally { timeEndPeriod(1); }
    return times.ToArray();
  }
}
"@
function Pct([double[]]$a, [double]$q) { if ($a.Count -eq 0) { return 0 }; $s = $a | Sort-Object; return $s[[Math]::Min($s.Count - 1, [int][Math]::Floor($q * $s.Count))] }
$name = $null; $proc = $null
try {
    $name = Start-Wren -Size 1100x700 -Url $Page
    $wpid = [uint32]((Wren-Ctl ping --json | ConvertFrom-Json).pid)
    $proc = Get-Process -Id $wpid
    $h = [IntPtr]::Zero; $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 15000) { $h = [AltDrag]::FindWren($wpid); if ($h -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 50 } }
    if ($h -eq [IntPtr]::Zero) { throw 'no window of the Wren found' }
    [AltDrag]::Park($h, 1100, 700, -not $OffScreen)
    Start-Sleep -Milliseconds 800
    $null = Wren-Ctl wait idle --timeout 15000
    $null = [AltDrag]::Drag($h, $false, 0, 900, 600, 1300, 850, 1000, $StepMs)   # warm-up
    Start-Sleep -Milliseconds 500
    '{0,-8} {1,6} {2,9} {3,8} {4,8} {5,8} {6,7} {7,6} {8,7} {9,8} {10,8} {11,8} {12,8} {13,7} {14,8} {15,8}' -f 'variant', 'steps', 'presented', 'gap p50', 'gap p95', 'gap max', 'paintFr', 'modal', 'ignored', 'cpu ms', 'SWP p50', 'SWP p95', 'SWP max', 'shown', 'SMT p50', 'SMT p95'
    for ($round = 1; $round -le $Rounds; $round++) {
        foreach ($v in $Variants) {
            $null = Wren-Ctl stats --json --reset-frames --reset-latency
            $s0 = (Wren-Ctl stats --json | ConvertFrom-Json)
            [AltDrag]::Send.Clear(); $swp = [AltDrag]::Drag($h, ($v -in 'altsnap', 'enterexit'), $(if ($v -in 'altsnap', 'sizing') { 1 } elseif ($v -eq 'null') { 2 } else { 0 }), 900, 600, 1300, 850, [int]($Secs * 1000), $StepMs)
            Start-Sleep -Milliseconds 600
            $s = Wren-Ctl stats --json | ConvertFrom-Json
            $shown = if ($s.latency) { $s.latency.framesShown } else { -1 }
            '{0,-8} {1,6} {2,9} {3,8:N1} {4,8:N1} {5,8:N1} {6,7} {7,6} {8,7} {9,8:N0} {10,8:N2} {11,8:N2} {12,8:N2} {13,7} {14,8:N2} {15,8:N2}' -f $v, $swp.Count, $s.framesPresented, $s.frameGapP50Ms, $s.frameGapP95Ms, $s.frameGapMaxMs, $s.paintFrames, $s.modalLoops, $s.ignoredSizeMoves, ($s.cpuTimeMs - $s0.cpuTimeMs), (Pct $swp 0.5), (Pct $swp 0.95), (Pct $swp 1.0), $shown, (Pct ([AltDrag]::Send.ToArray()) 0.5), (Pct ([AltDrag]::Send.ToArray()) 0.95)
        }
    }
} finally {
    # (a profile run, WREN_PROF: closed as a person closes it, the report is written at that exit; ctl stop leaves at once)
    try { if ($name) { if ($env:WREN_PROF -and $h) { [AltDrag]::Close($h) } else { Stop-Wren } } } catch { }
    if ($proc) { $proc.Refresh(); if (-not $proc.HasExited) { $proc.WaitForExit(15000) | Out-Null }; if (-not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit(5000) | Out-Null } }
}
