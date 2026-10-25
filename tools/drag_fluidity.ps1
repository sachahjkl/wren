# Measures how fluid dragging a tab along the strip is, without touching the screen or the real mouse.
#
#   powershell -NoProfile -File tools\drag_fluidity.ps1 [-Remote name] [-FromX 140 -ToX 760 -Y 35 -DurationMs 800 -Rate 1000] [-Pref name=value ...]
#
# A pointer is posted to the window (WM_MOUSEMOVE / WM_LBUTTONDOWN / WM_LBUTTONUP, as a 1 kHz mouse would) along a straight line
# at constant speed; the browser records, for every frame built while the tab is held (browser.frame.drag_probe), the pointer it
# read, where the tab was drawn and the refresh that showed it (`wren ctl stats --json`, field dragSamples). The report is:
#   lag (px, ms)   : where the pointer is on its line at the refresh the frame was shown at, minus where the tab is
#                    ("to screen"), and the same at the moment the frame read its input ("to frame")
#   step error     : between two refreshes the tab should have moved speed x elapsed; the difference in pixels (judder)
#   refresh gaps   : refreshes between two frames shown (1 = every refresh; 2 = one skipped)
#   dt             : the time step the animations were given (p50 / p95 / max, ms)
# With no -Remote a Wren with a throwaway profile is started and stopped at the end. A window that is never shown has no refresh
# to be shown at (no `shown` times): -Ghost shows it at 1 % opacity, click-through and never activated (for a run that must not
# disturb anyone); -Visible shows it as it is (the user's own screen: the monitor rate is the `hz` the report starts with).
# -Pref a=1,b=2 sets preferences (e.g. browser.frame.input_idle_periods=0: the old behaviour, to compare), -StartPref the ones that
# need a restart (browser.window.fixed_surface=false), -Dump / -DumpShown / -Timeline n print the raw frames, -Single the cost
# of lone pointer moves with the window at rest.
param(
    [string]$Remote = '',
    [int]$Tabs = 5,
    [int]$FromX = 140, [int]$ToX = 1000, [int]$Y = 35, [int]$Dpi = 96,
    [int]$DurationMs = 800,
    [int]$Rate = 1000,
    [string[]]$Pref = @(),
    [switch]$Visible,
    [switch]$Offscreen,
    [string]$StartPref = '',
    [switch]$Ghost,
    [switch]$Single,
    [int]$Dump = 0, [int]$DumpShown = 0, [int]$Timeline = 0,
    [string]$Size = '1280x800'
)
Set-Location (Split-Path $PSScriptRoot -Parent)
. tools\wrenctl.ps1

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class DragPoster {
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
    public static IntPtr FindWindow(uint pid) {
        IntPtr found = IntPtr.Zero; int best = 0;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            RECT r; if (p == pid && GetClientRect(h, out r) && r.r * r.b > best) { best = r.r * r.b; found = h; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint f);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetLong(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetLong(IntPtr h, int i, IntPtr v);
    // Shows a window that was never shown where nobody sees it: far outside every monitor, no taskbar button, never activated.
    // The compositor then presents its frames at the refresh, as for a window on the desktop (a hidden one has no refresh to wait for).
    public static void ShowFarAway(IntPtr h) {
        long ex = (long)GetLong(h, -20);
        SetLong(h, -20, (IntPtr)((ex | 0x80) & ~0x40000L));   // WS_EX_TOOLWINDOW, not WS_EX_APPWINDOW
        SetWindowPos(h, IntPtr.Zero, -30000, -30000, 0, 0, 0x0001 | 0x0004 | 0x0010);   // NOSIZE | NOZORDER | NOACTIVATE
        ShowWindow(h, 8);   // SW_SHOWNA
    }
    [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
    // Shows it on the desktop at 1 % opacity, click-through, no taskbar button, never activated: the compositor really presents
    // it at each refresh (one that is hidden or off every monitor is not waited for) and nobody sees or touches it.
    [DllImport("gdi32.dll")] static extern IntPtr CreateRectRgn(int a, int b, int c, int d);
    [DllImport("user32.dll")] static extern int SetWindowRgn(IntPtr h, IntPtr rgn, bool redraw);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    public static void ShowGhost(IntPtr h) {
        long ex = (long)GetLong(h, -20);
        SetLong(h, -20, (IntPtr)((ex | 0x80000 | 0x20 | 0x80 | 0x08000000) & ~0x40000L));   // LAYERED | TRANSPARENT | TOOLWINDOW | NOACTIVATE
        SetLayeredWindowAttributes(h, 0, 3, 2);   // 1 % opaque
        SetWindowPos(h, (IntPtr)(-1), 40, 40, 0, 0, 0x0001 | 0x0010);   // topmost, NOSIZE | NOACTIVATE
        ShowWindow(h, 8);
    }
    public static void Move(IntPtr h, int x, int y) { SetThreadDpiAwarenessContext((IntPtr)(-4)); PostMessageW(h, 0x0200, IntPtr.Zero, Pos(x, y)); }
    static IntPtr Pos(int x, int y) { return (IntPtr)((y << 16) | (x & 0xFFFF)); }
    static void Spin(long until) { while (Stopwatch.GetTimestamp() < until) { } }
    // press at (x0, y), hold still for holdMs, move along the line at rate Hz for ms, release. Returns the QPC tick the line starts at.
    public static long Run(IntPtr h, int x0, int x1, int y, int ms, int rate, int holdMs) {
        // per-monitor aware: an unaware sender's mouse coordinates are scaled by the window's DPI on delivery
        SetThreadDpiAwarenessContext((IntPtr)(-4));
        long f = Stopwatch.Frequency;
        PostMessageW(h, 0x0200, IntPtr.Zero, Pos(x0, y));
        Spin(Stopwatch.GetTimestamp() + f / 10);
        PostMessageW(h, 0x0201, (IntPtr)1, Pos(x0, y));
        Spin(Stopwatch.GetTimestamp() + f * holdMs / 1000);
        long t0 = Stopwatch.GetTimestamp();
        long step = f / rate; long end = t0 + f * ms / 1000;
        for (long t = t0 + step; t <= end; t += step) {
            Spin(t);
            double a = (double)(t - t0) / (end - t0);
            PostMessageW(h, 0x0200, (IntPtr)1, Pos((int)Math.Round(x0 + (x1 - x0) * a), y));
        }
        Spin(Stopwatch.GetTimestamp() + f / 20);
        PostMessageW(h, 0x0202, IntPtr.Zero, Pos(x1, y));
        return t0;
    }
}
'@

function Pct($a, [double]$q) { if ($a.Count -eq 0) { return [double]::NaN }; $s = $a | Sort-Object; return $s[[Math]::Min($s.Count - 1, [int][Math]::Floor($q * $s.Count))] }
function Fmt($v) { return ('{0,8:N2}' -f $v) }

$own = $false
if ($Remote -eq '') {
    $args2 = @{ Size = $Size; Dpi = $Dpi }
    if ($StartPref) { $args2.Pref = @($StartPref -split ',') }
    if ($Visible) { $args2.Visible = $true }
    $Remote = Start-Wren @args2
    $own = $true
}
$env:WREN_REMOTE = $Remote
try {
    foreach ($p in ($Pref -split ',')) { Wren-Ctl pref set ($p -split '=', 2)[0] ($p -split '=', 2)[1] | Out-Null }
    Wren-Ctl pref set browser.frame.drag_probe true | Out-Null
    $have = [int](Wren-Ctl stats --json | ConvertFrom-Json).tabs
    for ($i = $have; $i -lt $Tabs; $i++) { Wren-Ctl tab new about:blank | Out-Null }
    Start-Sleep -Milliseconds 1500
    $st0 = Wren-Ctl stats --json --reset-frames | ConvertFrom-Json
    $hwnd = [DragPoster]::FindWindow([uint32]$st0.pid)
    if ($hwnd -eq [IntPtr]::Zero) { throw 'no window of the process' }
    if ($Ghost) { [DragPoster]::ShowGhost($hwnd); Start-Sleep -Milliseconds 1500; Wren-Ctl stats --json --reset-frames | Out-Null }
    if ($Offscreen) { [DragPoster]::ShowFarAway($hwnd); Start-Sleep -Milliseconds 1500; Wren-Ctl stats --json --reset-frames | Out-Null }
    if ($Single) {
        # one pointer move at a time with the window at rest between them: what a lone event costs from input to screen
        Wren-Ctl stats --json --reset-latency | Out-Null
        foreach ($i in 1..12) { [DragPoster]::Move($hwnd, 200 + 37 * $i, 35); Start-Sleep -Milliseconds 400 }
        $l = (Wren-Ctl stats --json | ConvertFrom-Json).latency
        if ($l) { "lone events: {0} samples; input -> screen ms p50/p95 {1:N1} / {2:N1}, refreshes p50/p95 {3:N2} / {4:N2}; queue mean/max {5:N2} / {6}" -f $l.samples, $l.totalMs.p50, $l.totalMs.p95, $l.totalRefreshes.p50, $l.totalRefreshes.p95, $l.queueMean, $l.queueMax }
        Wren-Ctl stats --json --reset-latency --reset-frames | Out-Null
    }
    $t0 = [DragPoster]::Run($hwnd, $FromX, $ToX, $Y, $DurationMs, $Rate, 150)
    Start-Sleep -Milliseconds 500
    $st = Wren-Ctl stats --json | ConvertFrom-Json
    $freq = [Diagnostics.Stopwatch]::Frequency
    $t0us = [double]$t0 * 1e6 / $freq             # Odin's ticks are QPC in ns; the samples are in us
    $speed = ($ToX - $FromX) / ($DurationMs * 1000.0)   # px per us
    $period = 1e6 / $st.hz                        # us
    $rows = @($st.dragSamples | ForEach-Object { [pscustomobject]@{ read = $_[0]; shown = $_[1]; mouse = $_[2]; finger = $_[3]; dt = $_[4]; moves = $_[5]; done = $_[6]; waited = $_[7] } })
    $line = { param($t) $a = [Math]::Min([Math]::Max(($t - $t0us) / ($DurationMs * 1000.0), 0), 1); $FromX + ($ToX - $FromX) * $a }
    if ($Timeline) { $rows | Select-Object -Skip $Timeline -First 45 | ForEach-Object { '{0,9:N2} ms read +{1,5:N2} ms to Present returned, shown {2}' -f (($_.read - $t0us) / 1000), (($_.done - $_.read) / 1000), $(if ($_.shown) { '{0,9:N2}' -f (($_.shown - $t0us) / 1000) } else { '        -' }) } }
    if ($DumpShown) { $rows | Where-Object { $_.shown -gt 0 } | Select-Object -Skip 5 -First $DumpShown | ForEach-Object { '{0,9:N2} ms read, shown {1,9:N2} (+{2,6:N2} ms), tab {3,8:N1}, dt {4,6:N2} ms' -f (($_.read - $t0us) / 1000), (($_.shown - $t0us) / 1000), (($_.shown - $_.read) / 1000), $_.finger, ($_.dt * 1000) } }
    if ($Dump) { $rows | Select-Object -First $Dump | ForEach-Object { '{0,9:N2} ms read, mouse {1,8:N1}, tab {2,8:N1}, line {3,8:N1}, moves {4}' -f (($_.read - $t0us) / 1000), $_.mouse, $_.finger, (& $line $_.read), $_.moves } }
    # frames of the drag proper (the line is being followed; the tab is not stopped by the end of the strip)
    $rows = @($rows | Where-Object { $_.read -gt $t0us -and $_.read -lt $t0us + $DurationMs * 1000 -and [Math]::Abs($_.finger - $_.mouse) -lt 40 })
    if ($Dump) { $rows | Select-Object -First $Dump | ForEach-Object { '{0,9:N2} ms read, shown {1,9:N2}, mouse {2,8:N1}, tab {3,8:N1}, line {4,8:N1}, dt {5,6:N2} ms, moves {6}' -f (($_.read - $t0us) / 1000), $(if ($_.shown) { ($_.shown - $t0us) / 1000 } else { 0 }), $_.mouse, $_.finger, (& $line $_.read), ($_.dt * 1000), $_.moves } }
    $shown = @($rows | Where-Object { $_.shown -gt 0 } | Sort-Object shown)
    "monitor {0:N2} Hz ({1:N2} ms), {2} frames built while the tab moved, {3} shown, {4} never shown (replaced), line {5:N0} px/s" -f $st.hz, ($period / 1000), $rows.Count, $shown.Count, ($rows.Count - $shown.Count), ($speed * 1e6)
    if ($rows.Count -lt 3) { throw 'too few samples' }
    $lagIn = @($rows | ForEach-Object { (& $line $_.read) - $_.finger })
    "lag to frame (pointer read -> drawn)  px p50/p95/max: {0} {1} {2}" -f (Fmt (Pct $lagIn 0.5)), (Fmt (Pct $lagIn 0.95)), (Fmt (($lagIn | Measure-Object -Maximum).Maximum))
    "frames built per second: {0:N0}; pointer moves per frame p50 {1}" -f ($rows.Count * 1000.0 / $DurationMs), (Pct @($rows | ForEach-Object { $_.moves }) 0.5)
    $dts = @($rows | ForEach-Object { $_.dt * 1000 })
    "dt given to animations ms p50/p95/max: {0} {1} {2}" -f (Fmt (Pct $dts 0.5)), (Fmt (Pct $dts 0.95)), (Fmt (($dts | Measure-Object -Maximum).Maximum))
    if ($shown.Count -ge 3) {
        $lagOut = @($shown | ForEach-Object { (& $line $_.shown) - $_.finger })
        $lagMs = @($lagOut | ForEach-Object { $_ / ($speed * 1000) })
        "lag to screen (line at refresh - tab) px p50/p95/max: {0} {1} {2}   ms p50/p95/max: {3} {4} {5}" -f (Fmt (Pct $lagOut 0.5)), (Fmt (Pct $lagOut 0.95)), (Fmt (($lagOut | Measure-Object -Maximum).Maximum)), (Fmt (Pct $lagMs 0.5)), (Fmt (Pct $lagMs 0.95)), (Fmt (($lagMs | Measure-Object -Maximum).Maximum))
        $gaps = @(); $err = @()
        for ($i = 1; $i -lt $shown.Count; $i++) {
            $d = $shown[$i].shown - $shown[$i - 1].shown
            $gaps += [Math]::Round($d / $period, 2)
            $err += [Math]::Abs(($shown[$i].finger - $shown[$i - 1].finger) - $speed * $d)
        }
        "refreshes between two frames shown p50/p95/max: {0} {1} {2}; gaps over 1.5 refreshes: {3} of {4}" -f (Fmt (Pct $gaps 0.5)), (Fmt (Pct $gaps 0.95)), (Fmt (($gaps | Measure-Object -Maximum).Maximum)), @($gaps | Where-Object { $_ -gt 1.5 }).Count, $gaps.Count
        "step error per refresh px p50/p95/max: {0} {1} {2}" -f (Fmt (Pct $err 0.5)), (Fmt (Pct $err 0.95)), (Fmt (($err | Measure-Object -Maximum).Maximum))
    }
    $still = 0
    for ($i = 1; $i -lt $rows.Count; $i++) { if ($rows[$i].finger -eq $rows[$i - 1].finger -and $rows[$i].mouse -ne $rows[$i - 1].mouse) { $still++ } }
    "frames where the pointer moved and the tab did not: $still"
    if ($st.latency) { "swap chain queue (presented, not yet on screen) mean/max: {0:N2} / {1}; refreshes from input to screen p50/p95: {2:N2} / {3:N2}" -f $st.latency.queueMean, $st.latency.queueMax, $st.latency.totalRefreshes.p50, $st.latency.totalRefreshes.p95 }
    $busy = @($rows | Where-Object { $_.done -gt 0 } | ForEach-Object { ($_.done - $_.read) / 1000 })
    "read -> Present returned ms p50/p95/max: {0} {1} {2}" -f (Fmt (Pct $busy 0.5)), (Fmt (Pct $busy 0.95)), (Fmt (($busy | Measure-Object -Maximum).Maximum))
    $wt = @($rows | ForEach-Object { $_.waited })
    "wait for the screen's slot before the frame ms p50/p95/max: {0} {1} {2}" -f (Fmt (Pct $wt 0.5)), (Fmt (Pct $wt 0.95)), (Fmt (($wt | Measure-Object -Maximum).Maximum))
    "frame gaps (all presents) ms p50/p95/max: {0} {1} {2}" -f (Fmt $st.frameGapP50Ms), (Fmt $st.frameGapP95Ms), (Fmt $st.frameGapMaxMs)
}
finally {
    if ($own) { Stop-Wren | Out-Null }
}
