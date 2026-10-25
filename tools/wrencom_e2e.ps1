# wren.com, the console launcher (src\tools\wrencom): from a terminal `wren ctl ...` gives its output and its exit code to the caller
# (redirections and pipes included), an address or an option of the window lets go at once, the launcher dies with its child and
# refuses to start itself; and Setup (package desktop) writes it beside wren.exe with the PATH entry and takes it away with it.
# Everything happens in a scratch folder with scratch desktop roots (WREN_DESKTOP_* of src\desktop\cli.odin); only the Wren this
# script starts is ever stopped.
#   powershell -NoProfile -File tools\wrencom_e2e.ps1 [-Exe build\wren.exe] [-Com build\wren.com]
param([string]$Exe = '', [string]$Com = '')
$ErrorActionPreference = 'Continue'   # (not Stop: Windows PowerShell 5.1 makes an error of any line a program writes to stderr under 2>&1)
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'test_env.ps1')   # (WREN_DESKTOP_INTEGRATION=off: no Setup dialog in the Wren started below)
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
if (-not $Com) { $Com = Join-Path $root 'build\wren.com' }
$Exe = (Resolve-Path $Exe).Path; $Com = (Resolve-Path $Com).Path

$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "PASS  $name" } else { "FAIL  $name  $detail"; $script:fail++ }
}
function Wait-Until([scriptblock]$Test, [double]$Seconds = 15) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) { if (& $Test) { return $true }; Start-Sleep -Milliseconds 50 }
    return [bool](& $Test)
}
function Lf([string]$s) { return $s.Replace("`r`n", "`n") }
# wren.exe has no console: PowerShell's & does not wait for it. This does, and gives its output and its code.
function Run-Exe([string]$exe, [string[]]$exeArgs) {
    $f = Join-Path $tmp ("run_{0}.txt" -f [guid]::NewGuid().ToString('N').Substring(0, 6))
    $p = Start-Process $exe -ArgumentList $exeArgs -Wait -NoNewWindow -PassThru -RedirectStandardOutput $f
    $text = if (Test-Path $f) { [IO.File]::ReadAllText($f) } else { '' }
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text }
}

$id = 'c' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$tmp = Join-Path $root "build\tmp\wrencom_e2e_$id"
$app = Join-Path $tmp 'app'          # wren.exe and wren.com side by side, as Setup leaves them
$bare = Join-Path $tmp 'bare'        # wren.exe alone: what the integration starts from
$lone = Join-Path $tmp 'lone'        # wren.com without a wren.exe
$regRoot = "Software\WrenComE2E\$id"
New-Item -ItemType Directory -Force $app, $bare, $lone, "$tmp\profile", "$tmp\StartMenu", "$tmp\Desktop" | Out-Null
Copy-Item $Exe, $Com $app
Copy-Item $Exe $bare
Copy-Item $Com $lone
$ownExe = Join-Path $app 'wren.exe'
$started = New-Object Collections.Generic.List[int]   # the processes this script started: the only ones it ever stops
$roots = [ordered]@{
    WREN_DESKTOP_MENU_DIR = "$tmp\StartMenu"; WREN_DESKTOP_DESKTOP_DIR = "$tmp\Desktop"; WREN_DESKTOP_REGISTRY_ROOT = $regRoot
    WREN_DESKTOP_ENVIRONMENT_ROOT = "$regRoot\Environment"; WREN_DESKTOP_INSTALL_DIR = "$tmp\installed"
}
foreach ($k in $roots.Keys) { [Environment]::SetEnvironmentVariable($k, $roots[$k]) }
try {
    Push-Location $app
    try {
        # --- a console command: output, exit code, redirections, pipes
        $out = (& .\wren.com ctl help | Out-String); $code = $LASTEXITCODE
        Check 'ctl help: exit code 0' ($code -eq 0) "code $code"
        Check 'ctl help: the text is on the standard output' ($out -match 'drives a running Wren' -and $out -match '(?m)^\s+run\s') $out
        $out = (& .\wren.com ctl help ping | Out-String)
        Check 'ctl help <command>: the text of that command' ($out -match 'wren ctl ping') $out

        $bad = (& .\wren.com ctl nosuchcommand 2>&1 | Out-String); $code = $LASTEXITCODE
        Check 'ctl <unknown command>: its exit code (4, usage) reaches the caller' ($code -eq 4) "code $code"
        Check 'ctl <unknown command>: the message is on the error output' ($bad -match 'unknown command') $bad

        $help = Lf (& .\wren.com ctl help | Out-String)
        cmd /c ".\wren.com ctl help > out.txt"
        Check '> file: the file holds what the command printed' ((Lf ([IO.File]::ReadAllText("$app\out.txt"))).TrimEnd() -eq $help.TrimEnd())
        cmd /c ".\wren.com ctl nosuchcommand > o.txt 2> e.txt"
        Check '2> file: the error output goes to its own file, the standard output stays empty' ((Get-Item "$app\o.txt").Length -eq 0 -and ([IO.File]::ReadAllText("$app\e.txt")) -match 'unknown command')
        $both = cmd /c ".\wren.com ctl nosuchcommand 2>&1" | Out-String
        Check '2>&1: the error message comes through the standard output' ($both -match 'unknown command') $both
        $piped = cmd /c ".\wren.com ctl help | findstr /c:`"drives a running`""
        Check '| findstr: a pipe is read by the next program' ("$piped" -match 'drives a running Wren') "$piped"
        cmd /c ".\wren.com ctl nosuchcommand >nul 2>&1"
        Check 'cmd: %ERRORLEVEL% is the command''s (4)' ($LASTEXITCODE -eq 4) "code $LASTEXITCODE"
        $nc = (& .\wren.com ctl ping --remote "nosuchwren_$id" 2>&1 | Out-String); $code = $LASTEXITCODE
        Check 'ctl with no Wren to answer: exit code 3' ($code -eq 3) "code $code $nc"

        # --- the integration flag is a console command as well
        $st = (& .\wren.com --desktop-integration=status 2>&1 | Out-String); $code = $LASTEXITCODE
        Check '--desktop-integration=status through the launcher: waits, prints, code 1 (absent)' ($code -eq 1 -and $st -match 'absent') "code $code $st"
    } finally { Pop-Location }

    # --- Setup's side: the launcher goes with the PATH entry, beside wren.exe and nowhere else
    $b = Join-Path $bare 'wren.exe'
    $on = @('--profile', "$tmp\profile", '--pref', 'browser.desktop_integration.add_to_path=true')
    $off = @('--profile', "$tmp\profile", '--pref', 'browser.desktop_integration.add_to_path=false')
    $r = Run-Exe $b ($off + '--desktop-integration=install')
    Check 'integration without the PATH option: no wren.com' ($r.Code -eq 0 -and -not (Test-Path "$bare\wren.com")) "code $($r.Code) $($r.Text)"
    $r = Run-Exe $b ($on + '--desktop-integration=install')
    Check 'integration with the PATH option: wren.com is written beside wren.exe' ($r.Code -eq 0 -and (Test-Path "$bare\wren.com")) "code $($r.Code) $($r.Text)"
    Check '... and it is the launcher build.bat made, embedded in wren.exe' ((Get-FileHash "$bare\wren.com").Hash -eq (Get-FileHash $Com).Hash)
    $r = Run-Exe $b ($on + '--desktop-integration=status')
    Check 'the status is complete with it' ($r.Code -eq 0 -and $r.Text -match '^installed') "code $($r.Code) $($r.Text)"
    Remove-Item "$bare\wren.com"
    $r = Run-Exe $b ($on + '--desktop-integration=status')
    Check 'the status says to repair without it' ($r.Code -eq 2 -and $r.Text -match 'to repair') "code $($r.Code) $($r.Text)"
    $null = Run-Exe $b ($on + '--desktop-integration=install')
    Check 'installing again puts it back' (Test-Path "$bare\wren.com")
    $null = Run-Exe $b ($off + '--desktop-integration=install')
    Check 'the PATH option unticked: wren.com goes' (-not (Test-Path "$bare\wren.com"))
    $null = Run-Exe $b ($on + '--desktop-integration=install')
    $null = Run-Exe $b ($on + '--desktop-integration=remove')
    Check 'removing the integration: wren.com goes' (-not (Test-Path "$bare\wren.com"))
    [IO.File]::WriteAllText("$bare\wren.com", 'somebody else''s program')
    $r = Run-Exe $b ($on + '--desktop-integration=install')
    $null = Run-Exe $b ($on + '--desktop-integration=remove')
    Check 'a wren.com that is not the launcher is neither replaced nor deleted' ([IO.File]::ReadAllText("$bare\wren.com") -eq 'somebody else''s program') "code $($r.Code) $($r.Text)"

    # --- the launcher on its own
    $copyAsExe = Join-Path $tmp 'selfstart.exe'
    Copy-Item $Com $copyAsExe
    $r = (& $copyAsExe ctl help 2>&1 | Out-String); $code = $LASTEXITCODE
    Check 'named .exe it would start itself: refused (126)' ($code -eq 126 -and $r -match 'would\s+start\s+itself') "code $code $r"
    $r = (& "$lone\wren.com" ctl help 2>&1 | Out-String); $code = $LASTEXITCODE
    Check 'without a wren.exe beside it: says so (127)' ($code -eq 127 -and $r -match 'no .*wren\.exe') "code $code $r"

    # --- an interface start lets go; the Wren it started answers; it ends with `ctl quit`
    Push-Location $app
    try {
        $name = "wrencom_$id"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & .\wren.com --headless --no-single-instance --profile "$tmp\profile_gui" "--remote=$name" about:blank
        $code = $LASTEXITCODE; $ms = $sw.ElapsedMilliseconds
        Check 'window options: the launcher returns at once with code 0 (it does not wait for the window)' ($code -eq 0 -and $ms -lt 10000) "code $code after $ms ms"
        $up = Wait-Until { $null = (& .\wren.com ctl ping --remote $name 2>&1 | Out-String); $LASTEXITCODE -eq 0 } 30
        Check '... and the Wren it started is alive and answers through the launcher' $up
        $gui = @(Get-CimInstance Win32_Process -Filter "Name='wren.exe'" | Where-Object { $_.ExecutablePath -eq $ownExe })
        foreach ($g in $gui) { $started.Add([int]$g.ProcessId) }
        $q = (& .\wren.com ctl quit --remote $name 2>&1 | Out-String)
        Check 'ctl quit through the launcher: Wren has closed' ($gui.Count -eq 1 -and (Wait-Until { -not (Get-Process -Id $gui[0].ProcessId -ErrorAction SilentlyContinue) } 15)) $q
    } finally { Pop-Location }

    # --- --cli waits for anything, and the launcher's death takes its child along (the job object)
    $p = Start-Process "$app\wren.com" -ArgumentList '--cli', '--headless', '--no-single-instance', '--profile', "$tmp\profile_job", 'about:blank' -PassThru -WindowStyle Hidden
    $started.Add($p.Id)
    $script:child = $null
    $found = Wait-Until { $script:child = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.Id)" | Where-Object { $_.Name -eq 'wren.exe' } | Select-Object -First 1; [bool]$script:child } 20
    Check '--cli: the launcher waits (still there) while the Wren it started runs' ($found -and -not $p.HasExited)
    if ($script:child) {
        $started.Add([int]$script:child.ProcessId)
        Stop-Process -Id $p.Id -Force
        Check 'killing the launcher kills the Wren it started' (Wait-Until { -not (Get-Process -Id $script:child.ProcessId -ErrorAction SilentlyContinue) } 15)
    }
} finally {
    foreach ($procId in $started) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }   # (only what this script started; normally already gone)
    foreach ($k in $roots.Keys) { [Environment]::SetEnvironmentVariable($k, $null) }
    Remove-Item -Recurse -Force "HKCU:\$regRoot" -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem 'HKCU:\Software\WrenComE2E' -ErrorAction SilentlyContinue)) { Remove-Item 'HKCU:\Software\WrenComE2E' -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($script:fail -gt 0) { "$script:fail check(s) failed"; exit 1 }
'wrencom_e2e: all checks passed'
