# Who chose the address of a navigation (src\browser\nav_trust.odin), end to end: a Wren with a throwaway profile and no window
# shown. A web page asks, by script, for the addresses a web page must never reach (about:sites?clear=..., a file of this
# computer, a share through UNC); the navigation is refused, and what is left of it (the tab's address, the history entry)
# must not turn into an order the next F5, reload or Back obeys. The same addresses typed by the person (the address bar,
# `wren ctl nav`) still work, and the page of the browser that offers them (about:sites) still acts through its own links.
#   powershell -NoProfile -File tools\nav_trust_e2e.ps1 [-Exe build\wren.exe]
param([string]$Exe = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\test_env.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
. "$PSScriptRoot\wrenctl.ps1"

$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "PASS  $name" } else { "FAIL  $name  $detail"; $script:fail++ }
}
# The address of the current tab (`wren ctl tabs`: "1* title  address").
function Tab-Url { $line = (Wren-Ctl tabs | Select-Object -First 1); return ($line -split '\s+')[-1] }
# Waits (at most $Seconds) until $Test returns true.
function Wait-Until([scriptblock]$Test, [double]$Seconds = 8) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) { if (& $Test) { return $true }; Start-Sleep -Milliseconds 50 }
    return $false
}
function Stored { return (Wren-Eval 'String(localStorage.getItem("nav_trust"))') }

$secret = Join-Path $env:TEMP "nav_trust_$PID.html"
Set-Content -Path $secret -Value '<title>LOCAL-SECRET</title>local secret' -Encoding ASCII
$secretUrl = 'file:///' + ($secret -replace '\\', '/')
$server = Start-WrenTestServer
try {
    $page = "$($server.Origin)/site/remote/fixture.htm"
    $null = Start-Wren
    $null = Wren-Nav $page
    $null = Wren-Eval 'localStorage.setItem("nav_trust", "kept")'
    Check 'the data is there to begin with' ((Stored) -eq 'kept') "got $(Stored)"

    # --- a page asks for about:sites?clear=*&type=all
    $null = Wren-Eval 'setTimeout(function () { location.href = "about:sites?clear=*&type=all" }, 0)'
    $null = Wait-Until { (Tab-Url) -like 'about:sites*' }
    Check 'a page can open about:sites, without its query: the address is about:sites' ((Tab-Url) -eq 'about:sites') (Tab-Url)
    $null = Wren-Ctl key F5
    Start-Sleep -Milliseconds 600
    $null = Wren-Nav $page
    Check 'F5 on it cleared nothing' ((Stored) -eq 'kept') "got $(Stored)"
    $null = Wren-Ctl back
    Start-Sleep -Milliseconds 600
    $null = Wren-Ctl forward
    Start-Sleep -Milliseconds 600
    $null = Wren-Nav $page
    Check 'Back and Forward over it cleared nothing' ((Stored) -eq 'kept') "got $(Stored)"

    # --- a page asks for a file of this computer, and for a share (the loopback admin share names this very file)
    $unc = 'file://127.0.0.1/' + (($secret -replace '^([A-Za-z]):', '$1$$') -replace '\\', '/')
    foreach ($case in @(@('a local file', $secretUrl), @('a share', $unc))) {
        $what, $address = $case
        $null = Wren-Eval "setTimeout(function () { location.href = '$address' }, 0)"
        $null = Wait-Until { (Wren-Ctl console) -match 'Blocked' }
        Check "a page asking for $what is refused in its console" ((Wren-Ctl console) -match 'Blocked: a web page cannot open a file') (Wren-Ctl console)
        Check "...and the tab stays on the page ($what)" ((Tab-Url) -eq $page) (Tab-Url)
        $null = Wren-Ctl reload
        Start-Sleep -Milliseconds 800
        Check "...and F5 does not open it ($what)" ((Tab-Url) -eq $page -and (Wren-Eval 'document.title') -notmatch 'LOCAL-SECRET') "$(Tab-Url) / $(Wren-Eval 'document.title')"
    }

    # --- what the person types still works
    $null = Wren-Nav $secretUrl
    Check 'typed in the address bar, a file opens' ((Wren-Eval 'document.title') -eq 'LOCAL-SECRET') (Tab-Url)
    $null = Wren-Ctl reload
    Start-Sleep -Milliseconds 800
    Check '...and F5 shows it again' ((Wren-Eval 'document.title') -eq 'LOCAL-SECRET') (Tab-Url)
    $null = Wren-Nav $page
    $null = Wren-Eval 'localStorage.setItem("nav_trust", "again")'
    $null = Wren-Nav 'about:sites?clear=*&type=all'
    $null = Wren-Nav $page
    Check 'typed in the address bar, about:sites?clear=... clears the data' ((Stored) -eq 'null') "got $(Stored)"

    # --- the page of the browser acts through its own links
    $null = Wren-Eval 'localStorage.setItem("nav_trust", "link")'
    $null = Wren-Nav 'about:sites'
    $null = Wren-Ctl click --selector 'a.clear'
    Start-Sleep -Milliseconds 800
    $null = Wren-Nav $page
    Check "about:sites' own Clear all link clears the data" ((Stored) -eq 'null') "got $(Stored)"

    # --- going back to an entry that was typed with a clear does not clear again
    $null = Wren-Eval 'localStorage.setItem("nav_trust", "history")'
    $null = Wren-Nav 'about:sites?clear=*&type=all'
    $null = Wren-Nav $page
    $null = Wren-Eval 'localStorage.setItem("nav_trust", "after")'
    $null = Wren-Ctl back
    Start-Sleep -Milliseconds 600
    $null = Wren-Ctl forward
    Start-Sleep -Milliseconds 600
    Check 'Back to the typed clear and Forward again do not clear a second time' ((Stored) -eq 'after') "got $(Stored)"
} finally {
    if ($env:WREN_REMOTE) { Stop-Wren }
    Stop-WrenTestServer $server
    Remove-Item $secret -ErrorAction SilentlyContinue
}
if ($script:fail -gt 0) { "$script:fail check(s) failed"; exit 1 }
'nav_trust_e2e: all checks passed'
