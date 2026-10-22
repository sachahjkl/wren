# Shared by the test and measurement scripts (dot-source it: . "$PSScriptRoot\test_env.ps1"): a test server on a block
# of ports of its own, and the machine-wide locks of what cannot be shared between runs.
#
# Test server (tools\testserver\ports.go): every origin of the tests is an offset from one base port (+0 http on
# 127.0.0.1 and localhost, +1 https, +2 a second http origin, +3 / +4 the web-platform-tests origin). The demos and the
# release package use 8765; the scripts take a block of their own so that several worktrees (or several steps of one
# run) test side by side, and hand it to the tools through WREN_TEST_BASE_PORT (src/tools/testenv,
# examples/testports). Start-WrenTestServer starts build\testserver.exe on the first free block from -BasePort
# (-scan: base, base+10, ...), waits until it listens, and returns { Process; BasePort; Origin }. The server ends with
# the PowerShell process that started it (-parent-pid), even when that one is killed.
#
# Locks: only around what really is shared by the whole machine.
#   desktop  the real screen, keyboard, mouse and foreground window: a visible browser window that is captured or typed
#            into (screenshot.ps1, history_e2e.ps1, shots.ps1, ...). Taken by those scripts themselves, for as long as
#            their window lives.
#   bench    performance measurements, which other runs would skew (perf.ps1, js_bench.ps1, cfg_bench.ps1, ...).
# Nothing headless takes a lock (tools\test_all.ps1 takes none: its server is on ports of its own and nothing in it
# opens a window). S:\wb_wt\shared.lock, the former lock of everything, is no longer used by these scripts.
# The files: $env:WREN_LOCK_DIR, else S:\wb_wt when it exists (the agents' worktrees), else %TEMP%\wren_locks. A lock is
# the file opened without sharing: the system lets go of it when the process ends, even killed. The holder writes who
# it is in <name>.lock.owner, which a waiting script prints. A script that already holds a lock (it, or a script that
# started it: WREN_HELD_LOCKS is inherited) takes it again as a no-op.

function Get-WrenRepoRoot { Split-Path $PSScriptRoot -Parent }

function Get-WrenLockDir {
    if ($env:WREN_LOCK_DIR) { $d = $env:WREN_LOCK_DIR }
    elseif (Test-Path 'S:\wb_wt' -PathType Container) { $d = 'S:\wb_wt' }
    else { $d = Join-Path ([IO.Path]::GetTempPath()) 'wren_locks' }
    New-Item -ItemType Directory -Force $d | Out-Null
    return $d
}

# Takes the lock `Name` (desktop, bench), waiting at most -TimeoutSec; returns a handle for Exit-WrenLock (or $null when
# this process already holds it). Throws, saying who holds it, when the wait is over.
function Enter-WrenLock([Parameter(Mandatory)][string]$Name, [string]$What = '', [int]$TimeoutSec = 900) {
    $held = @($env:WREN_HELD_LOCKS -split ',' | Where-Object { $_ })
    if ($held -contains $Name) { return $null }
    $dir = Get-WrenLockDir
    $path = Join-Path $dir "$Name.lock"
    $ownerPath = "$path.owner"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $told = $false
    while ($true) {
        try { $fs = [IO.File]::Open($path, 'OpenOrCreate', 'ReadWrite', 'None'); break } catch { }
        if (-not $told -or $sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
            $owner = try { [IO.File]::ReadAllText($ownerPath).Trim() } catch { 'unknown' }
            if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
                throw "${Name}.lock: still held after $TimeoutSec s by $owner ($path). Try again later (that process may belong to another run: do not end it)."
            }
            [Console]::Error.WriteLine("waiting for $Name.lock (at most $TimeoutSec s), held by $owner")
            $told = $true
        }
        Start-Sleep -Milliseconds 250
    }
    $who = "pid $PID, $(Get-WrenRepoRoot), $(if ($What) { $What } else { Split-Path $MyInvocation.PSCommandPath -Leaf }), since $(Get-Date -Format 'HH:mm:ss')"
    try { [IO.File]::WriteAllText($ownerPath, $who) } catch { }
    if ($told) { [Console]::Error.WriteLine("took $Name.lock after $([int]$sw.Elapsed.TotalSeconds) s") }
    $env:WREN_HELD_LOCKS = (@($held) + $Name) -join ','
    return [pscustomobject]@{ Name = $Name; Stream = $fs; Owner = $ownerPath }
}

function Exit-WrenLock($Lock) {
    if (-not $Lock) { return }
    try { [IO.File]::WriteAllText($Lock.Owner, '') } catch { }
    $Lock.Stream.Close()
    $env:WREN_HELD_LOCKS = (@($env:WREN_HELD_LOCKS -split ',' | Where-Object { $_ -and $_ -ne $Lock.Name })) -join ','
}

# Runs $Body under the lock `Name` (taken and given back here, also on an error).
function Use-WrenLock([string]$Name, [scriptblock]$Body, [string]$What = '', [int]$TimeoutSec = 900) {
    $l = Enter-WrenLock $Name $What $TimeoutSec
    try { & $Body } finally { Exit-WrenLock $l }
}

# The first base port this worktree tries: derived from its path, so that two worktrees rarely try the same block
# (20000-28990 in steps of 10: below the dynamic ports of Windows, 49152+, and away from the default 8765).
function Get-WrenPreferredBasePort([string]$Root = (Get-WrenRepoRoot)) {
    $h = [uint32]2166136261
    foreach ($b in [Text.Encoding]::UTF8.GetBytes($Root.ToLowerInvariant().TrimEnd('\'))) {
        $h = [uint32](([uint64]($h -bxor $b) * 16777619) % 4294967296)
    }
    return 20000 + [int]($h % 900) * 10
}

# Starts build\testserver.exe (from the repository root: it serves examples\ from there) on the first free block of
# ports from -BasePort (default: this worktree's), and returns { Process; BasePort; Origin } once it listens.
# -WptOnly: the WPT origin alone (-BasePort is then its http port). Stop it with Stop-WrenTestServer.
function Start-WrenTestServer([int]$BasePort = 0, [string]$Exe = '', [switch]$WptOnly, [string]$Log = '', [int]$TimeoutSec = 60) {
    $root = Get-WrenRepoRoot
    if ($BasePort -le 0) { $BasePort = Get-WrenPreferredBasePort $root }
    if (-not $Exe) { $Exe = Join-Path $root 'build\testserver.exe' }
    $portFile = Join-Path ([IO.Path]::GetTempPath()) "wren_testserver_${PID}_$([guid]::NewGuid().ToString('N')).port"
    $a = if ($WptOnly) { @('-wpt-only', '-wpt-port', $BasePort) } else { @('-base-port', $BasePort) }
    $a += @('-scan', '-port-file', "`"$portFile`"", '-parent-pid', $PID)
    $sp = @{ FilePath = $Exe; ArgumentList = $a; PassThru = $true; WindowStyle = 'Hidden'; WorkingDirectory = $root }
    if ($Log) { $sp.RedirectStandardError = $Log }
    $p = Start-Process @sp
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not (Test-Path $portFile)) {
        if ($p.HasExited) { throw "the test server stopped at once (exit $($p.ExitCode)): no free block of ports from $BasePort?" }
        if ((Get-Date) -gt $deadline) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; throw "the test server did not listen within $TimeoutSec s" }
        Start-Sleep -Milliseconds 50
    }
    $base = [int](Get-Content $portFile -Raw)
    Remove-Item $portFile -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Process = $p; BasePort = $base; Origin = "http://127.0.0.1:$base" }
}

function Stop-WrenTestServer($Server) {
    if ($Server -and $Server.Process) { Stop-Process -Id $Server.Process.Id -Force -ErrorAction SilentlyContinue; $Server.Process.WaitForExit(5000) | Out-Null }
}

# No script that sources this file (tests, captures, measurements, the agents' runs) lets a Wren integrate itself with the machine's desktop:
# the first-run integration and the update offer of src/browser/desktop_shell.odin read this variable. (--desktop-integration=... on the command line still works.)
$env:WREN_DESKTOP_INTEGRATION = 'off'
