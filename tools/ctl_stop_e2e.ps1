# `wren ctl stop <name>` ends the Wren that `wren ctl start` made, and nothing else (src\remote\client\spawn_windows.odin, security
# review of 2026-10-25, finding 6). The session file keeps a pid; when the Wren has ended (closed by hand, crashed) and Windows has
# given the number to another program, `stop` used to wait 15 s for that program and then end it. It now checks the process it
# opened is the one written down (creation time and program) before it waits for it or ends it.
#   powershell -NoProfile -File tools\ctl_stop_e2e.ps1 [-Exe build\wren.exe]
param([string]$Exe = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
. "$PSScriptRoot\wrenctl.ps1"
$script:WrenExe = (Resolve-Path $Exe).Path

$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "PASS  $name" } else { "FAIL  $name  $detail"; $script:fail++ }
}
$dir = Join-Path $env:TEMP 'wren-ctl'
New-Item -ItemType Directory -Force $dir | Out-Null
$victims = @()
function New-Victim { $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\ping.exe') -ArgumentList '-n', '600', '127.0.0.1' -WindowStyle Hidden -PassThru; $script:victims += $p; return $p }
try {
    # a session file whose pid is now an unrelated program, written the way `start` writes it (a different creation time)
    $v = New-Victim
    $name = "stale$PID"
    $file = Join-Path $dir "$name.json"
    $image = (Join-Path $env:SystemRoot 'System32\ping.exe')
    [IO.File]::WriteAllText($file, (@{ name = $name; pid = $v.Id; created = 133000000000000000; image = $script:WrenExe; profile = ''; temp = $false } | ConvertTo-Json -Compress))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = Wren-Ctl stop $name
    $took = $sw.Elapsed.TotalSeconds
    $v.Refresh()
    Check 'a pid that is another program now: it is left alone' (-not $v.HasExited)
    Check '...at once (it was not waited for)' ($took -lt 10) "$took s"
    Check '...with exit 0 and a word on stderr' ($global:WrenExit -eq 0 -and $global:WrenErr -match 'left alone') "exit $global:WrenExit [$global:WrenErr]"
    Check '...and the session file is removed' (-not (Test-Path $file))

    # the same instant but the other program's image: not it either
    $v2 = New-Victim
    $name2 = "stale2$PID"
    $file2 = Join-Path $dir "$name2.json"
    $real = [Diagnostics.Process]::GetProcessById($v2.Id)
    $created = $real.StartTime.ToFileTime()
    [IO.File]::WriteAllText($file2, (@{ name = $name2; pid = $v2.Id; created = $created; image = $script:WrenExe; profile = ''; temp = $false } | ConvertTo-Json -Compress))
    $null = Wren-Ctl stop $name2
    $v2.Refresh()
    Check 'same creation time, another program: left alone' (-not $v2.HasExited) "exit $global:WrenExit [$global:WrenErr]"

    # a session file of an older wren ctl (no creation time, no program): unverifiable, left alone
    $v3 = New-Victim
    $name3 = "stale3$PID"
    $file3 = Join-Path $dir "$name3.json"
    [IO.File]::WriteAllText($file3, (@{ name = $name3; pid = $v3.Id; profile = ''; temp = $false } | ConvertTo-Json -Compress))
    $null = Wren-Ctl stop $name3
    $v3.Refresh()
    Check 'a session file without who it was: left alone' (-not $v3.HasExited) "exit $global:WrenExit [$global:WrenErr]"

    # and the real thing still ends its Wren
    $started = Start-Wren
    $info = Get-Content (Join-Path $dir "$started.json") -Raw | ConvertFrom-Json
    Check 'start writes who the process is' ($info.created -gt 0 -and $info.image -eq $script:WrenExe) ($info | ConvertTo-Json -Compress)
    $victimWren = [Diagnostics.Process]::GetProcessById([int]$info.pid)
    Stop-Wren
    $null = $victimWren.WaitForExit(15000)
    Check 'stop ends the Wren it started' ($victimWren.HasExited)
    Check '...and removes its session file' (-not (Test-Path (Join-Path $dir "$started.json")))
} finally {
    if ($env:WREN_REMOTE) { Stop-Wren }
    foreach ($p in $victims) { try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force } } catch {} }
    foreach ($n in "stale$PID", "stale2$PID", "stale3$PID") { Remove-Item (Join-Path $dir "$n.json") -ErrorAction SilentlyContinue }
}
if ($script:fail -gt 0) { "$script:fail check(s) failed"; exit 1 }
'ctl_stop_e2e: all checks passed'
