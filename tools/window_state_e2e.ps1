# The chrome's state of a window lives in the window (windows.odin Window_Own, refactor T4), end to end with wren ctl (no window
# shown): a page's element full screen in one window while a second window exists (each has its own), left with Escape, the
# scroll given back; the tab moved between the windows. The process must answer and leave no crash report; the dev build
# panics on a frame that moves where it may not (the frame gate).
# Then the developer tools of each window (devtools.odin: Window_Own.devtools): opened in one window only, one docked and one in a
# window of its own, going with the tab they show to a new window, closed with their window.
#   powershell -NoProfile -File tools\window_state_e2e.ps1 [-Exe build\wren.exe] [-ShotDir <folder for the captures>]
param([string]$Exe = '', [string]$ShotDir = '')
$ErrorActionPreference = 'Stop'
Add-Type -Namespace WrenE2E -Name WinState -MemberDefinition '[DllImport("user32.dll")] public static extern bool IsWindow(System.IntPtr h);'
# the windows by id (wren ctl windows --json)
function Get-WindowsById { $h = @{}; foreach ($x in @((Wren-Ctl windows --json | ConvertFrom-Json).windows)) { $h[[int]$x.windowId] = $x }; return $h }
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
. "$PSScriptRoot\wrenctl.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
$fail = 0
function Check([bool]$ok, [string]$what, [string]$detail = '') { if ($ok) { "PASS  $what" } else { "FAIL  $what  $detail"; $script:fail++ } }
$prof = Join-Path $env:TEMP ('wren-winstate-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$html = '<!doctype html><body style="margin:0"><div style="height:3000px"><button id=b style="position:fixed;left:20px;top:20px;width:120px;height:40px">full</button><div id=v style="position:absolute;left:0;top:200px;width:300px;height:150px;background:#08f"></div></div><script>b.onclick=()=>v.requestFullscreen().then(()=>document.title="fs on",()=>document.title="fs refused");document.onfullscreenchange=()=>{if(!document.fullscreenElement)document.title="fs off"}</script>'
$file = Join-Path $env:TEMP ('wren-winstate-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.html')   # (a page of a file: a typed data: address is not a document that may ask for full screen here)
[IO.File]::WriteAllText($file, $html)
$page = 'file:///' + ($file -replace '\\', '/')
$null = Start-Wren -Size 1000x700 -Dpi 96 -ProfileDir $prof -Pref 'blocker.update.enabled=false' -Url 'about:blank'
try {
    Wren-Ctl nav $page --wait load | Out-Null
    Wren-Ctl eval "scrollTo(0, 120); 'ok'" | Out-Null
    Wren-Ctl click --selector '#b' | Out-Null
    Wren-Ctl wait frames 70 | Out-Null   # (the change's events wait for the page laid out at the new size, a second at most)
    $t = Wren-Ctl eval 'document.title + "|" + (document.fullscreenElement ? document.fullscreenElement.id : "none")'
    Check ($t -eq 'fs on|v') 'a click asks the element''s full screen: granted' $t

    # a second window, then back: the first window's full screen is still its own
    $wins = Wren-Ctl windows --json | ConvertFrom-Json
    $first = @($wins.windows)[0].windowId
    Wren-Ctl cmd window.new | Out-Null
    Wren-Ctl wait frames 4 | Out-Null
    $wins = @((Wren-Ctl windows --json | ConvertFrom-Json).windows)
    Check ($wins.Count -eq 2) 'a second window opens (window.new)' ($wins | ConvertTo-Json -Compress -Depth 3)
    $t = Wren-Ctl eval 'document.title + "|" + (document.fullscreenElement ? document.fullscreenElement.id : "none")' --win-id $first
    Check ($t -eq 'fs on|v') 'the first window''s page is still in full screen' $t

    Wren-Ctl key Escape --win-id $first | Out-Null
    Wren-Ctl wait frames 70 --win-id $first | Out-Null
    $t = Wren-Ctl eval 'document.title + "|" + (document.fullscreenElement ? "still" : "none") + "|" + Math.round(scrollY)' --win-id $first
    Check ($t -match '^fs off\|none\|120$') 'Escape in that window leaves it, and the scroll comes back' $t

    # the developer tools: each window has its own, docked or in a window of their own; they go with the tab they show to another
    # window, and close with their window
    $second = @($wins | Where-Object { $_.windowId -ne $first })[0].windowId
    Wren-Ctl nav $page --wait load --win-id $second | Out-Null
    Wren-Ctl devtools console --win-id $first | Out-Null
    $w = Get-WindowsById
    Check ($w[$first].devtools.visible -and -not $w[$second].devtools.visible) 'the developer tools open in the window that asked for them, not in the other' ($w.Values | ConvertTo-Json -Compress -Depth 4)
    Wren-Ctl devtools network --dock window --win-id $second | Out-Null
    Wren-Ctl wait frames 6 --win-id $second | Out-Null
    $w = Get-WindowsById
    $dt2 = $w[$second].devtools
    Check ($dt2.visible -and $dt2.detached -and [int64]$dt2.hwnd -ne 0 -and $dt2.panel -eq 'network' -and $w[$first].devtools.visible -and -not $w[$first].devtools.detached -and $w[$first].devtools.panel -eq 'console') 'the second window''s developer tools go to a window of their own on Network; the first window''s stay docked on Console' ($w.Values | ForEach-Object { $_.devtools } | ConvertTo-Json -Compress)
    Check ([WrenE2E.WinState]::IsWindow([IntPtr][int64]$dt2.hwnd)) 'their window exists'
    if ($ShotDir) { Wren-Ctl shot (Join-Path $ShotDir '01 - fenetre 1 outils ancres avant deplacement.png') --win-id $first | Out-Null }

    # a tab of the first window with its developer tools on it goes to a window of its own: they go with it
    $tid = Wren-Ctl tab new $page --wait load --win-id $first
    Wren-Ctl wait frames 3 --win-id $first | Out-Null
    $third = [int](Wren-Ctl tab move $tid --to new)
    Wren-Ctl wait frames 6 --win-id $third | Out-Null
    $w = Get-WindowsById
    Check ($w.ContainsKey($third) -and $w[$third].devtools.visible -and $w[$third].devtools.panel -eq 'console' -and -not $w[$first].devtools.visible) 'the developer tools go with the tab they showed to its new window; the window it left has none open' ($w.Values | ForEach-Object { "$($_.windowId):$($_.devtools.visible)/$($_.devtools.panel)" } | Out-String)
    if ($ShotDir) { Wren-Ctl shot (Join-Path $ShotDir '02 - fenetre 3 outils venus avec l''onglet.png') --win-id $third | Out-Null; Wren-Ctl shot (Join-Path $ShotDir '03 - fenetre 1 apres le depart de l''onglet.png') --win-id $first | Out-Null }

    # the second window closes (its last tab): its developer tools' window closes with it
    $tab2 = $w[$second].currentTabId
    Wren-Ctl tab close $tab2 | Out-Null
    Wren-Ctl wait frames 4 --win-id $first | Out-Null
    $w = Get-WindowsById
    Check (-not $w.ContainsKey($second) -and -not [WrenE2E.WinState]::IsWindow([IntPtr][int64]$dt2.hwnd)) 'closing a window closes its developer tools'' window' ($w.Keys -join ',')
    $st = Wren-Ctl stats --json --win-id $third | ConvertFrom-Json
    Check ($st.devtools -eq $true) 'the stats of a window name its own developer tools' "$($st.devtools)"

    $null = Wren-Ctl ping --timeout 10000
    $crashes = @(Get-ChildItem (Join-Path $prof 'crashes') -Filter 'crash *.txt' -ErrorAction SilentlyContinue)
    $st = Wren-Ctl stats --json | ConvertFrom-Json
    Check ($global:WrenExit -eq 0 -and $crashes.Count -eq 0 -and $st.frameGate.violations -eq 0) 'the process answers, no crash report, no violation of the frame gate'
} finally {
    try { Stop-Wren } catch { }
    Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $file -ErrorAction SilentlyContinue
}
if ($fail) { "window_state_e2e: $fail check(s) failed"; exit 1 }
'window_state_e2e: all checks passed'
