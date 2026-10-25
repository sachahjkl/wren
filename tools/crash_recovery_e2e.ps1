# After a Wren ends abnormally the next start brings the tabs back, and never loops (src/browser/crash_recovery.odin, docs/crash_recovery.md).
# Real wren.exe processes on a scratch profile, driven with `wren ctl`; the Wren is "crashed" by ending its own process (the id
# `wren ctl start` wrote down), which leaves running.txt and recovery.txt in the profile exactly as a crash would.
#   powershell -NoProfile -File tools\crash_recovery_e2e.ps1 [-Exe build\wren.exe]
param([string]$Exe = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\wrenctl.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$script:WrenExe = (Resolve-Path $Exe).Path

$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { "PASS  $name" } else { "FAIL  $name  $detail"; $script:fail++ } }
$ctlDir = Join-Path $env:TEMP 'wren-ctl'
$profile = Join-Path $env:TEMP "wren-recovery-e2e-$PID"
$started = New-Object Collections.Generic.List[string]
$TabA = 'about:config'; $TabB = 'about:demos'

# Starts a Wren on the scratch profile (no blocker lists, snapshots a quarter of a second after a change).
function Start-OnProfile([string[]]$Pref = @()) {
    $n = Start-Wren -ProfileDir $profile -Pref (@('browser.session.crash_snapshot_ms=500') + $Pref)
    $started.Add($n)
    return $n
}
# Ends the process `wren ctl start` made, the way a crash does (no clean exit); only that process.
function Crash-Wren([string]$Name) {
    $info = Get-Content (Join-Path $ctlDir "$Name.json") -Raw | ConvertFrom-Json
    $p = [Diagnostics.Process]::GetProcessById([int]$info.pid)
    $p.Kill(); $p.WaitForExit(15000) | Out-Null
    Remove-Item (Join-Path $ctlDir "$Name.json") -ErrorAction SilentlyContinue
    $started.Remove($Name) | Out-Null
    Remove-Item Env:\WREN_REMOTE -ErrorAction SilentlyContinue
}
function Tab-Urls { return @((Wren-Ctl tabs) -split "`r?`n" | Where-Object { $_ } | ForEach-Object { ($_ -split '\s+')[-1] }) }
function Tabs-Are([string]$Expected) { return ((Tab-Urls) -join ' ') -eq $Expected }
function Wait-Until([scriptblock]$Test, [double]$Seconds = 15) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) { if (& $Test) { return $true }; Start-Sleep -Milliseconds 50 }
    return [bool](& $Test)
}
function Snapshot-Has([string]$Text) { $f = Join-Path $profile 'recovery.txt'; return (Test-Path $f) -and ((Get-Content $f -Raw) -match [regex]::Escape($Text)) }
function Marker { $f = Join-Path $profile 'running.txt'; if (Test-Path $f) { return Get-Content $f -Raw } else { return '' } }
function Backups { return @(Get-ChildItem $profile -Filter 'crashed-session *.txt' -ErrorAction SilentlyContinue) }

New-Item -ItemType Directory -Force $profile | Out-Null
try {
    # --- a crash: the tabs come back
    $n1 = Start-OnProfile
    Check 'a start writes its marker' ((Marker) -match 'wren-running 1' -and (Marker) -match 'restoring 0')
    $null = Wren-Ctl tab new $TabA
    $null = Wren-Ctl tab new $TabB
    Check 'the tabs are written to recovery.txt a moment after they change' (Wait-Until { Snapshot-Has $TabB })
    Crash-Wren $n1
    Check 'a crash leaves the marker and the snapshot' ((Marker) -ne '' -and (Test-Path (Join-Path $profile 'recovery.txt')))

    $n2 = Start-OnProfile
    # (the driver always gives the address about:blank, which opens after the restored tabs, as any address on the command line does)
    Check 'the next start has the same tabs, in the same order, then the address it was given' (Tabs-Are "about:blank $TabA $TabB about:blank") ((Tab-Urls) -join ' ')
    Check '...and its marker says it is restoring' ((Marker) -match 'restoring 1')

    # --- the restoring start crashes before it is stable: the third does not open the tabs again
    Crash-Wren $n2
    $n3 = Start-OnProfile
    Check 'a start after two crashes in a row opens only the address it was given, not the tabs' (Tabs-Are 'about:blank') ((Tab-Urls) -join ' ')
    $files = Backups
    $saved = if ($files.Count) { Get-Content $files[0].FullName -Raw } else { '' }
    Check '...and the tabs are kept in a file of the profile' ($files.Count -eq 1 -and $saved -match [regex]::Escape($TabB) -and $saved -match [regex]::Escape($TabA)) "$($files.Count) backup(s)"
    Check '...whose marker does not say restoring' ((Marker) -match 'restoring 0')
    $null = Wren-Ctl cmd tab.restore_crashed
    Check 'the command restores them by hand (the blank page makes way)' (Wait-Until { Tabs-Are "about:blank $TabA $TabB" }) ((Tab-Urls) -join ' ')

    # --- a normal end removes both files, and the next start restores nothing
    Stop-Wren
    $started.Remove($n3) | Out-Null
    Check 'a normal end removes the marker and the snapshot' ((Marker) -eq '' -and -not (Test-Path (Join-Path $profile 'recovery.txt')))
    $n4 = Start-OnProfile
    Check 'a start after a normal end has one blank tab' (Tabs-Are 'about:blank') ((Tab-Urls) -join ' ')

    # --- a restoring start that lived long enough counts as stable: the crash after it is a first crash again
    $null = Wren-Ctl tab new $TabA
    $null = Wren-Ctl tab new $TabB
    $null = Wait-Until { Snapshot-Has $TabB }
    Crash-Wren $n4
    $n5 = Start-OnProfile @('browser.session.crash_stable_ms=1000')
    Check 'restored again' (Tabs-Are "about:blank $TabA $TabB about:blank") ((Tab-Urls) -join ' ')
    Check 'the marker stops saying restoring once the start is stable' (Wait-Until { (Marker) -match 'restoring 0' })
    Crash-Wren $n5
    $n6 = Start-OnProfile
    Check 'a crash after a stable restore restores again (it is not the second in a row)' ((((Tab-Urls) | Select-Object -First 3) -join ' ') -eq "about:blank $TabA $TabB") ((Tab-Urls) -join ' ')
    Crash-Wren $n6

    # --- a Wren that still runs on the profile is not a crash: the second start leaves its files alone
    Remove-Item (Join-Path $profile 'running.txt'), (Join-Path $profile 'recovery.txt') -ErrorAction SilentlyContinue
    $n7 = Start-OnProfile
    $first = Marker
    $n8 = Start-Wren -ProfileDir $profile -Name "live$PID"
    $started.Add($n8)
    Check 'a second start on a profile that is in use opens one tab and does not restore' ((Tab-Urls).Count -eq 1)
    Check '...and leaves the first one marker as it was' ((Marker) -eq $first) (Marker)
    Wren-Ctl stop $n8 | Out-Null
    $started.Remove($n8) | Out-Null
    $env:WREN_REMOTE = $n7
    Check 'the one that ends does not take the marker of the one that runs' ((Marker) -eq $first)
    Stop-Wren $n7
    $started.Remove($n7) | Out-Null
} finally {
    foreach ($n in @($started)) { try { Wren-Ctl stop $n | Out-Null } catch {} }
    Remove-Item Env:\WREN_REMOTE -ErrorAction SilentlyContinue
    if ($profile -and (Test-Path $profile) -and $profile.Contains('wren-recovery-e2e')) {
        Get-ChildItem $profile -Recurse -File -Force | ForEach-Object { [IO.File]::Delete($_.FullName) }
        Get-ChildItem $profile -Recurse -Directory -Force | Sort-Object FullName -Descending | ForEach-Object { try { [IO.Directory]::Delete($_.FullName) } catch {} }
        try { [IO.Directory]::Delete($profile) } catch {}
    }
}
if ($script:fail -gt 0) { "crash_recovery_e2e: $script:fail check(s) failed"; exit 1 }
'crash_recovery_e2e: all checks passed'
