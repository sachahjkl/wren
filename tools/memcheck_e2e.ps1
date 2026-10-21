# The browser's check build on a real session: several tabs, navigations (JavaScript, images, forms, history), back and
# forward, closed tabs and their reopening, the command palette, about:history, then a normal exit. The check build
# (build.bat check -> build\browser_check.exe: every allocation tracked, src\base\memory.odin) writes what is still
# allocated at exit to the profile's memtrack.txt and exits with code 3 when anything is (WREN_MEMTRACK_FAIL=1).
#   powershell -File tools\memcheck_e2e.ps1 [-Exe build\browser_check.exe] [-NoBuild] [-Stacks] [-Out build\memcheck]
# Uses the real desktop through tools\screenshot.ps1 (which takes desktop.lock) and a test server of its own; the
# profile is a fresh folder under -Out. -Stacks records the call stack of every block (slower; the report then names
# the callers). Exit code: 0 clean, 1 leaks / bad frees or a failure of the run.
param([string]$Exe = '', [switch]$NoBuild, [switch]$Stacks, [string]$Out = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
. (Join-Path $PSScriptRoot 'test_env.ps1')
if (-not $Exe) { $Exe = Join-Path $root 'build\browser_check.exe' }
if (-not $Out) { $Out = Join-Path $root 'build\memcheck' }
if (-not $NoBuild) {
    cmd /c "build.bat check" | Out-Host
    if ($LASTEXITCODE) { 'FAIL building the check build'; exit 1 }
}
$profileDir = Join-Path $Out 'profile'
if (Test-Path $profileDir) { Get-ChildItem $profileDir -Recurse -File | Remove-Item -Force }
New-Item -ItemType Directory -Force $profileDir | Out-Null
$report = Join-Path $profileDir 'memtrack.txt'

$srv = Start-WrenTestServer
try {
    $o = $srv.Origin
    $env:WREN_MEMTRACK_FAIL = '1'
    $env:WREN_MEMTRACK_STACK = if ($Stacks) { '1' } else { '' }
    # every step waits long enough for a debug build: the waits only pace the session, nothing is timed
    $steps = @(
        'wait:1500'
        # a second and a third tab: scripts, the DOM from JavaScript, images, forms
        'key:Ctrl+T'; 'wait:300'; "type:$o/site/js.html"; 'key:Enter'; 'wait:2500'
        'key:Ctrl+T'; 'wait:300'; "type:$o/site/images.html"; 'key:Enter'; 'wait:2500'
        "key:Ctrl+T"; 'wait:300'; "type:$o/site/forms.html"; 'key:Enter'; 'wait:2000'
        # navigations in one tab: history, back / forward (the back/forward cache)
        'key:Ctrl+T'; 'wait:300'; "type:$o/site/js-dom.html"; 'key:Enter'; 'wait:2000'
        'key:Ctrl+L'; 'wait:200'; "type:$o/site/animations.html"; 'key:Enter'; 'wait:2000'
        'key:Ctrl+L'; 'wait:200'; "type:$o/site/mutation.html"; 'key:Enter'; 'wait:2000'
        'key:Alt+Left'; 'wait:1500'; 'key:Alt+Left'; 'wait:1500'; 'key:Alt+Right'; 'wait:1500'
        'key:F5'; 'wait:2000'
        # closing tabs, reopening one
        'key:Ctrl+W'; 'wait:800'; 'key:Ctrl+W'; 'wait:800'; 'key:Ctrl+Shift+T'; 'wait:2000'
        # the command palette, about:history
        'key:Ctrl+Shift+P'; 'wait:600'; 'type:hist'; 'wait:600'; 'key:Escape'; 'wait:400'
        'key:Ctrl+H'; 'wait:1500'; 'key:Ctrl+W'; 'wait:800'
        # more pages, then everything closed but one
        'key:Ctrl+T'; 'wait:300'; "type:$o/site/shadow-dom.html"; 'key:Enter'; 'wait:2000'
        'key:Ctrl+T'; 'wait:300'; "type:$o/site/layout.html"; 'key:Enter'; 'wait:2000'
        'key:Ctrl+W'; 'wait:600'; 'key:Ctrl+W'; 'wait:600'; 'key:Ctrl+W'; 'wait:600'
        'quit:180000'
    )
    $shot = Join-Path $Out 'memcheck.png'
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'screenshot.ps1'), '-Exe', $Exe, '-Url', "$o/site/index.html",
        '-Out', $shot, '-WaitMs', '3000', '-Extra', "--profile,$profileDir", '-Actions', ($steps -join ';'))
    powershell @a
    $code = $LASTEXITCODE
} finally { Stop-WrenTestServer $srv; Remove-Item Env:\WREN_MEMTRACK_FAIL -ErrorAction SilentlyContinue }

if (Test-Path $report) { Get-Content $report | Select-Object -First 60 }
switch ($code) {
    0 { "PASS the check build exits clean (report: $report)"; exit 0 }
    3 { "FAIL the check build left allocations at exit (report: $report)"; exit 1 }
    default { "FAIL the check build ended with code $code"; exit 1 }
}
