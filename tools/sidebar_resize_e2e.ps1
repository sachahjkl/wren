# The tab sidebar's width handle, dragged (no window shown, synthetic input, nothing timed):
#   * every frame of the drag draws the sidebar's edge where the pointer is in that frame (the same distance from it in all of
#     them: no frame shows the width of the frame before);
#   * every frame paints the page at the width of its area (never an image of another width);
#   * the page's innerWidth follows the handle after each step, and the width is written to browser.tabs.sidebar_width when
#     the button goes up, not before.
#   powershell -NoProfile -File tools\sidebar_resize_e2e.ps1 [-Exe build\wren.exe]
param([string]$Exe = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\wrenctl.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
$fail = 0
function Pass($m) { "PASS  $m" }
function Fail($m) { "FAIL  $m"; $script:fail++ }
# The pointer is posted to the window as the system sends it (WM_MOUSEMOVE / WM_LBUTTONDOWN / WM_LBUTTONUP): a move then reaches
# the frame that reads it as the frame's input, the case where an edge built before the handle's signal lags a frame.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SidePoster {
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
    public static void Post(IntPtr h, uint msg, bool down, int x, int y) {
        SetThreadDpiAwarenessContext((IntPtr)(-4));
        PostMessageW(h, msg, (IntPtr)(down ? 1 : 0), (IntPtr)((y << 16) | (x & 0xFFFF)));
    }
}
'@
$script:hwnd = [IntPtr]::Zero
function Ev($t, $x, $y) {
    switch ($t) {
        'mouseMoved'    { [SidePoster]::Post($script:hwnd, 0x0200, $script:down, $x, $y) }
        'mousePressed'  { $script:down = $true; [SidePoster]::Post($script:hwnd, 0x0201, $true, $x, $y) }
        'mouseReleased' { $script:down = $false; [SidePoster]::Post($script:hwnd, 0x0202, $false, $x, $y) }
    }
}
$script:down = $false

$tmp = Join-Path $env:TEMP "wren-sidebar-e2e-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    $page = Join-Path $tmp 'mq.html'
    # (media queries on the width: the page is restyled when the handle crosses them)
    [IO.File]::WriteAllText($page, '<!doctype html><meta charset=utf-8><title>mq</title><style>body{margin:0}p{font:16px sans-serif}@media (max-width:700px){p{font-size:20px;color:#a00}}@media (max-width:600px){p{font-size:24px}}</style><body>' + ('<p>Some text that wraps differently at every width of the page, again and again.</p>' * 40))
    $url = 'file:///' + ($page -replace '\\', '/')
    $dpi = 144; $scale = $dpi / 96.0
    $null = Start-Wren -Size 1400x800 -Dpi $dpi -Pref 'browser.tabs.position=left', 'browser.frame.drag_probe=true'   # (the width at its default, 240: one given here would be the command line's, above the user's) -Url $url
    try {
        Wren-Ctl wait load | Out-Null
        Wren-Ctl wait frames 4 | Out-Null
        $w0 = [double](Wren-Eval 'innerWidth')
        $script:hwnd = [SidePoster]::FindWindow([uint32](Wren-Ctl stats --json | ConvertFrom-Json).pid)
        if ($script:hwnd -eq [IntPtr]::Zero) { throw 'no window of the process' }
        $edge = [int][Math]::Round(240 * $scale)
        $x = $edge - 2; $y = 500
        Ev mouseMoved $x $y; Wren-Ctl wait frames 2 | Out-Null
        Wren-Ctl stats --json --reset-frames | Out-Null
        Ev mousePressed $x $y; Wren-Ctl wait frames 2 | Out-Null
        $widths = @()
        foreach ($dx in 30, 75, 120, 200, 90, -60) {
            Ev mouseMoved ($x + $dx) $y
            Wren-Ctl wait frames 2 | Out-Null
            $widths += [pscustomobject]@{ dx = $dx; inner = [double](Wren-Eval 'innerWidth') }
        }
        $pref = (Wren-Ctl pref get browser.tabs.sidebar_width) -join ''
        $st = Wren-Ctl stats --json | ConvertFrom-Json
        Ev mouseReleased ($x - 60) $y; Wren-Ctl wait frames 3 | Out-Null
        $after = (Wren-Ctl pref get browser.tabs.sidebar_width) -join ''
        $innerAfter = [double](Wren-Eval 'innerWidth')

        $rows = @($st.dragSamples | ForEach-Object { [pscustomobject]@{ mouse = $_[2]; edge = $_[3]; page = $_[8]; area = $_[9] } })
        if ($env:WREN_E2E_DUMP) { $rows | Format-Table | Out-String | Write-Host }
        if ($rows.Count -lt 6) { Fail "the drag left $($rows.Count) samples (browser.frame.drag_probe): the handle was not held" }
        else {
            $off = @($rows | ForEach-Object { $_.edge - $_.mouse })
            $spread = ($off | Measure-Object -Maximum).Maximum - ($off | Measure-Object -Minimum).Minimum
            if ($spread -le 1) { Pass "$($rows.Count) frames of the drag drew the edge at the pointer they read (edge - pointer: $($off[0]) px in all)" }
            else { Fail "the edge lagged the pointer in some frames (edge - pointer from $(($off | Measure-Object -Minimum).Minimum) to $(($off | Measure-Object -Maximum).Maximum) px)" }
            $other = @($rows | Where-Object { $_.page -gt 0 -and [Math]::Abs($_.page - $_.area) -ge 1 })
            if ($other.Count -eq 0) { Pass 'every frame painted the page at the width of its area' }
            else { Fail "$($other.Count) frame(s) painted the page at another width than its area (page $($other[0].page), area $($other[0].area))" }
        }
        $bad = @($widths | Where-Object { [Math]::Abs(($w0 - $_.inner) - [Math]::Round($_.dx / $scale)) -gt 1.5 })
        if ($bad.Count -eq 0) { Pass "innerWidth followed the handle ($(($widths | ForEach-Object { $_.inner }) -join ', '))" }
        else { Fail "innerWidth did not follow the handle: $(($widths | ForEach-Object { "$($_.dx):$($_.inner)" }) -join ' ') from $w0" }
        if ($pref -match '^240') { Pass 'the preference is untouched while the handle is held' } else { Fail "the preference changed during the drag: $pref" }
        $want = 240 + [Math]::Round(-60 / $scale)
        if ($after -match "^$want") { Pass "the width is written when the button goes up ($want)" } else { Fail "after the release browser.tabs.sidebar_width is '$after', not $want (innerWidth $innerAfter)" }
    } finally { Stop-Wren | Out-Null }
} finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
if ($fail) { "sidebar_resize_e2e: $fail check(s) failed"; exit 1 }
'sidebar_resize_e2e: all checks passed'
