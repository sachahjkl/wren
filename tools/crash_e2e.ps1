# What leaves a crash report (src/tools/crashtrace) and what does not need to: the test tool src/tools/crashmodes dies in each of the
# ways a Wren has died and the report folder is looked at. An access violation, an Odin assertion, a stack overflow (main thread and
# another one: the handler writes the report from a thread of its own, with stack guaranteed), a corrupted heap (the system ends the
# process without calling the filter: the vectored handler does) leave "crash <date>.txt" and a minidump; a fail-fast (nothing runs
# in the process) leaves a session file that the next start turns into "unclean exit <date>.txt", with Windows' own record of the end.
#   powershell -NoProfile -File tools\crash_e2e.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
[Environment]::CurrentDirectory = $root
odin build src/tools/crashmodes -collection:wb=src -debug -vet -out:build/crashmodes.exe
if ($LASTEXITCODE) { 'FAIL building crashmodes'; exit 1 }
$dir = Join-Path $env:TEMP "wren-crash-e2e-$PID"
New-Item -ItemType Directory -Force $dir | Out-Null
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { "PASS  $name" } else { "FAIL  $name  $detail"; $script:fail++ } }
function Clear-Dir([string]$d) { Get-ChildItem $d -File | ForEach-Object { [IO.File]::Delete($_.FullName) } }
# The modes that die are independent (a folder each); the ones that leave a session file for the next start are a chain (failfast, then two clean
# starts in the same folder). All of them run at once: a process that dies spends its time writing a minidump, not computing.
function Start-Mode([string]$mode, [string]$d) { return Start-Process build\crashmodes.exe -ArgumentList $mode, $d -PassThru -WindowStyle Hidden }
try {
    $cases = @(@('access', 'access violation'), @('assert', 'illegal instruction'), @('overflow', 'stack overflow'),
        @('overflow_thread', 'stack overflow'), @('heap', 'heap corruption'))
    $procs = @{}
    foreach ($case in $cases) {
        $d = Join-Path $dir $case[0]
        New-Item -ItemType Directory -Force $d | Out-Null
        $procs[$case[0]] = Start-Mode $case[0] $d
    }
    $chain = Join-Path $dir 'chain'
    New-Item -ItemType Directory -Force $chain | Out-Null
    $null = (Start-Mode 'failfast' $chain).WaitForExit()
    Check 'failfast: no report (nothing runs), a session file is left' ((@(Get-ChildItem $chain -Filter 'crash *').Count -eq 0) -and (Test-Path (Join-Path $chain 'session.txt')))
    $null = (Start-Mode 'clean' $chain).WaitForExit()
    $unc = @(Get-ChildItem $chain -Filter 'unclean exit *.txt')
    Check 'the next start reports the session that ended without a report' ($unc.Count -eq 1 -and (Get-Content $unc[0].FullName -Raw) -match 'ended without a crash report')
    Check 'a clean end removes the session file' (-not (Test-Path (Join-Path $chain 'session.txt')))
    $null = (Start-Mode 'clean' $chain).WaitForExit()
    Check 'and the start after that finds nothing to report' (@(Get-ChildItem $chain -Filter 'unclean exit *.txt').Count -eq 1)
    foreach ($case in $cases) {
        $p = $procs[$case[0]]
        $p.WaitForExit()
        $d = Join-Path $dir $case[0]
        $txt = @(Get-ChildItem $d -Filter 'crash *.txt')
        $dmp = @(Get-ChildItem $d -Filter 'crash *.dmp')
        $text = if ($txt.Count) { Get-Content $txt[0].FullName -Raw } else { '' }
        Check "$($case[0]): a report with the cause and a stack, and a minidump" ($txt.Count -eq 1 -and $dmp.Count -eq 1 -and $text -match [regex]::Escape($case[1]) -and $text -match '#0[0-3] 0x') "exit $($p.ExitCode), $($txt.Count) report(s), $($dmp.Count) dump(s)"
    }
} finally { foreach ($p in $procs.Values) { if ($p -and -not $p.HasExited) { $p.Kill() } }; Get-ChildItem $dir -Recurse -File | ForEach-Object { [IO.File]::Delete($_.FullName) }; Get-ChildItem $dir -Recurse -Directory | Sort-Object FullName -Descending | ForEach-Object { [IO.Directory]::Delete($_.FullName) }; [IO.Directory]::Delete($dir) }
if ($fail) { "crash_e2e: $fail check(s) failed"; exit 1 }
'crash_e2e: all checks passed'
