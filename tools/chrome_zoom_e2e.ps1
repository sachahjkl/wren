# End-to-end test of the zoom of the browser's own interface (chrome_zoom.odin), with no window shown: Ctrl+wheel over the chrome and
# Ctrl+Plus, Minus, 0 while it has the keyboard zoom it, and leave the page's scale and width alone; Ctrl+wheel over the page and the keys
# while the page has the keyboard zoom the page and leave the interface alone.
#   powershell -NoProfile -File tools\chrome_zoom_e2e.ps1 [-Exe build\wren.exe]
param([string]$Exe = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\test_env.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
. "$PSScriptRoot\wrenctl.ps1"

$SETTLE_TRIES = 50       # how many times a condition is looked at
$SETTLE_MS = 100         # between two looks

$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "PASS  $name" } else { "FAIL  $name  $detail"; $script:fail++ }
}
# The page's own measures: its scale, its width, and the height the chrome leaves it.
function Measures { $a = (Wren-Eval "devicePixelRatio + ' ' + innerWidth + ' ' + innerHeight") -split ' '; return @{ dpr = [double]$a[0]; w = [double]$a[1]; h = [double]$a[2] } }
function WaitFor([scriptblock]$cond) { for ($i = 0; $i -lt $SETTLE_TRIES; $i++) { if (& $cond) { return $true }; Start-Sleep -Milliseconds $SETTLE_MS }; return $false }
function Wheel([double]$x, [double]$y, [int]$dy, [int]$mods) {
    Wren-Ctl raw "{`"method`":`"Input.dispatchMouseEvent`",`"params`":{`"type`":`"mouseWheel`",`"x`":$x,`"y`":$y,`"deltaX`":0,`"deltaY`":$dy,`"modifiers`":$mods,`"space`":`"window`"}}" | Out-Null
}
$CTRL_MODIFIER = 2       # CDP's modifiers bit for Ctrl

$srv = Start-WrenTestServer
try {
    Start-Wren -Size 1000x600 | Out-Null
    Wren-Nav "$($srv.Origin)/" | Out-Null
    $m0 = Measures

    Wren-Ctl key Ctrl+L | Out-Null
    Wren-Ctl key Ctrl+Equal Ctrl+Equal Ctrl+Equal | Out-Null
    $ok = WaitFor { (Measures).h -lt $m0.h }
    $m1 = Measures
    Check 'the keys zoom the interface while it has the keyboard: the page gets less height' $ok "before $($m0.h), after $($m1.h)"
    Check 'the page keeps its scale and its width' ($m1.dpr -eq $m0.dpr -and $m1.w -eq $m0.w) "dpr $($m0.dpr) -> $($m1.dpr), width $($m0.w) -> $($m1.w)"
    Wren-Ctl key Ctrl+0 | Out-Null
    $ok = WaitFor { (Measures).h -eq $m0.h }
    Check 'Ctrl+0 brings the interface back' $ok "$((Measures).h) against $($m0.h)"

    # the pointer on the toolbar, near the top of the window
    Wheel 300 10 -100 $CTRL_MODIFIER
    $ok = WaitFor { (Measures).h -lt $m0.h }
    Check 'Ctrl+wheel over the interface zooms it' $ok "$((Measures).h) against $($m0.h)"
    $m2 = Measures
    Check 'and leaves the page''s scale alone' ($m2.dpr -eq $m0.dpr) "dpr $($m2.dpr)"
    Wheel 300 10 100 $CTRL_MODIFIER
    $ok = WaitFor { (Measures).h -eq $m0.h }
    Check 'the other way brings it back' $ok "$((Measures).h) against $($m0.h)"

    # the pointer on the page
    Wheel 500 400 -100 $CTRL_MODIFIER
    $ok = WaitFor { (Measures).dpr -gt $m0.dpr }
    $m3 = Measures
    Check 'Ctrl+wheel over the page zooms the page' $ok "dpr $($m3.dpr)"
    Stop-Wren | Out-Null
} finally {
    Stop-WrenTestServer $srv
}
if ($script:fail) { "$script:fail check(s) failed"; exit 1 }
'chrome_zoom_e2e: all checks passed'
