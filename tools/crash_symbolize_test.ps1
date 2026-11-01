# tools\crash_symbolize.ps1 and tools\symbols.ps1 on a release's crash: the test tool src/tools/crashmodes built as a release is (no PDB, a map named by the
# build's fingerprint) indexes out of range; the report says which build and where it was loaded, the frames of the program are offsets in it, and the map
# names them: the function that indexed out of range, under main. A report from before the "build" line is named through the minidump beside it.
# (What leaves a report: src\tools\e2e\crash_reports.odin. This tests two scripts, so it stays a script.)
#   powershell -NoProfile -File tools\crash_symbolize_test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
[Environment]::CurrentDirectory = $root
odin build src/tools/crashmodes -collection:wb=src -o:speed -vet -out:build/crashmodes_rel.exe -extra-linker-flags:/MAP
if ($LASTEXITCODE) { 'FAIL building crashmodes as a release'; exit 1 }
$published = powershell -NoProfile -ExecutionPolicy Bypass -File tools\symbols.ps1 -Publish build\crashmodes_rel.exe
if ($LASTEXITCODE) { "FAIL naming the symbols of crashmodes_rel: $published"; exit 1 }
$relFp = powershell -NoProfile -ExecutionPolicy Bypass -File tools\symbols.ps1 -Fingerprint build\crashmodes_rel.exe
$dir = Join-Path $env:TEMP "wren-crash-symbolize-$PID"
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { "PASS  $name" } else { "FAIL  $name  $detail"; $script:fail++ } }
New-Item -ItemType Directory -Force $dir | Out-Null
try {
    $p = Start-Process build\crashmodes_rel.exe -ArgumentList 'bounds', $dir -PassThru -WindowStyle Hidden
    $null = $p.WaitForExit()
    $txt = @(Get-ChildItem $dir -Filter 'crash *.txt')
    $text = if ($txt.Count) { [IO.File]::ReadAllText($txt[0].FullName) } else { '' }
    Check 'the report gives the build''s fingerprint and base, and module offsets' ($text -match "build crashmodes_rel\.exe $relFp, base 0x[0-9A-F]+, size 0x" -and $text -match '\[crashmodes_rel\.exe\+0x[0-9A-F]+\]') $text
    if ($txt.Count) {
        $named = powershell -NoProfile -ExecutionPolicy Bypass -File tools\crash_symbolize.ps1 $txt[0].FullName | Out-String
        Check 'crash_symbolize.ps1 names the frames from the map (index_out_of_range, under main)' ($named -match '(?s)runtime\.bounds_trap.*crashmodes\.index_out_of_range\+0x[0-9A-F]+.*\bmain\+0x') $named
        $old = Join-Path $dir 'old'
        New-Item -ItemType Directory -Force $old | Out-Null
        [IO.File]::WriteAllText("$old\crash old.txt", (($text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*build ' }) -join "`r`n"))
        Copy-Item ([IO.Path]::ChangeExtension($txt[0].FullName, '.dmp')) "$old\crash old.dmp"
        $named = powershell -NoProfile -ExecutionPolicy Bypass -File tools\crash_symbolize.ps1 "$old\crash old.txt" -Symbols build | Out-String
        Check 'a report without the build line is named through its minidump' ($named -match 'come from the minidump' -and $named -match 'crashmodes\.index_out_of_range\+0x') $named
    }
} finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
if ($fail) { "crash_symbolize_test: $fail check(s) failed"; exit 1 }
'crash_symbolize_test: all checks passed'
