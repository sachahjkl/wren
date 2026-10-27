# Two windows on monitors of different scales, end to end with wren ctl (no window shown): a window that "moves" to a monitor of
# another DPI (wren ctl window --dpi: the system's WM_DPICHANGED through the window procedure, with the rectangle the system
# suggests) changes its scale at once and alone: its chrome, its page (devicePixelRatio, resolution media queries, the layout),
# its size in proportion; the document stays where it was scrolled to (no jump); the other window keeps its own scale; a tab moved
# between the two takes the scale of the window it goes to, at the same place of its document. A machine with one monitor checks
# the path the system takes; what the screen shows when a window straddles two monitors is not checked here.
#   powershell -NoProfile -File tools\window_dpi_e2e.ps1 [-Exe build\wren.exe] [-ShotDir <folder for the captures>]
param([string]$Exe = '', [string]$ShotDir = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
. "$PSScriptRoot\wrenctl.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
$fail = 0
function Check([bool]$ok, [string]$what, [string]$detail = '') { if ($ok) { "PASS  $what" } else { "FAIL  $what  $detail"; $script:fail++ } }
function Get-WindowsById { $h = @{}; foreach ($x in @((Wren-Ctl windows --json | ConvertFrom-Json).windows)) { $h[[int]$x.windowId] = $x }; return $h }
function Stats([int]$id) { return Wren-Ctl window --json --win-id $id | ConvertFrom-Json }
function Shot([int]$id, [string]$name) { if ($ShotDir) { Wren-Ctl shot (Join-Path $ShotDir $name) --win-id $id | Out-Null } }
$prof = Join-Path $env:TEMP ('wren-dpi-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
# a tall page whose paragraphs say where they are, a media query on the resolution, an image of 2 device pixels per CSS pixel
$rows = (1..120 | ForEach-Object { "<p id=p$_ style='margin:0;height:40px;font:16px sans-serif'>paragraph $_</p>" }) -join ''
$html = "<!doctype html><title>dpi</title><style>body{margin:0} #m{position:fixed;right:10px;top:10px;width:60px;height:30px;background:red} @media (min-resolution: 1.4dppx){#m{background:green}}</style><div id=m></div>$rows<script>window.changes=0;window.mq=matchMedia('(min-resolution: 1.4dppx)');mq.addEventListener('change',()=>window.changes++)</script>"
$file = Join-Path $env:TEMP ('wren-dpi-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.html')
[IO.File]::WriteAllText($file, $html)
$page = 'file:///' + ($file -replace '\\', '/')
$null = Start-Wren -Size 1000x700 -ProfileDir $prof -Url 'about:blank'
try {
    Wren-Ctl nav $page --wait load | Out-Null
    $first = @((Wren-Ctl windows --json | ConvertFrom-Json).windows)[0].windowId
    $st = Stats $first
    $base = [double]$st.dpiScale
    Check ($base -gt 0) "the first window has the monitor's scale ($base)"
    Wren-Ctl cmd window.new | Out-Null
    Wren-Ctl wait frames 4 | Out-Null
    $w = Get-WindowsById
    $second = @($w.Keys | Where-Object { $_ -ne $first })[0]
    Wren-Ctl nav $page --wait load --win-id $second | Out-Null
    foreach ($id in $first, $second) { Wren-Ctl eval "scrollTo(0, 1600); 'ok'" --win-id $id | Out-Null; Wren-Ctl wait frames 3 --win-id $id | Out-Null }
    $before = Wren-Ctl eval 'Math.round(scrollY) + "|" + devicePixelRatio + "|" + innerWidth' --win-id $first
    $size0 = (Get-WindowsById)[$first]
    Shot $first '04 - dpi fenetre 1 avant (100 %).png'

    # window 1 goes to a monitor of 150 % (relative to where it is)
    $dpi = [int][math]::Round(96 * $base * 1.5)
    Wren-Ctl window --dpi $dpi --win-id $first | Out-Null
    Wren-Ctl wait frames 6 --win-id $first | Out-Null
    $st1 = Stats $first; $st2 = Stats $second
    $k = [double]$st1.dpiScale / $base
    Check ([math]::Abs($k - 1.5) -lt 0.02 -and [math]::Abs([double]$st1.uiScale - [double]$st1.dpiScale) -lt 0.01 -and [math]::Abs([double]$st1.pageScale - [double]$st1.dpiScale) -lt 0.01) 'the window that changed monitor has the new scale: its chrome and its page' "dpi $($st1.dpiScale) ui $($st1.uiScale) page $($st1.pageScale)"
    Check ([math]::Abs([double]$st2.dpiScale - $base) -lt 0.01 -and [math]::Abs([double]$st2.uiScale - $base) -lt 0.01 -and [math]::Abs([double]$st2.pageScale - $base) -lt 0.01) 'the other window keeps its own' "dpi $($st2.dpiScale) ui $($st2.uiScale) page $($st2.pageScale)"
    $size1 = (Get-WindowsById)[$first]
    Check ([math]::Abs($size1.width / $size0.width - 1.5) -lt 0.03 -and [math]::Abs($size1.height / $size0.height - 1.5) -lt 0.03) 'its size follows in proportion (the rectangle the system suggests)' "$($size0.width)x$($size0.height) -> $($size1.width)x$($size1.height)"
    $after = Wren-Ctl eval 'Math.round(scrollY) + "|" + devicePixelRatio + "|" + innerWidth + "|" + changes + "|" + getComputedStyle(m).backgroundColor' --win-id $first
    $a = $after.Trim('"').Split('|'); $b = $before.Trim('"').Split('|')
    Check ($a[0] -eq $b[0]) 'the document stays where it was scrolled to (no jump)' "before $before, after $after"
    Check ([math]::Abs([double]$a[1] - [double]$b[1] * 1.5) -lt 0.02) 'devicePixelRatio follows' "$($b[1]) -> $($a[1])"
    Check ([math]::Abs([double]$a[2] - [double]$b[2]) -le [double]$b[2] * 0.01) 'the viewport keeps its CSS width (the window grew with the scale)' "$($b[2]) -> $($a[2])"
    Check ($a[3] -eq '1' -and $a[4] -match '0, 128, 0') 'the resolution media query matches and its change event came once' "changes $($a[3]), color $($a[4])"
    $o = Wren-Ctl eval 'Math.round(scrollY) + "|" + devicePixelRatio' --win-id $second
    Check ($o.Trim('"') -eq "1600|$base" -or $o.Trim('"') -eq "1600|$([int]$base)") 'the other window''s page is as it was' $o
    Shot $first '05 - dpi fenetre 1 apres (150 %).png'
    Shot $second '06 - dpi fenetre 2 restee a 100 %.png'

    # a tab goes from the window at 150 % to the one at 100 %: it takes that window's scale, at the same place of its document
    $tid = Wren-Ctl tab new $page --wait load --win-id $first
    Wren-Ctl eval "scrollTo(0, 2000); 'ok'" --tab-id $tid | Out-Null
    Wren-Ctl wait frames 3 --win-id $first | Out-Null
    Wren-Ctl tab move $tid --to $second | Out-Null
    Wren-Ctl wait frames 6 --win-id $second | Out-Null
    $m = Wren-Ctl eval 'Math.round(scrollY) + "|" + devicePixelRatio' --tab-id $tid
    Check ($m.Trim('"') -eq "2000|$base" -or $m.Trim('"') -eq "2000|$([int]$base)") 'a tab moved to the window at the other scale takes its scale, at the same place' $m

    # back to where it was
    Wren-Ctl window --dpi ([int][math]::Round(96 * $base)) --win-id $first | Out-Null
    Wren-Ctl wait frames 6 --win-id $first | Out-Null
    $back = Wren-Ctl eval 'Math.round(scrollY) + "|" + devicePixelRatio + "|" + changes' --win-id $first
    $st1 = Stats $first
    Check ([math]::Abs([double]$st1.dpiScale - $base) -lt 0.01 -and $back.Trim('"').Split('|')[0] -eq $b[0] -and $back.Trim('"').Split('|')[2] -eq '2') 'back on the first monitor: its scale, the same place, the media query''s change event again' "$back dpi $($st1.dpiScale)"

    $null = Wren-Ctl ping --timeout 10000
    $crashes = @(Get-ChildItem (Join-Path $prof 'crashes') -Filter 'crash *.txt' -ErrorAction SilentlyContinue)
    $st = Wren-Ctl stats --json | ConvertFrom-Json
    Check ($global:WrenExit -eq 0 -and $crashes.Count -eq 0 -and $st.frameGate.violations -eq 0) 'the process answers, no crash report, no violation of the frame gate'
} finally {
    try { Stop-Wren } catch { }
    Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $file -ErrorAction SilentlyContinue
}
if ($fail) { "window_dpi_e2e: $fail check(s) failed"; exit 1 }
'window_dpi_e2e: all checks passed'
