# The cadence of the frames while a splitter is dragged (the developer tools docked at the right and at the bottom, the tab
# sidebar's width handle) against the one while the window itself is resized. No window shown: input is posted to the window
# (WM_MOUSEMOVE at about 1 kHz, as a gaming mouse sends it), the window is resized by SetWindowPos (every millisecond), and
# the frames are read from `wren ctl stats --json` (framesPresented, frameGapP50Ms, frameStates, framesAtOnce).
#   powershell -NoProfile -File tools\splitter_cadence.ps1 [-Exe build\wren.exe] [-Ms 1500] [-Pref name=value,...] [-Only names] [-At x,y]
# Scenarios: devtools_right, devtools_bottom, sidebar, and with -Measure window (a hidden window resized by SetWindowPos makes
# frames the stats count as resize steps but presents almost none: what a visible window's edge does needs the screen). Checks (nothing timed: the rates are printed, never asserted):
#   * the frames of a splitter's drag are in the Drag state of the cadence model (platform/pacing.odin);
#   * with browser.frame.variable_refresh=on (a variable refresh screen, whatever this machine's), a splitter's frames are
#     presented at once (framesAtOnce), as a resize's are: on such a screen a frame that waits for a refresh waits for the
#     rate the system reports at rest (60 Hz under Windows' dynamic refresh rate), not for the screen's top one.
# -Measure: no checks, the table only (the machine's own screen, preferences as given).
param([string]$Exe = '', [int]$Ms = 1500, [string[]]$Pref = @(), [string[]]$Only = @(), [switch]$Measure, [string]$At = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\wrenctl.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
$script:WrenExe = $env:WREN_EXE
$Pref = @($Pref | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if (-not $Measure -and -not ($Pref | Where-Object { $_ -like 'browser.frame.variable_refresh=*' })) { $Pref += 'browser.frame.variable_refresh=on' }
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Threading;
using System.Runtime.InteropServices;
public static class SplitCad {
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint p);
    [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
    public static IntPtr FindWindow(uint pid) {
        IntPtr found = IntPtr.Zero; int best = 0;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            RECT r; if (p == pid && GetClientRect(h, out r) && r.r * r.b > best) { best = r.r * r.b; found = h; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static void Move(IntPtr h, int x, int y) { SetThreadDpiAwarenessContext((IntPtr)(-4)); SetWindowPos(h, IntPtr.Zero, x, y, 0, 0, 0x15 | 0x200); }
    public static RECT Client(IntPtr h) { SetThreadDpiAwarenessContext((IntPtr)(-4)); RECT r; GetClientRect(h, out r); return r; }
    public static void Post(IntPtr h, uint msg, bool down, int x, int y) {
        SetThreadDpiAwarenessContext((IntPtr)(-4));
        PostMessageW(h, msg, (IntPtr)(down ? 1 : 0), (IntPtr)((y << 16) | (x & 0xFFFF)));
    }
    // The button held, the pointer swept along one axis around (x, y) for `ms`, a move every millisecond. Returns the moves.
    public static int Sweep(IntPtr h, int x, int y, bool alongX, int amp, int ms) {
        SetThreadDpiAwarenessContext((IntPtr)(-4));
        timeBeginPeriod(1);
        int n = 0;
        try {
            var sw = Stopwatch.StartNew(); long next = 0;
            while (sw.ElapsedMilliseconds < ms) {
                long t = sw.ElapsedTicks * 1000000 / Stopwatch.Frequency;   // us
                if (t >= next) {
                    int d = (int)(amp * Math.Sin(t / 450000.0));
                    int px = alongX ? x + d : x, py = alongX ? y : y + d;
                    PostMessageW(h, 0x0200, (IntPtr)1, (IntPtr)((py << 16) | (px & 0xFFFF)));
                    n++; next = t + 1000;
                }
                Thread.SpinWait(50);
            }
        } finally { timeEndPeriod(1); }
        return n;
    }
    // The window resized every millisecond for `ms` (its width swept), as a window's edge dragged by the system does.
    public static int Resize(IntPtr h, int ms) {
        SetThreadDpiAwarenessContext((IntPtr)(-4));
        RECT r; GetWindowRect(h, out r);
        int w0 = r.r - r.l, h0 = r.b - r.t, n = 0;
        var sw = Stopwatch.StartNew(); long next = 0;
        while (sw.ElapsedMilliseconds < ms) {
            long t = sw.ElapsedTicks * 1000000 / Stopwatch.Frequency;
            if (t >= next) {
                int w = (int)(w0 * (0.85 + 0.15 * Math.Sin(t / 400000.0)));
                SetWindowPos(h, IntPtr.Zero, r.l, r.t, w, h0, 0x14 | 0x200);   // no z-order, no activation, no owner z-order
                n++; next = t + 1000;
            }
            Thread.SpinWait(50);
        }
        SetWindowPos(h, IntPtr.Zero, r.l, r.t, w0, h0, 0x14 | 0x200);
        return n;
    }
}
'@
$fail = 0
function Pass($m) { "PASS  $m" }
function Fail($m) { "FAIL  $m"; $script:fail++ }
function States($s) {
    $h = @{}
    foreach ($kv in ("$s" -split ' ' | Where-Object { $_ })) { $p = $kv -split '='; $h[$p[0]] = [int]$p[1] }
    return $h
}
function Diff-States($a, $b) {
    $o = @{}
    foreach ($k in $b.Keys) { $d = $b[$k] - $(if ($a.ContainsKey($k)) { $a[$k] } else { 0 }); if ($d -gt 0) { $o[$k] = $d } }
    return $o
}
# The bottom splitter: the panel is dark, the page white; from the window's bottom edge up, the dark run ends at the bar.
function Find-BottomSplit($w) {
    $png = Join-Path $env:TEMP "splitcad_$PID.png"
    Wren-Ctl shot $png --window | Out-Null
    $bmp = [Drawing.Bitmap]::FromFile($png)
    $found = @()
    try {
        foreach ($f in 0.2, 0.35, 0.5, 0.65, 0.8) {
            $x = [int](($bmp.Width - 1) * $f); $y = [int]($bmp.Height * 0.25)
            while ($y -lt $bmp.Height - 1) { $c = $bmp.GetPixel($x, $y); if ($c.R -lt 200 -or $c.G -lt 200) { break }; $y++ }
            $found += $y
        }
    } finally { $bmp.Dispose(); Remove-Item $png -ErrorAction SilentlyContinue }
    return [int](($found | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name) + 2
}

$tmp = Join-Path $env:TEMP "wren-splitcad-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$rows = @()
try {
    $page = Join-Path $tmp 'p.html'
    [IO.File]::WriteAllText($page, '<!doctype html><meta charset=utf-8><title>p</title><style>html,body{margin:0;background:#fff}p{font:16px sans-serif;margin:8px}</style><body>' + ('<p>Text that wraps at every width of the page, again and again.</p>' * 30))
    $url = 'file:///' + ($page -replace '\\', '/')
    $dpi = 144; $scale = $dpi / 96.0
    $scen = [ordered]@{
        devtools_right  = @('browser.devtools.visible=true', 'browser.devtools.dock=right', 'browser.devtools.size=300', 'browser.devtools.tab=console')
        devtools_bottom = @('browser.devtools.visible=true', 'browser.devtools.dock=bottom', 'browser.devtools.size=300', 'browser.devtools.tab=console')
        sidebar         = @('browser.tabs.position=left')
        window          = @()
    }
    foreach ($name in $scen.Keys) {
        if ($Only.Count -gt 0 -and $Only -notcontains $name) { continue }
        if ($name -eq 'window' -and -not $Measure) { continue }   # (a comparison only: nothing checked)
        $null = Start-Wren -Size 1400x900 -Dpi $dpi -Pref (@($scen[$name]) + $Pref) -Url $url
        try {
            Wren-Ctl wait load | Out-Null
            Wren-Ctl wait frames 6 | Out-Null
            $st0 = Wren-Ctl stats --json | ConvertFrom-Json
            $h = [SplitCad]::FindWindow([uint32]$st0.pid)
            if ($h -eq [IntPtr]::Zero) { throw 'no window of the process' }
            # -At x,y: the hidden window moved there (physical px of the desktop: the monitor whose cadence is measured)
            if ($At) { $xy = $At -split ','; [SplitCad]::Move($h, [int]$xy[0], [int]$xy[1]); Wren-Ctl wait frames 3 | Out-Null }
            $c = [SplitCad]::Client($h)
            $alongX = $true; $amp = [int](120 * $scale)
            switch ($name) {
                'devtools_right'  { $x = [int]([double](Wren-Eval 'innerWidth') * $scale + 2.5 * $scale); $y = [int]($c.b * 0.6) }
                'devtools_bottom' { $x = [int]($c.r / 2); $y = Find-BottomSplit $c.r; $alongX = $false; $amp = [int](80 * $scale) }
                'sidebar'         { $x = [int][Math]::Round(240 * $scale) - 2; $y = [int]($c.b * 0.6) }
            }
            if ($name -ne 'window') {
                [SplitCad]::Post($h, 0x0200, $false, $x, $y); Wren-Ctl wait frames 2 | Out-Null
                [SplitCad]::Post($h, 0x0201, $true, $x, $y); Wren-Ctl wait frames 2 | Out-Null
            }
            $before = States (Wren-Ctl stats --json --reset-frames | ConvertFrom-Json).frameStates
            $moves = if ($name -eq 'window') { [SplitCad]::Resize($h, $Ms) } else { [SplitCad]::Sweep($h, $x, $y, $alongX, $amp, $Ms) }
            $raw = Wren-Ctl stats --json
            if ($env:SPLITCAD_DUMP) { [IO.File]::WriteAllText((Join-Path $env:SPLITCAD_DUMP "$name.json"), $raw) }
            $st = $raw | ConvertFrom-Json
            $innerHeld = [double](Wren-Eval ($(if ($alongX) { 'innerWidth' } else { 'innerHeight' })))
            if ($name -ne 'window') { [SplitCad]::Post($h, 0x0202, $false, $x, $y); Wren-Ctl wait frames 3 | Out-Null }
            $d = Diff-States $before (States $st.frameStates)
            $atOnce = if ($null -ne $st.framesAtOnce) { [int]$st.framesAtOnce } else { $null }
            $rows += [pscustomobject]@{
                scenario = $name; moves = $moves; presented = $st.framesPresented
                fps = [Math]::Round($st.framesPresented / ($Ms / 1000.0)); gapP50 = [Math]::Round($st.frameGapP50Ms, 2); gapP95 = [Math]::Round($st.frameGapP95Ms, 2)
                atOnce = $atOnce; states = (($d.Keys | Sort-Object | ForEach-Object { "$_=$($d[$_])" }) -join ' ')
                hz = [Math]::Round($st.hz, 1); hzReported = [Math]::Round($st.hzReported, 1); hzMax = [Math]::Round($st.hzMax, 1); hzNow = [Math]::Round($st.hzNow, 1)
                variable = $st.variableRefresh; strict = $st.frameCapStrict
            }
            if ($Measure) { continue }
            $made = ($d.Values | Measure-Object -Sum).Sum
            $drag = if ($d.ContainsKey('Drag')) { $d['Drag'] } else { 0 }
            # (half at least: on a slow machine a frame more than 1.5 periods after the last one answers input instead)
            if ($made -gt 0 -and $drag -ge $made * 0.5) { Pass "$name : $drag of $made frames of the drag in the Drag state" }
            else { Fail "$name : $drag of $made frames of the drag in the Drag state ($($rows[-1].states))" }
            if ($st.variableRefresh) {
                if ($null -eq $atOnce) { Fail "$name : stats has no framesAtOnce" }
                elseif ($atOnce -ge $st.framesPresented * 0.8) { Pass "$name : $atOnce of $($st.framesPresented) frames presented at once (variable refresh)" }
                else { Fail "$name : only $atOnce of $($st.framesPresented) frames presented at once on a variable refresh screen" }
            }
            $prop = if ($alongX) { 'innerWidth' } else { 'innerHeight' }
            if ($innerHeld -gt 0) { Pass "$name : the page followed the splitter ($prop $innerHeld while held)" }
        } finally { Stop-Wren | Out-Null }
    }
} finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
$rows | Format-List | Out-String -Width 300 | Write-Host
if ($Measure) { return }
if ($fail) { "splitter_cadence: $fail check(s) failed"; exit 1 }
'splitter_cadence: all checks passed'
