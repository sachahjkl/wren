# The developer tools while they are resized.
#   1. Docked: the panel has the size the preference gives it (the page area shrinks by the same amount), at the bottom and at
#      the side. (The panel once ignored its size: it shared the room half and half with the page, whatever the splitter did.)
#   2. A window being resized is never shown stretched: a strip of the window's top left (the header of the panel, the tab of the
#      browser) is read from the screen right after each SetWindowPos, before the window has drawn at the new size, and must be
#      what it was at rest: a swap chain that maps its last frame onto the new size would scale it. Done for the developer tools'
#      own window and for the browser window, which must both show the composition surface 1:1 and clipped
#      (browser.window.fixed_surface). Needs the desktop (desktop.lock).
#   3. The window of the panel is drawn while the browser window is resized by the system's loop (and the browser window while
#      the panel's is): the real mouse drags the corner of each for a few seconds, and the process lives.
#   powershell -NoProfile -File tools\devtools_resize_e2e.ps1 [-Exe build\wren.exe] [-Steps 40] [-NoDesktop]
param([string]$Exe = '', [int]$Steps = 40, [switch]$NoDesktop)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\test_env.ps1"
. "$PSScriptRoot\wrenctl.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$Exe = (Resolve-Path $Exe).Path
$script:WrenExe = $Exe
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class DE {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, int d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  public static IntPtr Find(uint pid, string part) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h)) return true;
      var sb = new StringBuilder(256); GetWindowText(h, sb, 256);
      if (sb.ToString().Contains(part)) found = h;
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@
[DE]::SetProcessDPIAware() | Out-Null
$fail = 0
function Pass($m) { "PASS  $m" }
function Fail($m) { "FAIL  $m"; $script:fail++ }

$server = Start-WrenTestServer
$tmp = Join-Path $env:TEMP "wren-dtresize-e2e-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:WREN_SINGLE_INSTANCE = 'off'
try {
    $page = "$($server.Origin)/site/devtools/dt4.html"
    $static = Join-Path $tmp 'static.html'
    [IO.File]::WriteAllText($static, '<!doctype html><meta charset=utf-8><title>static</title><body style="margin:0;background:#fff"><h1>Nothing moves</h1><p>A static page.</p>')
    $staticUrl = 'file:///' + ($static -replace '\\', '/')

    # ---- 1. docked: the size the preference gives
    foreach ($dock in 'right', 'bottom') {
        $n = Start-Wren -Size 1280x800 -Dpi 168 -Pref "browser.devtools.visible=true", "browser.devtools.tab=console", "browser.devtools.dock=$dock" -Url $page
        try {
            Wren-Ctl wait load | Out-Null
            $prop = if ($dock -eq 'right') { 'innerWidth' } else { 'innerHeight' }
            $vals = @()
            # sizes in proportion to the window as it is (a runner's screen may be smaller than the 1280 x 800 asked for; a panel is at least
            # 100 px and at most 70 % of the window): the whole is what the page leaves with a panel of a size no limit reaches, plus that size
            Wren-Ctl pref set browser.devtools.size 150 | Out-Null
            Wren-Ctl wait frames 6 | Out-Null
            $tot = [double](Wren-Eval "window.$prop") + 150
            $fr = if ($dock -eq 'right') { 0.30, 0.50, 0.22 } else { 0.32, 0.50, 0.27 }
            # (the preference is at least 100: a size below it is refused and the value stays; and three sizes at least 40 apart)
            $c = [Math]::Max(110, [int][Math]::Round($tot * $fr[2])); $a = [Math]::Max($c + 40, [int][Math]::Round($tot * $fr[0])); $b = [Math]::Max($a + 40, [int][Math]::Round($tot * $fr[1]))
            $b = [Math]::Min($b, [int][Math]::Floor($tot * 0.7))
            if (($b - $a) -lt 20 -or ($tot - $b) -lt 60) { Write-Host "  docked $dock : the window is too small to try three sizes ($tot px): skipped"; continue }
            $sizes = @($a, $b, $c)
            foreach ($size in $sizes) {
                Wren-Ctl pref set browser.devtools.size $size | Out-Null
                Wren-Ctl wait frames 6 | Out-Null
                $vals += [double](Wren-Eval "window.$prop")
            }
            # the page area (CSS pixels) gives up what the panel takes
            $d1 = $vals[0] - $vals[1]; $d2 = $vals[2] - $vals[0]
            if ([Math]::Abs($d1 - ($sizes[1] - $sizes[0])) -le 4 -and [Math]::Abs($d2 - ($sizes[0] - $sizes[2])) -le 4) { Pass "docked $dock : the page area follows the panel's size ($($vals -join ', '))" }
            else { Fail "docked $dock : the page's $prop did not follow the panel's size: $($vals -join ', ') for $($sizes -join ', ')" }
        } finally { Stop-Wren }
    }

    if ($NoDesktop) { "devtools_resize_e2e: desktop checks skipped"; if ($fail) { exit 1 }; return }

    # ---- 2. and 3. windows
    function Start-Visible([string]$url) {
        $name = 'dte' + [guid]::NewGuid().ToString('N').Substring(0, 6)
        $prof = Join-Path $tmp $name
        $p = Start-Process $Exe -ArgumentList "--remote=$name --profile `"$prof`" --no-single-instance --pref browser.devtools.visible=true --pref browser.devtools.tab=console $url" -PassThru
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 50; $p.Refresh() }
        $env:WREN_REMOTE = $name
        return $p
    }
    function Grab([IntPtr]$h, [int]$w, [int]$hh) {
        $pt = New-Object DE+POINT; [DE]::ClientToScreen($h, [ref]$pt) | Out-Null
        $bmp = New-Object Drawing.Bitmap $w, $hh
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($pt.X, $pt.Y, 0, 0, (New-Object Drawing.Size $w, $hh))
        $g.Dispose()
        return $bmp
    }
    function Differ($a, $b) {
        $n = 0
        for ($y = 0; $y -lt $a.Height; $y++) { for ($x = 0; $x -lt $a.Width; $x++) {
            $p = $a.GetPixel($x, $y); $q = $b.GetPixel($x, $y)
            if ([Math]::Abs($p.R - $q.R) + [Math]::Abs($p.G - $q.G) + [Math]::Abs($p.B - $q.B) -gt 24) { $n++ }
        } }
        return $n
    }
    # the window at rest, then resized by SetWindowPos in Steps sizes; the strip read right after each is the one at rest
    function Stretch-Check([string]$what, [IntPtr]$h, [int]$x, [int]$y, [int]$w0, [int]$h0) {
        [DE]::SetWindowPos($h, [IntPtr](-1), $x, $y, $w0, $h0, 0x40) | Out-Null   # topmost, shown
        [DE]::SetCursorPos(5, 5) | Out-Null
        Start-Sleep -Seconds 2
        $sw = 260; $sh = 44
        $rest = Grab $h $sw $sh
        $bad = 0; $worst = 0
        $rnd = New-Object Random 7
        for ($i = 0; $i -lt $Steps; $i++) {
            $w = [int]($w0 * (0.6 + 0.6 * $rnd.NextDouble())); $hh = [int]($h0 * (0.6 + 0.4 * $rnd.NextDouble()))
            [DE]::SetWindowPos($h, [IntPtr](-1), $x, $y, $w, $hh, 0x10) | Out-Null
            $got = Grab $h $sw $sh
            $d = Differ $rest $got
            $got.Dispose()
            if ($d -gt 40) { $bad++; if ($d -gt $worst) { $worst = $d } }
            Start-Sleep -Milliseconds (1 + $rnd.Next(0, 25))
        }
        $rest.Dispose()
        [DE]::SetWindowPos($h, [IntPtr](-1), $x, $y, $w0, $h0, 0x10) | Out-Null
        if ($bad -eq 0) { Pass "$what : $Steps sizes, the top left strip was never scaled" }
        else { Fail "$what : the strip was not as at rest in $bad of $Steps steps (up to $worst pixels differ): the window showed a stretched frame" }
    }
    function Real-Drag([IntPtr]$h, [int]$secs) {
        [DE]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x43) | Out-Null
        Start-Sleep -Milliseconds 300
        $r = New-Object DE+RECT; [DE]::GetWindowRect($h, [ref]$r) | Out-Null
        $x0 = $r.R - 3; $y0 = $r.B - 3
        [DE]::SetCursorPos($x0, $y0) | Out-Null; Start-Sleep -Milliseconds 300
        [DE]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $secs) {
            $t = $sw.ElapsedMilliseconds / 1000.0
            [DE]::SetCursorPos([int]($x0 + 200 * [Math]::Sin($t * 2.1)), [int]($y0 + 120 * [Math]::Sin($t * 1.3))) | Out-Null
            Start-Sleep -Milliseconds 10
        }
        [DE]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 300
    }

    $lock = Enter-WrenLock desktop 'devtools_resize_e2e'
    try {
        # the browser window, panel docked: its tab is the strip
        $p = Start-Visible $staticUrl
        try {
            Start-Sleep -Seconds 3
            Stretch-Check 'browser window' $p.MainWindowHandle 20 20 1280 800
        } finally { try { Wren-Ctl quit | Out-Null } catch {}; Start-Sleep 1; if (-not $p.HasExited) { $p.Kill() } }

        # the panel's own window
        $p = Start-Visible $staticUrl
        try {
            Start-Sleep -Seconds 3
            Wren-Ctl cmd view.devtools_detach | Out-Null
            $dh = [IntPtr]::Zero
            for ($i = 0; $i -lt 50 -and $dh -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 100; $dh = [DE]::Find([uint32]$p.Id, 'Developer Tools') }
            if ($dh -eq [IntPtr]::Zero) { Fail 'the developer tools window did not open' }
            else {
                Stretch-Check 'developer tools window' $dh 100 100 1100 760
                # both windows through the system's size loop
                Real-Drag $dh 4
                if ($p.HasExited) { Fail 'the process ended while the panel window was dragged' } else { Pass 'the panel window was dragged by its corner, the process lives' }
                Real-Drag $p.MainWindowHandle 4
                if ($p.HasExited) { Fail 'the process ended while the browser window was dragged with the panel detached' } else { Pass 'the browser window was dragged with the panel detached, the process lives' }
            }
        } finally { try { Wren-Ctl quit | Out-Null } catch {}; Start-Sleep 1; if (-not $p.HasExited) { $p.Kill() } }
    } finally { Exit-WrenLock $lock }
} finally {
    Stop-WrenTestServer $server
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { "devtools_resize_e2e: $fail check(s) failed"; exit 1 }
'devtools_resize_e2e: all checks passed'
