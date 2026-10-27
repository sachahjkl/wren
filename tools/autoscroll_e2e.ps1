# End-to-end test of middle-click autoscroll of the page (page_autoscroll.odin, ui/autoscroll.odin): a throwaway Wren
# with no window shown loads a tall page from the test server, a middle press and a pointer moved down scroll it, the
# speed grows with the distance, Escape stops it, and a middle click on a link opens a new tab. Correctness only (no
# timing asserts: not a perf test; the waits are generous).
#   powershell -NoProfile -File tools\autoscroll_e2e.ps1 [-Exe build\wren.exe]
param([string]$Exe = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\test_env.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
. "$PSScriptRoot\wrenctl.ps1"

$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "PASS  $name" } else { "FAIL  $name  $detail"; $script:fail++ }
}
function Mouse([string]$type, [double]$x, [double]$y, [string]$button = 'left') {
    $p = "{`"type`":`"$type`",`"x`":$x,`"y`":$y,`"button`":`"$button`",`"space`":`"page`"}"
    Wren-Ctl raw "{`"method`":`"Input.dispatchMouseEvent`",`"params`":$p}" | Out-Null
}
function ScrollY { return [double](Wren-Eval 'window.scrollY') }
function TabCount { return ([int]((Wren-Ctl tabs) -split "`n" | Where-Object { $_ -match '\S' }).Count) }

$srv = Start-WrenTestServer
try {
    $env:WREN_TEST_BASE_PORT = $srv.BasePort
    $url = "$($srv.Origin)/site/autoscroll.html"
    Start-Wren -Size '900x700' -Pref @('browser.scroll.autoscroll.enabled=true', 'blocker.welcome_toast=false') | Out-Null
    try {
        Wren-Nav -Url $url -Wait 'stable' | Out-Null
        $maxY = [double](Wren-Eval 'document.documentElement.scrollHeight - window.innerHeight')
        Check 'the page is tall enough to scroll' ($maxY -gt 1000) "maxY=$maxY"

        $y0 = ScrollY
        Check 'starts at the top' ($y0 -lt 1) "scrollY=$y0"

        # middle press low on the page, then hold the pointer far below the anchor: it scrolls down
        Mouse 'mousePressed' 450 400 'middle'
        Mouse 'mouseMoved'   450 650 'middle'
        Wren-Ctl wait frames 20 | Out-Null
        $y1 = ScrollY
        Check 'middle drag down scrolls down' ($y1 -gt $y0 + 2) "scrollY $y0 -> $y1"

        # farther from the anchor scrolls faster: the same frames move more
        $before = ScrollY
        Mouse 'mouseMoved' 450 690 'middle'   # near the edge: fast
        Wren-Ctl wait frames 10 | Out-Null
        $fast = (ScrollY) - $before
        $before2 = ScrollY
        Mouse 'mouseMoved' 450 420 'middle'   # just past the dead zone: slow
        Wren-Ctl wait frames 10 | Out-Null
        $slow = (ScrollY) - $before2
        Check 'the speed grows with the distance' ($fast -gt $slow + 1) "fast=$fast slow=$slow"

        # Escape ends the session
        Wren-Ctl key Escape | Out-Null
        Wren-Ctl wait frames 3 | Out-Null
        $yEsc = ScrollY
        Mouse 'mouseMoved' 450 690 'middle'
        Wren-Ctl wait frames 10 | Out-Null
        $yAfter = ScrollY
        Check 'Escape stops autoscroll' ([math]::Abs($yAfter - $yEsc) -lt 2) "after Escape $yEsc -> $yAfter"
        Mouse 'mouseReleased' 450 690 'middle'

        # a middle click on a link opens a new tab (autoscroll never starts over a link). Scroll to the top so the link
        # is in view, then a real middle press+release on it (the high-level `click` uses a synthetic activation, not the
        # mouse path, so the raw events exercise the autoscroll/link branch).
        Wren-Eval 'window.scrollTo(0,0)' | Out-Null
        Wren-Ctl wait frames 3 | Out-Null
        $lx = [double](Wren-Eval 'var r=document.getElementById("lnk").getBoundingClientRect(); Math.round(r.left+r.width/2)')
        $ly = [double](Wren-Eval 'var r=document.getElementById("lnk").getBoundingClientRect(); Math.round(r.top+r.height/2)')
        $tabsBefore = TabCount
        Mouse 'mousePressed'  $lx $ly 'middle'
        Mouse 'mouseReleased' $lx $ly 'middle'
        Wren-Ctl wait frames 6 | Out-Null
        $tabsAfter = TabCount
        Check 'a middle click on a link opens a new tab' ($tabsAfter -gt $tabsBefore) "tabs $tabsBefore -> $tabsAfter at $lx,$ly"
    }
    finally {
        Stop-Wren
    }
}
finally {
    Stop-WrenTestServer $srv
}

if ($script:fail) { "`n$script:fail failed"; exit 1 }
"`nall autoscroll e2e checks passed"
exit 0
