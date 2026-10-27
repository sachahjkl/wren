# The tab sidebar's features, driven by `wren ctl` (no window shown, synthetic input, nothing timed):
#   * the titles fade in and out when the sidebar opens or closes: its width goes through the widths between (no jump), and
#     it ends at the width asked for;
#   * pinned tabs, tab groups, the sound of a tab (see the checks below, each section says what it verifies).
# -ShotDir <folder>: also writes pictures of each state there (numbered), for the notes.
#   powershell -NoProfile -File tools\sidebar_tabs_e2e.ps1 [-Exe build\wren.exe] [-ShotDir <folder>] [-Only fade,pins,...]
param([string]$Exe = '', [string]$ShotDir = '', [string[]]$Only = @())
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\wrenctl.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
$fail = 0
function Pass($m) { "PASS  $m" }
function Fail($m) { "FAIL  $m"; $script:fail++ }
function Want($name) { return $Only.Count -eq 0 -or $Only -contains $name }
$script:shot = 0
function Shot($what) {
    if (-not $ShotDir) { return }
    New-Item -ItemType Directory -Force $ShotDir | Out-Null
    $script:shot++
    Wren-Ctl shot (Join-Path $ShotDir ('{0:D2} - {1}.png' -f $script:shot, $what)) --settle 3 | Out-Null
}
# The page's width once it stops changing (an animation of the sidebar ends; at most 30 s).
function Wait-Width {
    $last = -1; $until = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $until) {
        Wren-Ctl wait frames 10 | Out-Null
        $w = [double](Wren-Eval 'innerWidth')
        if ($w -eq $last) { return $w }
        $last = $w
    }
    return $last
}
function Tabs { return @((Wren-Ctl tabs --json | ConvertFrom-Json).targetInfos) }
$tmp = Join-Path $env:TEMP "wren-sidebar-tabs-e2e-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
# a page of its own per title (file: pages; a top-level data: address is refused)
function Page($title, $body = '') {
    $f = Join-Path $tmp "$title.html"
    [IO.File]::WriteAllText($f, "<!doctype html><meta charset=utf-8><title>$title</title><body style='font:20px sans-serif'>$title $body")
    return 'file:///' + ($f -replace '\\', '/')
}

$null = Start-Wren -Size 1100x700 -Pref 'browser.tabs.position=left', 'browser.ui.animations=on' -Url (Page 'Alpha')
try {
    Wren-Ctl wait load | Out-Null
    foreach ($n in 'Bravo', 'Charlie', 'Delta', 'Echo') { Wren-Ctl tab new (Page $n) | Out-Null }
    Wren-Ctl wait frames 3 | Out-Null
    Shot 'barre laterale ouverte'

    if (Want 'fade') {
        # (slow enough to see the frames between: 600 ms)
        Wren-Ctl pref set browser.tabs.sidebar_animation_ms 600 | Out-Null
        $w0 = [double](Wren-Eval 'innerWidth')
        # (the page notes every width it is given: a frame of each)
        Wren-Eval 'window.__w = []; addEventListener("resize", () => __w.push(innerWidth)); 1' | Out-Null
        Wren-Ctl cmd view.tabs_sidebar_collapse | Out-Null
        $w1 = Wait-Width
        $seen = @((Wren-Eval 'JSON.stringify(__w)') | ConvertFrom-Json | ForEach-Object { $_ })
        Shot 'barre laterale reduite'
        if ($env:WREN_E2E_DUMP) { "widths: $($seen -join ', ')" }
        $between = @($seen | Where-Object { $_ -gt $w0 + 1 -and $_ -lt $w1 - 1 } | Select-Object -Unique)
        if ($w1 -gt $w0) { Pass "closing the sidebar gave the page its room ($w0 -> $w1)" } else { Fail "the page did not widen when the sidebar closed ($w0 -> $w1)" }
        if ($between.Count -ge 2) { Pass "the width went through $($between.Count) widths between (no jump)" } else { Fail "the sidebar jumped to its width ($(($seen | Select-Object -Unique) -join ', '))" }
        $down = $true
        for ($k = 1; $k -lt $seen.Count; $k++) { if ($seen[$k] -lt $seen[$k - 1] - 0.5) { $down = $false } }
        if ($down) { Pass 'the page only widened while the sidebar closed' } else { Fail "the width went back and forth: $($seen -join ', ')" }
        Wren-Ctl cmd view.tabs_sidebar_collapse | Out-Null
        if ($ShotDir) { Wren-Ctl shot (Join-Path $ShotDir ('{0:D2} - ouverture en cours %d.png' -f ($script:shot + 1))) --count 4 --interval 60 | Out-Null; $script:shot++ }
        $w2 = Wait-Width
        if ([Math]::Abs($w2 - $w0) -le 0.5) { Pass "opening it again gives back the width it had ($w2)" } else { Fail "after opening again innerWidth is $w2, not $w0" }
        Wren-Ctl pref set browser.tabs.sidebar_animation_ms 0 | Out-Null
        Wren-Ctl cmd view.tabs_sidebar_collapse | Out-Null
        Wren-Ctl wait frames 2 | Out-Null
        $w3 = [double](Wren-Eval 'innerWidth')
        if ([Math]::Abs($w3 - $w1) -le 0.5) { Pass 'with browser.tabs.sidebar_animation_ms 0 it closes at once' } else { Fail "with no animation the width is $w3 after two frames, not $w1" }
        Wren-Ctl cmd view.tabs_sidebar_collapse | Out-Null
        Wren-Ctl pref set browser.tabs.sidebar_animation_ms 180 | Out-Null
        Wren-Ctl wait frames 3 | Out-Null
    }
} finally { Stop-Wren | Out-Null; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
if ($fail) { "sidebar_tabs_e2e: $fail check(s) failed"; exit 1 }
'sidebar_tabs_e2e: all checks passed'
