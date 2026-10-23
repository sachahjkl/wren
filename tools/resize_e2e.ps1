# Live resize while a video plays: the real mouse drags the window's corner back and forth for a while (the system's modal size
# loop paints the window from WM_PAINT) over examples/site/yt-sim.html playing a 30 s H.264 file, and the process must live. A
# message pump inside a chrome frame (a page script or a layout pass running) used to start that loop under it, and its paint ran
# a full frame inside the chrome frame: the page's world a second time, re-entrantly (a panic in the dev build, a corrupted layout
# in a release one). Needs the desktop (mouse, a visible window: desktop.lock) and the files of tools\gen_perf_media.ps1.
#   powershell -NoProfile -File tools\resize_e2e.ps1 [-Exe build\wren.exe] [-Rounds 3] [-Secs 15]
param([string]$Exe = '', [int]$Rounds = 3, [int]$Secs = 15)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\test_env.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$Exe = (Resolve-Path $Exe).Path
if (-not (Test-Path (Join-Path $root 'examples\site\media\video\perf_h264_1080p60_a.mp4'))) { & powershell -NoProfile -File (Join-Path $PSScriptRoot 'gen_perf_media.ps1') }
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
try {
    $url = "$($server.Origin)/site/yt-sim.html?src=perf_h264_1080p60"
    for ($round = 1; $round -le $Rounds; $round++) {
        $prof = Join-Path $tmp "profile$round"
        $p = Start-Process $Exe -ArgumentList "--pref media.autoplay.policy=allow-all --profile `"$prof`" $url" -PassThru
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 50; $p.Refresh() }
            $h = $p.MainWindowHandle
            [RZ]::SetWindowPos($h, [IntPtr](-1), 20, 20, 1280, 800, 0x40) | Out-Null
            Start-Sleep 9
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
            Start-Sleep 2; $p.Refresh()
            $crashes = @(Get-ChildItem (Join-Path $prof 'crashes') -Filter *.txt -ErrorAction SilentlyContinue)
            $alive = -not $p.HasExited
            if ($alive) { "PASS  round ${round}: the window was dragged for $Secs s while the video played, and lives" }
            else {
                "FAIL  round ${round}: the process ended (exit code $($p.ExitCode)); $($crashes.Count) crash report(s)"
                foreach ($c in $crashes) { Get-Content $c.FullName | Select-Object -First 14 }
                $fail++
            }
        } finally { if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null } }
    }
} finally {
    Exit-WrenLock $lock
    Stop-WrenTestServer $server
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { "resize_e2e: $fail round(s) failed"; exit 1 }
'resize_e2e: all rounds passed'
