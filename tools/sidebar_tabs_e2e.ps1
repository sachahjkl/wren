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
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
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
function Targets { return (Wren-Ctl tabs --json | ConvertFrom-Json) }
function Tabs { return @((Targets).targetInfos) }
function Groups { return @((Targets).tabGroups) }
function Tab($title) { return (Tabs | Where-Object { $_.title -eq $title } | Select-Object -First 1) }
function Order { return ((Tabs | ForEach-Object { if ($_.pinned) { "[$($_.title)]" } else { $_.title } }) -join ' ') }
function Center($r) { return '{0},{1}' -f [int]($r[0] + $r[2] / 2), [int]($r[1] + $r[3] / 2) }
function Select-Tab($title) { Wren-Ctl tab activate (Tab $title).targetId | Out-Null; Wren-Ctl wait frames 2 | Out-Null }
function Drag($from, $to) { Wren-Ctl drag $from $to --steps 12 --window | Out-Null; Wren-Ctl wait frames 6 | Out-Null }
function Expect($what, $got, $want) { if ($got -eq $want) { Pass "$what ($got)" } else { Fail "$what`: '$got', not '$want'" } }
$tmp = Join-Path $env:TEMP "wren-sidebar-tabs-e2e-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
# a page of its own per title (file: pages; a top-level data: address is refused)
function Page($title, $body = '') {
    $f = Join-Path $tmp "$title.html"
    [IO.File]::WriteAllText($f, "<!doctype html><meta charset=utf-8><title>$title</title><body style='font:20px sans-serif'>$title $body")
    return 'file:///' + ($f -replace '\\', '/')
}

$null = Start-Wren -Size 1100x700 -Pref 'browser.ui.animations=on' -Url (Page 'Alpha')
try {
    Wren-Ctl wait load | Out-Null
    # (set as the user does: one given on the command line would stay above what the test sets later)
    Wren-Ctl pref set browser.tabs.position left | Out-Null
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

    if (Want 'pins') {
        Select-Tab 'Bravo'; Wren-Ctl cmd tab.pin | Out-Null
        Select-Tab 'Delta'; Wren-Ctl cmd tab.pin | Out-Null
        Wren-Ctl wait frames 3 | Out-Null
        Expect 'pinned tabs go first, in the order they were pinned' (Order) '[Bravo] [Delta] Alpha Charlie Echo'
        Shot 'onglets epingles'
        Drag (Center (Tab 'Delta').rect) (Center (Tab 'Bravo').rect)
        Expect 'a pinned tab dragged onto another takes its place' (Order) '[Delta] [Bravo] Alpha Charlie Echo'
        Drag (Center (Tab 'Echo').rect) (Center (Tab 'Bravo').rect)
        Expect 'a tab of the list dragged up to the pinned tabs is pinned' (Order) '[Delta] [Echo] [Bravo] Alpha Charlie'
        Drag (Center (Tab 'Echo').rect) (Center (Tab 'Charlie').rect)
        $o = Order
        if ($o -match '^\[Delta\] \[Bravo\]' -and $o -match ' Echo' -and $o -notmatch '\[Echo\]') { Pass "a pinned tab dragged down into the list is no longer pinned ($o)" } else { Fail "after dragging Echo down: $o" }
        Select-Tab 'Bravo'; Wren-Ctl cmd tab.pin | Out-Null; Wren-Ctl wait frames 2 | Out-Null
        $o = Order
        if ($o -match '^\[Delta\] Bravo ') { Pass "unpinned, it is the first of the others ($o)" } else { Fail "after unpinning Bravo: $o" }
        Wren-Ctl pref set browser.tabs.sidebar_collapsed true | Out-Null; Wren-Ctl wait frames 4 | Out-Null
        Shot 'epingles, barre reduite'
        Wren-Ctl pref set browser.tabs.sidebar_collapsed false | Out-Null; Wren-Ctl wait frames 4 | Out-Null
        Wren-Ctl pref set browser.tabs.position top | Out-Null; Wren-Ctl wait frames 4 | Out-Null
        Shot 'epingles, onglets en haut'
        Wren-Ctl pref set browser.tabs.position left | Out-Null; Wren-Ctl wait frames 4 | Out-Null
        # (back to no pinned tab for the next sections)
        foreach ($p in @(Tabs | Where-Object { $_.pinned })) { Wren-Ctl tab activate $p.targetId | Out-Null; Wren-Ctl cmd tab.pin | Out-Null }
        Wren-Ctl wait frames 2 | Out-Null
    }

    if (Want 'groups') {
        Select-Tab 'Alpha'; Wren-Ctl cmd tab.group_new | Out-Null; Wren-Ctl wait frames 3 | Out-Null
        $g = @(Groups)
        Expect 'a new group' $g.Count 1
        Expect 'the tab is in it' ((Tab 'Alpha').group) $g[0].id
        $before = Order
        Drag (Center (Tab 'Charlie').rect) (Center (Tab 'Alpha').rect)
        Expect 'a tab dragged onto a tab of the group joins it' ((Tab 'Charlie').group) $g[0].id
        Select-Tab 'Alpha'
        Wren-Ctl cmd tab.group_rename | Out-Null; Wren-Ctl wait frames 3 | Out-Null
        Wren-Ctl type 'Work' | Out-Null; Wren-Ctl key Enter | Out-Null; Wren-Ctl wait frames 3 | Out-Null
        Expect 'renamed in its header' (Groups)[0].name 'Work'
        Wren-Ctl cmd tab.group_color.green | Out-Null; Wren-Ctl wait frames 2 | Out-Null
        Expect 'its colour' (Groups)[0].color 'green'
        Shot 'groupe Work'
        $order = @(Tabs | ForEach-Object { $_.group })
        $runs = 0; $prev = -1; foreach ($x in $order) { if ($x -ne $prev -and $x -ne 0) { $runs++ }; $prev = $x }
        Expect 'the group''s tabs are next to each other' $runs 1
        Wren-Ctl click (Center (Groups)[0].rect) --window | Out-Null; Wren-Ctl wait frames 4 | Out-Null
        Expect 'a click on the header collapses the group' ((Groups)[0].collapsed) $true
        $cur = Tabs | Where-Object { $_.active }
        if ($cur.group -ne (Groups)[0].id) { Pass "the current tab left the collapsed group ($($cur.title))" } else { Fail 'the current tab is hidden in the collapsed group' }
        if (-not (Tab 'Alpha').rect) { Pass 'its tabs are not drawn' } else { Fail 'a tab of the collapsed group is still drawn' }
        Start-Sleep -Milliseconds 800   # (two clicks in the system's double-click time are a double click: the header's rename)
        Shot 'groupe Work replie'
        Wren-Ctl click (Center (Groups)[0].rect) --window | Out-Null; Wren-Ctl wait frames 4 | Out-Null
        Expect 'a second click expands it' ((Groups)[0].collapsed) $false
        $below = Tabs | Where-Object { $_.group -eq 0 -and -not $_.pinned } | Select-Object -Last 1
        Drag (Center (Tab 'Charlie').rect) (Center $below.rect)
        Expect 'dragged onto a tab outside the group, it leaves the group' ((Tab 'Charlie').group) 0
        Select-Tab 'Alpha'; Wren-Ctl cmd tab.group_leave | Out-Null; Wren-Ctl wait frames 2 | Out-Null
        Expect 'its last tab gone, the group goes' @(Groups).Count 0
    }

    if (Want 'sound') {
        # (a file: page reads only files under its own folder)
        Copy-Item (Join-Path $root 'examples\site\devtools\assets\tone_opus.webm') (Join-Path $tmp 'tone.webm')
        $tone = 'tone.webm'
        Wren-Ctl pref set media.autoplay.policy allow-all | Out-Null
        Wren-Ctl tab new (Page 'Sound' "<audio src='$tone' autoplay loop></audio>") | Out-Null
        $until = (Get-Date).AddSeconds(30); $s = $null
        while ((Get-Date) -lt $until) { $s = Tab 'Sound'; if ($s.audible) { break }; Wren-Ctl wait frames 5 | Out-Null }
        if ($s.audible -and $s.playing) { Pass 'a tab that plays sound shows its speaker (audible)' } else { Fail "the tab playing a tone is not audible: $($s | ConvertTo-Json -Compress)" }
        if (-not (Tab 'Alpha').audible) { Pass 'the others do not' } else { Fail 'a silent tab is audible' }
        Shot 'son, haut-parleur'
        Wren-Ctl cmd tab.mute | Out-Null; Wren-Ctl wait frames 3 | Out-Null
        $s = Tab 'Sound'
        if ($s.muted -and -not $s.audible -and $s.playing) { Pass 'muted: the speaker is crossed out, the page still plays' } else { Fail "after tab.mute: $($s | ConvertTo-Json -Compress)" }
        Expect 'the page is not told (its element is not muted)' (Wren-Eval 'String(document.querySelector("audio").muted)') 'false'
        Shot 'son, onglet muet'
        Wren-Ctl pref set browser.tabs.sidebar_collapsed true | Out-Null; Wren-Ctl wait frames 6 | Out-Null
        Shot 'son, barre reduite'
        Wren-Ctl pref set browser.tabs.sidebar_collapsed false | Out-Null; Wren-Ctl wait frames 6 | Out-Null
        Wren-Ctl cmd tab.mute | Out-Null; Wren-Ctl wait frames 3 | Out-Null
        Expect 'unmuted' (Tab 'Sound').muted $false
        Wren-Ctl pref set browser.tabs.audio_hold_ms 0 | Out-Null
        Wren-Eval 'document.querySelector("audio").pause(); 1' | Out-Null
        Wren-Ctl wait frames 5 | Out-Null
        $s = Tab 'Sound'
        if (-not $s.audible -and -not $s.playing) { Pass 'paused, the speaker goes' } else { Fail "after pause: $($s | ConvertTo-Json -Compress)" }
        Wren-Ctl cmd tab.close | Out-Null
    }
} finally { Stop-Wren | Out-Null; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

# Saved in the profile: the pinned tabs come back without the session, the groups with it.
if (Want 'persist') {
    $prof = Join-Path $env:TEMP "wren-sidebar-tabs-profile-$PID"
    New-Item -ItemType Directory -Force $prof | Out-Null
    $tmp2 = Join-Path $env:TEMP "wren-sidebar-tabs-e2e2-$PID"
    New-Item -ItemType Directory -Force $tmp2 | Out-Null
    $tmp = $tmp2
    try {
        $null = Start-Wren -Size 1100x700 -ProfileDir $prof -Pref 'browser.tabs.position=left' -Url (Page 'One')
        try {
            Wren-Ctl wait load | Out-Null
            Wren-Ctl tab new (Page 'Two') | Out-Null; Wren-Ctl wait frames 2 | Out-Null
            Select-Tab 'One'; Wren-Ctl cmd tab.pin | Out-Null; Wren-Ctl wait frames 2 | Out-Null
        } finally { Stop-Wren | Out-Null }
        $null = Start-Wren -Size 1100x700 -ProfileDir $prof -Pref 'browser.tabs.position=left' -Url (Page 'Three')
        try {
            Wren-Ctl wait load | Out-Null
            $o = Order
            if ($o -match '^\[(One|.*One\.html)\] ') { Pass "the pinned tab came back without the session ($o)" } else { Fail "after a restart the pinned tab is not there: $o" }
            Wren-Ctl pref set browser.session.restore true | Out-Null
            Select-Tab (Tabs | Where-Object { -not $_.pinned } | Select-Object -First 1).title
            Wren-Ctl cmd tab.group_new | Out-Null; Wren-Ctl wait frames 2 | Out-Null
            Wren-Ctl cmd tab.group_color.purple | Out-Null; Wren-Ctl wait frames 2 | Out-Null
        } finally { Stop-Wren | Out-Null }
        # (started by hand: `wren ctl start` gives an address, and a session is restored only when none is given)
        $name = "side-tabs-$PID"
        $proc = Start-Process -PassThru -FilePath $env:WREN_EXE -ArgumentList "--remote=$name", '--profile', "`"$prof`"", '--headless', '--no-single-instance', '--pref', 'browser.tabs.position=left', '--pref', 'browser.session.restore=true'
        $env:WREN_REMOTE = $name
        try {
            $until = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $until) { Wren-Ctl ping | Out-Null; if ($WrenExit -eq 0) { break }; Start-Sleep -Milliseconds 200 }
            Wren-Ctl wait frames 4 | Out-Null
            $g = @(Groups)
            if ($g.Count -eq 1 -and $g[0].color -eq 'purple' -and @(Tabs | Where-Object { $_.group -eq $g[0].id }).Count -eq 1) { Pass "the group came back with the session ($(Order))" } else { Fail "after a restart with the session: groups $($g | ConvertTo-Json -Compress), tabs $(Order)" }
            if ((Tabs)[0].pinned) { Pass 'and the pinned tab with it' } else { Fail "the pinned tab did not come back with the session: $(Order)" }
        } finally {
            Wren-Ctl quit | Out-Null
            if (-not $proc.WaitForExit(30000)) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            $env:WREN_REMOTE = ''
        }
    } finally {
        Remove-Item -Recurse -Force $prof -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $tmp2 -ErrorAction SilentlyContinue
    }
}
if ($fail) { "sidebar_tabs_e2e: $fail check(s) failed"; exit 1 }
'sidebar_tabs_e2e: all checks passed'
