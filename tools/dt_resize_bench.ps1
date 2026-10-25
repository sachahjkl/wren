# Frame times while the developer tools are resized: the splitter between the page and the docked panel, the window with the
# panel open, the detached panel's window. Needs build\wren_prof.exe (build.bat profile). One line per run: the frames of the
# drag (median / 95th percentile / worst CPU time of a frame, the longest gap between two frames, frames per second), and the
# phases that took the time.
#   powershell -File tools\dt_resize_bench.ps1 [-Only name,name] [-Tag suffix] [-Passes 3] [-Exe wren_prof.exe] [-Sample]
# Scenario names: <what>_<tab>_<page>: what = split_bottom | split_right | win_bottom | win_right | detached_win | detached_main
# | float_size; tab = console | elements | network | application | performance | memory; page = light (a small page of the
# test server with some requests) | heavy (10 000 elements). -Only takes names or wildcards.
# Input is posted to the window (no desktop.lock), as tools\perf.ps1 does; each run holds bench.lock.
param([string[]]$Only = @(), [string]$Tag = '', [int]$Passes = 1, [string]$Exe = 'wren_prof.exe', [switch]$Sample, [int]$Secs = 6,
      [string[]]$Pref = @(), [string]$Out = '', [switch]$Real, [string]$Site = '', [string[]]$Tabs = @(), [string[]]$OnlyPages = @())
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$outDir = if ($Out) { $Out } else { Join-Path $root 'build\dtbench' }
New-Item -ItemType Directory -Force $outDir | Out-Null
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class DB {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, int d, IntPtr e);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static IntPtr FindDevtools(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h)) return true;
      var sb = new StringBuilder(256); GetWindowText(h, sb, 256);
      if (sb.ToString().Contains("Developer Tools")) found = h;
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@
[DB]::SetProcessDPIAware() | Out-Null
. (Join-Path $PSScriptRoot 'test_env.ps1')
. (Join-Path $PSScriptRoot 'wrenctl.ps1')
Add-Type -AssemblyName System.Drawing
$script:WrenExe = Join-Path $root "build\$Exe"
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Tabs = @($Tabs | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$OnlyPages = @($OnlyPages | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

function Pct($v, $p) { if ($v.Count -eq 0) { return 0 }; $s = @($v | Sort-Object); $s[[Math]::Min($s.Count - 1, [Math]::Max(0, [int][Math]::Ceiling($s.Count * $p / 100) - 1))] }
function Rnd($x, $n = 1) { [math]::Round([double]$x, $n) }

$heavy = Join-Path $outDir 'p10k.html'
if (-not (Test-Path $heavy)) {
    $src = Join-Path $root 'build\perf\p10k.html'
    if (-not (Test-Path $src)) { $src = 'S:\wren\build\perf\p10k.html' }
    Copy-Item $src $heavy
}
# reflow: text whose line breaks depend on the width (every width change re-wraps all of it: a layout that is long at any size)
$reflow = Join-Path $outDir 'reflow.html'
if (-not (Test-Path $reflow)) {
    $para = 'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. '
    $body = (1..1500 | ForEach-Object { "<p>$_ $para$para</p>" }) -join "`n"
    [IO.File]::WriteAllText($reflow, "<!doctype html><meta charset=utf-8><style>body{font:16px sans-serif;margin:8px}p{margin:0 0 8px}</style>$body")
}
# wrap: thousands of boxes in a wrapping flex row: the rows break again at every width, the layout of all of them is redone
$wrap = Join-Path $outDir 'wrap.html'
if (-not (Test-Path $wrap)) {
    $cells = (1..12000 | ForEach-Object { "<div>$_ box</div>" }) -join ''
    [IO.File]::WriteAllText($wrap, "<!doctype html><meta charset=utf-8><style>body{margin:8px;font:14px sans-serif}.w{display:flex;flex-wrap:wrap}.w div{width:90px;height:40px;margin:2px;border:1px solid #888;padding:2px}</style><div class=w>$cells</div>")
}
function FileUrl($p) { 'file:///' + ($p -replace '\\', '/') }

function Client($h) { $r = New-Object DB+RECT; [DB]::GetClientRect($h, [ref]$r) | Out-Null; $r }
function MakeLp([int]$x, [int]$y) { [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF)) }
function Post($h, [uint32]$m, [int]$w, [int]$x, [int]$y) { [DB]::PostMessage($h, $m, [IntPtr]$w, (MakeLp $x $y)) | Out-Null }

# the splitter is a 5 px bar (CSS) between the page and the panel: bottom, its y is the client's bottom minus the status bar
# and the panel; side, its x is the client's right minus the panel
function Find-Splitter([string]$dock, [int]$w, [int]$hh) {
    # the panel is dark, the page light: from the window's bottom (or right) edge the dark run ends at the splitter. Several
    # lines are read (a letter of the panel breaks one) and the median taken.
    $png = Join-Path $env:TEMP "dtb_split_$PID.png"
    Wren-Ctl shot $png --window | Out-Null
    $bmp = [Drawing.Bitmap]::FromFile($png)
    $found = @()
    try {
        $dark = { param($c) $c.R -lt 90 -and $c.G -lt 90 -and $c.B -lt 90 }
        if ($dock -eq 'bottom') {
            foreach ($f in 0.003, 0.02, 0.05, 0.2, 0.35, 0.5, 0.65, 0.8, 0.9, 0.97) {
                $x = [int](($bmp.Width - 1) * $f); $y = $bmp.Height - 1
                while ($y -gt 0 -and (& $dark $bmp.GetPixel($x, $y))) { $y-- }
                $found += $y
            }
        } else {
            foreach ($f in 0.3, 0.4, 0.5, 0.6, 0.7, 0.75, 0.8, 0.85, 0.9) {
                $y = [int](($bmp.Height - 1) * $f); $x = $bmp.Width - 1
                while ($x -gt 0 -and (& $dark $bmp.GetPixel($x, $y))) { $x-- }
                $found += $x
            }
        }
    } finally { $bmp.Dispose(); Remove-Item $png -ErrorAction SilentlyContinue }
    $s = @($found | Sort-Object)
    if ($env:DTB_DEBUG) { Write-Host "  splitter candidates ($dock): $($s -join ',')" }
    $mode = ($s | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
    return [int]$mode + 5   # the page's last pixel is the mode; the grip (about 9 px) follows it
}function Split-Drag($h, [string]$dock, [int]$ms, [double]$sc, [int]$every) {
    $c = Client $h
    # (right: from the geometry, the panel is 300 CSS px wide and the bar 5 px left of it; reading the colors fails on a dark page)
    $pos = if ($dock -eq 'right') { [int]($c.R - 302.5 * $sc) } else { Find-Splitter $dock $c.R $c.B }
    if ($pos -lt 0) { throw "splitter not found" }
    Mark
    if ($dock -eq 'bottom') { $x = [int]($c.R / 2); $y0 = $pos }
    else { $y = [int]($c.B * 0.6); $x0 = $pos }
    if ($dock -eq 'bottom') { Post $h 0x0200 0 $x $y0 } else { Post $h 0x0200 0 $x0 $y }
    Start-Sleep -Milliseconds 120
    if ($dock -eq 'bottom') { Post $h 0x0201 1 $x $y0 } else { Post $h 0x0201 1 $x0 $y }
    $sw = [Diagnostics.Stopwatch]::StartNew(); $next = 0; $shot = $false
    $amp = if ($dock -eq 'bottom') { [int]($c.B * 0.22) } else { [int]($c.R * 0.22) }
    while ($sw.ElapsedMilliseconds -lt $ms) {
        if ($sw.ElapsedMilliseconds -ge $next) {
            $d = [int]($amp * [Math]::Sin($sw.ElapsedMilliseconds / 450.0))
            if ($dock -eq 'bottom') { Post $h 0x0200 1 $x ($y0 + $d) } else { Post $h 0x0200 1 ($x0 + $d) $y }
            $next = $sw.ElapsedMilliseconds + $every
        }
        if ($env:DTB_SHOT -and -not $shot -and $sw.ElapsedMilliseconds -gt $ms * 0.6) { $shot = $true; Wren-Ctl shot $env:DTB_SHOT --window --scale 0.5 | Out-Null }
        [Threading.Thread]::Yield() | Out-Null
    }
    if ($dock -eq 'bottom') { Post $h 0x0202 0 $x $y0 } else { Post $h 0x0202 0 $x0 $y }
    MarkEnd
    Start-Sleep -Milliseconds 300
    Write-Host ('  panel size pref after: ' + (Wren-Ctl pref get browser.devtools.size) + ' (300 before)')
}
function Win-Drag($h, [int]$ms, [int]$every, [bool]$both = $true) {
    $r = New-Object DB+RECT; [DB]::GetWindowRect($h, [ref]$r) | Out-Null
    $w0 = $r.R - $r.L; $h0 = $r.B - $r.T; $sw = [Diagnostics.Stopwatch]::StartNew(); $next = 0
    while ($sw.ElapsedMilliseconds -lt $ms) {
        if ($sw.ElapsedMilliseconds -ge $next) {
            $t = $sw.ElapsedMilliseconds / 400.0
            $w = [int]($w0 * (0.8 + 0.2 * [Math]::Sin($t)))
            $hh = if ($both) { [int]($h0 * (0.8 + 0.2 * [Math]::Sin($t * 0.7))) } else { $h0 }
            [DB]::SetWindowPos($h, [IntPtr]::Zero, $r.L, $r.T, $w, $hh, 0x14) | Out-Null
            $next = $sw.ElapsedMilliseconds + $every
        }
        [Threading.Thread]::Yield() | Out-Null
    }
    [DB]::SetWindowPos($h, [IntPtr]::Zero, $r.L, $r.T, $w0, $h0, 0x14) | Out-Null
}

# With -Real the window's corner is dragged by the real mouse (the system's size loop, as a user does it; needs the desktop and
# holds desktop.lock), else SetWindowPos from this process (no loop of the system, no lock).
function Real-Drag($h, [int]$ms, [int]$every = 8) {
    [DB]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x43) | Out-Null   # topmost, no move, no size
    Start-Sleep -Milliseconds 300
    $r = New-Object DB+RECT; [DB]::GetWindowRect($h, [ref]$r) | Out-Null
    $x0 = $r.R - 3; $y0 = $r.B - 3
    [DB]::SetCursorPos($x0, $y0) | Out-Null; Start-Sleep -Milliseconds 300
    [DB]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $t = $sw.ElapsedMilliseconds / 1000.0
        [DB]::SetCursorPos([int]($x0 + 250 * [Math]::Sin($t * 2.1)), [int]($y0 + 150 * [Math]::Sin($t * 1.3))) | Out-Null
        Start-Sleep -Milliseconds $every
    }
    [DB]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 300
}
function Resize-Drag($h, [int]$ms) { if ($Real) { Real-Drag $h $ms } else { Win-Drag $h $ms 4 } }

$script:rows = New-Object Collections.ArrayList

function Run($name, $url, [string]$dock, [string]$tab, [scriptblock]$actions) {
    if ($Only.Count -gt 0 -and -not ($Only | Where-Object { $name -like $_ })) { return }
    for ($pass = 1; $pass -le $Passes; $pass++) {
        $prefix = Join-Path $outDir "$name$Tag.$pass"
        $env:WREN_PROF = $prefix
        $env:WREN_SAMPLE = if ($Sample) { '1' } else { '0' }
        $prof = Join-Path $env:TEMP ("dtb_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $rname = 'dtb' + [guid]::NewGuid().ToString('N').Substring(0, 6)
        $env:WREN_REMOTE = $rname
        $args2 = @("--remote=$rname", '--no-single-instance', '--profile', "`"$prof`"", '--pref', 'browser.devtools.visible=true', '--pref', "browser.devtools.tab=$tab", '--pref', ('browser.devtools.dock=' + $(if ($dock -like 'float*' -or $dock -like 'detach*') { 'bottom' } else { $dock }))) + @($Pref | ForEach-Object { '--pref'; $_ }) + @($url)
        $bench = Enter-WrenLock bench "dt_resize_bench $name"
        $desk = if ($Real) { Enter-WrenLock desktop "dt_resize_bench $name" } else { $null }
        $p = $null
        try {
            $p = Start-Process (Join-Path $root "build\$Exe") -ArgumentList $args2 -PassThru
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not $p.HasExited -and $p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20; $p.Refresh() }
            $h = $p.MainWindowHandle
            [DB]::SetWindowPos($h, [IntPtr]::Zero, 20, 20, 1280, 800, 0x14) | Out-Null
            $script:runSw = $sw; $script:actMs = -1; $script:endMs = -1
            & $actions $h $p
            [IO.File]::WriteAllText("$prefix.act", "$script:actMs $script:endMs")
            [DB]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            if (-not $p.WaitForExit(30000)) { Write-Host "$name did not exit, killed"; $p.Kill() }
        } finally { if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null }; if ($desk) { Exit-WrenLock $desk }; Exit-WrenLock $bench; Remove-Item -Recurse -Force $prof -ErrorAction SilentlyContinue }
        $row = Summarize $name $pass $prefix
        if ($row) { [void]$script:rows.Add($row); Write-Host (($row.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join " ") }
    }
}
function Detach($p) {
    Wren-Ctl cmd view.devtools_detach | Out-Null
    $dh = [IntPtr]::Zero
    for ($i = 0; $i -lt 50 -and $dh -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 100; $dh = [DB]::FindDevtools([uint32]$p.Id) }
    if ($dh -eq [IntPtr]::Zero) { throw "the developer tools window did not open" }
    [DB]::SetWindowPos($dh, [IntPtr]::Zero, 100, 100, 1100, 760, 0x14) | Out-Null
    Start-Sleep -Seconds 2
    return $dh
}
function Mark { $script:actMs = $script:runSw.ElapsedMilliseconds }
function MarkEnd { $script:endMs = $script:runSw.ElapsedMilliseconds }

function Summarize($name, $pass, $prefix) {
    if (-not (Test-Path "$prefix.csv")) { Write-Host "$name pass ${pass}: no profile"; return }
    $d = @(Import-Csv "$prefix.csv")
    $a = (Get-Content "$prefix.act").Split(' ')
    $t0 = [double]$a[0]; $t1 = [double]$a[1]
    $d = @($d | Where-Object { [double]$_.t_ms -ge $t0 -and ($t1 -lt 0 -or [double]$_.t_ms -le $t1) })
    if ($d.Count -lt 3) { return [pscustomobject]@{ run = "$name.$pass"; frames = $d.Count } }
    $cpu = @($d | ForEach-Object { [double]$_.Frame - [double]$_.Wait - [double]$_.Present })
    $gaps = @(for ($i = 1; $i -lt $d.Count; $i++) { [double]$d[$i].t_ms - [double]$d[$i - 1].t_ms })
    $span = ([double]$d[-1].t_ms - [double]$d[0].t_ms) / 1000
    function Avg($col) { Rnd (($d | ForEach-Object { [double]$_.$col } | Measure-Object -Average).Average) 2 }
    $dw = $null
    if (Test-Path "$prefix.dtwin.csv") {
        $w = @(Import-Csv "$prefix.dtwin.csv" | Where-Object { [double]$_.t_ms -ge $t0 -and ($t1 -lt 0 -or [double]$_.t_ms -le $t1) })
        if ($w.Count -ge 3) {
            $wc = @($w | ForEach-Object { [double]$_.dur_ms - [double]$_.present_ms })
            $wg = @(for ($i = 1; $i -lt $w.Count; $i++) { [double]$w[$i].t_ms - [double]$w[$i - 1].t_ms })
            $dw = [pscustomobject]@{ n = $w.Count; cpu50 = Rnd (Pct $wc 50); cpu95 = Rnd (Pct $wc 95); cpumax = Rnd ($wc | Measure-Object -Maximum).Maximum; gap50 = Rnd (Pct $wg 50); gap95 = Rnd (Pct $wg 95); gapmax = Rnd ($wg | Measure-Object -Maximum).Maximum }
        }
    }
    $o = [pscustomobject]@{
        run = "$name.$pass"; frames = $d.Count; fps = Rnd ($d.Count / [math]::Max($span, 0.001))
        cpu_p50 = Rnd (Pct $cpu 50); cpu_p95 = Rnd (Pct $cpu 95); cpu_max = Rnd ($cpu | Measure-Object -Maximum).Maximum
        gap_p50 = Rnd (Pct $gaps 50); gap_p95 = Rnd (Pct $gaps 95); gap_max = Rnd ($gaps | Measure-Object -Maximum).Maximum
        laid = @($d | Where-Object { [double]$_.Layout -gt 0 }).Count; layout_max = Rnd ($d | ForEach-Object { [double]$_.Layout } | Measure-Object -Maximum).Maximum
        styles = Avg 'Styles'; layout = Avg 'Layout'; build = Avg 'Build_UI'; draw = Avg 'UI_Draw'; submit = Avg 'Submit'; present = Avg 'Present'; wait = Avg 'Wait'
    }
    if ($dw) { foreach ($k in $dw.PSObject.Properties) { $o | Add-Member -NotePropertyName ('dw_' + $k.Name) -NotePropertyValue $k.Value } }
    $o
}

$srv = Start-WrenTestServer
try {
    $env:WREN_TEST_BASE_PORT = "$($srv.BasePort)"
    $light = "$($srv.Origin)/site/devtools/dt4.html"
    $pages = [ordered]@{ light = $light; heavy = (FileUrl $heavy); reflow = (FileUrl $reflow); wrap = (FileUrl $wrap) }
    # -Site: a real site (and about:home) among the pages; -Tabs: only these panels; -OnlyPages: only these pages
    if ($Site) { $pages['site'] = $Site; $pages['home'] = 'about:home' }
    if ($OnlyPages.Count -gt 0) { foreach ($k in @($pages.Keys)) { if ($OnlyPages -notcontains $k) { $pages.Remove($k) } } }
    $tabs = if ($Tabs.Count -gt 0) { $Tabs } else { 'console', 'elements', 'network' }
    foreach ($pg in $pages.Keys) {
        $url = $pages[$pg]
        $settle = if ($pg -ne 'light') { 9 } else { 5 }
        foreach ($tab in $tabs) {
            Run "detached_win_${tab}_$pg" $url 'bottom' $tab { param($h, $p) Start-Sleep $settle; $dh = Detach $p; Mark; Resize-Drag $dh ($Secs * 1000); MarkEnd }
            Run "detached_main_${tab}_$pg" $url 'bottom' $tab { param($h, $p) Start-Sleep $settle; $dh = Detach $p; Mark; Resize-Drag $h ($Secs * 1000); MarkEnd }
            Run "split_bottom_${tab}_$pg" $url 'bottom' $tab { param($h) Start-Sleep $settle; Split-Drag $h 'bottom' ($Secs * 1000) ([DB]::GetDpiForWindow($h) / 96.0) 4 }
            Run "split_right_${tab}_$pg" $url 'right' $tab { param($h) Start-Sleep $settle; Split-Drag $h 'right' ($Secs * 1000) ([DB]::GetDpiForWindow($h) / 96.0) 4 }
            Run "win_bottom_${tab}_$pg" $url 'bottom' $tab { param($h) Start-Sleep $settle; Mark; Resize-Drag $h ($Secs * 1000); MarkEnd }
            Run "win_right_${tab}_$pg" $url 'right' $tab { param($h) Start-Sleep $settle; Mark; Resize-Drag $h ($Secs * 1000); MarkEnd }
        }
    }
} finally { Stop-WrenTestServer $srv }

if ($script:rows.Count) {
    "`n--- summary (ms; cpu = a frame without its waits; gap = between two frames) ---"
    $script:rows | Format-Table -AutoSize | Out-String -Width 400 | Write-Host
    $script:rows | Export-Csv -NoTypeInformation (Join-Path $outDir "summary$Tag.csv")
}
