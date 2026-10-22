# Drives the Setup dialog of a real wren.exe on a scratch desktop and checks the disk afterwards. Nothing of the real
# desktop is touched: the Start menu, the Desktop, HKCU\Software (Clients, Classes, RegisteredApplications, the Settings > Apps
# record) and HKCU\Environment (PATH) are scratch roots (WREN_DESKTOP_* of src/desktop/cli.odin), the install folder is
# a scratch folder, the profile is a scratch profile. After the run the scratch is deleted and the real Start menu, PATH
# and StartMenuInternet are compared with what they were before.
#   powershell -NoProfile -File tools\setup_e2e.ps1 [-Exe build\wren.exe]
# The clicks are window messages (no foreground window, no real pointer, no keyboard focus needed), at positions of the
# 1280 x 800 window on a 175 % screen (the layout is in em: another scale needs other positions, see $Pos).
# Scenarios: A install with Enter (the main button has the keyboard); B uninstall from the installed copy (two clicks, the
# running executable is deleted once the process has ended); C "Use standalone" (remembered in the profile); D the
# automatic opening at the first start (and not again after the answer); E nothing opens by itself with
# WREN_DESKTOP_INTEGRATION=off, with --profile, in a portable copy.
param([string]$Exe = '', [int]$LockTimeoutSec = 600)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'test_env.ps1')   # (sets WREN_DESKTOP_INTEGRATION=off: scenario D unsets it for its own runs)
$desktopLock = Enter-WrenLock desktop 'setup_e2e.ps1' $LockTimeoutSec   # the windows it opens take the focus: the screen is shared
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$Exe = (Resolve-Path $Exe).Path
Add-Type @"
using System; using System.Runtime.InteropServices;
public class SE {
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
}
"@
[SE]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

$id = 'e' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$scratch = Join-Path $root "build\tmp\setup_e2e_$id"
$regRoot = "Software\WrenSetupTest\$id"
New-Item -ItemType Directory -Force "$scratch\StartMenu", "$scratch\Desktop", "$scratch\profile" | Out-Null
$installDir = "$scratch\Programs\Wren Dev"
$installed = "$installDir\wren.exe"
$failures = New-Object Collections.Generic.List[string]
function Check($ok, $what) { if ($ok) { "  ok   $what" } else { "  FAIL $what"; $failures.Add($what) } }

# what the real machine has now (compared at the end)
function Real-State {
    $env0 = (Get-ItemProperty 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path
    $menu = (Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" -Filter 'Wren*.lnk' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ','
    $smi = (Get-ChildItem 'HKCU:\Software\Clients\StartMenuInternet' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Wren*' } | ForEach-Object { $_.PSChildName }) -join ','
    $apps = (Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Wren*' } | ForEach-Object { $_.PSChildName }) -join ','
    "path=$env0|menu=$menu|smi=$smi|apps=$apps"
}
$before = Real-State

$scratchVars = @{
    WREN_DESKTOP_MENU_DIR = "$scratch\StartMenu"; WREN_DESKTOP_DESKTOP_DIR = "$scratch\Desktop"
    WREN_DESKTOP_REGISTRY_ROOT = $regRoot; WREN_DESKTOP_ENVIRONMENT_ROOT = "$regRoot\Environment"
    WREN_DESKTOP_INSTALL_DIR = $installDir
}
function Start-Wren([string]$exe, [string[]]$wrenArgs, [hashtable]$extraEnv = @{}, [string[]]$unset = @()) {
    $saved = @{}
    $all = $scratchVars.Clone(); foreach ($k in $extraEnv.Keys) { $all[$k] = $extraEnv[$k] }
    foreach ($k in $all.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $all[$k]) }
    foreach ($k in $unset) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $null) }
    try { $p = Start-Process $exe -ArgumentList $wrenArgs -PassThru } finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $p.MainWindowHandle -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 50; $p.Refresh() }
    if ($p.HasExited) { throw "wren exited at once (code $($p.ExitCode))" }
    [SE]::SetWindowPos($p.MainWindowHandle, [IntPtr]::Zero, 40, 40, 1280, 800, 0x14) | Out-Null   # no z-order change, no activation
    return $p
}
function Click($p, [int]$x, [int]$y) {
    $h = $p.MainWindowHandle
    $r = New-Object SE+RECT
    if ([SE]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [SE]::GetWindowRect($h, [ref]$r) | Out-Null }
    $pt = New-Object SE+POINT; $pt.X = $r.L + $x; $pt.Y = $r.T + $y
    [SE]::ScreenToClient($h, [ref]$pt) | Out-Null
    $lp = [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))
    [SE]::PostMessage($h, 0x0200, [IntPtr]::Zero, $lp) | Out-Null; Start-Sleep -Milliseconds 120
    [SE]::PostMessage($h, 0x0201, [IntPtr]1, $lp) | Out-Null; Start-Sleep -Milliseconds 80
    [SE]::PostMessage($h, 0x0202, [IntPtr]::Zero, $lp) | Out-Null; Start-Sleep -Milliseconds 300
}
function Key($p, [int]$vk) {
    $h = $p.MainWindowHandle
    [SE]::PostMessage($h, 0x0100, [IntPtr]$vk, [IntPtr]1) | Out-Null; Start-Sleep -Milliseconds 60
    [SE]::PostMessage($h, 0x0101, [IntPtr]$vk, [IntPtr]0xC0000001) | Out-Null; Start-Sleep -Milliseconds 400
}
function Close-Wren($p) {
    if ($p.HasExited) { return }
    [SE]::PostMessage($p.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null   # WM_CLOSE
    if (-not $p.WaitForExit(20000)) { Stop-Process -Id $p.Id -Force; "  (had to be killed)" }
}
$Enter = 0x0D; $Escape = 0x1B
$Pos = @{ Install = @(762, 693); Uninstall = @(182, 693); Confirm = @(182, 733); Secondary = @(1040, 693) }   # (1280 x 800 window, 175 %)

try {
    $profile = "$scratch\profile"
    "A. install: Enter on the main button"
    $p = Start-Wren $Exe @('--profile', $profile, '--setup')
    Start-Sleep -Milliseconds 3000
    Key $p $Enter
    Start-Sleep -Milliseconds 3500
    Check (Test-Path $installed) 'wren.exe is in the install folder'
    Check (Test-Path "$installDir\wren_install.txt") 'the manifest is written'
    Check (Test-Path "$scratch\StartMenu\Wren Dev.lnk") 'the Start menu shortcut exists'
    Check (Test-Path "HKCU:\$regRoot\Clients\StartMenuInternet\WrenDev") 'registered as a browser (scratch key)'
    Check (Test-Path "HKCU:\$regRoot\Microsoft\Windows\CurrentVersion\Uninstall\WrenDev") 'the Settings > Apps record exists (scratch key)'
    Check (-not (Test-Path "$scratch\Desktop\Wren Dev.lnk")) 'no desktop shortcut (not ticked)'
    Close-Wren $p

    "B. uninstall from the installed copy"
    $p = Start-Wren $installed @('--profile', $profile, '--setup')
    Start-Sleep -Milliseconds 3000
    Click $p $Pos.Uninstall[0] $Pos.Uninstall[1]
    Check (Test-Path $installed) 'the first click only asks'
    Click $p $Pos.Confirm[0] $Pos.Confirm[1]
    Start-Sleep -Milliseconds 2500
    Check (-not (Test-Path "$scratch\StartMenu\Wren Dev.lnk")) 'the Start menu shortcut is gone'
    Check (-not (Test-Path "HKCU:\$regRoot\Clients\StartMenuInternet\WrenDev")) 'the browser registration is gone'
    Check (-not (Test-Path "HKCU:\$regRoot\Microsoft\Windows\CurrentVersion\Uninstall\WrenDev")) 'the Settings > Apps record is gone'
    Check (-not (Test-Path "$installDir\wren_install.txt") -or (Test-Path "$installDir\wren.exe.old")) 'the running copy is out of the way (renamed), the rest is gone'
    Close-Wren $p
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ((Test-Path $installDir) -and $sw.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 300 }
    Check (-not (Test-Path $installDir)) "the install folder is deleted after the process ended ($([int]$sw.Elapsed.TotalSeconds) s)"
    if (Test-Path $installDir) { '    left: ' + ((Get-ChildItem $installDir -Force | ForEach-Object { $_.Name }) -join ', '); Get-ChildItem $env:TEMP -Filter 'wren_cleanup_*.cmd' | ForEach-Object { '    helper script still there: ' + $_.Name } }
    Check (-not (Get-ChildItem $env:TEMP -Filter 'wren_cleanup_*.cmd' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-2) })) 'the helper batch file deleted itself'

    "C. Use standalone"
    $p = Start-Wren $Exe @('--profile', $profile, '--setup')
    Start-Sleep -Milliseconds 3000
    Click $p $Pos.Secondary[0] $Pos.Secondary[1]
    Start-Sleep -Milliseconds 600
    $choice = if (Test-Path "$profile\setup.txt") { Get-Content "$profile\setup.txt" -Raw } else { '' }
    Check ($choice -match 'choice=standalone') 'setup.txt says standalone'
    Close-Wren $p
    Remove-Item "$profile\setup.txt" -ErrorAction SilentlyContinue

    "D. the first start opens it by itself, once"
    # a profile outside the temporary folder, found through APPDATA (not --profile: that never offers anything)
    $appdata = "$scratch\appdata"; New-Item -ItemType Directory -Force $appdata | Out-Null
    $first = @{ APPDATA = $appdata }
    $p = Start-Wren $Exe @('--pref', 'browser.desktop_integration.on_first_run=true') $first @('WREN_DESKTOP_INTEGRATION')
    Start-Sleep -Milliseconds 3500
    Key $p $Escape
    Start-Sleep -Milliseconds 500
    $choice = if (Test-Path "$appdata\Wren\setup.txt") { Get-Content "$appdata\Wren\setup.txt" -Raw } else { '' }
    Check ($choice -match 'choice=dismissed') 'it opened, and Escape was remembered as "dismissed"'
    Close-Wren $p
    Remove-Item "$appdata\Wren\setup.txt" -ErrorAction SilentlyContinue
    # answered "standalone": not again
    Set-Content "$appdata\Wren\setup.txt" "choice=standalone`nversion=0.0.1`n" -Encoding ASCII
    $p = Start-Wren $Exe @('--pref', 'browser.desktop_integration.on_first_run=true') $first @('WREN_DESKTOP_INTEGRATION')
    Start-Sleep -Milliseconds 3500
    Key $p $Escape
    Close-Wren $p
    $choice = Get-Content "$appdata\Wren\setup.txt" -Raw
    Check ($choice -match 'choice=standalone' -and $choice -notmatch 'dismissed') 'after "standalone" it does not open (Escape wrote nothing)'

    "E. never by itself: WREN_DESKTOP_INTEGRATION=off, --profile, a portable copy"
    Remove-Item "$appdata\Wren\setup.txt" -ErrorAction SilentlyContinue
    foreach ($case in @(
        @{ Name = 'WREN_DESKTOP_INTEGRATION=off'; Args = @('--pref', 'browser.desktop_integration.on_first_run=true'); Env = @{ APPDATA = $appdata; WREN_DESKTOP_INTEGRATION = 'off' }; File = "$appdata\Wren\setup.txt" },
        @{ Name = '--profile'; Args = @('--profile', "$scratch\profile2", '--pref', 'browser.desktop_integration.on_first_run=true'); Env = @{ APPDATA = $appdata }; File = "$scratch\profile2\setup.txt" })) {
        $unset = if ($case.Env.ContainsKey('WREN_DESKTOP_INTEGRATION')) { @() } else { @('WREN_DESKTOP_INTEGRATION') }
        $p = Start-Wren $Exe $case.Args $case.Env $unset
        Start-Sleep -Milliseconds 3500
        Key $p $Escape
        Close-Wren $p
        Check (-not (Test-Path $case.File)) "$($case.Name): the dialog did not open (Escape wrote nothing)"
    }
    $portableDir = "$scratch\portable"; New-Item -ItemType Directory -Force $portableDir | Out-Null
    Copy-Item $Exe "$portableDir\wren.exe"; Set-Content "$portableDir\wren.portable" '' -Encoding ASCII
    $appdata2 = "$scratch\appdata2"; New-Item -ItemType Directory -Force $appdata2 | Out-Null
    $p = Start-Wren "$portableDir\wren.exe" @('--pref', 'browser.desktop_integration.on_first_run=true') @{ APPDATA = $appdata2 } @('WREN_DESKTOP_INTEGRATION')
    Start-Sleep -Milliseconds 3500
    Key $p $Escape
    Close-Wren $p
    Check (-not (Test-Path "$portableDir\data\setup.txt")) 'a portable copy: the dialog did not open'
    Check (Test-Path "$portableDir\data") 'a portable copy keeps its profile in <folder>\data'
    Check (-not (Test-Path "$appdata2\Wren")) 'a portable copy wrote nothing to %APPDATA%'
}
finally {
    Exit-WrenLock $desktopLock
    Get-Process wren -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($scratch, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Stop-Process -Id $_.Id -Force }
    Start-Sleep -Milliseconds 500
    Remove-Item "HKCU:\$regRoot" -Recurse -ErrorAction SilentlyContinue
    if ((Get-ChildItem 'HKCU:\Software\WrenSetupTest' -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) { Remove-Item 'HKCU:\Software\WrenSetupTest' -ErrorAction SilentlyContinue }
    if (Test-Path $scratch) { [IO.Directory]::Delete($scratch, $true) }   # (a plain folder tree: no junction inside)
}
$after = Real-State
Check ($after -eq $before) 'nothing leaked into the real Start menu, PATH, StartMenuInternet or Settings > Apps'
if ($after -ne $before) { "  before: $before"; "  after:  $after" }
if ($failures.Count) { "FAILED: $($failures.Count)"; exit 1 }
"all scenarios passed"
