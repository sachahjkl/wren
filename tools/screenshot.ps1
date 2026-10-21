# Starts the browser, optionally clicks at window-relative pixel positions, saves a capture of the window frame.
#   powershell -File tools\screenshot.ps1 -Url file:///S:/wasm_browser/build/e2e.wasm -Out shot.png [-Click 120,230] [-Keys PageDown,Down,End] [-WaitMs 1500]
# -Keys: virtual keys posted after the clicks (names: PageUp PageDown End Home Left Up Right Down Space Tab, or a number).
# -Actions: drags, right / double / triple clicks, keys with modifiers, typed text, captures in between (see below).
# The cursor is parked outside the window for the first capture. Aborts if another window covers the target.
# -Extra: more arguments for the browser before the address (e.g. "--pref","browser.ui.theme=daylight").
# -Exe: another build of the browser (default build\browser.exe).
# The desktop: the window is topmost, captured from the screen, and may get the real pointer and keyboard; the script holds
# desktop.lock (tools\test_env.ps1) from the start of the browser to its end, waiting at most -LockTimeoutSec for it
# (another run's capture: a few seconds). Callers take no lock. A page of the test server: start one with
# Start-WrenTestServer (tools\test_env.ps1) and pass its origin, rather than relying on a server on 8765.
param([string]$Url = "", [string]$Out = "shot.png", [string[]]$Click = @(), [int]$WaitMs = 1500, [string]$Out2 = "", [int]$ClickPauseMs = 400, [int]$SettleMs = 300, [int]$Width = 0, [int]$Height = 0, [string[]]$Keys = @(), [string[]]$Actions = @(), [string[]]$Extra = @(), [string]$Exe = "", [int]$LockTimeoutSec = 600)
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
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, int d, IntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
  [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO ci);
  [DllImport("user32.dll")] public static extern bool GetIconInfo(IntPtr h, out ICONINFO ii);
  [DllImport("user32.dll")] public static extern bool DrawIconEx(IntPtr hdc, int x, int y, IntPtr h, int cx, int cy, uint step, IntPtr br, uint flags);
  [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
  [StructLayout(LayoutKind.Sequential)] public struct CURSORINFO { public int cbSize; public int flags; public IntPtr hCursor; public POINT pt; }
  [StructLayout(LayoutKind.Sequential)] public struct ICONINFO { public bool fIcon; public int xHotspot; public int yHotspot; public IntPtr hbmMask; public IntPtr hbmColor; }
}
"@
Add-Type -AssemblyName System.Drawing
# per-monitor aware: window rects, client coordinates and captures in the physical pixels the browser sees
if (-not [SH]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [SH]::SetProcessDPIAware() | Out-Null }

function Grab($h, $path, $withCursor = $false) {
    $r = New-Object SH+RECT
    if ([SH]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [SH]::GetWindowRect($h, [ref]$r) | Out-Null }
    $w = $r.R - $r.L; $hh = $r.B - $r.T
    $pt = New-Object SH+POINT; $pt.X = $r.L + [int]($w / 2); $pt.Y = $r.T + [int]($hh / 2)
    if ([SH]::GetAncestor([SH]::WindowFromPoint($pt), 2) -ne $h) { throw "window covered, not capturing" }
    $bmp = New-Object Drawing.Bitmap $w, $hh
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
    if ($withCursor) {
        # a screen capture leaves the pointer out: draw the cursor shown now where it is, by its hotspot
        $ci = New-Object SH+CURSORINFO; $ci.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($ci)
        if ([SH]::GetCursorInfo([ref]$ci) -and ($ci.flags -band 1) -and $ci.hCursor -ne [IntPtr]::Zero) {
            $ii = New-Object SH+ICONINFO
            $hx = 0; $hy = 0
            if ([SH]::GetIconInfo($ci.hCursor, [ref]$ii)) {
                $hx = $ii.xHotspot; $hy = $ii.yHotspot
                if ($ii.hbmMask -ne [IntPtr]::Zero) { [SH]::DeleteObject($ii.hbmMask) | Out-Null }
                if ($ii.hbmColor -ne [IntPtr]::Zero) { [SH]::DeleteObject($ii.hbmColor) | Out-Null }
            }
            $hdc = $g.GetHdc()
            [SH]::DrawIconEx($hdc, $ci.pt.X - $r.L - $hx, $ci.pt.Y - $r.T - $hy, $ci.hCursor, 0, 0, 0, [IntPtr]::Zero, 3) | Out-Null   # DI_NORMAL
            $g.ReleaseHdc($hdc)
        }
    }
    $g.Dispose()
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

# (through powershell -File an array comes as one comma-joined string: "--pref,a=b" is split back at its option names)
$Extra = @($Extra | ForEach-Object { $_ -split ',(?=--)' } | ForEach-Object { if ($_ -match '^(--[a-z-]+),(.*)$') { $Matches[1]; $Matches[2] } else { $_ } })
$args2 = @($Extra | Where-Object { $_ }) + $(if ($Url) { @($Url) } else { @() })
$exePath = if ($Exe) { $Exe } else { Join-Path $root 'build\browser.exe' }
. (Join-Path $PSScriptRoot 'test_env.ps1')
$desktop = Enter-WrenLock desktop "screenshot.ps1 $Url" $LockTimeoutSec
$p = $null
try {
    $p = if ($args2.Count) { Start-Process $exePath -ArgumentList $args2 -PassThru } else { Start-Process $exePath -PassThru }
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
    # -Actions "drag:x1,y1-x2,y2; rclick:x,y; midclick:x,y; xback:x,y; dclick:x,y; tclick:x,y; click:x,y; key:Ctrl+F; type:some text; wait:ms; shot:path.png;
    #          hover:x,y; hovershot:path.png; mdrag:x1,y1-x2,y2; wheel:x,y,notches[,ctrl|shift]; hwheel:x,y,notches;
    #          cursorshot:path.png; rdown:x,y; rmove:x,y; rup"
    #          (hover: the real pointer; hovershot: a capture that leaves it where it is; mdrag: middle button)
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
            $upw = if ($down -eq 0x020B) { [IntPtr]($btn -band 0xFFFF0000) } else { [IntPtr]::Zero }   # (an X button names itself in the release too)
            [SH]::PostMessage($h, $up, $upw, $lp) | Out-Null; Start-Sleep -Milliseconds 60
        }
    }
    foreach ($a in (($Actions -join ';') -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $kind, $arg = $a -split ':', 2
        switch ($kind) {
            'click'  { $xy = $arg -split ','; Press 0x0201 0x0202 1 $xy[0] $xy[1] 1 }
            'dclick' { $xy = $arg -split ','; Press 0x0201 0x0202 1 $xy[0] $xy[1] 2 }
            'tclick' { $xy = $arg -split ','; Press 0x0201 0x0202 1 $xy[0] $xy[1] 3 }
            'rclick' { $xy = $arg -split ','; Press 0x0204 0x0205 2 $xy[0] $xy[1] 1 }
            'midclick' { $xy = $arg -split ','; Press 0x0207 0x0208 0x10 $xy[0] $xy[1] 1 }   # the middle button (closes a tab)
            'xback' { $xy = $arg -split ','; Press 0x020B 0x020C 0x10020 $xy[0] $xy[1] 1 }   # the mouse's back button (XBUTTON1)
            { $_ -eq 'drag' -or $_ -eq 'mdrag' } {
                # (mdrag: with the middle button)
                $mid = $_ -eq 'mdrag'
                $down = if ($mid) { 0x0207 } else { 0x0201 }; $upm = if ($mid) { 0x0208 } else { 0x0202 }; $mk = if ($mid) { 0x10 } else { 1 }
                $ends = $arg -split '-'; $p1 = $ends[0] -split ','; $p2 = $ends[1] -split ','
                $lp = ClientLp $p1[0] $p1[1]
                [SH]::PostMessage($h, 0x0200, [IntPtr]::Zero, $lp) | Out-Null; Start-Sleep -Milliseconds 60
                [SH]::PostMessage($h, $down, [IntPtr]$mk, $lp) | Out-Null; Start-Sleep -Milliseconds 60
                for ($s = 1; $s -le 12; $s++) {
                    $x = [int]$p1[0] + ([int]$p2[0] - [int]$p1[0]) * $s / 12; $y = [int]$p1[1] + ([int]$p2[1] - [int]$p1[1]) * $s / 12
                    [SH]::PostMessage($h, 0x0200, [IntPtr]$mk, (ClientLp $x $y)) | Out-Null; Start-Sleep -Milliseconds 30
                }
                Start-Sleep -Milliseconds 100
                [SH]::PostMessage($h, $upm, [IntPtr]::Zero, (ClientLp $p2[0] $p2[1])) | Out-Null
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
            # hover:x,y moves the real pointer there (window-relative); hovershot:path captures without parking it
            'hover' {
                $xy = $arg -split ','
                $r = New-Object SH+RECT
                if ([SH]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [SH]::GetWindowRect($h, [ref]$r) | Out-Null }
                $x0 = $(if ([int]$xy[0] -lt 0) { $r.R } else { $r.L }) + [int]$xy[0]   # (negative x: from the right edge)
                [SH]::SetCursorPos($x0 - 3, $r.T + [int]$xy[1]) | Out-Null; Start-Sleep -Milliseconds 60
                [SH]::SetCursorPos($x0, $r.T + [int]$xy[1]) | Out-Null
            }
            'hovershot' { Start-Sleep -Milliseconds $SettleMs; Grab $h $arg }
            # cursorshot:path: a capture with the pointer drawn in (the cursor the system shows now, at its place)
            'cursorshot' { Start-Sleep -Milliseconds $SettleMs; Grab $h $arg $true }
            # the real left button: rdown:x,y presses there, rmove:x,y moves (in 8 steps) with it held, rup releases
            'rdown' {
                $xy = $arg -split ','; $r = New-Object SH+RECT
                if ([SH]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [SH]::GetWindowRect($h, [ref]$r) | Out-Null }
                [SH]::SetCursorPos($r.L + [int]$xy[0], $r.T + [int]$xy[1]) | Out-Null; Start-Sleep -Milliseconds 120
                [SH]::mouse_event(0x2, 0, 0, 0, [IntPtr]::Zero)
            }
            'rmove' {
                $xy = $arg -split ','; $r = New-Object SH+RECT
                if ([SH]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [SH]::GetWindowRect($h, [ref]$r) | Out-Null }
                $from = New-Object SH+POINT; [SH]::GetCursorPos([ref]$from) | Out-Null
                $tx = $r.L + [int]$xy[0]; $ty = $r.T + [int]$xy[1]
                for ($s = 1; $s -le 8; $s++) {
                    [SH]::SetCursorPos($from.X + ($tx - $from.X) * $s / 8, $from.Y + ($ty - $from.Y) * $s / 8) | Out-Null; Start-Sleep -Milliseconds 30
                }
            }
            'rup' { [SH]::mouse_event(0x4, 0, 0, 0, [IntPtr]::Zero) }
            # move:x,y: a posted pointer move (no real pointer: works whatever the foreground window is)
            'move' { $xy = $arg -split ','; [SH]::PostMessage($h, 0x0200, [IntPtr]::Zero, (ClientLp $xy[0] $xy[1])) | Out-Null }
            # the real pointer: mclick / mdclick:x,y click there (window-relative, a negative x counts from the right edge; goes through the system's hit test, so
            # the window's own title bar, caption buttons and frame react as to a user); max / restore: the window state
            'mclick' {
                $xy = $arg -split ','; $r = New-Object SH+RECT
                if ([SH]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [SH]::GetWindowRect($h, [ref]$r) | Out-Null }
                [SH]::SetCursorPos($(if ([int]$xy[0] -lt 0) { $r.R } else { $r.L }) + [int]$xy[0], $r.T + [int]$xy[1]) | Out-Null; Start-Sleep -Milliseconds 120
                [SH]::mouse_event(0x2, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 50; [SH]::mouse_event(0x4, 0, 0, 0, [IntPtr]::Zero)
            }
            'mdclick' {
                $xy = $arg -split ','; $r = New-Object SH+RECT
                if ([SH]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [SH]::GetWindowRect($h, [ref]$r) | Out-Null }
                [SH]::SetCursorPos($(if ([int]$xy[0] -lt 0) { $r.R } else { $r.L }) + [int]$xy[0], $r.T + [int]$xy[1]) | Out-Null; Start-Sleep -Milliseconds 120
                for ($i = 0; $i -lt 2; $i++) { [SH]::mouse_event(0x2, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 30; [SH]::mouse_event(0x4, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 60 }
            }
            # wheel:x,y,delta[,ctrl|shift] / hwheel:x,y,delta: a wheel turn at a window-relative point, in notches (fractions
            # too, as a touchpad sends; negative: towards the user / to the left); ctrl / shift travel with the message (MK_*)
            # as a real wheel's do, which is also how Windows sends a touchpad's pinch (Ctrl+wheel)
            { $_ -eq 'wheel' -or $_ -eq 'hwheel' } {
                $f = $arg -split ','
                $r = New-Object SH+RECT
                if ([SH]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [SH]::GetWindowRect($h, [ref]$r) | Out-Null }
                $sx = $r.L + [int]$f[0]; $sy = $r.T + [int]$f[1]
                $lpc = ClientLp $f[0] $f[1]
                [SH]::PostMessage($h, 0x0200, [IntPtr]::Zero, $lpc) | Out-Null; Start-Sleep -Milliseconds 40
                $mk = 0; if ($f.Count -gt 3) { if ($f[3] -eq 'ctrl') { $mk = 0x8 } elseif ($f[3] -eq 'shift') { $mk = 0x4 } }
                $d = [int]([double]$f[2] * 120); if ($_ -eq 'wheel') { $d = -$d }   # (+delta: content moves on, as Event.delta)
                $wp = [IntPtr][long]((($d -band 0xFFFF) -shl 16) -bor $mk)
                $lp = [IntPtr][long]((($sy -band 0xFFFF) -shl 16) -bor ($sx -band 0xFFFF))   # (screen coordinates)
                [SH]::PostMessage($h, $(if ($_ -eq 'wheel') { 0x020A } else { 0x020E }), $wp, $lp) | Out-Null
            }
            'max' { [SH]::PostMessage($h, 0x0112, [IntPtr]0xF030, [IntPtr]::Zero) | Out-Null }       # WM_SYSCOMMAND SC_MAXIMIZE
            'restore' { [SH]::PostMessage($h, 0x0112, [IntPtr]0xF120, [IntPtr]::Zero) | Out-Null }   # SC_RESTORE
        }
        Start-Sleep -Milliseconds $ClickPauseMs
    }
    if ($Click.Count -gt 0 -or $Keys.Count -gt 0 -or $Actions.Count -gt 0) {
        [SH]::SetCursorPos($r0.R + 15, $r0.T + 200) | Out-Null
        Start-Sleep -Milliseconds $SettleMs
        Grab $h $(if ($Out2) { $Out2 } else { $Out -replace '\.png$', '_after.png' })
    }
} finally { if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null }; Exit-WrenLock $desktop }
