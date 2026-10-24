# How much JavaScript the interpreter runs for a page, with the content blocker's scriptlets done one way or the other: a Wren driven by
# `wren ctl` loads each site (a profile that has the filter lists, copied fresh for every run), the page's own functions are sampled
# (WREN_JS_PROFILE: the engine counts the frames of the stack every few interrupt checks) and, after the wait, the samples are summed
# over every page of the tab (the frames too). `blocker` samples are those of the blocker's own scripts (wren-blocker:...).
#   powershell -NoProfile -File tools\blocker_js.ps1 -Seed build\tpm -Wait 25 -Urls a,b,c -Exes before=build\wren_before.exe,after=build\wren.exe -Out build\blocker_js.tsv
# Each executable runs with the blocker on; the last one runs once more with blocker.enabled=false (the page alone).
param([string]$Seed, [string[]]$Urls, [string[]]$Exes, [int]$Wait = 25, [string]$Out = 'build\blocker_js.tsv', [string]$Pref = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
[Environment]::CurrentDirectory = $root
. "$PSScriptRoot\wrenctl.ps1"
$Urls = @($Urls | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Exes = @($Exes | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$tmp = Join-Path $env:TEMP "blocker-js-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
Remove-Item $Out -ErrorAction SilentlyContinue
Add-Content $Out "site`tconfig`tinterp_samples`tblocker_samples`tcpu_s`telements`tmem_mb"

function Run-One([string]$exe, [string]$label, [string]$url, [string[]]$prefs) {
    $prof = Join-Path $tmp 'profile'
    if (Test-Path $prof) { cmd /c "rmdir /s /q `"$prof`"" | Out-Null }
    robocopy $Seed $prof /E /NFL /NDL /NJH /NJS /NP | Out-Null
    Get-ChildItem $tmp -Filter 'jsp*.js.txt' -ErrorAction SilentlyContinue | Remove-Item -Force
    $env:WREN_EXE = (Resolve-Path $exe).Path
    $env:WREN_JS_PROFILE = Join-Path $tmp 'jsp'
    $null = Start-Wren -Dpi 96 -Size 1280x800 -ProfileDir $prof -Pref $prefs
    $elements = -1; $cpu = -1; $mem = -1
    try {
        $wrenPid = [int](((Wren-Ctl ping --json) | ConvertFrom-Json).pid)
        if ($url -match 'youtube\.com') {
            Wren-Nav 'https://www.youtube.com/' -Wait idle | Out-Null
            Start-Sleep 2
            $null = Wren-Eval '(()=>{ const b=[...document.querySelectorAll("button")].find(x=>/reject all/i.test(x.textContent)); if(b){ b.click() } })()'
            Start-Sleep 4
        }
        $proc = Get-Process -Id $wrenPid
        $c0 = $proc.UserProcessorTime.TotalSeconds + $proc.PrivilegedProcessorTime.TotalSeconds
        try { Wren-Nav $url -Wait none | Out-Null } catch { }
        Start-Sleep -Seconds $Wait
        $proc.Refresh()
        $cpu = [Math]::Round($proc.UserProcessorTime.TotalSeconds + $proc.PrivilegedProcessorTime.TotalSeconds - $c0, 1)
        $mem = [int]($proc.WorkingSet64 / 1MB)
    } finally { try { Stop-Wren } catch {} }
    Start-Sleep 2
    $samples = 0; $blocker = 0
    foreach ($f in Get-ChildItem $tmp -Filter 'jsp*.js.txt') {
        $lines = Get-Content $f.FullName
        if ($lines[0] -match '; (\d+) samples\)') { $samples += [int]$Matches[1] }
        $own = 0
        foreach ($l in $lines) { if ($l -match 'wren-blocker' -and $l -match '^\s*[\d.]+ %\s+(\d+)\s') { $own = [Math]::Max($own, [int]$Matches[1]) } }
        $blocker += $own
    }
    $host_ = ([Uri]$url).Host -replace '^www\.', ''
    $line = "$host_`t$label`t$samples`t$blocker`t$cpu`t$elements`t$mem"
    Add-Content $Out $line
    $line
}

try {
    foreach ($url in $Urls) {
        foreach ($e in $Exes) {
            $name, $path = $e -split '=', 2
            Run-One $path "$name (blocker on)" $url @('blocker.update.enabled=false')
        }
        $name, $path = ($Exes[-1] -split '=', 2)
        Run-One $path "$name (blocker off)" $url @('blocker.update.enabled=false', 'blocker.enabled=false')
    }
} finally {
    Remove-Item Env:WREN_JS_PROFILE -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
