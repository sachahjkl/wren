# Starts the browser, optionally clicks at window-relative pixel positions, saves a capture of the window frame.
#   powershell -File tools\screenshot.ps1 -Url file:///S:/wasm_browser/build/e2e.wasm -Out shot.png [-Click 120,230] [-Keys PageDown,Down,End] [-WaitMs 1500]
# -Keys: virtual keys posted after the clicks (names: PageUp PageDown End Home Left Up Right Down Space Tab, or a number).
# -Actions: drags, right / double / triple clicks, keys with modifiers, typed text, captures in between (see below).
# The cursor is parked outside the window for the first capture. Aborts if another window covers the target.
param([string]$Url = "", [string]$Out = "shot.png", [string[]]$Click = @(), [int]$WaitMs = 1500, [string]$Out2 = "", [int]$ClickPauseMs = 400, [int]$SettleMs = 300, [int]$Width = 0, [int]$Height = 0, [string[]]$Keys = @(), [string[]]$Actions = @())
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type @"
using System; using System.Runtime.InteropServices;
public class SH {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, int d, IntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
}
"@
Add-Type -AssemblyName System.Drawing
# per-monitor aware: window rects, client coordinates and captures in the physical pixels the browser sees
if (-not [SH]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [SH]::SetProcessDPIAware() | Out-Null }

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
    $vk = @{ PageUp = 0x21; PageDown = 0x22; End = 0x23; Home = 0x24; Left = 0x25; Up = 0x26; Right = 0x27; Down = 0x28; Space = 0x20; Tab = 0x09 }
    foreach ($k in (($Keys -join ',') -split ',' | Where-Object { $_ })) {
        $code = if ($vk.ContainsKey($k)) { $vk[$k] } else { [int]$k }
        [SH]::PostMessage($h, 0x0100, [IntPtr]$code, [IntPtr]1) | Out-Null            # WM_KEYDOWN
        Start-Sleep -Milliseconds 60
        [SH]::PostMessage($h, 0x0101, [IntPtr]$code, [IntPtr]0xC0000001) | Out-Null   # WM_KEYUP
        Start-Sleep -Milliseconds $ClickPauseMs
    }
    # -Actions "drag:x1,y1-x2,y2; rclick:x,y; dclick:x,y; tclick:x,y; click:x,y; key:Ctrl+F; type:some text; wait:ms; shot:path.png"
    # (window-relative pixels like -Click; key: real keyboard input, so modifiers count: Ctrl+Shift+T, Shift+F10, Menu, F6...)
    $named = @{ PageUp = 0x21; PageDown = 0x22; End = 0x23; Home = 0x24; Left = 0x25; Up = 0x26; Right = 0x27; Down = 0x28; Space = 0x20; Tab = 0x09;
        Enter = 0x0D; Escape = 0x1B; Esc = 0x1B; Delete = 0x2E; Backspace = 0x08; Menu = 0x5D; Plus = 0xBB; Minus = 0xBD; Insert = 0x2D }
    function ClientLp($x, $y) {
        $r = New-Object SH+RECT
        if ([SH]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [SH]::GetWindowRect($h, [ref]$r) | Out-Null }
        $pt = New-Object SH+POINT; $pt.X = $r.L + [int]$x; $pt.Y = $r.T + [int]$y
        [SH]::ScreenToClient($h, [ref]$pt) | Out-Null
        return [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))
    }
    function Press($down, $up, $btn, $x, $y, $count) {
        $lp = ClientLp $x $y
        [SH]::PostMessage($h, 0x0200, [IntPtr]::Zero, $lp) | Out-Null
        Start-Sleep -Milliseconds 60
        for ($i = 0; $i -lt $count; $i++) {
            [SH]::PostMessage($h, $down, [IntPtr]$btn, $lp) | Out-Null; Start-Sleep -Milliseconds 40
            [SH]::PostMessage($h, $up, [IntPtr]::Zero, $lp) | Out-Null; Start-Sleep -Milliseconds 60
        }
    }
    foreach ($a in (($Actions -join ';') -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $kind, $arg = $a -split ':', 2
        switch ($kind) {
            'click'  { $xy = $arg -split ','; Press 0x0201 0x0202 1 $xy[0] $xy[1] 1 }
            'dclick' { $xy = $arg -split ','; Press 0x0201 0x0202 1 $xy[0] $xy[1] 2 }
            'tclick' { $xy = $arg -split ','; Press 0x0201 0x0202 1 $xy[0] $xy[1] 3 }
            'rclick' { $xy = $arg -split ','; Press 0x0204 0x0205 2 $xy[0] $xy[1] 1 }
            'drag' {
                $ends = $arg -split '-'; $p1 = $ends[0] -split ','; $p2 = $ends[1] -split ','
                $lp = ClientLp $p1[0] $p1[1]
                [SH]::PostMessage($h, 0x0200, [IntPtr]::Zero, $lp) | Out-Null; Start-Sleep -Milliseconds 60
                [SH]::PostMessage($h, 0x0201, [IntPtr]1, $lp) | Out-Null; Start-Sleep -Milliseconds 60
                for ($s = 1; $s -le 12; $s++) {
                    $x = [int]$p1[0] + ([int]$p2[0] - [int]$p1[0]) * $s / 12; $y = [int]$p1[1] + ([int]$p2[1] - [int]$p1[1]) * $s / 12
                    [SH]::PostMessage($h, 0x0200, [IntPtr]1, (ClientLp $x $y)) | Out-Null; Start-Sleep -Milliseconds 30
                }
                Start-Sleep -Milliseconds 100
                [SH]::PostMessage($h, 0x0202, [IntPtr]::Zero, (ClientLp $p2[0] $p2[1])) | Out-Null
            }
            'key' {
                $parts = $arg -split '\+'
                $mods = @(); foreach ($m in $parts[0..($parts.Count - 2)]) { if ($parts.Count -gt 1) { $mods += @{ Ctrl = 0x11; Shift = 0x10; Alt = 0x12 }[$m] } }
                $last = $parts[-1]
                $code = if ($named.ContainsKey($last)) { $named[$last] } elseif ($last -match '^F(\d+)$') { 0x6F + [int]$Matches[1] } elseif ($last.Length -eq 1) { [int][char]$last.ToUpper() } else { [int]$last }
                # real keyboard input goes to the foreground window: make sure it is ours (never type into another one)
                if ([SH]::GetForegroundWindow() -ne $h) {
                    [SH]::keybd_event(0x12, 0, 0, [IntPtr]::Zero); [SH]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)   # lets SetForegroundWindow succeed
                    [SH]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Milliseconds 100
                }
                if ([SH]::GetForegroundWindow() -ne $h) { throw "the browser window is not in the foreground: keys not sent" }
                foreach ($m in $mods) { [SH]::keybd_event([byte]$m, 0, 0, [IntPtr]::Zero) }
                [SH]::keybd_event([byte]$code, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 30
                [SH]::keybd_event([byte]$code, 0, 2, [IntPtr]::Zero)
                foreach ($m in $mods) { [SH]::keybd_event([byte]$m, 0, 2, [IntPtr]::Zero) }
            }
            'vkey' {
                # a posted key (no modifiers, the window need not be in the foreground)
                $code = if ($named.ContainsKey($arg)) { $named[$arg] } elseif ($arg -match '^F(\d+)$') { 0x6F + [int]$Matches[1] } elseif ($arg.Length -eq 1) { [int][char]$arg.ToUpper() } else { [int]$arg }
                [SH]::PostMessage($h, 0x0100, [IntPtr]$code, [IntPtr]1) | Out-Null; Start-Sleep -Milliseconds 40
                [SH]::PostMessage($h, 0x0101, [IntPtr]$code, [IntPtr]0xC0000001) | Out-Null
            }
            'type' { foreach ($ch in $arg.ToCharArray()) { [SH]::PostMessage($h, 0x0102, [IntPtr][int]$ch, [IntPtr]1) | Out-Null; Start-Sleep -Milliseconds 20 } }
            'wait' { Start-Sleep -Milliseconds ([int]$arg) }
            'shot' { [SH]::SetCursorPos($r0.R + 15, $r0.T + 200) | Out-Null; Start-Sleep -Milliseconds $SettleMs; Grab $h $arg }
        }
        Start-Sleep -Milliseconds $ClickPauseMs
    }
    if ($Click.Count -gt 0 -or $Keys.Count -gt 0 -or $Actions.Count -gt 0) {
        [SH]::SetCursorPos($r0.R + 15, $r0.T + 200) | Out-Null
        Start-Sleep -Milliseconds $SettleMs
        Grab $h $(if ($Out2) { $Out2 } else { $Out -replace '\.png$', '_after.png' })
    }
} finally { if (-not $p.HasExited) { $p.Kill() } }
