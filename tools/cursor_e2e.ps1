# End-to-end test of the page's cursors in the real browser window (not part of test_all.ps1: it moves the real pointer).
# examples/site/cursors.html?rects puts the rectangles of its elements in its title; the pointer goes over each case and
# the cursor the system shows (GetCursorInfo) is checked: a system cursor is the very handle of the system's (shared
# by every process), a drawn one is none of them and as large as the system's, `none` hides the pointer, an image
# cursor is the image at the window's scale with its hotspot. WREN_CURSOR_LOG (page_cursor.odin) says what the
# browser chose and finds where the page area is. Also: a press held on the page keeps its cursor while the pointer
# moves elsewhere.
# Starts build\testserver.exe on a block of ports of its own (tools\test_env.ps1) and holds desktop.lock while the
# browser window is open.
#   powershell -File tools\cursor_e2e.ps1 [-Exe build\wren.exe]
param([string]$Exe = "")
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
Add-Type @"
using System; using System.Runtime.InteropServices;
public class CE {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO ci);
  [DllImport("user32.dll")] public static extern bool GetIconInfo(IntPtr h, out ICONINFO ii);
  [DllImport("user32.dll")] public static extern IntPtr LoadCursorW(IntPtr inst, IntPtr id);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetSystemMetricsForDpi(int i, uint dpi);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, int d, IntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("gdi32.dll")] public static extern int GetObjectW(IntPtr h, int c, out BITMAP bm);
  [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct CURSORINFO { public int cbSize; public int flags; public IntPtr hCursor; public POINT pt; }
  [StructLayout(LayoutKind.Sequential)] public struct ICONINFO { public bool fIcon; public int xHotspot; public int yHotspot; public IntPtr hbmMask; public IntPtr hbmColor; }
  [StructLayout(LayoutKind.Sequential)] public struct BITMAP { public int bmType, bmWidth, bmHeight, bmWidthBytes; public short bmPlanes, bmBitsPixel; public IntPtr bmBits; }
}
"@
[CE]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$failed = 0
function Check($ok, $what) { if ($ok) { "PASS $what" } else { "FAIL $what"; $script:failed++ } }

# the cursor shown now: handle, visible, bitmap size and hotspot
function Shown {
    $ci = New-Object CE+CURSORINFO; $ci.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($ci)
    [CE]::GetCursorInfo([ref]$ci) | Out-Null
    $r = [pscustomobject]@{ Handle = $ci.hCursor; Visible = (($ci.flags -band 1) -ne 0 -and $ci.hCursor -ne [IntPtr]::Zero); W = 0; H = 0; HX = 0; HY = 0 }
    if ($ci.hCursor -ne [IntPtr]::Zero) {
        $ii = New-Object CE+ICONINFO
        if ([CE]::GetIconInfo($ci.hCursor, [ref]$ii)) {
            $bm = New-Object CE+BITMAP
            $src = if ($ii.hbmColor -ne [IntPtr]::Zero) { $ii.hbmColor } else { $ii.hbmMask }
            [CE]::GetObjectW($src, [Runtime.InteropServices.Marshal]::SizeOf($bm), [ref]$bm) | Out-Null
            $r.W = $bm.bmWidth; $r.H = $(if ($ii.hbmColor -ne [IntPtr]::Zero) { $bm.bmHeight } else { $bm.bmHeight / 2 }); $r.HX = $ii.xHotspot; $r.HY = $ii.yHotspot
            if ($ii.hbmMask -ne [IntPtr]::Zero) { [CE]::DeleteObject($ii.hbmMask) | Out-Null }
            if ($ii.hbmColor -ne [IntPtr]::Zero) { [CE]::DeleteObject($ii.hbmColor) | Out-Null }
        }
    }
    $r
}

# the system's cursors (IDC_*): their handles are the same in every process
$idc = @{ default = 32512; text = 32513; wait = 32514; crosshair = 32515; 'nwse-resize' = 32642; 'nesw-resize' = 32643; 'ew-resize' = 32644;
    'ns-resize' = 32645; move = 32646; 'not-allowed' = 32648; pointer = 32649; progress = 32650; help = 32651 }
$alias = @{ 'n-resize' = 'ns-resize'; 's-resize' = 'ns-resize'; 'e-resize' = 'ew-resize'; 'w-resize' = 'ew-resize'; 'ne-resize' = 'nesw-resize';
    'sw-resize' = 'nesw-resize'; 'nw-resize' = 'nwse-resize'; 'se-resize' = 'nwse-resize'; 'all-scroll' = 'move' }
$system = @{}
foreach ($k in $idc.Keys) { $system[$k] = [CE]::LoadCursorW([IntPtr]::Zero, [IntPtr]$idc[$k]) }
$drawn = 'context-menu', 'cell', 'vertical-text', 'alias', 'copy', 'no-drop', 'grab', 'grabbing', 'col-resize', 'row-resize', 'zoom-in', 'zoom-out'

. (Join-Path $PSScriptRoot 'test_env.ps1')
$srv = Start-WrenTestServer
$log = Join-Path $root 'build\cursor_e2e_log.txt'
$profile = Join-Path $root 'build\cursor_e2e_profile'
New-Item -ItemType Directory -Force $profile | Out-Null
Get-ChildItem $profile -File -Recurse | Remove-Item -Force

function With-Page($y, $w, $hh, [scriptblock]$body) {
    Remove-Item $log -ErrorAction SilentlyContinue
    $env:WREN_CURSOR_LOG = $log
    $desktop = Enter-WrenLock desktop "cursor_e2e.ps1"
    $p = $null
    try {
        $p = Start-Process $Exe -ArgumentList '--profile', $profile, "$($srv.Origin)/site/cursors.html?rects&y=$y" -PassThru
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 50; $p.Refresh() }
        $h = $p.MainWindowHandle
        [CE]::SetWindowPos($h, [IntPtr](-1), 20, 20, $w, $hh, 0x10) | Out-Null
        [CE]::SetForegroundWindow($h) | Out-Null
        Start-Sleep -Milliseconds 1500   # (the page reports every 400 ms: after the resize)
        $title = $null
        while ($sw.ElapsedMilliseconds -lt 20000) { $p.Refresh(); if ($p.MainWindowTitle -match 'rects (.*)$') { $title = $Matches[1]; break }; Start-Sleep -Milliseconds 100 }
        if (-not $title) { throw "the page did not report its rectangles (title: $($p.MainWindowTitle))" }
        $rects = @{}
        foreach ($part in $title -split ';') { if ($part -match '^([^:]+):(-?\d+),(-?\d+),(\d+),(\d+)') { $rects[$Matches[1]] = [int[]]@($Matches[2], $Matches[3], $Matches[4], $Matches[5]) } }
        $scale = [CE]::GetDpiForWindow($h) / 96.0
        # where the page area is: one point in it, and what the browser logged for it (CSS pixels of the page area)
        function ToScreen($cx, $cy) { $pt = New-Object CE+POINT; $pt.X = [int]$cx; $pt.Y = [int]$cy; [CE]::ClientToScreen($h, [ref]$pt) | Out-Null; $pt }
        $probe = ToScreen 600 500
        $last = $null
        for ($try = 0; $try -lt 10 -and -not $last; $try++) {
            [CE]::SetCursorPos($probe.X, $probe.Y - 400) | Out-Null; Start-Sleep -Milliseconds 300   # (over the chrome first: a new line)
            [CE]::SetCursorPos($probe.X, $probe.Y) | Out-Null; Start-Sleep -Milliseconds 400
            $last = Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -match ' at=' -and $_ -notmatch 'node=- ' } | Select-Object -Last 1
        }
        if ($last -notmatch 'at=(-?\d+),(-?\d+)') { throw "no cursor log line for the page ($last)" }
        $origin = @((600 - [int]$Matches[1] * $scale), (500 - [int]$Matches[2] * $scale))
        $ctx = [pscustomobject]@{ H = $h; Rects = $rects; Scale = $scale; Origin = $origin }
        & $body $ctx
    } finally {
        if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null }
        Exit-WrenLock $desktop
        Remove-Item Env:\WREN_CURSOR_LOG -ErrorAction SilentlyContinue
    }
}

# the pointer over element `id` (fx, fy: where in its rectangle, fractions), then what shows
function Over($ctx, $id, $fx = 0.5, $fy = 0.5) {
    $r = $ctx.Rects[$id]
    if (-not $r) { throw "no rectangle for #$id" }
    $cx = $ctx.Origin[0] + ($r[0] + $r[2] * $fx) * $ctx.Scale
    $cy = $ctx.Origin[1] + ($r[1] + $r[3] * $fy) * $ctx.Scale
    $pt = New-Object CE+POINT; $pt.X = [int]$cx; $pt.Y = [int]$cy; [CE]::ClientToScreen($ctx.H, [ref]$pt) | Out-Null
    if ([CE]::GetAncestor([CE]::WindowFromPoint($pt), 2) -ne $ctx.H) {
        # (another window passing over: ours to the top again, once)
        [CE]::SetWindowPos($ctx.H, [IntPtr](-1), 0, 0, 0, 0, 0x13) | Out-Null; [CE]::SetForegroundWindow($ctx.H) | Out-Null; Start-Sleep -Milliseconds 500
    }
    if ([CE]::GetAncestor([CE]::WindowFromPoint($pt), 2) -ne $ctx.H) { throw "the browser window is not under #$id ($($r -join ',') -> client $([int]$cx),$([int]$cy))" }
    [CE]::SetCursorPos($pt.X - 2, $pt.Y) | Out-Null; Start-Sleep -Milliseconds 60
    [CE]::SetCursorPos($pt.X, $pt.Y) | Out-Null; Start-Sleep -Milliseconds 350
    Shown
}

function Expect-Keyword($s, $name, $what) {
    $sysname = if ($alias.ContainsKey($name)) { $alias[$name] } else { $name }
    if ($name -eq 'none') { Check (-not $s.Visible) "$what`: hidden"; return }
    if ($system.ContainsKey($sysname)) { Check ($s.Handle -eq $system[$sysname]) "$what`: the system's $name cursor"; return }
    $isSystem = $false; foreach ($v in $system.Values) { if ($s.Handle -eq $v) { $isSystem = $true } }
    $want = [CE]::GetSystemMetricsForDpi(13, [uint32]([math]::Round($script:scaleNow * 96)))
    Check ($s.Visible -and -not $isSystem -and $s.W -eq $want -and $s.H -eq $want) "$what`: drawn $name cursor ($($s.W)x$($s.H), the system's size $want)"
}

try {
    With-Page 0 2400 2000 {
        param($ctx)
        $script:scaleNow = $ctx.Scale
        "page area at $([int]$ctx.Origin[0]) $([int]$ctx.Origin[1]), scale $($ctx.Scale)"
        foreach ($id in $ctx.Rects.Keys | Where-Object { $_ -like 'k-*' } | Sort-Object) {
            $name = $id.Substring(2)
            $want = if ($name -eq 'auto') { 'default' } else { $name }   # (a cell's text cannot be selected: auto is the arrow)
            Expect-Keyword (Over $ctx $id) $want "cursor: $name"
        }
        # images: the 32 px target at the window's scale, hotspot at its center; the pen (SVG) hotspot at its tip
        $s = Over $ctx 'png'
        $px = [int][math]::Round(32 * $ctx.Scale)
        Check ($s.Visible -and $s.W -eq $px -and [math]::Abs($s.HX - 16 * $ctx.Scale) -le 1 -and [math]::Abs($s.HY - 16 * $ctx.Scale) -le 1) "url(png) 16 16: $($s.W)x$($s.H) hotspot $($s.HX),$($s.HY) (want $px, $(16 * $ctx.Scale))"
        $s = Over $ctx 'svg'
        Check ($s.Visible -and $s.W -eq $px -and [math]::Abs($s.HX - 3 * $ctx.Scale) -le 1 -and [math]::Abs($s.HY - 29 * $ctx.Scale) -le 1) "url(svg) 3 29: rasterized at $($s.W)x$($s.H), hotspot $($s.HX),$($s.HY)"
        $s = Over $ctx 'set'
        Check ($s.Visible -and $s.W -eq $px) "image-set(): the candidate for the screen, at $($s.W)x$($s.H)"
        $last = Get-Content $log | Select-Object -Last 1
        Check ($last -match 'custom=true node=div#set') "image-set(): logged as a custom cursor ($last)"
        Expect-Keyword (Over $ctx 'huge') 'not-allowed' 'url(200 px image): too large, the fallback'
        Expect-Keyword (Over $ctx 'missing') 'grab' 'url(missing image): the fallback'
        Expect-Keyword (Over $ctx 'hidden') 'none' 'cursor: none over a box'
        # a press held on the grab cell keeps grab while the pointer goes over the pointer cell, until released
        $s = Over $ctx 'k-grab'
        [CE]::mouse_event(0x2, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 200
        $s = Over $ctx 'k-pointer'
        Expect-Keyword $s 'grab' 'a press held on the page keeps the cursor it started with'
        [CE]::mouse_event(0x4, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 200
        $s = Over $ctx 'k-pointer' 0.4
        Expect-Keyword $s 'pointer' 'released: the cursor under the pointer again'
        # the chrome keeps its own above the page
        $pt = New-Object CE+POINT; $pt.X = 1400; $pt.Y = [int](30 * $ctx.Scale); [CE]::ClientToScreen($ctx.H, [ref]$pt) | Out-Null   # (the empty caption, below the resize band)
        [CE]::SetCursorPos($pt.X, $pt.Y) | Out-Null; Start-Sleep -Milliseconds 300
        Check ((Shown).Handle -eq $system['default']) "over the title bar: the arrow"
    }
    With-Page 2000 1500 1000 {
        param($ctx)
        $script:scaleNow = $ctx.Scale
        Expect-Keyword (Over $ctx 'text' 0.15 0.2) 'text' 'auto over text: the I-beam'
        Expect-Keyword (Over $ctx 'link' 0.5 0.5) 'pointer' 'a link: the hand'
        Expect-Keyword (Over $ctx 'noselect' 0.5 0.5) 'default' 'user-select: none: the arrow'
        Expect-Keyword (Over $ctx 'field') 'text' 'a text field: the I-beam'
        Expect-Keyword (Over $ctx 'area') 'text' 'a textarea: the I-beam'
        Expect-Keyword (Over $ctx 'button') 'default' 'a button: the arrow'
        Expect-Keyword (Over $ctx 'select') 'default' 'a select: the arrow'
        Expect-Keyword (Over $ctx 'range') 'default' 'a range: the arrow'
        Expect-Keyword (Over $ctx 'disabled') 'default' 'a disabled field: the arrow'
        Expect-Keyword (Over $ctx 'editable' 0.9 0.5) 'text' 'contenteditable: the I-beam'
        Expect-Keyword (Over $ctx 'over') 'copy' 'pointer-events: none: the cursor of what is under'
        Expect-Keyword (Over $ctx 'scroll' 0.4 0.5) 'help' 'a scroll box: its cursor'
        Expect-Keyword (Over $ctx 'scroll' 0.985 0.5) 'default' 'its scroll bar: the arrow'
    }
} finally {
    Stop-WrenTestServer $srv
}
"failed: $failed"
exit $failed
