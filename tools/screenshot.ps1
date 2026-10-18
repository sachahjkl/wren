# Starts the browser, optionally clicks at window-relative pixel positions, saves a capture of the window frame.
#   powershell -File tools\screenshot.ps1 -Url file:///S:/wasm_browser/build/e2e.wasm -Out shot.png [-Click 120,230] [-WaitMs 1500]
# The cursor is parked outside the window for the first capture. Aborts if another window covers the target.
param([string]$Url = "", [string]$Out = "shot.png", [string[]]$Click = @(), [int]$WaitMs = 1500, [string]$Out2 = "", [int]$ClickPauseMs = 400, [int]$SettleMs = 300, [int]$Width = 0, [int]$Height = 0)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type @"
using System; using System.Runtime.InteropServices;
public class SH {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, int d, IntPtr e);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
}
"@
Add-Type -AssemblyName System.Drawing
[SH]::SetProcessDPIAware() | Out-Null

function Grab($h, $path) {
    $r = New-Object SH+RECT
    if ([SH]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [SH]::GetWindowRect($h, [ref]$r) | Out-Null }
    $w = $r.R - $r.L; $hh = $r.B - $r.T
    $pt = New-Object SH+POINT; $pt.X = $r.L + [int]($w / 2); $pt.Y = $r.T + [int]($hh / 2)
    if ([SH]::GetAncestor([SH]::WindowFromPoint($pt), 2) -ne $h) { throw "window covered, not capturing" }
    $bmp = New-Object Drawing.Bitmap $w, $hh
    [Drawing.Graphics]::FromImage($bmp).CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

$args2 = if ($Url) { @($Url) } else { @() }
$p = if ($args2.Count) { Start-Process (Join-Path $root 'build\browser.exe') -ArgumentList $args2 -PassThru } else { Start-Process (Join-Path $root 'build\browser.exe') -PassThru }
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20; $p.Refresh() }
    $h = $p.MainWindowHandle
    $r0 = New-Object SH+RECT; [SH]::GetWindowRect($h, [ref]$r0) | Out-Null
    [SH]::SetCursorPos($r0.R + 15, $r0.T + 200) | Out-Null
    [SH]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x13) | Out-Null   # topmost, so nothing covers it while we capture
    if ($Width -gt 0 -and $Height -gt 0) { [SH]::SetWindowPos($h, [IntPtr](-1), 0, 0, $Width, $Height, 0x12) | Out-Null }   # -Width / -Height: outer size
    [SH]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds $WaitMs
    Grab $h $Out
    foreach ($c in (($Click -join ';') -split ';' | Where-Object { $_ })) {
        $xy = $c -split ','
        $r = New-Object SH+RECT
        if ([SH]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [SH]::GetWindowRect($h, [ref]$r) | Out-Null }
        # window messages with client coordinates: independent of focus, cursor position and other windows
        $pt = New-Object SH+POINT; $pt.X = $r.L + [int]$xy[0]; $pt.Y = $r.T + [int]$xy[1]
        [SH]::ScreenToClient($h, [ref]$pt) | Out-Null
        $lp = [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))
        [SH]::PostMessage($h, 0x0200, [IntPtr]::Zero, $lp) | Out-Null   # WM_MOUSEMOVE
        Start-Sleep -Milliseconds 80
        [SH]::PostMessage($h, 0x0201, [IntPtr]1, $lp) | Out-Null        # WM_LBUTTONDOWN
        Start-Sleep -Milliseconds 60
        [SH]::PostMessage($h, 0x0202, [IntPtr]::Zero, $lp) | Out-Null   # WM_LBUTTONUP
        Start-Sleep -Milliseconds $ClickPauseMs
    }
    if ($Click.Count -gt 0) {
        [SH]::SetCursorPos($r0.R + 15, $r0.T + 200) | Out-Null
        Start-Sleep -Milliseconds $SettleMs
        Grab $h $(if ($Out2) { $Out2 } else { $Out -replace '\.png$', '_after.png' })
    }
} finally { if (-not $p.HasExited) { $p.Kill() } }
