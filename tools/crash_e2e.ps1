# What leaves a crash report (src/tools/crashtrace) and what does not need to: the test tool src/tools/crashmodes dies in each of the
# ways a Wren has died and the report folder is looked at. An access violation, an Odin assertion, a stack overflow (main thread and
# another one: the handler writes the report from a thread of its own, with stack guaranteed), a corrupted heap (the system ends the
# process without calling the filter: the vectored handler does) leave "crash <date>.txt" and a minidump; a fail-fast (nothing runs
# in the process) leaves a session file that the next start turns into "unclean exit <date>.txt", with Windows' own record of the end.
# An index out of range in the tool built as a release (no PDB, a map: tools\symbols.ps1) is named by tools\crash_symbolize.ps1.
#   powershell -NoProfile -File tools\crash_e2e.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
[Environment]::CurrentDirectory = $root
odin build src/tools/crashmodes -collection:wb=src -debug -vet -out:build/crashmodes.exe
if ($LASTEXITCODE) { 'FAIL building crashmodes'; exit 1 }
# the same tool built as a release is: no -debug (no PDB: the report names none of its functions), the linker's map named by the
# build's fingerprint (tools\symbols.ps1), from which tools\crash_symbolize.ps1 names the frames
odin build src/tools/crashmodes -collection:wb=src -o:speed -vet -out:build/crashmodes_rel.exe -extra-linker-flags:/MAP
if ($LASTEXITCODE) { 'FAIL building crashmodes as a release'; exit 1 }
$published = powershell -NoProfile -ExecutionPolicy Bypass -File tools\symbols.ps1 -Publish build\crashmodes_rel.exe
if ($LASTEXITCODE) { "FAIL naming the symbols of crashmodes_rel: $published"; exit 1 }
$relFp = powershell -NoProfile -ExecutionPolicy Bypass -File tools\symbols.ps1 -Fingerprint build\crashmodes_rel.exe
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
    $bounds = Join-Path $dir 'bounds'
    New-Item -ItemType Directory -Force $bounds | Out-Null
    $procs['bounds'] = Start-Process build\crashmodes_rel.exe -ArgumentList 'bounds', $bounds -PassThru -WindowStyle Hidden
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

    # a release's crash: the report says which build and where it was loaded, the frames of the program are offsets in it, and the
    # build's map names them: the function that indexed out of range, under main
    $null = $procs['bounds'].WaitForExit(60000)
    $txt = @(Get-ChildItem $bounds -Filter 'crash *.txt')
    $text = if ($txt.Count) { [IO.File]::ReadAllText($txt[0].FullName) } else { '' }
    Check 'bounds (a release): the report gives the build''s fingerprint and base, and module offsets' ($text -match "build crashmodes_rel\.exe $relFp, base 0x[0-9A-F]+, size 0x" -and $text -match '\[crashmodes_rel\.exe\+0x[0-9A-F]+\]') $text
    if ($txt.Count) {
        $named = powershell -NoProfile -ExecutionPolicy Bypass -File tools\crash_symbolize.ps1 $txt[0].FullName | Out-String
        Check 'bounds: tools\crash_symbolize.ps1 names the frames from the map (index_out_of_range, under main)' ($named -match '(?s)runtime\.bounds_trap.*crashmodes\.index_out_of_range\+0x[0-9A-F]+.*\bmain\+0x') $named
        # a report from before the "build" line: the minidump beside it gives the base and the fingerprint
        $old = Join-Path $bounds 'old'
        New-Item -ItemType Directory -Force $old | Out-Null
        [IO.File]::WriteAllText("$old\crash old.txt", (($text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*build ' }) -join "`r`n"))
        Copy-Item ([IO.Path]::ChangeExtension($txt[0].FullName, '.dmp')) "$old\crash old.dmp"
        $named = powershell -NoProfile -ExecutionPolicy Bypass -File tools\crash_symbolize.ps1 "$old\crash old.txt" -Symbols build | Out-String
        Check 'bounds: a report without the build line is named through its minidump' ($named -match 'come from the minidump' -and $named -match 'crashmodes\.index_out_of_range\+0x') $named
    }
} finally { foreach ($p in $procs.Values) { if ($p -and -not $p.HasExited) { $p.Kill() } }; Get-ChildItem $dir -Recurse -File | ForEach-Object { [IO.File]::Delete($_.FullName) }; Get-ChildItem $dir -Recurse -Directory | Sort-Object FullName -Descending | ForEach-Object { [IO.Directory]::Delete($_.FullName) }; [IO.Directory]::Delete($dir) }
if ($fail) { "crash_e2e: $fail check(s) failed"; exit 1 }
'crash_e2e: all checks passed'
