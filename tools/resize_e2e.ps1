# Live resize while a video plays: the real mouse drags the window's corner back and forth for a while (the system's modal size
# loop paints the window from WM_PAINT) over examples/site/yt-sim.html playing a 30 s H.264 file, and the process must live. A
# message pump inside a chrome frame (a page script or a layout pass running) used to start that loop under it, and its paint ran
# a full frame inside the chrome frame: the page's world a second time, re-entrantly (a panic in the dev build, a corrupted layout
# in a release one). Needs the desktop (mouse, a visible window: desktop.lock) and the files of tools\gen_perf_media.ps1.
#   powershell -NoProfile -File tools\resize_e2e.ps1 [-Exe build\wren.exe] [-Rounds 3] [-Secs 15] [-Page url]
# One Wren serves every round (the check is about the process living through the drags, not about its start): a round loads the page
# again after a `wren ctl reset`, waits until the video has played (a condition, not a fixed 9 s) and drags for -Secs; afterwards the
# process must still answer, and have left no crash report. The Wren has the remote channel on (that is how the waits and the final
# question are asked), a window that is shown, and a profile of its own.
param([string]$Exe = '', [int]$Rounds = 3, [int]$Secs = 15, [string]$Page = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\test_env.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$Exe = (Resolve-Path $Exe).Path
$env:WREN_EXE = $Exe
. "$PSScriptRoot\wrenctl.ps1"
if (-not $Page -and -not (Test-Path (Join-Path $root 'examples\site\media\video\perf_h264_1080p60_a.mp4'))) { & powershell -NoProfile -File (Join-Path $PSScriptRoot 'gen_perf_media.ps1') }
Add-Type @"
using System; using System.Runtime.InteropServices;
public class RZ {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, int d, IntPtr e);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
[RZ]::SetProcessDPIAware() | Out-Null
$fail = 0
$server = Start-WrenTestServer
$tmp = Join-Path $env:TEMP "wren-resize-e2e-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:WREN_SINGLE_INSTANCE = 'off'
$lock = Enter-WrenLock desktop 'resize_e2e'
$prof = Join-Path $tmp 'profile'
$p = $null
try {
    $url = if ($Page) { $Page } else { "$($server.Origin)/site/yt-sim.html?src=perf_h264_1080p60" }
    Section 'start: the Wren, its window shown and placed'
    $name = Start-Wren -Visible -Size 1280x800 -ProfileDir $prof -Pref 'media.autoplay.policy=allow-all', 'blocker.update.enabled=false'
    $wpid = [int]((Wren-Ctl ping --json | ConvertFrom-Json).pid)
    $p = Get-Process -Id $wpid
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 50; $p.Refresh() }
    $h = $p.MainWindowHandle
    [RZ]::SetWindowPos($h, [IntPtr](-1), 20, 20, 1280, 800, 0x40) | Out-Null
    for ($round = 1; $round -le $Rounds; $round++) {
        Section "round ${round}: the page, the video playing"
        if ($round -gt 1) { $null = Wren-Ctl reset --timeout 30000 }
        $null = Wren-Ctl nav $url --timeout 60000
        $null = Wren-Ctl wait function 'var v = document.querySelector("video"); !!v && v.currentTime > 1' --timeout 60000
        Section "round ${round}: the drag ($Secs s)"
        $r = New-Object RZ+RECT; [RZ]::GetWindowRect($h, [ref]$r) | Out-Null
        $x0 = $r.R - 3; $y0 = $r.B - 3
        [RZ]::SetCursorPos($x0, $y0) | Out-Null; Start-Sleep -Milliseconds 300
        [RZ]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero)
        $sw.Restart()
        while ($sw.Elapsed.TotalSeconds -lt $Secs -and -not $p.HasExited) {
            $t = $sw.ElapsedMilliseconds / 1000.0
            [RZ]::SetCursorPos([int]($x0 + 250 * [Math]::Sin($t * 2.1)), [int]($y0 + 150 * [Math]::Sin($t * 1.3))) | Out-Null
            Start-Sleep -Milliseconds 12
        }
        [RZ]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero)
        Section "round ${round}: does it live?"
        $null = Wren-Ctl ping --timeout 10000   # (the modal loop is over: it answers)
        $p.Refresh()
        $crashes = @(Get-ChildItem (Join-Path $prof 'crashes') -Filter *.txt -ErrorAction SilentlyContinue)
        $alive = -not $p.HasExited -and $global:WrenExit -eq 0
        if ($alive -and $crashes.Count -eq 0) { "PASS  round ${round}: the window was dragged for $Secs s while the video played, and lives" }
        else {
            "FAIL  round ${round}: the process ended or does not answer (exit code $(if ($p.HasExited) { $p.ExitCode } else { 'still running' }), ctl exit $global:WrenExit); $($crashes.Count) crash report(s)"
            foreach ($c in $crashes) { Get-Content $c.FullName | Select-Object -First 14 }
            $fail++
            break   # (nothing left to drag; the next round would only say the same)
        }
    }
} finally {
    Exit-WrenLock $lock
    try { if ($p -and -not $p.HasExited) { Stop-Wren } } catch { }
    if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null }
    Stop-WrenTestServer $server
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Show-WrenSections resize_e2e
if ($fail) { "resize_e2e: $fail round(s) failed"; exit 1 }
'resize_e2e: all rounds passed'
