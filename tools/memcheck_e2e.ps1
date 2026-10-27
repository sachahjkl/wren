# The browser's check build on a real session: several tabs, navigations (JavaScript, images, forms, animations,
# shadow DOM), back / forward / reload (the back/forward cache), closed tabs and their reopening, the command palette,
# about:history and its tree, then a normal exit. The check build (build.bat check -> build\wren_check.exe: every
# allocation tracked, src\base\memory.odin) drives itself from a script (WREN_MEMCHECK_SCRIPT, src\browser\memcheck.odin:
# no keyboard or mouse of the desktop, no lock), writes what is still allocated at exit to the profile's memtrack.txt
# and exits with code 3 when anything is (WREN_MEMTRACK_FAIL=1).
#   powershell -File tools\memcheck_e2e.ps1 [-Exe build\wren_check.exe] [-NoBuild] [-Stacks] [-Out build\memcheck] [-TimeoutSec 600] [-Prefs name=value,...]
# -Stacks records the call stack of every block (slower; the report then names the callers). Its own test server, a
# fresh profile under -Out. Exit code: 0 clean, 1 leaks / bad frees or a failure of the run.
param([string]$Exe = '', [switch]$NoBuild, [switch]$Stacks, [string]$Out = '', [int]$TimeoutSec = 600, [string[]]$Prefs = @())
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
. (Join-Path $PSScriptRoot 'test_env.ps1')
if (-not $Exe) { $Exe = Join-Path $root 'build\wren_check.exe' }
if (-not $Out) { $Out = Join-Path $root 'build\memcheck' }
if (-not $NoBuild -and $Exe -eq (Join-Path $root 'build\wren_check.exe')) {
    # (built unless newer than its sources, and never beside another build of this tree: the other steps of test_all that need it wait here)
    if (-not (Ensure-WrenBuild 'check')) { $global:WrenBuildOutput; 'FAIL building the check build'; exit 1 }
}

# Runs the check build on `$script` (lines; {o} is the test server's origin) with a fresh profile; returns its exit code.
function Invoke-CheckSession($name, [string[]]$script, $statsFile = '', [string[]]$extra = @()) {
    # (no download of the blocker's lists in a session of the check build: one still in flight when the browser exits, or an engine
    # being built from it, is memory left allocated at the exit test, which then depends on how fast the network of the day is)
    $extra = @('--pref', 'blocker.update.enabled=false', '--pref', 'blocker.welcome_toast=false') + $extra
    $dir = Join-Path $Out $name
    $profileDir = Join-Path $dir 'profile'
    if (Test-Path $profileDir) { Get-ChildItem $profileDir -Recurse -File | Remove-Item -Force }
    New-Item -ItemType Directory -Force $profileDir | Out-Null
    $srv = Start-WrenTestServer
    try {
        $scriptFile = Join-Path $dir 'session.txt'
        [IO.File]::WriteAllText($scriptFile, (($script | ForEach-Object { $_.Replace('{o}', $srv.Origin) }) -join "`n") + "`n")
        $env:WREN_MEMCHECK_SCRIPT = $scriptFile
        $env:WREN_MEMTRACK_FAIL = '1'
        $env:WREN_MEMTRACK_STACK = if ($Stacks) { '1' } else { '' }
        $env:WREN_MEMCHECK_STATS = $statsFile
        $p = Start-Process $Exe -ArgumentList (@('--profile', $profileDir) + $extra + @("$($srv.Origin)/site/index.html")) -PassThru
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill(); $p.WaitForExit(5000) | Out-Null; Write-Host "FAIL ${name}: the session did not end in $TimeoutSec s"; return 1 }
        $code = $p.ExitCode
    } finally {
        Stop-WrenTestServer $srv
        foreach ($v in 'WREN_MEMCHECK_SCRIPT', 'WREN_MEMTRACK_FAIL', 'WREN_MEMTRACK_STACK', 'WREN_MEMCHECK_STATS') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
    }
    $report = Join-Path $profileDir 'memtrack.txt'
    if (Test-Path $report) { Get-Content $report | Select-Object -First 80 | Out-Host }
    switch ($code) {
        0 { Write-Host "PASS ${name}: the check build exits clean ($report)" }
        3 { Write-Host "FAIL ${name}: allocations left at exit ($report)" }
        default { Write-Host "FAIL ${name}: the check build ended with code $code" }
    }
    return $code
}

if ($MyInvocation.InvocationName -ne '.') {
    $session = @(
        'load'
        'open {o}/site/js.html'; 'load'
        'open {o}/site/images.html'; 'load'
        'open {o}/site/forms.html'; 'load'
        'open {o}/site/js-dom.html'; 'load'
        'go {o}/site/animations.html'; 'load'; 'frames 20'
        'go {o}/site/mutation.html'; 'load'; 'frames 20'
        'command nav.back'; 'load'
        'command nav.back'; 'load'
        'command nav.forward'; 'load'
        'command nav.reload'; 'load'
        'command tab.close'; 'command tab.close'
        'command tab.reopen_closed'; 'load'
        'command browser.command_palette'; 'frames 10'
        'command browser.history'; 'wait 500'
        'command browser.history_tree'; 'wait 500'
        'command tab.close'
        'open {o}/site/shadow-dom.html'; 'load'
        'open {o}/site/layout.html'; 'load'
        'open about:wren?card=sample'; 'load'; 'frames 60'; 'wait 500'
        'open {o}/site/media.html'; 'load'
        'command tab.duplicate'; 'load'
        'command tab.close'; 'command tab.close'; 'command tab.close'
        'wait 500'
        'quit'
    )
    $code = Invoke-CheckSession 'session' $session '' @($Prefs | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { '--pref'; $_ })
    exit $(if ($code -eq 0) { 0 } else { 1 })
}
