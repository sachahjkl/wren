# A tab dragged from one window onto another's tabs, end to end with wren ctl (no window shown, no real mouse: the pointer is
# injected into the window the press began in, which keeps the drag as a captured mouse would). The window it is carried over
# shows where it would go (the insertion mark) exactly where the release puts it, among pinned tabs and groups: in a row of tabs,
# between two tabs of a group (it joins the group); in the sidebar's list, on the lower half of a group's header (the start of
# the group, in it). Each time: the mark's place and what it says (index, group), a capture of the window with the mark (-ShotDir),
# then the release and the tabs' order.
#   powershell -NoProfile -File tools\tab_drag_windows_e2e.ps1 [-Exe build\wren.exe] [-ShotDir <folder for the captures>]
param([string]$Exe = '', [string]$ShotDir = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
. "$PSScriptRoot\wrenctl.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
$fail = 0
function Check([bool]$ok, [string]$what, [string]$detail = '') { if ($ok) { "PASS  $what" } else { "FAIL  $what  $detail"; $script:fail++ } }
function Windows { $h = @{}; foreach ($x in @((Wren-Ctl windows --json | ConvertFrom-Json).windows)) { $h[[int]$x.windowId] = $x }; return $h }
function Targets { return (Wren-Ctl tabs --json | ConvertFrom-Json) }
function Tabs([int]$w) { return @((Targets).targetInfos | Where-Object { $_.windowId -eq $w }) }
function Tab($title) { return ((Targets).targetInfos | Where-Object { $_.title -eq $title } | Select-Object -First 1) }
function Order([int]$w) { return ((Tabs $w | ForEach-Object { $t = $_.title; if ($_.group) { $t = "$t{g}" }; if ($_.pinned) { "[$t]" } else { $t } }) -join ' ') }
function Shot([int]$id, [string]$name) { if ($ShotDir) { Wren-Ctl shot (Join-Path $ShotDir $name) --win-id $id --settle 2 | Out-Null } }
$tmp = Join-Path $env:TEMP "wren-tabdrag-e2e-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
function Page($title) {
    $f = Join-Path $tmp "$title.html"
    [IO.File]::WriteAllText($f, "<!doctype html><meta charset=utf-8><title>$title</title><body style='font:20px sans-serif'>$title")
    return 'file:///' + ($f -replace '\\', '/')
}
# A point of window `to` (its client pixels) in the client pixels of window `from` (where the drag's pointer is injected).
function Across($from, $to, [double]$x, [double]$y) { return '{0},{1}' -f [int]($to.clientLeft + $x - $from.clientLeft), [int]($to.clientTop + $y - $from.clientTop) }

$null = Start-Wren -Size 1100x600 -Url (Page 'Alpha')
try {
    Wren-Ctl wait load | Out-Null
    Wren-Ctl pref set browser.ui.animations off | Out-Null
    $a = @((Wren-Ctl windows --json | ConvertFrom-Json).windows)[0].windowId
    foreach ($n in 'Carried', 'Charlie') { Wren-Ctl tab new (Page $n) --wait load | Out-Null }
    # window B: a pinned tab, a group of two, a tab in none
    Wren-Ctl cmd window.new | Out-Null
    Wren-Ctl wait frames 4 | Out-Null
    $b = @((Windows).Keys | Where-Object { $_ -ne $a })[0]
    Wren-Ctl nav (Page 'Pin') --wait load --win-id $b | Out-Null
    foreach ($n in 'GroupOne', 'GroupTwo', 'Free') { Wren-Ctl tab new (Page $n) --wait load --win-id $b | Out-Null }
    Wren-Ctl tab activate (Tab 'Pin').targetId | Out-Null; Wren-Ctl cmd tab.pin --win-id $b | Out-Null
    Wren-Ctl tab activate (Tab 'GroupOne').targetId | Out-Null; Wren-Ctl cmd tab.group_new --win-id $b | Out-Null
    Wren-Ctl wait frames 4 --win-id $b | Out-Null
    # GroupTwo dragged onto GroupOne joins its group (the row's own reorder)
    $r1 = (Tab 'GroupOne').rect; $r2 = (Tab 'GroupTwo').rect
    Wren-Ctl drag ('{0},{1}' -f [int]($r2[0] + $r2[2] / 2), [int]($r2[1] + $r2[3] / 2)) ('{0},{1}' -f [int]($r1[0] + 4), [int]($r1[1] + $r1[3] / 2)) --steps 10 --window --win-id $b | Out-Null
    Wren-Ctl wait frames 4 --win-id $b | Out-Null
    $g = [int](Tab 'GroupOne').group
    Check ($g -ne 0 -and (Order $b) -eq '[Pin] GroupTwo{g} GroupOne{g} Free') 'window B: a pinned tab, a group of two, a tab in none' (Order $b)

    # 1. a row of tabs: Carried over the gap between the group's two tabs
    Wren-Ctl tab activate (Tab 'Alpha').targetId | Out-Null; Wren-Ctl wait frames 2 --win-id $a | Out-Null
    $w = Windows
    $rc = (Tab 'Carried').rect; $rg = (Tab 'GroupOne').rect
    $from = '{0},{1}' -f [int]($rc[0] + $rc[2] / 2), [int]($rc[1] + $rc[3] / 2)
    $away = '{0},{1}' -f [int]($rc[0] + $rc[2] / 2), [int]($rc[1] + 300)   # (far below the row: the tab leaves it)
    $over = Across $w[$a] $w[$b] ($rg[0] + 6) ($rg[1] + $rg[3] / 2)
    Wren-Ctl window --front --win-id $b | Out-Null   # (B above A where they overlap: the drop goes to the window on top)
    Wren-Ctl drag $from $away $over --steps 10 --window --hold --win-id $a | Out-Null
    Wren-Ctl wait frames 3 --win-id $b | Out-Null
    $w = Windows
    $d = $w[$b].drop
    Check ($null -ne $d -and $d.index -eq 2 -and $d.group -eq $g -and [math]::Abs($d.mark - $rg[0]) -le 1.5) 'over B''s row: the mark is between the group''s two tabs, and says it joins the group' ($d | ConvertTo-Json -Compress)
    Check ($w.Count -eq 3) 'the tab left its row for a window of its own, which follows the pointer' "$($w.Count) windows"
    Shot $b '07 - glisser rangee, repere entre deux onglets du groupe.png'
    Wren-Ctl drag $over $over --steps 1 --window --resume --win-id $a | Out-Null
    Wren-Ctl wait frames 4 --win-id $b | Out-Null
    Check ((Order $b) -eq '[Pin] GroupTwo{g} Carried{g} GroupOne{g} Free' -and [int](Tab 'Carried').group -eq $g) 'released there: it is where the mark was, in the group' (Order $b)
    Check ((Windows).Count -eq 2 -and $null -eq (Windows)[$b].drop) 'the carried window closed, the mark is gone'
    Shot $b '10 - rangee apres le depot.png'

    # 2. the sidebar's list: Charlie over the lower half of the group's header
    Wren-Ctl pref set browser.tabs.position left | Out-Null
    Wren-Ctl wait frames 4 --win-id $a | Out-Null
    Wren-Ctl wait frames 4 --win-id $b | Out-Null
    if ($env:WREN_E2E_DUMP) { Shot $b '11 - B en barre laterale avant le glisser.png'; Shot $a '12 - A en barre laterale avant le glisser.png' }
    $w = Windows
    $rc = (Tab 'Charlie').rect
    $hdr = @((Targets).tabGroups | Where-Object { $_.windowId -eq $b -and $_.id -eq $g })[0]
    $hr = $hdr.rect
    $from = '{0},{1}' -f [int]($rc[0] + $rc[2] / 2), [int]($rc[1] + $rc[3] / 2)
    $away = '{0},{1}' -f [int]($rc[0] + $rc[2] / 2 + 500), [int]($rc[1] + $rc[3] / 2)   # (far beside the sidebar: the tab leaves it)
    $over = Across $w[$a] $w[$b] ($hr[0] + $hr[2] / 2) ($hr[1] + $hr[3] * 0.75)
    Wren-Ctl window --front --win-id $b | Out-Null   # (B above A where they overlap: the drop goes to the window on top)
    Wren-Ctl drag $from $away $over --steps 10 --window --hold --win-id $a | Out-Null
    Wren-Ctl wait frames 3 --win-id $b | Out-Null
    $d = (Windows)[$b].drop
    Check ($null -ne $d -and $d.index -eq 1 -and $d.group -eq $g -and [math]::Abs($d.mark - ($hr[1] + $hr[3])) -le 1.5) 'over B''s list, on the lower half of the group''s header: the mark is under the header, the start of the group' "drop $($d | ConvertTo-Json -Compress), header $($hr -join ','), from $from away $away over $over, windows $((Windows).Count)"
    Shot $b '08 - glisser barre laterale, repere sous l''en-tete du groupe.png'
    Wren-Ctl drag $over $over --steps 1 --window --resume --win-id $a | Out-Null
    Wren-Ctl wait frames 4 --win-id $b | Out-Null
    Check ((Order $b) -eq '[Pin] Charlie{g} GroupTwo{g} Carried{g} GroupOne{g} Free') 'released there: the first tab of the group' (Order $b)
    $txt = Wren-Ctl eval 'document.title + "|" + document.body.textContent + "|" + innerWidth + "|" + scrollY + "|" + document.visibilityState' --win-id $b
    if ($env:WREN_E2E_DUMP) {
        "B after the drop: $txt"
        $s = Wren-Ctl stats --json --win-id $b | ConvertFrom-Json
        Wren-Ctl window --json --win-id $b
        Wren-Ctl window --json --win-id $a
        Wren-Ctl window --size 1000x600 --win-id $b | Out-Null; Wren-Ctl wait frames 4 --win-id $b | Out-Null
        Shot $b '13 - B apres redimension.png'
        Wren-Ctl tab activate (Tab 'Free').targetId | Out-Null; Wren-Ctl wait frames 4 --win-id $b | Out-Null
        Shot $b '14 - B autre onglet.png'
    }
    Check ($txt -match '^"?Charlie\|Charlie\|') 'the tab dropped is the current one of B, its page as it was' $txt
    Shot $b '09 - barre laterale apres le depot.png'

    $null = Wren-Ctl ping --timeout 10000
    $st = Wren-Ctl stats --json | ConvertFrom-Json
    Check ($global:WrenExit -eq 0 -and $st.frameGate.violations -eq 0) 'the process answers, no violation of the frame gate'
} finally {
    try { Stop-Wren } catch { }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { "tab_drag_windows_e2e: $fail check(s) failed"; exit 1 }
'tab_drag_windows_e2e: all checks passed'
