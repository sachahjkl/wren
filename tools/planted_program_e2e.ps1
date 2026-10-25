# The programs the browser starts are the system's, by their full path (src\desktop\system_windows.odin, crashtrace): a program of the
# same name in the working directory must not run. The case that was open: after a session that ended without a report (killed, a
# fail-fast), the next start asks `wevtutil.exe` for Windows' record of that end; started by its bare name, CreateProcess looked in
# the working directory first, so a wevtutil.exe beside a document opened from that folder ran with the user's rights.
#   powershell -NoProfile -File tools\planted_program_e2e.ps1 [-Exe build\wren.exe]
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

$tmp = Join-Path ([IO.Path]::GetTempPath()) "planted_program_e2e_$PID"
$trap = Join-Path $tmp 'trap'
$profile_ = Join-Path $tmp 'profile'
$marker = Join-Path $tmp 'planted_ran.txt'
New-Item -ItemType Directory -Force $trap | Out-Null
try {
    # a wevtutil.exe that only leaves a mark
    $src = Join-Path $tmp 'planted'
    New-Item -ItemType Directory -Force $src | Out-Null
    $markerOdin = $marker -replace '\\', '\\'
    Set-Content (Join-Path $src 'main.odin') "package main`nimport `"core:os`"`nmain :: proc() { _ = os.write_entire_file(`"$markerOdin`", transmute([]byte)string(`"ran`")) }"
    odin build $src -file -out:(Join-Path $trap 'wevtutil.exe') | Out-Null
    Check 'the planted wevtutil.exe was built' (Test-Path (Join-Path $trap 'wevtutil.exe'))

    # a session that ends without a report: its process is ended from outside
    $null = Start-Wren -ProfileDir $profile_
    $victim = [int]((Wren-Ctl ping | ConvertFrom-Json).pid)
    Stop-Process -Id $victim -Force
    Remove-Item Env:\WREN_REMOTE -ErrorAction SilentlyContinue

    # the next start, from the folder with the planted program
    Push-Location $trap
    try {
        $null = Start-Wren -ProfileDir $profile_
        $report = $null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 15 -and -not $report) {
            $report = Get-ChildItem (Join-Path $profile_ 'crashes') -Filter 'unclean exit*' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $report) { Start-Sleep -Milliseconds 100 }
        }
        Check 'the next start reports the session that ended without a report' ($null -ne $report)
        Check 'the wevtutil.exe of the working directory did not run' (-not (Test-Path $marker))
        Stop-Wren
    } finally { Pop-Location }
} finally {
    if ($env:WREN_REMOTE) { Stop-Wren }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($script:fail -gt 0) { "$script:fail check(s) failed"; exit 1 }
'planted_program_e2e: all checks passed'
