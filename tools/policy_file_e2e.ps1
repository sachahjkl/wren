# Where the policy file is read from (src\browser\policy_file.odin): beside the executable, or where --policy says; never from the
# working directory (a folder a document was opened from, an archive, a share), where a file planted by someone else would be read
# at the highest layer and lock any preference (security.file_access.policy=all, ...).
#   powershell -NoProfile -File tools\policy_file_e2e.ps1 [-Exe build\wren.exe]
param([string]$Exe = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
. "$PSScriptRoot\wrenctl.ps1"

$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "PASS  $name" } else { "FAIL  $name  $detail"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) "policy_file_e2e_$PID"
$trap = Join-Path $tmp 'trap'      # the working directory, with a policy file in it
$home_ = Join-Path $tmp 'program'  # a copy of the executable, with its own
New-Item -ItemType Directory -Force $trap, $home_ | Out-Null
$copy = Join-Path $home_ 'wren.exe'
Copy-Item $Exe $copy
$script:WrenExe = $copy
function Pref { return (Wren-Ctl pref get security.file_access.policy | Select-Object -First 1) }
try {
    [IO.File]::WriteAllText((Join-Path $trap 'policies.txt'), "wbpolicy 1`nsecurity.file_access.policy`tall`n")
    Push-Location $trap
    try {
        $null = Start-Wren
        Check 'a policies.txt in the working directory is not read' ((Pref) -eq 'own_tree') (Pref)
        Stop-Wren
        [IO.File]::WriteAllText((Join-Path $home_ 'policies.txt'), "wbpolicy 1`nsecurity.file_access.policy`tnone`n")
        $null = Start-Wren
        Check 'the one beside the executable is' ((Pref) -eq 'none') (Pref)
        Stop-Wren
    } finally { Pop-Location }
} finally {
    if ($env:WREN_REMOTE) { Stop-Wren }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($script:fail -gt 0) { "$script:fail check(s) failed"; exit 1 }
'policy_file_e2e: all checks passed'
