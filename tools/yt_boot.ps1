# How long a heavy page takes to start, as the page itself sees it: a Wren driven by `wren ctl` loads https://www.youtube.com (a watch page,
# the home page or a Short) with tools\js_prelude\ytmarks.js run first (WREN_JS_PRELUDE): it notes, in ms since the navigation began,
# when the masthead, the logo, the first thumbnail and the first video data are in the DOM, and after 30 s adds the size of the DOM
# (window.__ytm, read back with wren ctl eval once the 30 s are over). Nothing is captured or asked of the page meanwhile (a capture or a script call costs the page time).
# Also the CPU the process used in those 30 s (user and kernel) and its memory.
#   cold  a new profile (nothing cached; the consent dialog answered before)
#   warm  the same profile again after the Wren was closed (HTTP cache, bytecode cache, Wasm code cache)
#   powershell -NoProfile -File tools\yt_boot.ps1 [-Exe build\wren.exe] [-Runs 3] [-Page watch|home|short] [-Pref a=b,c=d] [-Tag name] [-NoWarm]
# Prints one line per run and the medians; with -Tag also appends them to build\yt_boot.txt.
param([string]$Exe = '', [int]$Runs = 3, [ValidateSet('watch', 'home', 'short')][string]$Page = 'watch', [string[]]$Pref = @(), [string]$Tag = '', [switch]$NoWarm)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
[Environment]::CurrentDirectory = $root
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
$env:WREN_JS_PRELUDE = Join-Path $PSScriptRoot 'js_prelude\ytmarks.js'
. "$PSScriptRoot\wrenctl.ps1"
$urls = @{ watch = 'https://www.youtube.com/watch?v=aqz-KE-bpKQ'; home = 'https://www.youtube.com/'; short = 'https://www.youtube.com/shorts/aqz-KE-bpKQ' }
$tmp = Join-Path $env:TEMP "yt-boot-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Measure-Load([string]$prof, [bool]$consent) {
    $null = Start-Wren -Dpi 96 -Size 1280x800 -ProfileDir $prof -Pref $Pref
    $wrenPid = [int](((Wren-Ctl ping --json) | ConvertFrom-Json).pid)
    try {
        if ($consent) {
            Wren-Nav 'https://www.youtube.com/' -Wait idle | Out-Null
            Start-Sleep 2
            $null = Wren-Eval '(()=>{ const b=[...document.querySelectorAll("button")].find(x=>/reject all/i.test(x.textContent)); if(b){ b.click() } })()'
            Start-Sleep 4
        }
        $proc = Get-Process -Id $wrenPid
        $cpu0 = $proc.UserProcessorTime.TotalSeconds; $krn0 = $proc.PrivilegedProcessorTime.TotalSeconds
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Wren-Nav $urls[$Page] -Wait load | Out-Null
        $marks = $null
        Start-Sleep -Seconds ([Math]::Max(0, 31 - [int]$sw.Elapsed.TotalSeconds))
        while ($sw.Elapsed.TotalSeconds -lt 60 -and -not $marks) {
            $json = Wren-Eval 'window.__ytm && window.__ytm.done ? JSON.stringify(window.__ytm) : ""'
            if ($json) { $marks = $json | ConvertFrom-Json } else { Start-Sleep -Seconds 2 }
        }
        $proc.Refresh()
        $cpuU = [Math]::Round($proc.UserProcessorTime.TotalSeconds - $cpu0, 1); $cpuK = [Math]::Round($proc.PrivilegedProcessorTime.TotalSeconds - $krn0, 1)
        $v = { param($x) if ($null -eq $x) { -1 } else { [int]$x } }
        [pscustomobject]@{ masthead = (& $v $marks.masthead); logo = (& $v $marks.logo); thumbs = (& $v $marks.thumbs); video = (& $v $marks.loadeddata); dcl = (& $v $marks.dcl); load = (& $v $marks.load); elements = (& $v $marks.elements); user = $cpuU; kernel = $cpuK; mb = [int]($proc.WorkingSet64 / 1MB) }
    } finally { try { Stop-Wren } catch {} }
}

$rows = @()
try {
    for ($i = 1; $i -le $Runs; $i++) {
        $prof = Join-Path $tmp "profile$i"
        foreach ($mode in $(if ($NoWarm) { @('cold') } else { @('cold', 'warm') })) {
            $r = Measure-Load $prof ($mode -eq 'cold')
            $r | Add-Member mode $mode
            $rows += $r
            "{0,-4} run {1}: masthead {2,6} | logo {3,6} | thumbs {4,6} | video {5,6} ms | dcl {6,5} load {7,5} | {8} elements | cpu user {9,5} s kernel {10,5} s | {11} MB" -f $mode, $i, $r.masthead, $r.logo, $r.thumbs, $r.video, $r.dcl, $r.load, $r.elements, $r.user, $r.kernel, $r.mb
        }
    }
} finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
function Median($v) { $s = @($v | Where-Object { $_ -ge 0 } | Sort-Object); if ($s.Count -eq 0) { return -1 }; return $s[[int][Math]::Floor(($s.Count - 1) / 2)] }
$lines = @()
foreach ($mode in 'cold', 'warm') {
    $g = @($rows | Where-Object { $_.mode -eq $mode })
    if ($g.Count -eq 0) { continue }
    $lines += "{0,-4} {1} median of {2}: masthead {3} | logo {4} | thumbs {5} | video {6} ms | cpu user {7} s kernel {8} s" -f $mode, $Page, $g.Count, (Median ($g | % masthead)), (Median ($g | % logo)), (Median ($g | % thumbs)), (Median ($g | % video)), (Median ($g | % user)), (Median ($g | % kernel))
}
$lines
if ($Tag) { Add-Content -Path (Join-Path $root 'build\yt_boot.txt') -Value (@("== $Tag ($(Get-Date -Format s)) exe $Exe prefs $($Pref -join ',')") + $lines) }
