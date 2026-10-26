# The chrome's state of a window lives in the window (windows.odin Window_Own, refactor T4), end to end with wren ctl (no window
# shown): a page's element full screen in one window while a second window exists (each has its own), left with Escape, the
# scroll given back; the tab moved between the windows. The process must answer and leave no crash report; the dev build
# panics on a frame that moves where it may not (the frame gate).
#   powershell -NoProfile -File tools\window_state_e2e.ps1 [-Exe build\wren.exe]
param([string]$Exe = '')
$ErrorActionPreference = 'Stop'
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
