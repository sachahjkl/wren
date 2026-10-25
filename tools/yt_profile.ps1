# Where a real YouTube page spends its time, per phase of use: a profiler build (build.bat profile -> build\wren_prof.exe) driven by
# `wren ctl` (no window shown, synthetic input), the network allowed. One process per scenario (the report is written when it closes):
#   home     the home page (a profile that is not signed in gets an empty feed), settle, then -Window s still
#   grid     a channel's video grid (-Channel), as a feed stands in for the home page: settle, then -Window s still
#   scroll   the channel grid, settle, then 40 wheel notches over -Window s
#   results  a search results page, settle, then -Window s still, then -Window s of scrolling
#   watch    a watch page played at the best quality the player gives, 30 s of playback
#   full     the same, in full screen (the browser's own command) for 20 s
#   spa      the home page, then a click on the first thumbnail (the page changes without a navigation)
#   hover    the home page, then the pointer over six thumbnails in turn (inline previews)
# -Pref a=b,c=d sets preferences (browser.frame.target_hz=180 paces the frame loop at 180 Hz on any display).
# For each: <out>\<scenario>.txt (the profiler's report; add -Sample for the sampling profiler), .csv (every frame), .jsprof.*.js.txt
# (the page's own functions: WREN_JS_PROFILE), .host.txt (host calls: WREN_HOST_PROFILE), and one summary line per window: frames drawn,
# CPU / GPU per frame p50 / p95 / max, the phases in ms per second, the process's CPU and memory. Measurements, not tests: nothing asserts.
#   powershell -NoProfile -File tools\yt_profile.ps1 [-Scenario home,scroll,...] [-Out build\yt] [-Sample] [-Video id] [-Query text]
param([string[]]$Scenario = @('home', 'scroll', 'results', 'watch'), [string]$Out = 'build\yt', [switch]$Sample, [string]$Video = 'aqz-KE-bpKQ', [string]$Query = 'big buck bunny', [string]$Channel = 'https://www.youtube.com/@MrBeast/videos', [string]$Size = '1920x1080', [string]$Exe = 'build\wren_prof.exe', [int]$Settle = 15, [int]$Window = 15, [string[]]$Pref = @())
$ErrorActionPreference = 'Stop'
$Scenario = @($Scenario | ForEach-Object { $_ -split ',' })   # (-File passes "a,b" as one string)
$Pref = @($Pref | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
[Environment]::CurrentDirectory = $root
$env:WREN_EXE = (Resolve-Path $Exe).Path
. "$PSScriptRoot\wrenctl.ps1"
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$prof = Join-Path $Out 'profile'
$reject = '(()=>{ const b=[...document.querySelectorAll("button")].find(x=>/reject all/i.test(x.textContent)); if(b){ b.click(); return "rejected" } return "none" })()'

function Stat($v) {
    $s = @($v | Sort-Object)
    if ($s.Count -eq 0) { return [pscustomobject]@{ n = 0; p50 = 0; p95 = 0; max = 0 } }
    [pscustomobject]@{ n = $s.Count; p50 = $s[[int][Math]::Floor(($s.Count - 1) * 0.5)]; p95 = $s[[int][Math]::Floor(($s.Count - 1) * 0.95)]; max = $s[-1] }
}
function Stats-Json { (Wren-Ctl stats --json) | ConvertFrom-Json }

# The frames of the profiler's csv between two times (ms since the profiler started). CPU = frame - wait - present.
function Window-Summary([string]$csv, [double]$from, [double]$to, [string]$label) {
    $rows = @(Import-Csv $csv | Where-Object { [double]$_.t_ms -ge $from -and [double]$_.t_ms -lt $to })
    if ($rows.Count -eq 0) { "{0,-26} no frame" -f $label; return }
    $cpu = $rows | ForEach-Object { [double]$_.Frame - [double]$_.Wait - [double]$_.Present }
    $gpu = $rows | Where-Object { [double]$_.gpu_ms -gt 0 } | ForEach-Object { [double]$_.gpu_ms }
    $c = Stat $cpu; $g = Stat $gpu
    $secs = ($to - $from) / 1000
    $ph = foreach ($p in 'Events', 'Animation', 'Build_UI', 'Styles', 'Layout', 'Paint_Items', 'Submit', 'Present', 'Tex_Create', 'Tex_Upload') {
        $sum = ($rows | ForEach-Object { [double]$_.$p } | Measure-Object -Sum).Sum
        "{0} {1:N0}" -f $p, ($sum / $secs)
    }
    # the stalls: frames whose CPU work took more than two refreshes, and which phase they spent it in
    $slow = @($rows | Where-Object { ([double]$_.Frame - [double]$_.Wait - [double]$_.Present) -gt 33 })
    $slowTxt = ''
    if ($slow.Count -gt 0) {
        $lost = ($slow | ForEach-Object { [double]$_.Frame - [double]$_.Wait - [double]$_.Present } | Measure-Object -Sum).Sum
        $by = foreach ($p in 'Loop', 'Animation', 'Events', 'Styles', 'Layout', 'Paint_Items', 'Submit') { "{0} {1:N0}" -f $p, ($slow | ForEach-Object { [double]$_.$p } | Measure-Object -Sum).Sum }
        $slowTxt = "`n{0,-26} stalls > 33 ms: {1} frames, {2:N0} ms in all; where (ms): {3}" -f '', $slow.Count, $lost, ($by -join ', ')
    }
    "{0,-26} frames {1,5} ({2,5:N1}/s) | CPU p50 {3,6:N2} p95 {4,6:N2} max {5,7:N2} | GPU p50 {6,5:N2} p95 {7,5:N2} max {8,5:N2} | ms/s: {9}{10}" -f $label, $rows.Count, ($rows.Count / $secs), $c.p50, $c.p95, $c.max, $g.p50, $g.p95, $g.max, ($ph -join ', '), $slowTxt
}

function Scroll-Burst {
    for ($i = 0; $i -lt 40; $i++) { $null = Wren-Ctl scroll 3 960,600; Start-Sleep -Milliseconds ([int](1000 * $Window / 40 - 100)) }
}

function Run-Scenario([string]$name) {
    $pre = Join-Path $Out $name
    Remove-Item "$pre.*" -ErrorAction SilentlyContinue
    $env:WREN_PROF = $pre
    $env:WREN_SAMPLE = if ($Sample) { '1' } else { '0' }
    $env:WREN_JS_PROFILE = "$pre.jsprof"
    $env:WREN_HOST_PROFILE = "$pre.host.txt"
    $null = Start-Wren -Dpi 96 -Size $Size -ProfileDir $prof -Pref $Pref
    $wrenPid = [int]((Wren-Ctl ping --json) | ConvertFrom-Json).pid
    $proc = Get-Process -Id $wrenPid
    $t0 = $proc.StartTime
    $now = { ((Get-Date) - $t0).TotalMilliseconds }
    $wins = @()
    try {
        $url = switch ($name) {
            'home' { 'https://www.youtube.com/' }
            'grid' { $Channel } 'scroll' { $Channel }
            { $_ -in 'results', 'spa', 'hover' } { 'https://www.youtube.com/results?search_query=' + [uri]::EscapeDataString($Query) }
            default { "https://www.youtube.com/watch?v=$Video" }
        }
        Wren-Nav $url -Wait load | Out-Null
        Start-Sleep 3
        $null = Wren-Eval $reject
        Start-Sleep ($Settle - 3)
        if ($name -in 'watch', 'full') {
            $null = Wren-Eval '(()=>{ const p=document.getElementById("movie_player"); const v=document.querySelector("video"); try { p.setPlaybackQualityRange("hd1080","hd1080") } catch(e){}; v.muted=true; v.play(); return 1 })()'
            Start-Sleep 12
        }
        $s0 = Stats-Json
        $a = & $now
        switch ($name) {
            { $_ -in 'home', 'grid' } { Start-Sleep $Window; $wins += , @('still', $a, (& $now)) }
            'scroll' { Scroll-Burst; $wins += , @('scroll', $a, (& $now)) }
            'results' {
                Start-Sleep $Window; $b = & $now; $wins += , @('still', $a, $b)
                Scroll-Burst; $wins += , @('scroll', $b, (& $now))
            }
            'spa' {   # the click on a thumbnail: the page changes without a navigation (YouTube is a single page app)
                $null = Wren-Ctl click --selector "ytd-video-renderer a#thumbnail"; Start-Sleep $Window
                $wins += , @('click -> watch page', $a, (& $now))
            }
            'hover' {   # the pointer over six thumbnails in turn: YouTube starts an inline preview after a moment
                $pts = (Wren-Eval '[...document.querySelectorAll("ytd-video-renderer a#thumbnail")].slice(0,5).map(a=>{const r=a.getBoundingClientRect();return Math.round(r.x+r.width/2)+","+Math.round(r.y+r.height/2)}).join(" ")') -split ' '
                foreach ($pt in $pts) { $r = Wren-Ctl hover $pt; Start-Sleep 3 }
                "[hover] points: $($pts -join ' ')"
                $wins += , @('hover previews', $a, (& $now))
            }
            'watch' { Start-Sleep 30; $wins += , @('playback 1080p', $a, (& $now)) }
            'full' {
                $null = Wren-Ctl cmd view.full_screen; Start-Sleep 4
                $a = & $now; Start-Sleep 20
                $wins += , @('fullscreen playback', $a, (& $now))
            }
        }
        $s1 = Stats-Json
        $q = Wren-Eval '(()=>{ const v=document.querySelector("video"); if(!v) return JSON.stringify({nodes:document.getElementsByTagName("*").length}); const q=v.getVideoPlaybackQuality?v.getVideoPlaybackQuality():null; let n=""; try { const s=document.getElementById("movie_player").getStatsForNerds(); n=s.codecs+" "+s.resolution } catch(e){}; return JSON.stringify({w:v.videoWidth,h:v.videoHeight,t:v.currentTime,paused:v.paused,q:q&&{total:q.totalVideoFrames,dropped:q.droppedVideoFrames},codecs:n,nodes:document.getElementsByTagName("*").length}) })()'
        "[{5}] page: {6} | process CPU in the windows {0:N1} s over {1:N0} s | memory {2:N0} MB private, {3:N0} MB working set | threads {4}" -f (($s1.cpuTimeMs - $s0.cpuTimeMs) / 1000), (($wins[-1][2] - $wins[0][1]) / 1000), ($s1.privateBytes / 1MB), ($s1.workingSetBytes / 1MB), $s1.threads, $name, $q
    } finally { try { Stop-Wren } catch {} }
    Start-Sleep 3
    if (Test-Path "$pre.csv") { foreach ($w in $wins) { Window-Summary "$pre.csv" $w[1] $w[2] "[$name] $($w[0])" } }
    else { "[$name] no profiler csv (is $Exe a profile build?)" }
}

# the consent dialog, answered once for the profile
$env:WREN_PROF = ''
$null = Start-Wren -Dpi 96 -Size $Size -ProfileDir $prof
try { Wren-Nav 'https://www.youtube.com/' -Wait idle | Out-Null; Start-Sleep 3; $null = Wren-Eval $reject; Start-Sleep 3 } finally { Stop-Wren }
foreach ($s in $Scenario) { try { Run-Scenario $s } catch { "[$s] failed: $_" } }
