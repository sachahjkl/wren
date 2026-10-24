# Drives Wren from PowerShell scripts: `wren ctl` (the client built into wren.exe) with its text output and its exit code.
#
#   . tools\wrenctl.ps1
#   Start-Wren -Size 1280x800 -Dpi 175            # a Wren with a throwaway profile, no window shown; sets $env:WREN_REMOTE
#   Wren-Nav 'http://127.0.0.1:8765/site/'        # waits for the load
#   Wren-Shot out.png                             # from the renderer's frame: covered or hidden is fine
#   Wren-Eval 'document.title'
#   Stop-Wren
#   Wren-Run -Url $u -Shot out.png -Size 1280x800 # the one-call form: start, load, capture, close
#
# Why this file exists: wren.exe is a program without a console window. Started from cmd or PowerShell the plain way it
# gives the prompt back at once (a script sees neither the end nor the exit code) and a redirection into a file needs care.
# The functions start it with the standard handles redirected and wait for it (System.Diagnostics.Process, which is about
# 80 ms quicker than Start-Process and does not spoil the output), then return the text on stdout; the exit code is in
# $global:WrenExit (0 done, 1 failed, 2 timed out, 3 no Wren answers, 4 wrong usage) and the error text in $global:WrenErr.
# The same thing by hand:
#   Start-Process -Wait -NoNewWindow -FilePath build\wren.exe -ArgumentList 'ctl','shot','out.png' -RedirectStandardOutput o.txt
# Exe: build\wren.exe of this tree, or $env:WREN_EXE.

$script:WrenExe = if ($env:WREN_EXE) { $env:WREN_EXE } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'build\wren.exe' }
$global:WrenExit = 0
$global:WrenErr = ''
# how many `wren ctl` processes the script started and how long they took (Show-WrenSections in test_env.ps1 prints them)
$global:WrenCtlCalls = 0
$global:WrenCtlMs = 0

# A path as PowerShell means it (relative to the current location, which is not the process's current folder).
function Resolve-PathHere([string]$p) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p) }

function ConvertTo-WinArg([string]$a) {
    if ($a -ne '' -and $a -notmatch '[\s"]') { return $a }
    $s = $a -replace '(\\*)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return '"' + $s + '"'
}

# Runs `wren ctl <args>`: returns stdout (without the final newline); exit code in $global:WrenExit, stderr in $global:WrenErr.
function Wren-Ctl {
    [CmdletBinding(PositionalBinding = $false)]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CtlArgs, [int]$TimeoutSec = 120)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $script:WrenExe
    $psi.Arguments = (@('ctl') + $CtlArgs | ForEach-Object { ConvertTo-WinArg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = (Get-Location).ProviderPath
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $global:WrenCtlCalls++
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        # (only the process this call started)
        try { $p.Kill() } catch {}
        $global:WrenExit = 2; $global:WrenErr = "wren ctl did not end in $TimeoutSec s"
        $global:WrenCtlMs += $clock.ElapsedMilliseconds
        return ''
    }
    $p.WaitForExit()
    $global:WrenExit = $p.ExitCode
    $global:WrenErr = $errTask.Result.TrimEnd()
    $global:WrenCtlMs += $clock.ElapsedMilliseconds
    return $outTask.Result.TrimEnd("`r", "`n")
}

# Starts a Wren in the background and selects it ($env:WREN_REMOTE); returns its name.
function Start-Wren {
    param([string]$Size = '1280x800', [double]$Dpi = 0, [string]$ProfileDir = '', [switch]$Visible, [string]$Url = '', [string]$Name = '', [string[]]$Pref = @())
    $a = @('start')
    if ($Size) { $a += @('--size', $Size) }
    if ($Dpi -gt 0) { $a += @('--dpi', "$Dpi") }
    if ($ProfileDir) { $a += @('--profile', $ProfileDir) }
    if ($Visible) { $a += '--visible' }
    if ($Name) { $a += @('--name', $Name) }
    foreach ($p in $Pref) { $a += @('--pref', $p) }
    if ($Url) { $a += $Url }
    $name = Wren-Ctl @a
    if ($global:WrenExit -ne 0) { throw "Start-Wren failed ($global:WrenExit): $global:WrenErr" }
    $env:WREN_REMOTE = $name
    return $name
}

function Wren-Nav {
    param([Parameter(Mandatory = $true)][string]$Url, [string]$Wait = 'load')
    $r = Wren-Ctl nav $Url --wait $Wait
    if ($global:WrenExit -ne 0) { throw "Wren-Nav failed ($global:WrenExit): $global:WrenErr" }
    return $r
}

# Capture to a file (a PNG): -Tab the page area, -Selector an element, -Rect 'x,y,w,h', -Scale n.
function Wren-Shot {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Tab, [string]$Selector = '', [string]$Rect = '', [double]$Scale = 0)
    $a = @('shot', (Resolve-PathHere $Path))
    if ($Tab) { $a += '--tab' }
    if ($Selector) { $a += @('--selector', $Selector) }
    if ($Rect) { $a += @('--rect', $Rect) }
    if ($Scale -gt 0) { $a += @('--scale', "$Scale") }
    $r = Wren-Ctl @a
    if ($global:WrenExit -ne 0) { throw "Wren-Shot failed ($global:WrenExit): $global:WrenErr" }
    return $r
}

function Wren-Eval {
    param([Parameter(Mandatory = $true)][string]$Js, [switch]$Await)
    $a = @('eval', $Js)
    if ($Await) { $a += '--await' }
    $r = Wren-Ctl @a
    if ($global:WrenExit -ne 0) { throw "Wren-Eval failed ($global:WrenExit): $global:WrenErr" }
    return $r
}

# The one-call form: start, load, wait, run script, capture, close. Returns stdout; exit code in $global:WrenExit.
function Wren-Run {
    param([string]$Url = '', [string]$Shot = '', [string]$Size = '1280x800', [double]$Dpi = 0, [string]$Wait = 'load', [string]$Eval = '', [string]$ProfileDir = '', [switch]$Visible, [switch]$Timing)
    $a = @('run', '--size', $Size, '--wait', $Wait)
    if ($Dpi -gt 0) { $a += @('--dpi', "$Dpi") }
    if ($Shot) { $a += @('--shot', (Resolve-PathHere $Shot)) }
    if ($Eval) { $a += @('--eval', $Eval) }
    if ($ProfileDir) { $a += @('--profile', $ProfileDir) }
    if ($Visible) { $a += '--visible' }
    if ($Timing) { $a += '--timing' }
    if ($Url) { $a += $Url }
    return Wren-Ctl @a
}

# Closes the Wren Start-Wren made (and removes its throwaway profile).
function Stop-Wren {
    param([string]$Name = $env:WREN_REMOTE)
    if (-not $Name) { return }
    Wren-Ctl stop $Name | Out-Null
    if ($env:WREN_REMOTE -eq $Name) { Remove-Item Env:\WREN_REMOTE -ErrorAction SilentlyContinue }
}
