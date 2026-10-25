# The docked developer tools while their splitter is dragged: the first frame drawn at a new width must be the one that is
# drawn at that width once the layout has settled (no frame laid out for the width of the frame before: a header, a filter
# field or columns squeezed or stretched into the new box). No timing, no desktop: a Wren with no window shown, the splitter pressed
# and moved by synthetic mouse events; after each step `wait frames 1`, a capture of the panel (A), five frames later another (B).
# A and B must be the same picture. For each panel (Network, Console, Elements) and each dock side.
#   powershell -NoProfile -File tools\devtools_split_e2e.ps1 [-Exe wren.exe]
param([string]$Exe = 'wren.exe', [string]$Out = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\test_env.ps1"
. "$PSScriptRoot\wrenctl.ps1"
$script:WrenExe = Join-Path $root "build\$Exe"
$tmp = if ($Out) { $Out } else { Join-Path $env:TEMP "wren-dtsplit-$PID" }
New-Item -ItemType Directory -Force $tmp | Out-Null
$ww = 1280; $wh = 800
$fail = 0
function Pass($m) { "PASS  $m" }
function Fail($m) { "FAIL  $m"; $script:fail++ }
function Mouse([string]$type, [int]$x, [int]$y) {
    Wren-Ctl raw ('{"method":"Input.dispatchMouseEvent","params":{"type":"' + $type + '","x":' + $x + ',"y":' + $y + ',"button":"left","space":"window"}}') | Out-Null
}
$server = Start-WrenTestServer
try {
    # a page that does nothing by itself (dt4.html streams: its panels change under the comparison)
    $static = Join-Path $tmp 'static.html'
    [IO.File]::WriteAllText($static, '<!doctype html><meta charset=utf-8><title>static</title><body style="margin:0;background:#fff"><h1>Nothing moves</h1>')
    $url = 'file:///' + ($static -replace '\\', '/')
    foreach ($tab in 'network', 'console', 'elements') {
        foreach ($dock in 'right', 'left') {
            $null = Start-Wren -Size "${ww}x$wh" -Dpi 96 -Pref 'browser.devtools.visible=true', "browser.devtools.tab=$tab", "browser.devtools.dock=$dock" -Url $url
            try {
                Wren-Ctl wait load | Out-Null
                Wren-Ctl wait frames 12 | Out-Null
                # the bar: 5 px wide, next to the 300 px panel
                $start = if ($dock -eq 'right') { $ww - 303 } else { 303 }
                $y = [int]($wh * 0.5)
                Mouse mouseMoved $start $y
                Mouse mousePressed $start $y
                $bad = 0; $steps = 0
                # the widths of the panel in turn: wider, much wider, narrower, narrow
                foreach ($w in 380, 520, 440, 330, 260, 410) {
                    $x = if ($dock -eq 'right') { $ww - $w - 3 } else { $w + 3 }
                    # (two moves: the pointer comes to the new place by a step, as a hand's does)
                    Mouse mouseMoved $x $y
                    Wren-Ctl wait frames 1 | Out-Null
                    # the panel without the bar and the page's notices: its header and its first rows
                    $rx = if ($dock -eq 'right') { $ww - $w + 10 } else { 4 }
                    $rect = "$rx,84,$($w - 14),90"
                    $a = Join-Path $tmp "a_${tab}_${dock}_$w.png"; $b = Join-Path $tmp "b_${tab}_${dock}_$w.png"
                    Wren-Ctl shot $a --rect $rect --settle 0 | Out-Null
                    Wren-Ctl wait frames 6 | Out-Null
                    Wren-Ctl shot $b --rect $rect --settle 0 | Out-Null
                    Wren-Ctl diff $a $b --tolerance 6 --max-percent 0 --out (Join-Path $tmp "d_${tab}_${dock}_$w.png") | Out-Null
                    $steps++
                    if ($global:WrenExit -ne 0) { $bad++; Write-Host "  $tab $dock : the first frame at $w px differs from the settled one" }
                }
                Mouse mouseReleased $x $y
                # and what the panel took for its own width was the width its layout gave it, at every frame
                $st = Wren-Ctl stats --json | ConvertFrom-Json
                if ($st.devtoolsRoomChecks -gt 0 -and $st.devtoolsRoomWrong -gt 0) { $bad++; Write-Host "  $tab $dock : the panel's width as asked differed from its layout's in $($st.devtoolsRoomWrong) of $($st.devtoolsRoomChecks) frames" }
                if ($bad -eq 0) { Pass "$tab, panel at the $dock : $steps widths, the first frame of each is the settled one" }
                else { Fail "$tab, panel at the $dock : $bad of $steps widths showed a frame laid out for another width (pictures in $tmp)" }
            } finally { Wren-Ctl quit | Out-Null }
        }
    }
} finally {
    Stop-WrenTestServer $server
    if (-not $Out -and $fail -eq 0) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
if ($fail) { "devtools_split_e2e: $fail check(s) failed"; exit 1 }
'devtools_split_e2e: all checks passed'
