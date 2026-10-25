# What a page does when nothing moves on screen: a profiler build (build.bat profile) driven by `wren ctl`, headless, one process per page.
# After the page has settled it counts, over -Window seconds with nothing touched:
#   * the frames drawn and the process's CPU (`wren ctl stats`: framesDrawn, cpuTimeMs, at two moments), and per frame the CPU p50 / p95 / max;
#   * the CPU of each thread (tools\thread_cpu.ps1);
#   * what the page runs: timers, animation frames, observers' callbacks, fetch / XHR / beacons, postMessage and the reads that force a layout, by call
#     site, with how often and how long (tools\js_prelude\census.js, WREN_JS_PRELUDE);
#   * which of the page's own functions the interpreter was in (WREN_JS_PROFILE from the start of the window: WREN_JS_PROFILE_FROM; a count of the
#     interpreter's interrupt checks, not milliseconds);
#   * the requests made meanwhile (`wren ctl network`).
# Pages: blank (about:home), static (https://example.com/), results (a YouTube search), grid (a channel's videos), home (YouTube's home page: empty
# without an account), watch (a video, paused as soon as it plays), watchplay (the same, playing: for comparison).
#   powershell -NoProfile -File tools\yt_idle.ps1 [-Page blank,static,results,watch,...] [-Out build\yt\idle] [-Window 20] [-Settle 30]
# It measures, it asserts nothing: not a CI step.
param([string[]]$Page = @('blank', 'static', 'results', 'watch'), [string]$Out = 'build\yt\idle', [int]$Window = 20, [int]$Settle = 30, [string]$Exe = 'build\wren_prof.exe',
      [string]$Video = 'aqz-KE-bpKQ', [string]$Query = 'big buck bunny', [string]$Channel = 'https://www.youtube.com/@MrBeast/videos', [int]$Top = 8, [string[]]$Pref = @())
$ErrorActionPreference = 'Stop'
$Page = @($Page | ForEach-Object { $_ -split ',' })
$Pref = @($Pref | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
[Environment]::CurrentDirectory = $root
$env:WREN_EXE = (Resolve-Path $Exe).Path
. "$PSScriptRoot\wrenctl.ps1"
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$prof = Join-Path (Split-Path $Out -Parent) 'profile'
$reject = '(()=>{ const b=[...document.querySelectorAll("button")].find(x=>/reject all/i.test(x.textContent)); if(b){ b.click(); return "rejected" } return "none" })()'
function Stat($v) {
    $s = @($v | Sort-Object)
    if ($s.Count -eq 0) { return [pscustomobject]@{ n = 0; p50 = 0; p95 = 0; max = 0 } }
    [pscustomobject]@{ n = $s.Count; p50 = $s[[int][Math]::Floor(($s.Count - 1) * 0.5)]; p95 = $s[[int][Math]::Floor(($s.Count - 1) * 0.95)]; max = $s[-1] }
}
function Stats-Json { (Wren-Ctl stats --json) | ConvertFrom-Json }

function Run-Page([string]$name) {
    $pre = Join-Path $Out $name
    Remove-Item "$pre.*" -ErrorAction SilentlyContinue
    $env:WREN_PROF = $pre
    $env:WREN_SAMPLE = '0'
    $env:WREN_JS_PRELUDE = Join-Path $PSScriptRoot 'js_prelude\census.js'
    $env:WREN_JS_PROFILE = "$pre.jsprof"
    $env:WREN_JS_PROFILE_FROM = [string](($Settle - 1) * 1000)
    $url = switch ($name) {
        'blank' { 'about:home' } 'static' { 'https://example.com/' }
        'results' { 'https://www.youtube.com/results?search_query=' + [uri]::EscapeDataString($Query) }
        'grid' { $Channel } 'home' { 'https://www.youtube.com/' }
        default { "https://www.youtube.com/watch?v=$Video" }
    }
    $null = Start-Wren -Dpi 96 -Size 1920x1080 -ProfileDir $prof -Pref $Pref
    $wrenPid = [int]((Wren-Ctl ping --json) | ConvertFrom-Json).pid
    $t0 = (Get-Process -Id $wrenPid).StartTime
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $summary = @()
    try {
        $null = Wren-Ctl nav $url --wait load --timeout 30000
        if ($WrenExit -ne 0) { "[$name] the page did not load in 30 s ($WrenErr)"; return }
        $nav = $clock.Elapsed.TotalSeconds
        if ($name -like 'watch*') {
            Start-Sleep 4
            $want = if ($name -eq 'watchplay') { 'true' } else { 'false' }
            $null = Wren-Eval ('(()=>{ const v=document.querySelector("video"); if (!v) return; if (' + $want + ') { v.muted=true; v.play() } else { v.pause() } })()')
        } else { Start-Sleep 3 }
        $null = Wren-Eval $reject
        Start-Sleep ([Math]::Max(1, $Settle - [int]$clock.Elapsed.TotalSeconds))
        $null = Wren-Ctl network --clear
        $s0 = Stats-Json
        $a = ((Get-Date) - $t0).TotalMilliseconds
        $null = Wren-Eval 'window.__census ? window.__census.start() : "no census"'
        $thr = ''
        $thr = (powershell -NoProfile -File "$PSScriptRoot\thread_cpu.ps1" -ProcessId $wrenPid -Seconds 8 | Out-String)
        $left = $Window - 8 - 2
        if ($left -gt 0) { Start-Sleep $left }
        $null = Wren-Eval 'window.__census ? window.__census.stop() : 0'
        $s1 = Stats-Json
        $b = ((Get-Date) - $t0).TotalMilliseconds
        $census = Wren-Eval "window.__census ? window.__census.report($Top) : '{}'"
        $net = (Wren-Ctl network --json) | ConvertFrom-Json
        $state = Wren-Eval '(()=>{ const v=document.querySelector("video"); return JSON.stringify({video: v ? {paused: v.paused, t: v.currentTime} : null, nodes: document.getElementsByTagName("*").length, title: document.title.slice(0,50)}) })()'
        $secs = ($s1.uptimeMs - $s0.uptimeMs) / 1000
        $summary += "[$name] loaded in $([int]$nav) s; window $([Math]::Round($secs,1)) s from $Settle s after the navigation; $state"
        $summary += "[$name] frames drawn {0} ({1:N2}/s) | process CPU {2:N0} ms ({3:N1} % of a core) | memory {4:N0} MB private | threads {5}" -f ($s1.framesDrawn - $s0.framesDrawn), (($s1.framesDrawn - $s0.framesDrawn) / $secs), ($s1.cpuTimeMs - $s0.cpuTimeMs), (($s1.cpuTimeMs - $s0.cpuTimeMs) / 10 / $secs), ($s1.privateBytes / 1MB), $s1.threads
        $reqs = @($net.requests)
        $byHost = $reqs | Group-Object { ([uri]$_.url).Host } | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Name) x$($_.Count)" }
        $summary += "[$name] network in the window: {0} requests ({1:N1}/s), {2:N0} KB; by host: {3}" -f $reqs.Count, ($reqs.Count / $secs), ($net.bytes / 1KB), ($byHost -join ', ')
        foreach ($r in ($reqs | Select-Object -First 12)) { $summary += "[$name]   $($r.method) $($r.destination) $($r.status) $($r.bytes) B $([int]$r.ms) ms $(($r.url -replace '\?.*$', '').Substring(0, [Math]::Min(110, ($r.url -replace '\?.*$', '').Length)))" }
        if ($thr) { $summary += ($thr -split "`n" | Where-Object { $_ -match '^\s*\d+\s' } | Select-Object -First 6 | ForEach-Object { "[$name] thread $($_.Trim())" }) }
        try {
            $c = $census | ConvertFrom-Json
            foreach ($k in $c.kinds.PSObject.Properties) {
                $summary += "[$name] {0}: {1} in all, {2} ms/s" -f $k.Name, $k.Value.totalN, $k.Value.totalMsPerSec
                foreach ($r in $k.Value.rows) { $summary += "[$name]   {0,7}/s {1,7} ms/s (avg {2} max {3} ms{4}) {5}" -f $r.perSec, $r.msPerSec, $r.avgMs, $r.maxMs, $(if ($r.items) { ", $($r.items) items" } else { '' }), $r.key }
            }
        } catch { $summary += "[$name] census: $census" }
        Set-Content -Path "$pre.census.json" -Value $census -Encoding UTF8
    } finally { try { Stop-Wren } catch {} }
    Start-Sleep 3
    if (Test-Path "$pre.csv") {
        $rows = @(Import-Csv "$pre.csv" | Where-Object { [double]$_.t_ms -ge $a -and [double]$_.t_ms -lt $b })
        if ($rows.Count -gt 0) {
            $cpu = $rows | ForEach-Object { [double]$_.Frame - [double]$_.Wait - [double]$_.Present }
            $c = Stat $cpu
            $ph = foreach ($p in 'Loop', 'Animation', 'Build_UI', 'Styles', 'Layout', 'Paint_Items', 'Submit') { "{0} {1:N1}" -f $p, (($rows | ForEach-Object { [double]$_.$p } | Measure-Object -Sum).Sum / $secs) }
            $summary += "[$name] per frame: CPU p50 {0:N2} p95 {1:N2} max {2:N1} ms | ms of work per second: {3}" -f $c.p50, $c.p95, $c.max, ($ph -join ', ')
        }
    }
    $summary
}

# the consent dialog, answered once for the profile
$env:WREN_PROF = ''; $env:WREN_JS_PRELUDE = ''; $env:WREN_JS_PROFILE = ''; $env:WREN_JS_PROFILE_FROM = ''
if ($Page | Where-Object { $_ -notin 'blank', 'static' }) {
    $null = Start-Wren -Dpi 96 -Size 1920x1080 -ProfileDir $prof
    try { $null = Wren-Ctl nav 'https://www.youtube.com/' --wait idle --timeout 30000; Start-Sleep 3; $null = Wren-Eval $reject; Start-Sleep 3 } finally { Stop-Wren }
}
foreach ($p in $Page) { try { Run-Page $p } catch { "[$p] failed: $_" } }
