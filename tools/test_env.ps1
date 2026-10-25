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

# Performance tests: what asserts on a duration, a CPU time, a throughput, a latency or a count of frames in a window of time depends on the
# machine, and the CI runners are of unknown speed. Those checks are opt-in (test_all.ps1 -Perf, or WREN_PERF=1) and never run when the CI
# variable is set. This is the one place that decides for the scripts (src\base\perf.odin does the same for the Odin tests).
#   Test-WrenPerf       are the performance tests on?
#   Skip-WrenPerf       says that one is skipped ("perf: skipped, run with -Perf: <what>")
#   Check-Perf          Check (the calling script's own) when they are on, a skip line otherwise; put the measure in the name or the detail
function Test-WrenPerf { return (-not $env:CI) -and ($env:WREN_PERF -eq '1' -or $env:WREN_PERF -eq 'true') }
function Skip-WrenPerf([string]$What) {
    if ($env:CI) { "perf: skipped on the CI (the CI variable is set): $What" } else { "perf: skipped, run with -Perf (test_all.ps1 -Perf, or WREN_PERF=1): $What" }
}
function Check-Perf([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if (-not (Test-WrenPerf)) { Skip-WrenPerf $Name; return }
    Check "perf: $Name" $Ok $Detail
}

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

# Builds build\testserver.exe when it is missing or older than a source of tools\testserver, one builder at a time (a named mutex: the steps
# that run side by side wait for it and find it built). A server that runs holds its exe: the build then fails to replace it, and that
# one stays (it is the build of a run that began before the sources changed).
function Ensure-WrenTestServer([string]$root, [string]$Exe) {
    $src = Join-Path $root 'tools\testserver'
    $stale = {
        if (-not (Test-Path $Exe)) { return $true }
        $built = [IO.File]::GetLastWriteTimeUtc($Exe)
        foreach ($f in [IO.Directory]::EnumerateFiles($src, '*', [IO.SearchOption]::AllDirectories)) {
            if (($f.EndsWith('.go') -or $f.EndsWith('go.mod') -or $f.EndsWith('go.sum')) -and [IO.File]::GetLastWriteTimeUtc($f) -gt $built) { return $true }
        }
        return $false
    }
    if (-not (& $stale)) { return }
    $sha = [Security.Cryptography.SHA1]::Create()
    $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant().TrimEnd('\')))) -replace '-', '').Substring(0, 16)
    $mutex = New-Object Threading.Mutex($false, "wren_testserver_build_$key")
    try {
        try { [void]$mutex.WaitOne() } catch [Threading.AbandonedMutexException] { }
        if (-not (& $stale)) { return }
        Push-Location $src
        try { go build -o $Exe . 2>&1 | Out-Null } finally { Pop-Location }
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

# Starts build\testserver.exe (from the repository root: it serves examples\ from there) on the first free block of
# ports from -BasePort (default: this worktree's), and returns { Process; BasePort; Origin } once it listens.
# -WptOnly: the WPT origin alone (-BasePort is then its http port). Stop it with Stop-WrenTestServer.
function Start-WrenTestServer([int]$BasePort = 0, [string]$Exe = '', [switch]$WptOnly, [string]$Log = '', [int]$TimeoutSec = 60) {
    $root = Get-WrenRepoRoot
    if ($BasePort -le 0) { $BasePort = Get-WrenPreferredBasePort $root }
    if (-not $Exe) {
        $Exe = Join-Path $root 'build\testserver.exe'
        # a fresh checkout (CI) has not built it yet, and a worktree whose build\ is old holds a server that lacks the routes of the tests
        # (a 404 on /video/f/ made the video checks time out): a test that needs it does not depend on the order of test_all's steps
        Ensure-WrenTestServer $root $Exe
        if (-not (Test-Path $Exe)) { throw "build\testserver.exe is missing and 'go build' of tools\testserver did not make it" }
    }
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

# Is build\<variant>.exe (default wren) newer than everything it is built from? A test that needs the browser built (the CI built it one step
# before; a developer built it a minute ago) skips the 40 s that `build.bat` takes even when nothing changed: Odin compiles the whole program every time.
# The inputs: the sources of the browser and of the toolkit (not their tests), the libraries and the script engine's image build.bat links or
# embeds, build.bat and odin.version themselves.
function Test-WrenBuildFresh([string]$Variant = 'wren') {
    $root = Get-WrenRepoRoot
    $exe = Join-Path $root "build\$Variant.exe"
    if (-not (Test-Path $exe)) { return $false }
    $built = [IO.File]::GetLastWriteTimeUtc($exe)
    foreach ($f in 'build.bat', 'odin.version', 'build\js\wren_js.wasm', 'build\lexbor\lexbor.lib', 'build\media\wren_media.lib') {
        $p = Join-Path $root $f
        if (-not (Test-Path $p) -or [IO.File]::GetLastWriteTimeUtc($p) -gt $built) { return $false }
    }
    foreach ($dir in 'src', 'ext\gui_toolkit', 'api', 'sdk') {
        $d = Join-Path $root $dir
        if (-not (Test-Path $d)) { continue }
        foreach ($p in [IO.Directory]::EnumerateFiles($d, '*', [IO.SearchOption]::AllDirectories)) {
            if ($p.EndsWith('_test.odin') -or $p.Contains('\tests\') -or $p.Contains('\.git\') -or $p.EndsWith('.md')) { continue }
            if ([IO.File]::GetLastWriteTimeUtc($p) -gt $built) { return $false }
        }
    }
    return $true
}

# Builds the browser (Variant 'dev': build\wren.exe, 'check': build\wren_check.exe) unless Test-WrenBuildFresh says it is newer than its sources, and
# never two builds of this worktree at once: build.bat writes build\bindgen.exe, build\wren.com and the version resource, which Windows refuses to
# a second writer (Error(013)), so the steps that run side by side (test_all -Jobs n) wait on a named mutex and then find the program built.
# Returns $true when the program is there; otherwise $false with the build's output in $global:WrenBuildOutput and LASTEXITCODE set.
$global:WrenBuildOutput = ''
function Ensure-WrenBuild([string]$Variant = 'dev') {
    $name = if ($Variant -eq 'check') { 'wren_check' } else { 'wren' }
    if (Test-WrenBuildFresh $name) { return $true }
    $root = Get-WrenRepoRoot
    $sha = [Security.Cryptography.SHA1]::Create()
    $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant().TrimEnd('\')))) -replace '-', '').Substring(0, 16)
    $mutex = New-Object Threading.Mutex($false, "wren_build_$key")
    try {
        try { [void]$mutex.WaitOne() } catch [Threading.AbandonedMutexException] { }
        if (Test-WrenBuildFresh $name) { return $true }
        Push-Location $root
        try { $global:WrenBuildOutput = (cmd /c "build.bat $Variant 2>&1" | Out-String) } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { return $false }
        return $true
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

# Odin compiles a whole program every time (no incremental build): a tool that a run builds twice (test262.ps1 is called twice by test_all)
# or that is already built does not need it again. Builds `Output` with `Build` (a script block), unless Output is newer than every source of the
# repository's src and ext\gui_toolkit (tests aside) and was built with the same `Flags` (written beside it, Output.flags).
function Invoke-WrenBuildIfStale([string]$Output, [string]$Flags, [scriptblock]$Build) {
    $root = Get-WrenRepoRoot
    $stamp = "$Output.flags"
    $fresh = (Test-Path $Output) -and (Test-Path $stamp) -and ([IO.File]::ReadAllText($stamp) -eq $Flags)
    if ($fresh) {
        $built = [IO.File]::GetLastWriteTimeUtc($Output)
        foreach ($dir in 'src', 'ext\gui_toolkit') {
            $d = Join-Path $root $dir
            if (-not (Test-Path $d)) { continue }
            foreach ($p in [IO.Directory]::EnumerateFiles($d, '*', [IO.SearchOption]::AllDirectories)) {
                if ($p.EndsWith('_test.odin') -or $p.Contains('\tests\') -or $p.Contains('\.git\') -or $p.EndsWith('.md')) { continue }
                if ([IO.File]::GetLastWriteTimeUtc($p) -gt $built) { $fresh = $false; break }
            }
            if (-not $fresh) { break }
        }
    }
    if ($fresh) { return $true }
    & $Build
    if ($LASTEXITCODE -ne 0) { return $false }
    [IO.File]::WriteAllText($stamp, $Flags)
    return $true
}

# Where the time of a script goes, section by section (the tests are slow when nobody can see which part is):
#   Section 'name'      ends the section in progress and starts a new one (a section is a stretch of the script, from one call to the next)
#   Show-WrenSections   ends the last one and prints "seconds  section" for the script, longest first, with the total and (when
#                       wrenctl.ps1 is loaded) how many `wren ctl` processes were started and for how long
# When $env:WREN_TIMINGS_FILE names a file (tools\test_all.ps1 sets it), every section is appended to it as "script<TAB>section<TAB>seconds"
# and test_all prints the longest ones at the end of the run (and in the job summary of a GitHub run): the table is there in a CI log too.
$global:WrenSections = New-Object Collections.Generic.List[object]
$global:WrenSectionName = $null
$global:WrenSectionClock = [Diagnostics.Stopwatch]::StartNew()
$global:WrenSectionScript = if ($MyInvocation.PSCommandPath) { [IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath) } else { 'script' }
function Close-WrenSection {
    if ($null -eq $global:WrenSectionName) { return }
    $global:WrenSections.Add([pscustomobject]@{ Section = $global:WrenSectionName; Seconds = [Math]::Round($global:WrenSectionClock.Elapsed.TotalSeconds, 2) })
    $global:WrenSectionName = $null
}
function Section([string]$Name) {
    Close-WrenSection
    $global:WrenSectionName = $Name
    $global:WrenSectionClock.Restart()
}
function Show-WrenSections([string]$Title = '') {
    Close-WrenSection
    if ($global:WrenSections.Count -eq 0) { return }
    $scr = if ($Title) { $Title } else { $global:WrenSectionScript }
    $total = ($global:WrenSections | Measure-Object Seconds -Sum).Sum
    "sections of ${scr}: $([Math]::Round($total, 1)) s in $($global:WrenSections.Count) sections" + $(if ($null -ne $global:WrenCtlCalls) { "; $($global:WrenCtlCalls) wren ctl processes started, $([Math]::Round($global:WrenCtlMs / 1000.0, 1)) s in them" } else { '' })
    foreach ($s in ($global:WrenSections | Sort-Object Seconds -Descending)) { '  {0,7:N2} s  {1}' -f $s.Seconds, $s.Section }
    if ($env:WREN_TIMINGS_FILE) {
        try { [IO.File]::AppendAllText($env:WREN_TIMINGS_FILE, (($global:WrenSections | ForEach-Object { "$scr`t$($_.Section)`t$($_.Seconds)" }) -join "`n") + "`n") } catch { }
    }
    $global:WrenSections.Clear()
}

# No script that sources this file (tests, captures, measurements, the agents' runs) lets a Wren integrate itself with the machine's desktop:
# Setup's offer at the start (setup.odin), the system watcher of the integration (desktop_shell.odin) and the update check (update_check.odin) read this variable. (--desktop-integration=... on the command line still works.)
$env:WREN_DESKTOP_INTEGRATION = 'off'
# ... and none lets itself be taken for the user's Wren, or for another run's: a second start with the same profile hands its addresses to the first and ends
# (src/browser/instance_shell.odin). WREN_SINGLE_INSTANCE=on, set by the one script that checks it (instance_e2e.ps1), turns it back on.
$env:WREN_SINGLE_INSTANCE = 'off'
